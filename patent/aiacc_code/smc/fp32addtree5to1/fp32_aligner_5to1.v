`include "fp32_defines.vh"

module fp32_aligner_5to1 #(
    parameter NUM_INPUTS = 8
) (
    input  wire [NUM_INPUTS-1:0]                     signs,
    input  wire [NUM_INPUTS*`FP32_EXP_WIDTH-1:0]     exponents_flat,  
    input  wire [NUM_INPUTS*`FP32_MANT_WIDTH-1:0]    mantissas_flat, 
    input  wire [NUM_INPUTS-1:0]                     is_zeros,
    input  wire [NUM_INPUTS-1:0]                     is_infs,
    input  wire [NUM_INPUTS-1:0]                     is_nans,

    output wire [`FP32_EXP_WIDTH-1:0]                max_exponent,
    output wire [NUM_INPUTS*`ALIGNED_MANT_WIDTH-1:0] aligned_mantissas_flat, 
    output wire [NUM_INPUTS-1:0]                     effective_signs
);

    // ==================== 阶段1：找到最大指数 ====================
    // 仅对有限且非零（非Inf/NaN/Zero）的数参与最大指数比较；
    // 注意：这里不提升非规格化数(exp=0且非零)为1，这样当所有有效数均为非规格化时，max_exponent可以为0，
    
    wire [`FP32_EXP_WIDTH-1:0] exp_candidates   [0:NUM_INPUTS-1];
    wire [NUM_INPUTS-1:0]      is_finite_nz;

    genvar i;
    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : gen_exp_cand
            wire [`FP32_EXP_WIDTH-1:0] exp_i  = exponents_flat[i*`FP32_EXP_WIDTH +: `FP32_EXP_WIDTH];
            wire is_finite              = !(is_infs[i] | is_nans[i]);
            wire is_nz                  = !is_zeros[i];
            assign is_finite_nz[i]      = is_finite & is_nz;
            assign exp_candidates[i] = {`FP32_EXP_WIDTH{is_finite_nz[i]}} & exp_i;
        end
    endgenerate

    // 线性归约求最大候选指数
    wire [`FP32_EXP_WIDTH-1:0] max_exp_pipeline [0:NUM_INPUTS];
    assign max_exp_pipeline[0] = {`FP32_EXP_WIDTH{1'b0}};
    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : gen_max_reduce
            assign max_exp_pipeline[i+1] = (exp_candidates[i] > max_exp_pipeline[i]) ?
                                            exp_candidates[i] : max_exp_pipeline[i];
        end
    endgenerate

    assign max_exponent = max_exp_pipeline[NUM_INPUTS];

    // ==================== 阶段2：尾数对齐逻辑 ====================
    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : align_mantissa
            wire [`FP32_EXP_WIDTH-1:0] exp_in    = exponents_flat[i*`FP32_EXP_WIDTH +: `FP32_EXP_WIDTH];
            wire [`FP32_MANT_WIDTH-1:0] mant_in  = mantissas_flat[i*`FP32_MANT_WIDTH +: `FP32_MANT_WIDTH];
            
            // 处理非规格化数：使用 (exp_in==0 && mant_in!=0) 判定 subnormal，避免与 is_zeros 形成不可能的覆盖组合
            wire is_subnormal = (exp_in == 0) && (mant_in != {`FP32_MANT_WIDTH{1'b0}});
            wire [`FP32_EXP_WIDTH-1:0] exp_effective = (is_subnormal && (max_exponent != 0)) ? 1 : exp_in;
            
            // 计算需要右移的位数
            wire [`FP32_EXP_WIDTH-1:0] exp_diff = (exp_effective < max_exponent) ? (max_exponent - exp_effective) : 0;
            wire shift_overflow = (exp_diff >= `ALIGNED_MANT_WIDTH);
            wire [$clog2(`ALIGNED_MANT_WIDTH)-1:0] shift_amt = shift_overflow ? (`ALIGNED_MANT_WIDTH-1) : exp_diff;
            
            // 尾数预处理：添加隐含位和保护位（正规数 exponent!=0 即有隐藏位；零/次正规/特殊值都为0）
            wire has_implied_bit = (exp_in != 0);
            
            wire [`ALIGNED_MANT_WIDTH-1:0] mant_shifted = ({ {has_implied_bit, mant_in}, {`GUARD_BITS{1'b0}} } >> shift_amt);

            // 生成低位掩码（不含 MSB 位38）：低 shift_amt 位为 1，其余为 0；避免产生永远为0的 lower_mask[38] 覆盖项
            wire [`ALIGNED_MANT_WIDTH-2:0] lower_mask_nomsb = (shift_amt == 0)
                                        ? {(`ALIGNED_MANT_WIDTH-1){1'b0}}
                                        : ((({{(`ALIGNED_MANT_WIDTH-2){1'b0}}, 1'b1} << shift_amt) - 1'b1));
            // 粘滞位：直接与 {1'b0, lower_mask_nomsb} 相与后归约或，避免对拼接表达式做切片选择
            wire sticky_bit = |( ({ {has_implied_bit, mant_in}, {`GUARD_BITS{1'b0}} }) & {1'b0, lower_mask_nomsb} );
            
            // 对齐后尾数组合（特殊值尾数为0）
            wire is_special = is_zeros[i] | is_infs[i] | is_nans[i];
            wire [`ALIGNED_MANT_WIDTH-1:0] mant_aligned = is_special ? 0 : 
                {mant_shifted[`ALIGNED_MANT_WIDTH-1:1], (mant_shifted[0] | sticky_bit)};
            
            assign aligned_mantissas_flat[i*`ALIGNED_MANT_WIDTH +: `ALIGNED_MANT_WIDTH] = mant_aligned;
        end
    endgenerate

    assign effective_signs = signs;


endmodule