# FP32 加法树 5to1 数据分解与计算公式

> 源文件：`rtl/smc/fp32addtree5to1/fp32_adder_tree_final_pipeline_5to1.v`
> 模块：`fp32_adder_tree_final_pipeline_5to1`

---

## 一、端口概览

| 方向 | 名称 | 位宽 | 说明 |
|------|------|------|------|
| Input | `dvr_fp32addtree5to1_s0 ~ s7` | 8 × 128 bit | 8 组源寄存器，每组含 4 个 FP32 |
| Output | `dr_fp32addtree5to1_d0` | 128 bit | 4 × FP32 结果（通道 0~3） |
| Output | `dr_fp32addtree5to1_d1` | 128 bit | 4 × FP32 结果（通道 4~7） |

---

## 二、数据分解（以 FP32 为单位）

### 1. 输入分解

每个 128-bit 源寄存器按 **4 × FP32** 切分（lane0 = bit[31:0]，lane3 = bit[127:96]）：

$$
S_i = \{\,S_i[3],\; S_i[2],\; S_i[1],\; S_i[0]\,\},\quad i = 0,1,\dots,7
$$

### 2. 反馈累加项

每个加法通道有一份"旧值" $old_i$，等于该通道上一次的输出（来自 Stage 4 的寄存器 `add_result_stage4[i]`）：

$$
old_i = \text{add\_result}_i^{(t-1)}
$$

---

## 三、计算公式（FP32 加法）

模块例化 **8 路并行的 5-input FP32 加法器**，第 $i$ 路的 5 个输入为
`{Si[0], Si[1], Si[2], Si[3], old_i}`：

$$
\boxed{\;\text{add\_result}_i \;=\; S_i[0] \;+\; S_i[1] \;+\; S_i[2] \;+\; S_i[3] \;+\; old_i\;},\quad i=0,1,\dots,7
$$

即每个通道完成 **"4 个新 FP32 + 1 个累加 FP32"** 的 5-to-1 浮点求和。

---

## 四、输出组装（4 × FP32 → 128-bit）

两个 128-bit 目的寄存器按 lane 顺序打包：

$$
D_0 = \{\,\text{add\_result}_3,\; \text{add\_result}_2,\; \text{add\_result}_1,\; \text{add\_result}_0\,\}
$$

$$
D_1 = \{\,\text{add\_result}_7,\; \text{add\_result}_6,\; \text{add\_result}_5,\; \text{add\_result}_4\,\}
$$

---

## 五、整体一句话总结

> 把 8 个源寄存器各拆成 4 个 FP32，分别送入 8 路加法器；每路 $i$ 计算
> $\text{add\_result}_i = \sum_{k=0}^{3} S_i[k] + \text{add\_result}_i^{(t-1)}$ ，
> 再将 `add_result[0:3]` 拼成 `D0`、`add_result[4:7]` 拼成 `D1`。

---

## 六、数据流示意

```
S0[127:0] ──► [S0[3] | S0[2] | S0[1] | S0[0]] ──┐
                                                 ├─► Adder0 (5-to-1 FP32) ──► add_result[0] ─┐
                                  old_0 (反馈) ──┘                                            │
                                                                                              ├─► D0[127:0]
S1 ─► [S1[3..0]] ─► Adder1 + old_1 ─► add_result[1] ──────────────────────────────────────────┤
S2 ─► [S2[3..0]] ─► Adder2 + old_2 ─► add_result[2] ──────────────────────────────────────────┤
S3 ─► [S3[3..0]] ─► Adder3 + old_3 ─► add_result[3] ──────────────────────────────────────────┘

S4 ─► [S4[3..0]] ─► Adder4 + old_4 ─► add_result[4] ─┐
S5 ─► [S5[3..0]] ─► Adder5 + old_5 ─► add_result[5] ─┤
                                                     ├─► D1[127:0]
S6 ─► [S6[3..0]] ─► Adder6 + old_6 ─► add_result[6] ─┤
S7 ─► [S7[3..0]] ─► Adder7 + old_7 ─► add_result[7] ─┘
```
