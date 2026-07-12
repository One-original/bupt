`ifndef FP32_DEFINES_VH
`define FP32_DEFINES_VH

// 引用全局定义
`include "global_defines.vh"

// `define USE_FPGA_IP // 使用FPGA IP
// 对齐阶段参数
//`define GUARD_BITS 23//当前pass最小值
`define GUARD_BITS 24

// 对齐后的尾数宽度 (隐藏位 + 尾数 + GRS)
`define ALIGNED_MANT_WIDTH (1+ `FP32_MANT_WIDTH + `GUARD_BITS)// 1代表隐藏位24+21=45

// 最终累加总线位宽：幅度位 + 进位增长 + 符号位
`define FULL_SUM_WIDTH (`ALIGNED_MANT_WIDTH + $clog2(5) +1)//49

`define NORM_IN_WIDTH `FULL_SUM_WIDTH

// ============================================================================
// IEEE-754 Rounding Mode Definitions
// ============================================================================
`define RM_RNE  3'b000  // Round to Nearest, ties to Even (default)
`define RM_RTZ  3'b001  // Round Towards Zero
`define RM_RDN  3'b010  // Round Down (towards -¡Þ)
`define RM_RUP  3'b011  // Round Up (towards +¡Þ)
`define RM_RMM  3'b100  // Round to Nearest, ties to Max magnitude

// ============================================================================
// IEEE-754 Exception Flag Definitions
// ============================================================================
`define EXC_INVALID    0  // Invalid Operation
`define EXC_DIV_ZERO   1  // Division by Zero (N/A for adder)
`define EXC_OVERFLOW   2  // Overflow
`define EXC_UNDERFLOW  3  // Underflow
`define EXC_INEXACT    4  // Inexact

`endif

