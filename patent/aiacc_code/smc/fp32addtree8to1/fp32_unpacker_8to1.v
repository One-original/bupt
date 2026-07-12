//=========================================================================
// Project   : FP32 Adder Tree
// File      : fp32_unpacker.v
// Module    : fp32_unpacker
// Author    : sunny
// Email     : 2042504725@qq.com
// Created   : 2025-08-20
// Modified  : 2025-11-06
// Version   : v1.1
//=========================================================================
// Description:
// - Unpack FP32 into sign/exponent/mantissa and detect zero/inf/nan
// - Verilog-2001 compliant;
//
// IO Ports:
// - Input : fp_in (FP32)
// - Outputs: sign, exponent, mantissa, is_zero, is_inf, is_nan
//
// Dependencies:
// - `../define/fp32_defines.vh`
//
// Revision History:
// - v1.1 (2025-11-06)
//=========================================================================
`include "fp32_defines.vh"

module fp32_unpacker_8to1 #(
    parameter IEEE_754 = 1
)(
    input  wire [`FP32_WIDTH-1:0]       i_fp_in,    // FP32 输入

    output wire                         o_sign,     // 符号位
    output wire [`FP32_EXP_WIDTH-1:0]   o_exponent, // 指数位 
    output wire [`FP32_MANT_WIDTH-1:0]  o_mantissa, // 尾数位
    output wire                         o_is_zero,  // 输入是否为 0
    output wire                         o_is_inf,   // 输入是否为无穷大
    output wire                         o_is_nan    // 输入是否为 NaN
);
    // 直接分解
    assign o_sign = i_fp_in[`FP32_WIDTH-1];
    assign o_exponent = i_fp_in[`FP32_WIDTH-2 : `FP32_MANT_WIDTH];

    // 特殊情况检测
    wire exp_all_zeros;
    wire exp_all_ones;
    wire mant_all_zeros;
    
    assign exp_all_zeros = (o_exponent == {`FP32_EXP_WIDTH{1'b0}});
    assign exp_all_ones  = (o_exponent == {`FP32_EXP_WIDTH{1'b1}});
    
    // 使用 generate 块进行条件编译
    generate
        if (IEEE_754 == 1) begin : gen_ieee754
            // IEEE 754 模式：直接提取尾数
            assign o_mantissa = i_fp_in[`FP32_MANT_WIDTH-1 : 0];
            assign mant_all_zeros = (o_mantissa == {`FP32_MANT_WIDTH{1'b0}});
            // 是否为零 (包括 +0 和 -0)
            assign o_is_zero = exp_all_zeros && mant_all_zeros;
        end else begin : gen_non_ieee754
            // 非 IEEE 754 模式：如果指数全0，尾数强制为0
            assign o_mantissa = exp_all_zeros ? {`FP32_MANT_WIDTH{1'b0}} : i_fp_in[`FP32_MANT_WIDTH-1 : 0];
            assign mant_all_zeros = (o_mantissa == {`FP32_MANT_WIDTH{1'b0}});
            // 是否为零：仅检查指数
            assign o_is_zero = exp_all_zeros;
        end
    endgenerate

    // 是否为无穷大 (指数全1，尾数全0)
    assign o_is_inf = exp_all_ones && mant_all_zeros;
    // 是否为 NaN (指数全1，尾数非0)
    assign o_is_nan = exp_all_ones && !mant_all_zeros;

endmodule
