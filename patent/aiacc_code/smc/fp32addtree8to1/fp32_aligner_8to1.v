//=========================================================================
// Project   : FP32 Adder Tree
// File      : fp32_aligner.v
// Module    : fp32_aligner
// Author    : sunny
// Email     : 2042504725@qq.com
// Created   : 2025-08-20
// Modified  : 2025-11-06
// Version   : v1.1
//=========================================================================
// Description:
// - Align per-lane mantissas to global max exponent and build sticky
// - Verilog-2001 compliant; no functional changes
//
// IO Ports:
// - Inputs : i_signs, i_exponents_flat, i_mantissas_flat, i_is_zeros, i_is_infs, i_is_nans
// - Outputs: o_max_exponent, o_aligned_mantissas_flat, o_effective_signs
//=========================================================================
`include "fp32_defines.vh"

module fp32_aligner_8to1 #(
    parameter NUM_INPUTS = 8
) (
    input  wire [NUM_INPUTS-1:0]                     i_signs,
    input  wire [NUM_INPUTS*`FP32_EXP_WIDTH-1:0]     i_exponents_flat,  
    input  wire [NUM_INPUTS*`FP32_MANT_WIDTH-1:0]    i_mantissas_flat, 
    input  wire [NUM_INPUTS-1:0]                     i_is_zeros,
    input  wire [NUM_INPUTS-1:0]                     i_is_infs,
    input  wire [NUM_INPUTS-1:0]                     i_is_nans,

    output wire [`FP32_EXP_WIDTH-1:0]                o_max_exponent,
    output wire [NUM_INPUTS*`ALIGNED_MANT_WIDTH-1:0] o_aligned_mantissas_flat, 
    output wire [NUM_INPUTS-1:0]                     o_effective_signs
);

    // ==================== 阶段1：找到最大指数 ====================
    // 仅对有限且非零（排除 Inf/NaN/Zero）参与最大指数比较；
    wire [`FP32_EXP_WIDTH-1:0] w_exp_cand [0:NUM_INPUTS-1]; //exponent candidate
    wire [NUM_INPUTS-1:0]      w_valid;
    genvar i;
    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : gen_exp_cand
            wire [`FP32_EXP_WIDTH-1:0] w_exp_i = i_exponents_flat[i*`FP32_EXP_WIDTH +: `FP32_EXP_WIDTH];
            wire w_finite = !(i_is_infs[i] | i_is_nans[i]);
            wire w_nonzero = !i_is_zeros[i];
            assign w_valid[i]   = w_finite & w_nonzero;
            assign w_exp_cand[i] = {`FP32_EXP_WIDTH{w_valid[i]}} & w_exp_i;
        end
    endgenerate

    // 线性归约求最大候选指数
    wire [`FP32_EXP_WIDTH-1:0] w_max_pipe [0:NUM_INPUTS];
    assign w_max_pipe[0] = {`FP32_EXP_WIDTH{1'b0}};
    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : gen_max_reduce
            assign w_max_pipe[i+1] = (w_exp_cand[i] > w_max_pipe[i]) ? w_exp_cand[i] : w_max_pipe[i];
        end
    endgenerate

    assign o_max_exponent = w_max_pipe[NUM_INPUTS];

    // ==================== 阶段2：尾数对齐逻辑 ====================
    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : align_mantissa
            wire [`FP32_EXP_WIDTH-1:0] exp_in    = i_exponents_flat[i*`FP32_EXP_WIDTH +: `FP32_EXP_WIDTH];
            wire [`FP32_MANT_WIDTH-1:0] mant_in  = i_mantissas_flat[i*`FP32_MANT_WIDTH +: `FP32_MANT_WIDTH];
            
            // 使用 (exp_in==0 && mant_in!=0) 判定 subnormal（避免与 is_zeros 矛盾组合）
            wire w_is_sub = (exp_in == 0) && (mant_in != {`FP32_MANT_WIDTH{1'b0}});
            wire [`FP32_EXP_WIDTH-1:0] w_exp_eff = (w_is_sub && (o_max_exponent != 0)) ? 1 : exp_in; //effective exponent
            
            // 计算右移位数
            wire [`FP32_EXP_WIDTH-1:0] w_exp_diff = (w_exp_eff < o_max_exponent) ? (o_max_exponent - w_exp_eff) : 0;
            wire w_shift_ovf = (w_exp_diff >= `ALIGNED_MANT_WIDTH);
            wire [$clog2(`ALIGNED_MANT_WIDTH)-1:0] w_shift = w_shift_ovf ? (`ALIGNED_MANT_WIDTH-1) : w_exp_diff;
            
            // 尾数预处理：正规数含隐藏位；Zero/Subnormal/Special 为 0
            wire w_has_ibh = (exp_in != 0);
            
            wire [`ALIGNED_MANT_WIDTH-1:0] w_mant_shifted = ({ {w_has_ibh, mant_in}, {`GUARD_BITS{1'b0}} } >> w_shift);

            // 低位掩码（不含 MSB 位）：低 shift 位置 1，其余 0
            wire [`ALIGNED_MANT_WIDTH-2:0] w_lower_mask = (w_shift == 0)
                                        ? {(`ALIGNED_MANT_WIDTH-1){1'b0}}
                                        : ((({{(`ALIGNED_MANT_WIDTH-2){1'b0}}, 1'b1} << w_shift) - 1'b1));
            // 粘滞位：与 {1'b0, w_lower_mask} 相与后归约或
            wire w_sticky = |( ({ {w_has_ibh, mant_in}, {`GUARD_BITS{1'b0}} }) & {1'b0, w_lower_mask} );
            
            // 对齐后尾数（特殊值尾数为 0）
            wire w_is_special = i_is_zeros[i] | i_is_infs[i] | i_is_nans[i];
            wire [`ALIGNED_MANT_WIDTH-1:0] w_mant_aligned = w_is_special ? 0 : 
                {w_mant_shifted[`ALIGNED_MANT_WIDTH-1:1], (w_mant_shifted[0] | w_sticky)};
            
            assign o_aligned_mantissas_flat[i*`ALIGNED_MANT_WIDTH +: `ALIGNED_MANT_WIDTH] = w_mant_aligned;
        end
    endgenerate

    assign o_effective_signs = i_signs;

endmodule