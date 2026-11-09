`include "fp32_defines.vh"

module fp32_packer_5to1 #(
    parameter IEEE_754 = 1
)(
    input wire final_sign,
    input wire [`FP32_EXP_WIDTH-1:0] final_exponent, 
    input wire [`FP32_MANT_WIDTH-1:0] final_mantissa, 
    input wire result_is_zero, 
    input wire result_is_inf,  
    input wire result_is_nan,  

    output wire [`FP32_WIDTH-1:0] fp_out 
);

    // 定义标准特殊值表示
    localparam FP32_QNAN     = {1'b0, {`FP32_EXP_WIDTH{1'b1}}, {1'b1, {(`FP32_MANT_WIDTH-1){1'b0}}}}; // 标准 Quiet NaN (符号位通常为0)
    localparam FP32_POS_INF  = {1'b0, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
    localparam FP32_NEG_INF  = {1'b1, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
    localparam FP32_POS_ZERO = {1'b0, {(`FP32_EXP_WIDTH + `FP32_MANT_WIDTH){1'b0}}};
    localparam FP32_NEG_ZERO = {1'b1, {(`FP32_EXP_WIDTH + `FP32_MANT_WIDTH){1'b0}}};

    // 根据特殊情况标志选择最终输出
    generate
        if (IEEE_754 == 1) begin : gen_ieee754
            assign fp_out = result_is_nan ? FP32_QNAN :
                            result_is_inf ? (final_sign ? FP32_NEG_INF : FP32_POS_INF) :
                            result_is_zero ? (final_sign ? FP32_NEG_ZERO : FP32_POS_ZERO) :
                            {final_sign, final_exponent, final_mantissa}; // Normal number
        end else begin : gen_non_ieee754
            wire exp_0;
            assign exp_0 = (final_exponent == {`FP32_EXP_WIDTH{1'b0}});
            assign fp_out = result_is_nan ? {1'b0, {`FP32_EXP_WIDTH{1'b1}}, {1'b1, {(`FP32_MANT_WIDTH-1){1'b1}}}} :
                            result_is_inf ? (final_sign ? FP32_NEG_INF : FP32_POS_INF) :
                            (result_is_zero || exp_0) ? (final_sign ? FP32_NEG_ZERO : FP32_POS_ZERO) :
                            {final_sign, final_exponent, final_mantissa}; // Normal number
        end
    endgenerate

endmodule