# LOAD_STORE_V2 — 多 SMC Load→Compute→Store 融合测试框架

本框架把 **Load（从 DDR/HBM 搬数据到 UR）→ Compute（算子计算）→ Store（结果写回 DDR/HBM）** 的完整数据通路抽象为公共能力。算子开发者只需实现少量接口，即可一键生成 8-SMC 的 RTL 测试用例并跑通验证。

已验证算子：`mul`、`bitwise_and`（纯 Compute 与 Load-Compute-Store 全流程均 pass=8）。

---

## 目录

1. [整体架构](#1-整体架构)
2. [数据流与 HBM/UR 地址布局](#2-数据流与-hbmur-地址布局)
3. [多 SMC 与 NoC 分窗机制](#3-多-smc-与-noc-分窗机制)
4. [文件结构](#4-文件结构)
5. [核心接口说明](#5-核心接口说明)
6. [接入一个新算子（分步指南）](#6-接入一个新算子分步指南)
7. [编译与运行](#7-编译与运行)
8. [常见问题排查](#8-常见问题排查)
9. [已知限制](#9-已知限制)

---

## 1. 整体架构

```
                    LsuOpBase（公共基类）
                          │
            ┌─────────────┴─────────────┐
            │                           │
       MulLsuOp                   BwAndLsuOp
       （算子子类，每个只实现 3 个虚函数）
```

公共基类 `LsuOpBase` 负责：
- 根据"计算描述"（`LsuComputeDesc`）**自动计算** Load/Store 的 LDB/LDBAXI/STB/STBAXI 微指令参数
- 生成 8 个 SMC 的 HBM 初始数据（每个 SMC 不同随机 seed）
- 组装完整 case 目录（IQ hex、UR bank、golden）

算子子类只负责：
- 提供 Compute 的 IQ 指令（调用各自的 `XxxOp::compile()`）
- 提供 golden 计算逻辑（软件参考结果）
- 提供 bank/数据量配置

---

## 2. 数据流与 HBM/UR 地址布局

以 mul（2 输入）为例：

```
 DDR (memory_initN.hex)            UR (8 banks × 256 lines)        DDR (hbm_result)
┌────────────────────┐          ┌────────────────────┐         ┌────────────────────┐
│ line 0..254  input │── Load1 ─→│ bank0 (input)      │         │                    │
│ line 255     (gap) │          │                    │         │                    │
│ line 256..510 other│── Load2 ─→│ bank1 (other)      │         │                    │
│                    │          │        │ Compute    │         │                    │
│                    │          │        ▼            │         │                    │
│                    │          │ bank3 (result)     │── Store ─→│ line 512..766      │
└────────────────────┘          └────────────────────┘         └────────────────────┘
```

关键常量：
- **1 word = 1 UR line = 128 bit = 16 bytes**
- UR bank 深度 = 256 lines（line 0~255）
- 每个输入段之间留 1 行 gap（地址对齐用，`gr_base = (前序总word数 + 1) × 16`）

地址自动计算（`lsu_op_base.cpp`）：
- `input_gr_base(name)`：按 `inputs` map 迭代顺序累加 `(word_count+1)*16`
- `store_gr_base()`：所有输入之后

---

## 3. 多 SMC 与 NoC 分窗机制

仿真里有 **8 个物理独立的 HBM**（`memory_init1.hex` ~ `memory_init8.hex`），通过 NoC 路由到不同地址窗口：

| SMC | HBM 文件 | NoC 地址窗口 |
|-----|----------|--------------|
| 0 | memory_init1.hex | 0x00000000 ~ 0x0FFFFFFF |
| 1 | memory_init2.hex | 0x10000000 ~ 0x1FFFFFFF |
| ... | ... | ... |
| 7 | memory_init8.hex | 0x70000000 ~ 0x7FFFFFFF |

**`gr_intlv_addr = 0x10000000`** 让同一条 LDB/STB 指令在不同 SMC 上自动偏移到各自的 HBM 窗口：

```
SMC_n 实际地址 = gr_base_addr + n × gr_intlv_addr
```

8 个 SMC 执行同一套指令，但各自访问独立的 HBM 区域，互不干扰。

---

## 4. 文件结构

### 框架核心（必须）
```
load_store_v2/
├── lsu_op_base.h          # 公共基类 + 三个配置结构体
└── lsu_op_base.cpp        # Load/Store 参数计算、IQ 生成、case 组装
```

### 算子子类（每个算子一套）
```
load_store_v2/mul/
├── mul_lsu_op.h
├── mul_lsu_op.cpp
load_store_v2/gen_mul_lsu_case.cpp     # mul 入口（在根目录）

load_store_v2/bitwise_and/
├── bw_and_lsu_op.h
├── bw_and_lsu_op.cpp
└── gen_bw_and_lsu_case.cpp
```

### 依赖（复用现有，无需修改）
```
op/common/lsu_emit.h / lsu_emit.cpp     # emit_load_iq_files / emit_store_iq_files
iq/modules/ldb_iq.* / stb_iq.*          # LDB/STB/LDBAXI/STBAXI 微指令打包
op/<operator>/                          # 各算子原有的 compile 实现
```

### 构建与测试
```
Makefile               # 编译 tvgen（已排除 *_main.cpp）
run_rtl_test.sh        # 一键测试脚本
```

### RTL 侧（已改）
```
../../../Jianyuan_aiacc_v4.19/tb_aiacc_top_v04_f.v
    - 三相触发：Phase1 LOAD → Phase2 COMPUTE → Phase3 STORE
    - 每相等待 100000 周期（支持多迭代/慢算子）
```

---

## 5. 核心接口说明

### 5.1 配置结构体

```cpp
struct PortInfo {
    uint8_t  bank;          // UR bank 编号 (0~7)
    uint16_t word_offset;   // bank 内起始 word
    uint16_t word_count;    // word 数量（≤255）
};

struct LsuComputeDesc {
    std::map<std::string, PortInfo> inputs;   // 命名输入端口（任意个）
    PortInfo output;                          // 单个输出端口
    uint8_t  num_smc{8};                      // SMC 数量
    uint8_t  smc_id_en{7};                    // = num_smc - 1
    uint64_t gr_intlv_addr{0x10000000ULL};    // SMC 间地址步长（v4.19 固定）
};

struct LsuCaseConfig {
    std::string case_name;     // case 名
    std::string case_root;     // case 输出目录（绝对路径）
    std::string hbm_init_dir;  // memory_init*.hex 输出目录
    uint32_t    seed_base{42}; // 随机数据种子
};
```

### 5.2 子类必须实现的虚函数

| 虚函数 | 作用 |
|--------|------|
| `get_name()` | 返回算子名（用于 tvgen 识别，须与 `XxxOp::get_name()` 一致） |
| `generate_compute_iq_files()` | 调用算子的 `compile()` 生成 Compute IQ 指令 |
| `generate_golden_for_smc(smc, input_datas, golden)` | 软件参考结果，`input_datas` 是按名字索引的输入数据 |

### 5.3 基类自动完成的工作

| 方法 | 作用 |
|------|------|
| `build_load_params()` | 计算 LDB+LDBAXI 参数（ur_addr/loops/gr_base...） |
| `generate_load_iq_files()` | 遍历 inputs 生成 N 条 Load 指令 |
| `generate_store_iq_files()` | 生成 Store 指令 |
| `generate_hbm_data()` | 为每个 SMC 生成随机 HBM 数据 |
| `assemble_full_case()` | 组装完整 case（IQ hex + UR + HBM + golden） |

---

## 6. 接入一个新算子（分步指南）

以接入 `add` 算子为例（2 输入，输出到 bank2）。

### 步骤 1：创建 `load_store_v2/add/add_lsu_op.h`

```cpp
#ifndef ADD_LSU_OP_H
#define ADD_LSU_OP_H
#include "../lsu_op_base.h"
#include "../../op/add/add_op.h"          // 算子原有头文件

namespace aiacc { namespace lsu {

class AddLsuOp : public LsuOpBase {
public:
    std::string get_name() const override { return "Add"; }   // 与 AddOp::get_name() 一致
    std::vector<op::IqInstructionFile> generate_compute_iq_files() const override;
    void generate_golden_for_smc(
        uint8_t smc_id,
        const std::map<std::string, std::vector<uint8_t>>& input_datas,
        std::vector<uint8_t>& golden_out) const override;
    static LsuComputeDesc default_compute_desc();
};

}} // namespace
#endif
```

### 步骤 2：创建 `load_store_v2/add/add_lsu_op.cpp`

```cpp
#include "add_lsu_op.h"
#include <cstring>

namespace aiacc { namespace lsu {

LsuComputeDesc AddLsuOp::default_compute_desc() {
    LsuComputeDesc d;
    d.inputs["input"] = {0, 0, 255};   // bank0
    d.inputs["other"] = {1, 0, 255};   // bank1
    d.output          = {2, 0, 255};   // bank2（按算子实际输出 bank 填）
    d.num_smc = 8;
    d.smc_id_en = 7;
    d.gr_intlv_addr = 0x10000000ULL;
    return d;
}

std::vector<op::IqInstructionFile> AddLsuOp::generate_compute_iq_files() const {
    op::AddOpParams params;
    params.para_n = 1; params.para_c = 1; params.para_h = 1;
    params.para_w = desc_.output.word_count * 4;   // word 数 × 每 word 元素数
    params.para_input_bank  = desc_.inputs.at("input").bank;
    params.para_other_bank  = desc_.inputs.at("other").bank;
    params.para_output_bank = desc_.output.bank;
    // ... 其余 addr 参数

    op::AddOp op;
    auto insts = op.compile(params);
    return insts.get_iq_files();   // 普通算子用 get_iq_files()
}

void AddLsuOp::generate_golden_for_smc(
    uint8_t, const std::map<std::string, std::vector<uint8_t>>& in,
    std::vector<uint8_t>& golden) const {
    const auto& a = in.at("input");
    const auto& b = in.at("other");
    uint32_t n = a.size() / 4;
    golden.resize(n * 4);
    for (uint32_t i = 0; i < n; ++i) {
        float fa, fb; std::memcpy(&fa, &a[i*4], 4); std::memcpy(&fb, &b[i*4], 4);
        float r = fa + fb;                       // 算子的参考语义
        std::memcpy(&golden[i*4], &r, 4);
    }
}

}} // namespace
```

### 步骤 3：创建 `load_store_v2/add/gen_add_lsu_case.cpp`

直接拷贝 `gen_mul_lsu_case.cpp`，把 `MulLsuOp` 换成 `AddLsuOp`、case 名换成 `add_lsu_test` 即可。

### 步骤 4：在 `run_rtl_test.sh` 注册 add

在脚本顶部的 map 里加：
```bash
OP_NAME_MAP[add]="Add"
OP_INPUT_BANK[add]=0
OP_OTHER_BANK[add]=1
OP_OUTPUT_BANK[add]=2
```

### 步骤 5：一键测试

```bash
./run_rtl_test.sh add --lsu --rebuild
```

---

## 7. 编译与运行

### 一键脚本（推荐）

```bash
cd Multi_SMC_SMI_IQ

# 纯 Compute 测试（8 SMC，带波形）
./run_rtl_test.sh mul --rebuild
./run_rtl_test.sh bitwise_and --rebuild

# Load→Compute→Store 全流程测试
./run_rtl_test.sh mul --lsu --rebuild
./run_rtl_test.sh bitwise_and --lsu --rebuild

# 指定随机种子
./run_rtl_test.sh mul --lsu --seed 12345 --rebuild
```

参数：
- `--lsu`：Load→Compute→Store 模式（不加则纯 Compute）
- `--seed N`：随机数据种子
- `--rebuild`：强制 VCS 全量重编（生成 KDB 波形数据库，Verdi 才能看代码）

### 脚本内部 5 步流程
```
[1/5] make tvgen                          # 编译 tvgen
[2/5] tvgen / LSU 生成器 生成微指令+数据   # 生成 IQ hex、HBM 数据、golden
[3/5] generate_data_list_coverage.py      # 展开 IQ → iq_inst_*.txt + data_list
[4/5] run_sim_aiacc_top_f.sh              # VCS 编译 + RTL 仿真 + 三相触发
[5/5] compare_ur_to_golden.py             # 比对结果
```

### 结果与波形
```
日志:  /tmp/<case>_rtl.log
波形:  Jianyuan_aiacc_v4.19/sim_output_aiacc_top_f/verification_v2_fsdb/.../*.fsdb

# 打开波形（--rebuild 后才有代码）
verdi -ssf <波形路径> &
```

---

## 8. 常见问题排查

| 现象 | 原因 | 解决 |
|------|------|------|
| compile multiple definition of `main` | 算子目录有 `*_main.cpp` | Makefile 已排除 `*_main.cpp` |
| tvgen 报 `Failed to get operator` | 算子名大小写不对 | 用 `XxxOp::get_name()` 的精确名字 |
| compare fail，dump 全零 | Compute 没执行 | 检查 IQ 文件名、output bank |
| bank dump 错位 1 行 | LDBAXI 多发 1 beat | HBM 数据要比读取量多 1 行 gap |
| Verdi 上半区无代码 | simv 没带 `-kdb` 编译 | 用 `--rebuild` 重新编译 |
| smc_0 fail 其余 pass | bulk 模式 beat 串扰 | 用 loops 模式（默认） |

---

## 9. 已知限制

| 项 | 当前状态 |
|----|----------|
| 输入端口数量 | 任意个（`map<string, PortInfo>`） |
| 输出端口 | 仅 1 个 |
| 单输入数据量 | ≤ 255 word（UR bank 深度） |
| SMC 数量 | 可配置（默认 8） |
| LDB/STB 模式 | header loops（稳定）；bulk 模式（`ur_wr_line_cnt=255`）在 smc_0 有 beat 串扰问题，未启用 |

---

## 附：已验证结果

| 算子 | 纯 Compute | Load→Compute→Store |
|------|-----------|---------------------|
| mul | pass=8 | pass=8 |
| bitwise_and | pass=8 | pass=8 |
