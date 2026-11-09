// ============================================================================
// 浮点格式参数定义 (IEEE 754标准)
// ============================================================================

// FP16 (Half Precision) 参数
`define FP16_WIDTH        16
`define FP16_EXP_WIDTH    5
`define FP16_MANT_WIDTH   10
`define FP16_BIAS         15
`define FP16_EXP_MAX      31
`define FP16_EXP_MIN      0
`define FP16_MANT_MAX     1023

// FP32 (Single Precision) 参数  
`define FP32_WIDTH        32
`define FP32_EXP_WIDTH    8
`define FP32_MANT_WIDTH   23
`define FP32_BIAS         127
`define FP32_EXP_MAX      255
`define FP32_EXP_MIN      0
`define FP32_MANT_MAX     8388607

// BFloat16 参数
`define BF16_WIDTH        16
`define BF16_EXP_WIDTH    8
`define BF16_MANT_WIDTH   7
`define BF16_BIAS         127

// ============================================================================
// 整数格式定义
// ============================================================================
`define INT8_WIDTH     8
`define INT16_WIDTH    16
`define INT32_WIDTH    32
`define INT64_WIDTH    64

// ============================================================================
// 调试和仿真用颜色定义
// ============================================================================
`define TEXT_RESET   "\033[0m"
`define TEXT_BLACK   "\033[0;30m"
`define TEXT_RED     "\033[0;31m"
`define TEXT_GREEN   "\033[0;32m"
`define TEXT_YELLOW  "\033[0;33m"
`define TEXT_BLUE    "\033[0;34m"
`define TEXT_MAGENTA "\033[0;35m"
`define TEXT_CYAN    "\033[0;36m"
`define TEXT_WHITE   "\033[0;37m"
