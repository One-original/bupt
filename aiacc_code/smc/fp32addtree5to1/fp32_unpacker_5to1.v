`include "fp32_defines.vh"

module fp32_unpacker_5to1 #(
    parameter IEEE_754 = 1
)(
    input wire [`FP32_WIDTH-1:0] fp_in,       // FP32 输入

    output wire sign,                         // 符号位
    output wire [`FP32_EXP_WIDTH-1:0] exponent,    // 指数位 
    output wire [`FP32_MANT_WIDTH-1:0] mantissa,   // 尾数位
    output wire is_zero,                      // 输入是否为 0
    output wire is_inf,                       // 输入是否为无穷大
    output wire is_nan                       // 输入是否为 NaN
);
    wire exp_all_zeros;
    wire exp_all_ones;
    wire mant_all_zeros;

    // 直接分解
    assign sign = fp_in[`FP32_WIDTH-1];
    assign exponent = fp_in[`FP32_WIDTH-2 : `FP32_MANT_WIDTH];

    // 特殊情况检测
    assign exp_all_zeros = (exponent == {`FP32_EXP_WIDTH{1'b0}});
    assign exp_all_ones = (exponent == {`FP32_EXP_WIDTH{1'b1}});
    
    // 使用 generate 块进行条件编译
    generate
        if (IEEE_754 == 1) begin : gen_ieee754
            // IEEE 754 模式：直接提取尾数
            assign mantissa = fp_in[`FP32_MANT_WIDTH-1 : 0];
            assign mant_all_zeros = (mantissa == {`FP32_MANT_WIDTH{1'b0}});
            // 是否为零 (包括 +0 和 -0)
            assign is_zero = exp_all_zeros && mant_all_zeros;
        end else begin : gen_non_ieee754
            // 非 IEEE 754 模式：如果指数全0，尾数强制为0
            assign mantissa = exp_all_zeros ? {`FP32_MANT_WIDTH{1'b0}} : fp_in[`FP32_MANT_WIDTH-1 : 0];
            assign mant_all_zeros = (mantissa == {`FP32_MANT_WIDTH{1'b0}});
            // 是否为零：仅检查指数
            assign is_zero = exp_all_zeros;
        end
    endgenerate
    
    // 是否为无穷大 (指数全1，尾数全0)
    assign is_inf = exp_all_ones && mant_all_zeros;
    // 是否为 NaN (指数全1，尾数非0)
    assign is_nan = exp_all_ones && !mant_all_zeros;

endmodule