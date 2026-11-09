//=========================================================================
// Project   : FP32 Adder Tree
// File      : fp32_packer.v
// Module    : fp32_packer
// Author    : sunny
// Email     : 
// Created   : 2025-08-20
// Modified  : 2025-11-06
// Version   : v1.1
//=========================================================================
// Description:
// - Pack final FP32 fields with special-case handling
// - Verilog-2001 compliant; i_/o_ naming applied; no logic change
//=========================================================================
`include "fp32_defines.vh"

module fp32_packer_8to1 #(
    parameter IEEE_754 = 1
)(
    input  wire                    i_final_sign,
    input  wire [`FP32_EXP_WIDTH-1:0]  i_final_exponent, 
    input  wire [`FP32_MANT_WIDTH-1:0] i_final_mantissa, 
    input  wire                    i_result_is_zero, 
    input  wire                    i_result_is_inf,  
    input  wire                    i_result_is_nan,  

    output wire [`FP32_WIDTH-1:0]  o_fp_out 
);

    // 定义标准特殊值表示
    localparam FP32_QNAN     = {1'b0, {`FP32_EXP_WIDTH{1'b1}}, {1'b1, {(`FP32_MANT_WIDTH-1){1'b0}}}}; // 标准 Quiet NaN (符号位通常为0)
    localparam FP32_POS_INF  = {1'b0, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
    localparam FP32_NEG_INF  = {1'b1, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
    localparam FP32_POS_ZERO = {1'b0, {(`FP32_EXP_WIDTH + `FP32_MANT_WIDTH){1'b0}}};
    localparam FP32_NEG_ZERO = {1'b1, {(`FP32_EXP_WIDTH + `FP32_MANT_WIDTH){1'b0}}};
    
    // 使用 generate 块进行条件编译
    generate
        if (IEEE_754 == 1) begin : gen_ieee754
            // IEEE 754 模式：根据特殊情况标志选择最终输出
            assign o_fp_out = i_result_is_nan ? FP32_QNAN :
                              i_result_is_inf ? (i_final_sign ? FP32_NEG_INF : FP32_POS_INF) :
                              i_result_is_zero ? (i_final_sign ? FP32_NEG_ZERO : FP32_POS_ZERO) :
                              {i_final_sign, i_final_exponent, i_final_mantissa}; // Normal number
        end else begin : gen_non_ieee754
            // 非 IEEE 754 模式：指数为0时也输出零
            wire exp_0;
            assign exp_0 = (i_final_exponent == {`FP32_EXP_WIDTH{1'b0}});
            assign o_fp_out = i_result_is_nan ? {1'b0, {`FP32_EXP_WIDTH{1'b1}}, {1'b1, {(`FP32_MANT_WIDTH-1){1'b1}}}} :
                              i_result_is_inf ? (i_final_sign ? FP32_NEG_INF : FP32_POS_INF) :
                              (i_result_is_zero || exp_0) ? (i_final_sign ? FP32_NEG_ZERO : FP32_POS_ZERO) :
                              {i_final_sign, i_final_exponent, i_final_mantissa}; // Normal number
        end
    endgenerate
endmodule