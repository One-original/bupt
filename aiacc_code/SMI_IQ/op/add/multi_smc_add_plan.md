# Multi-SMC Add 当前方案：8 SMC Local UR Data-Parallel

## 1. 背景

本文档记录 `FusedScaleAdd` / Add 算子当前多 SMC 实现方案，对应代码：

```text
SMI_IQ/op/add/add_op_multi_stage1.cpp
```

原始 Add 语义为：

```text
out = input + alpha * other
```

当前多 SMC 方案不是跨 SMC 通信方案，而是 **8 SMC local UR 数据并行方案**：

```text
8 个 SMC 沿 W 维度切分输入数据。
每个 SMC 只处理自己的 local W 分片。
每个 SMC 使用自己的本地 UR 数据和自己的单 SMC Add 指令流。
SMC 之间不通信、不 reduce、不集中写回。
```

---

## 2. 当前总体方案

当前方案名称：

```text
multi_smc_local_add / data_parallel_local_ur
```

核心思想：

```text
1. 复用已有单 SMC Add 编译器 `AddOp::compile()`。
2. 全局 W 维度切成 8 段。
3. 每个 SMC 编译一套 local W 的 Add 指令。
4. 每个 SMC 装载自己的 input / other / alpha / output_zero UR 数据。
5. 每个 SMC 独立执行：out_local = input_local + alpha * other_local。
6. 最终结果由 8 个 SMC 的 local output 按 split 顺序拼接得到。
```

当前默认 SMC 数：

```text
smc_num = 8
```

---

## 3. 与旧 SHIFTUP/SHIFTDN 方案的区别

旧文档中曾描述过：

```text
SMC0 通过 SHIFTUP 把 alpha 发送给 SMC1
SMC1 从 DR_SHIFTUP_D 获取 alpha
后续可能通过 SHIFTDN 回传 partial/result
```

该方案已经过时，当前 `add_op_multi_stage1.cpp` 不实现这条路径。

当前实现明确为：

```text
communication = none
shiftup       = disabled
shiftdn       = disabled
reduce        = disabled
```

也就是说：

```text
不生成 SHIFTUP 指令
不生成 SHIFTDN 指令
不修改 RtoVR 输入源为 DR_SHIFTUP_D
不做 SMC 间数据传输
不做 SMC 间归约
不做集中写回
```

alpha 的处理方式也不同：

```text
旧方案：SMC0 发送 alpha，其他 SMC 接收 alpha。
当前方案：每个 SMC 的本地 UR bank2 都放同一个 alpha 128-bit word。
```

---

## 4. W 维度 8 路切分

当前只支持 local add 的一维 W 切分，约束为：

```text
N = 1
C = 1
H = 1
W = 全局元素数
```

默认均分时：

```text
SMC0: W[0 * W/8 : 1 * W/8)
SMC1: W[1 * W/8 : 2 * W/8)
SMC2: W[2 * W/8 : 3 * W/8)
SMC3: W[3 * W/8 : 4 * W/8)
SMC4: W[4 * W/8 : 5 * W/8)
SMC5: W[5 * W/8 : 6 * W/8)
SMC6: W[6 * W/8 : 7 * W/8)
SMC7: W[7 * W/8 : 8 * W/8)
```

代码支持两种切分方式：

```text
1. --smc-num 8
   由编译器按 W / 8 均分。

2. --split A,B,C,D,E,F,G,H
   用户显式指定 8 个 local W。
```

切分合法性要求：

```text
split 非空
split 数量不超过 32
每个 split width 非 0
所有 split width 之和必须等于全局 W
每个 split width 必须按 elems_per_word 对齐
```

其中：

```text
FP32: elems_per_word = 4
FP16: elems_per_word = 8
```

因此 8 SMC 均分时推荐：

```text
FP32: W 是 8 * 4 = 32 的倍数
FP16: W 是 8 * 8 = 64 的倍数
```

---

## 5. 每个 SMC 的本地计算流

每个 SMC 都复用单 SMC Add 的计算流：

```text
UR-R0: 读取 input_local
UR-R1: 读取 other_local
UR-R2: 读取 alpha word

RtoVR stage1:
  UR_RDATA_2 -> DVR_FPMUL_S0
  UR_RDATA_1 -> DVR_FPMUL_S1

FPMUL:
  alpha * other_local

RtoVR stage2:
  UR_RDATA_0 -> DVR_FPADD_S0
  DR_FPMUL_D -> DVR_FPADD_S1

FPADD:
  input_local + alpha * other_local

RtoVR stage3:
  DR_FPADD_D -> UVR_WDATA_0

UR-W0:
  写回 output_local
```

对 8 个 SMC 来说，区别只在于：

```text
smc_id 不同
local W 不同或相同
input_local slice 不同
other_local slice 不同
output_local slice 不同
IQ/UR 输出目录不同
```

计算指令本身仍然来自：

```text
AddOpInstructions inst = add.compile(local_params);
inst.get_iq_files();
```

---

## 6. 每个 SMC 的 UR 数据布局

每个 SMC 都有独立的本地 UR 数据目录：

```text
smc0_ur/
smc1_ur/
...
smc7_ur/
```

每个目录内的数据文件含义一致：

```text
bank0_input.bin / bank0_input.hex
bank1_other.bin / bank1_other.hex
bank2_alpha.bin / bank2_alpha.hex
bank3_output_zero.bin / bank3_output_zero.hex
```

对应关系：

```text
bank0_input       = input_bin 的当前 SMC slice
bank1_other       = other_bin 的当前 SMC slice
bank2_alpha       = alpha_bin 的第一个 128-bit word
bank3_output_zero = 当前 SMC local output 的零初始化 buffer
```

注意：

```text
bank2_alpha 不是通过 SHIFTUP 接收的。
每个 SMC 都直接在自己的 local UR bank2 中拥有 alpha word。
```

---

## 7. alpha 约定

当前 `make_tvgen_req()` 会通过 `AddOp::fill_random_request()` 生成测试请求，然后把 alpha 参数全部设置为命令行指定的 scalar：

```text
alpha_scalar 默认值 = 1.0
```

对于每个 SMC 的 local UR，只取：

```text
first_word(alpha_bin)
```

作为 `bank2_alpha`。

128-bit word 中包含的元素数量：

```text
FP32: 4 lanes
FP16: 8 lanes
```

因此当前方案等价于每个 SMC 本地读取同一个 alpha broadcast word。

---

## 8. 编译输出结构

standalone 工具运行后会生成一个输出目录，默认：

```text
out/multi_smc_add_stage1
```

目录中包含全局原始数据：

```text
input.bin / input.hex
other.bin / other.hex
alpha.bin / alpha.hex
golden.bin / golden.hex
summary.txt
multi_smc_config.json
```

以及每个 SMC 的 IQ 和 UR 数据：

```text
smc0_iq/
smc0_ur/
smc1_iq/
smc1_ur/
...
smc7_iq/
smc7_ur/
```

`summary.txt` 会记录：

```text
mode=data_parallel_local_ur
smc_num=8
split=...
ur_layout=local_address
communication=none
shiftup=disabled
shiftdn=disabled
reduce=disabled
```

`multi_smc_config.json` 会记录每个 SMC 的指令目录和 UR 数据目录。

---

## 9. 命令行参数

standalone 模式支持：

```text
--dtype fp32|fp16
--w W
--smc-num N
--split A,B,...
--alpha A
--seed S
--output DIR
```

默认参数：

```text
dtype   = fp32
W       = 16
smc_num = 8
alpha   = 1.0
seed    = 1
output  = out/multi_smc_add_stage1
```

注意：默认 `W=16` 与默认 `smc_num=8` 组合时，FP32 均分得到每个 SMC `local_w=2`，不满足 FP32 的 `elems_per_word=4` 对齐要求。因此实际运行 8 SMC FP32 时应显式指定满足对齐的 W，例如：

```text
--dtype fp32 --w 32 --smc-num 8
```

FP16 运行示例：

```text
--dtype fp16 --w 64 --smc-num 8
```

也可以显式指定 split，例如：

```text
--dtype fp32 --w 32 --split 4,4,4,4,4,4,4,4
```

---

## 10. golden 对比方式

`golden.bin` 是全局 W 的完整 golden：

```text
golden = input + alpha * other
```

每个 SMC 只产生自己的 local output。验证时需要按 split 顺序拼接 8 个 SMC 的 local output：

```text
output_all = concat(output_smc0,
                    output_smc1,
                    output_smc2,
                    output_smc3,
                    output_smc4,
                    output_smc5,
                    output_smc6,
                    output_smc7)
```

然后比较：

```text
output_all == golden
```

---

## 11. 当前限制

当前方案限制如下：

```text
仅支持 N=C=H=1 的 W 维切分
默认目标是 8 SMC，但代码也保留 --smc-num / --split 的通用能力
每个 split width 必须按 128-bit word 对齐
每个 SMC 本地写回自己的 output_local
不支持跨 SMC 通信
不支持 SHIFTUP alpha 分发
不支持 SHIFTDN 回传
不支持 reduce
不支持集中写回
```

如果后续要做真正的跨 SMC reduce 或集中写回，应单独设计新阶段，不应再把它描述为当前 8 SMC local UR data-parallel Add 方案的一部分。
