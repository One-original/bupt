//=========================================================================
// Project   : FP32 Adder Tree (Pipelined Version)
// File      : fp32_normalizer_rounder.v
// Module    : fp32_normalizer_rounder
// Author    : sunny
// Email     : 
// Created   : 2025-8-20
// Modified  : 2025-01-XX
// Version   : v2.0 (Pipelined for 100MHz)
//=========================================================================
// Description:
// - Normalize and round FP32 mantissa with guard/round/sticky handling
// - Supports denormal path and overflow/underflow/zero flags
// - 2-stage pipeline: Stage 1 (Normalize + Round) -> Register -> Stage 2 (Denorm + Pack)
// - Verilog-2001 compliant 
// - Designed for 100MHz operation
//
// IO Ports:
// - Inputs : clk, rst_n, mant_raw (IN_WIDTH), exp_in (FP32 exp), sign_in
// - Outputs: fp_out (FP32), overflow, underflow, zero_out
//
// Dependencies:
// - `../define/fp32_defines.vh`
//
// Called by:
// - `fp32_adder_tree_8_inputs`
//
// Revision History:
// - v1.0 (2025-11-06): initial version (combinational)
// - v2.0 (2025-01-XX): add 2-stage pipeline for timing closure
//=========================================================================
`include "fp32_defines.vh"

module fp32_normalizer_rounder_8to1 #(
    parameter IN_WIDTH = `FULL_SUM_WIDTH
) (
    input  wire clk,
    input  wire rst_n,
    input  wire [IN_WIDTH-1:0]         i_mant_raw,      // 输入原始尾数绝对值
    input  wire [`FP32_EXP_WIDTH-1:0]  i_exp,           // 输入指数
    input  wire                        i_sign,          // 输入符号
    input  wire [2:0]                  i_rounding_mode, // Rounding mode: 000=RNE, 001=RTZ, 010=RDN, 011=RUP, 100=RMM

    output wire [`FP32_WIDTH-1:0]      o_fp_out,        // 输出FP32
    output wire                        o_overflow,      // 上溢
    output wire                        o_underflow,     // 下溢
    output wire                        o_zero_out,      // 精确零
    output wire                        o_inexact        // 不精确标志
);

//=============================================================================
// 参数与常量
//=============================================================================
localparam TARGET_POS        = `FP32_MANT_WIDTH + 1;        
localparam TARGET_POS_GUARD  = TARGET_POS + `GUARD_BITS; 
localparam NORM_MANT_WIDTH   = TARGET_POS + `GUARD_BITS;     
localparam EXP_MAX           = 255;                      
localparam ZERO_EXP          = {`FP32_EXP_WIDTH{1'b0}};    

//=============================================================================
// 状态与中间量
//=============================================================================
reg [`FP32_WIDTH-1:0]      fp_out_reg;      
assign o_fp_out = fp_out_reg;
reg zero_out_comb;
reg overflow_comb;
reg underflow_comb;
reg inexact_comb;
reg signed [10:0]          exp_adj_s;       // 中间指数（signed）
reg [NORM_MANT_WIDTH-1:0]  mant_norm;       // 规格化窗口（含 G/R/S）
integer                    msb_pos;         // i_mant_raw 的 MSB 位置
reg signed [10:0]          shift_amt_s;     // 规格化移位量（signed）
reg                        sticky_tmp;      // 右移移出位的聚合 OR
reg                        sticky;          // 粘滞位
reg                        is_denorm_input; // 输入是否为次正规
integer                    sticky_i;        // sticky 统计循环变量
reg [2:0]                  rounding_mode_reg; // 寄存器化的舍入模式

// 统一在扩展位宽上移位，避免左移溢出与变长位选；
localparam integer EXT_WIDTH = (NORM_MANT_WIDTH > IN_WIDTH) ? NORM_MANT_WIDTH : IN_WIDTH;
wire [EXT_WIDTH-1:0]  mant_ext_full = (EXT_WIDTH > IN_WIDTH) ? {{(EXT_WIDTH-IN_WIDTH){1'b0}}, i_mant_raw} : i_mant_raw;


// 非规格数路径
reg [`FP32_MANT_WIDTH:0]   dn_mant24_pre;   
reg [`FP32_MANT_WIDTH:0]   dn_mant24_rounded;
reg                        dn_g, dn_r, dn_s, dn_lsb, dn_round_up;
reg                        has_discarded_tiny;  // 用于 tiny_to_denorm 路径的舍入判断


//=============================================================================
// 规格化
//=============================================================================
always @(*) begin : NORMALIZE_BLOCK
    reg [EXT_WIDTH-1:0] mant_shifted_full; // 扩展位宽移位结果
    integer upper; // 预先裁剪循环上界
    // 初始化
    zero_out_comb   = 1'b0;
    exp_adj_s  = 0;
    mant_norm  = {NORM_MANT_WIDTH{1'b0}};
    msb_pos    = -1;
    sticky     = 1'b0;
    sticky_tmp = 1'b0;
    is_denorm_input = (i_exp == 0 && i_mant_raw != 0);

    if (i_mant_raw == 0) begin
        zero_out_comb = 1'b1;
        shift_amt_s   = 11'sd0;   // 避免组合逻辑产生 latch
    end else begin
        // 1) 找最高位
        begin : FIND_MSB
            integer i;
            msb_pos = -1;
            for (i = IN_WIDTH-1; i >= 0; i = i - 1) begin
                if (i_mant_raw[i]) begin
                    if (msb_pos == -1)
                        msb_pos = i;
                end
            end
        end

    //  目标隐藏位位置 
    if (msb_pos >= 0 && msb_pos < `GUARD_BITS) begin
        shift_amt_s = 0;
    end else begin
        shift_amt_s = msb_pos - (TARGET_POS_GUARD - 1);
    end
    //  移位与 sticky
    if (shift_amt_s > 0) begin
        upper = (shift_amt_s < EXT_WIDTH) ? shift_amt_s : EXT_WIDTH;
        sticky_tmp = 1'b0;
        for (sticky_i = 0; sticky_i < upper && sticky_i <= (EXT_WIDTH-1); sticky_i = sticky_i + 1) begin
            sticky_tmp = sticky_tmp | mant_ext_full[sticky_i];
        end
        mant_shifted_full = (mant_ext_full >> shift_amt_s);
        sticky = sticky_tmp;
        end else if (shift_amt_s < 0) begin
            mant_shifted_full = (mant_ext_full << $unsigned(-shift_amt_s));
            sticky = 1'b0; // 左移/不移不产生外部 sticky
        end else begin
            mant_shifted_full = mant_ext_full;
            sticky = 1'b0;
        end

        // 截取规格化窗口低 NORM_MANT_WIDTH 位
        mant_norm = mant_shifted_full[NORM_MANT_WIDTH-1:0];

        // 指数调整（signed）
        if (msb_pos >= 0 && msb_pos < `GUARD_BITS) begin
            // 值在保护位区域，强制指数为0，走次正规路径
            exp_adj_s = 0;
        end else if (is_denorm_input) begin
            if (msb_pos < (TARGET_POS_GUARD - 1)) begin
                exp_adj_s = 0; // 仍为次正规
            end else begin
                exp_adj_s = 11'sd1 + shift_amt_s; // 次正规提升为正规
            end
        end else begin
            exp_adj_s = $signed({3'b000, i_exp}) + shift_amt_s; // 正规路径
        end
    end
end

//=================================
// 舍入逻辑（支持5种IEEE 754舍入模式）
//=================================
wire [`FP32_MANT_WIDTH-1:0] mant_rounded;    // 舍入后的 23 位尾数
wire [TARGET_POS-1:0]      mant_main_pre = mant_norm[NORM_MANT_WIDTH-1:`GUARD_BITS];
wire                       bit_g  = mant_norm[`GUARD_BITS-1];      // Guard位
wire                       bit_r  = mant_norm[`GUARD_BITS-2];      // Round位
wire                       bits_sticky_low = (|mant_norm[`GUARD_BITS-3:0]) | sticky;  // Sticky位
wire                       bit_lsb = mant_main_pre[0];             // 最低有效位
wire                       has_discarded_bits = bit_g | bit_r | bits_sticky_low;  // 是否有被丢弃的位

// 根据舍入模式决定是否向上舍入
reg round_up_w;
always @(*) begin
    case (rounding_mode_reg)
        `RM_RNE: begin
            // Round to Nearest, ties to Even
            round_up_w = (bit_g & (bit_r | bits_sticky_low)) | 
                         (bit_g & ~bit_r & ~bits_sticky_low & bit_lsb);
        end
        `RM_RTZ: begin
            // Round Towards Zero (truncate)
            round_up_w = 1'b0;
        end
        `RM_RDN: begin
            // Round Down (towards -∞)
            round_up_w = i_sign & has_discarded_bits;
        end
        `RM_RUP: begin
            // Round Up (towards +∞)
            round_up_w = ~i_sign & has_discarded_bits;
        end
        `RM_RMM: begin
            // Round to Nearest, ties to Max magnitude
            round_up_w = bit_g;
        end
        default: begin
            // Default to RNE
            round_up_w = (bit_g & (bit_r | bits_sticky_low)) | 
                         (bit_g & ~bit_r & ~bits_sticky_low & bit_lsb);
        end
    endcase
end

wire [TARGET_POS:0]        mant_main_with_carry = {1'b0, mant_main_pre} + (round_up_w ? 1'b1 : 1'b0);
wire                       mant_round_carry = mant_main_with_carry[TARGET_POS];
wire [TARGET_POS-1:0]      mant_main_rounded = mant_round_carry ? {1'b1, {(`FP32_MANT_WIDTH){1'b0}}} : mant_main_with_carry[TARGET_POS-1:0];

wire  tiny_to_denorm = (mant_main_pre == {TARGET_POS{1'b0}}) && (bit_g | bit_r | bits_sticky_low);

// 舍入后取低 23 位
assign mant_rounded = mant_main_rounded[`FP32_MANT_WIDTH-1:0];

// 最终指数
wire signed [10:0] final_exp_signed = exp_adj_s + (mant_round_carry ? 11'sd1 : 11'sd0);

//=============================================================================
// 流水线寄存器
//=============================================================================
reg signed [10:0] final_exp_signed_reg;
reg [NORM_MANT_WIDTH-1:0] mant_norm_reg;
reg sticky_reg;
reg is_denorm_input_reg;
reg zero_out_reg;
reg tiny_to_denorm_reg;
reg sign_in_reg;
reg [`FP32_EXP_WIDTH-1:0] exp_in_reg;
reg [IN_WIDTH-1:0] mant_raw_reg;
reg [`FP32_MANT_WIDTH-1:0] mant_rounded_reg;
reg has_discarded_bits_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sign_in_reg <= 1'b0;
        exp_in_reg <= {`FP32_EXP_WIDTH{1'b0}};
        mant_raw_reg <= {(IN_WIDTH){1'b0}};
        mant_norm_reg <= {NORM_MANT_WIDTH{1'b0}};
        final_exp_signed_reg <= 11'sd0;
        sticky_reg <= 1'b0;
        is_denorm_input_reg <= 1'b0;
        zero_out_reg <= 1'b0;
        tiny_to_denorm_reg <= 1'b0;
        mant_rounded_reg <= {`FP32_MANT_WIDTH{1'b0}};
        rounding_mode_reg <= `RM_RNE;
        has_discarded_bits_reg <= 1'b0;
    end else begin
        mant_norm_reg <= mant_norm;
        final_exp_signed_reg <= final_exp_signed;
        sticky_reg <= sticky;
        is_denorm_input_reg <= is_denorm_input;
        zero_out_reg <= zero_out_comb;
        tiny_to_denorm_reg <= tiny_to_denorm;
        sign_in_reg <= i_sign;
        exp_in_reg <= i_exp;
        mant_raw_reg <= i_mant_raw;
        mant_rounded_reg <= mant_rounded;
        rounding_mode_reg <= i_rounding_mode;
        has_discarded_bits_reg <= has_discarded_bits;
    end
end

//===========================
// 非规格路径中间量
//===========================
always @(*) begin : DENORM_COMB_BLOCK
    integer den_shift_local;
    reg [NORM_MANT_WIDTH-1:0] dm_window;
    reg [NORM_MANT_WIDTH-1:0] dm_shifted;
    reg sticky_den_extra;
    integer msb_in_norm;
    reg [`FP32_MANT_WIDTH:0] denorm_mant;
    integer i;
    msb_in_norm = -1;

    if (tiny_to_denorm_reg) begin
        // 在保护位区域内找最高位
        begin : FIND_MSB_IN_NORM
            integer i;
            for (i = `GUARD_BITS-1; i >= 0; i = i - 1) begin
                if (mant_norm_reg[i] && msb_in_norm == -1) begin
                    msb_in_norm = i;
                end
            end
        end
        
        den_shift_local = 0;
    end else begin
        den_shift_local = (final_exp_signed_reg <= 0) ? (1 - final_exp_signed_reg) : 0;
    end
    
    dm_window = mant_norm_reg;

    if (den_shift_local <= 0) begin
        sticky_den_extra = 1'b0;
        dm_shifted = dm_window;
    end else begin
        // 限制 den_shift_local 的最大值以避免超过 NORM_MANT_WIDTH
        if (den_shift_local > NORM_MANT_WIDTH) begin
            // 如果移位量超过位宽，所有位都会被移出，sticky为所有位的OR
            sticky_den_extra = |dm_window;
            dm_shifted = {NORM_MANT_WIDTH{1'b0}};
        end else if (den_shift_local > 0) begin
            // 使用归约OR计算被移出位的sticky
            sticky_den_extra = 1'b0;
            begin : CALC_STICKY
                integer i;
                integer upper_limit;
                // 确保循环索引不超过 dm_window 的有效范围 [NORM_MANT_WIDTH-1:0]
                upper_limit = (den_shift_local <= NORM_MANT_WIDTH) ? den_shift_local : NORM_MANT_WIDTH;
                for (i = 0; i < upper_limit && i < NORM_MANT_WIDTH; i = i + 1) begin
                    sticky_den_extra = sticky_den_extra | dm_window[i];
                end
            end
            dm_shifted = dm_window >> den_shift_local;
        end else begin
            sticky_den_extra = 1'b0;
            dm_shifted = dm_window;
        end
    end

    // 对于tiny_to_denorm的情况，值在保护位区域，需要直接从保护位区域提取
    if (tiny_to_denorm_reg) begin
        if (msb_in_norm >= 0) begin
            denorm_mant = {(`FP32_MANT_WIDTH+1){1'b0}};
            begin : COPY_DENORM_MANT
                integer i;
                integer upper_limit;
                upper_limit = (msb_in_norm <= `FP32_MANT_WIDTH) ? msb_in_norm : `FP32_MANT_WIDTH;
                for (i = 0; i <= upper_limit && i <= `FP32_MANT_WIDTH; i = i + 1) begin
                    denorm_mant[i] = mant_norm_reg[i];
                end
            end
            dn_mant24_pre = {1'b0, denorm_mant[`FP32_MANT_WIDTH-1:0]};
            // 对于tiny_to_denorm路径，如果dn_mant24_pre为全零，需要根据舍入模式决定是否舍入
            if (dn_mant24_pre == {(`FP32_MANT_WIDTH+1){1'b0}}) begin
                // 值为零，检查是否有被丢弃的位来决定是否舍入
                has_discarded_tiny = (|mant_norm_reg[`GUARD_BITS-1:0]) | sticky_reg;
                case (rounding_mode_reg)
                    `RM_RDN: 
                        dn_round_up = sign_in_reg & has_discarded_tiny;
                    `RM_RUP: 
                        dn_round_up = ~sign_in_reg & has_discarded_tiny;
                    default: 
                        dn_round_up = 1'b0;
                endcase
                dn_mant24_rounded = dn_mant24_pre + (dn_round_up ? 1'b1 : 1'b0);
            end else begin
                dn_mant24_rounded = dn_mant24_pre;
            end
        end else begin
            // Fallback 到标准路径
            dn_mant24_pre = dm_shifted[NORM_MANT_WIDTH-1:`GUARD_BITS];
            dn_g = dm_shifted[`GUARD_BITS-1];
            dn_r = dm_shifted[`GUARD_BITS-2];
            dn_s = (|dm_shifted[`GUARD_BITS-3:0]) | sticky_den_extra;
            dn_lsb = dn_mant24_pre[0];
            // 根据舍入模式决定是否向上舍入（非规格化数路径）
            case (rounding_mode_reg)
                `RM_RNE: 
                    dn_round_up = (dn_g & (dn_r | dn_s)) | (dn_g & ~dn_r & ~dn_s & dn_lsb);
                `RM_RTZ: 
                    dn_round_up = 1'b0;
                `RM_RDN: 
                    dn_round_up = sign_in_reg & (dn_g | dn_r | dn_s);
                `RM_RUP: 
                    dn_round_up = ~sign_in_reg & (dn_g | dn_r | dn_s);
                `RM_RMM: 
                    dn_round_up = dn_g;
                default: 
                    dn_round_up = (dn_g & (dn_r | dn_s)) | (dn_g & ~dn_r & ~dn_s & dn_lsb);
            endcase
            dn_mant24_rounded = dn_mant24_pre + (dn_round_up ? 1'b1 : 1'b0);
        end
    end else begin
        // 标准路径
        dn_mant24_pre = dm_shifted[NORM_MANT_WIDTH-1:`GUARD_BITS];
        dn_g = dm_shifted[`GUARD_BITS-1];
        dn_r = dm_shifted[`GUARD_BITS-2];
        dn_s = (|dm_shifted[`GUARD_BITS-3:0]) | sticky_den_extra;
        dn_lsb = dn_mant24_pre[0];
        // 根据舍入模式决定是否向上舍入（非规格化数路径）
        case (rounding_mode_reg)
            `RM_RNE: 
                dn_round_up = (dn_g & (dn_r | dn_s)) | (dn_g & ~dn_r & ~dn_s & dn_lsb);
            `RM_RTZ: 
                dn_round_up = 1'b0;
            `RM_RDN: 
                dn_round_up = sign_in_reg & (dn_g | dn_r | dn_s);
            `RM_RUP: 
                dn_round_up = ~sign_in_reg & (dn_g | dn_r | dn_s);
            `RM_RMM: 
                dn_round_up = dn_g;
            default: 
                dn_round_up = (dn_g & (dn_r | dn_s)) | (dn_g & ~dn_r & ~dn_s & dn_lsb);
        endcase
        dn_mant24_rounded = dn_mant24_pre + (dn_round_up ? 1'b1 : 1'b0);
    end
end

//===========================
// 最终结果封装
//===========================
always @(*) begin
    fp_out_reg = {sign_in_reg, ZERO_EXP, {`FP32_MANT_WIDTH{1'b0}}};
    overflow_comb = 1'b0;
    underflow_comb = 1'b0;
    inexact_comb = 1'b0;

    if (zero_out_reg) begin
        // 精确零的情况：输入本身就是零，符号应该根据舍入模式来决定
        // 在 RDN 模式下：根据 IEEE 754 标准，x + (-x) = -0，但如果输入本身就是精确的正零，应该保持正零
        // 在 RUP 模式下：x + (-x) = +0，但如果输入本身就是精确的负零，应该保持负零
        // 其他模式下，使用原始符号
        // 精确零的情况：符号应该根据舍入模式和输入来决定
        // 在 RDN 模式下：根据 IEEE 754 标准，x + (-x) = -0，但如果输入本身就是精确的正零，应该保持正零
        // 在 RUP 模式下：x + (-x) = +0，但如果输入本身就是精确的负零，应该保持负零
        // 其他模式下，使用原始符号
        // 注意：sign_in_reg 已经根据舍入模式计算过了，这里直接使用即可
        fp_out_reg = {sign_in_reg, ZERO_EXP, {`FP32_MANT_WIDTH{1'b0}}};
        inexact_comb = 1'b0;  // 零是精确的
        
    end else if (final_exp_signed_reg >= EXP_MAX) begin
        // 上溢：根据舍入模式产生不同结果
        overflow_comb = 1'b1;
        inexact_comb = 1'b1;  // 溢出总是导致不精确
        
        case (rounding_mode_reg)
            `RM_RNE, `RM_RMM: begin
                // 舍入到无穷大
                fp_out_reg = {sign_in_reg, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
            end
            `RM_RTZ: begin
                // 舍入到最大有限值
                fp_out_reg = {sign_in_reg, 8'd254, {`FP32_MANT_WIDTH{1'b1}}};
            end
            `RM_RDN: begin
                if (sign_in_reg)
                    fp_out_reg = {sign_in_reg, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};  // -∞
                else
                    fp_out_reg = {sign_in_reg, 8'd254, {`FP32_MANT_WIDTH{1'b1}}};  // +最大有限值
            end
            `RM_RUP: begin
                if (sign_in_reg)
                    fp_out_reg = {sign_in_reg, 8'd254, {`FP32_MANT_WIDTH{1'b1}}};  // -最大有限值
                else
                    fp_out_reg = {sign_in_reg, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};  // +∞
            end
            default: begin
                // Default to RNE
                fp_out_reg = {sign_in_reg, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
            end
        endcase
        
    end else if ((final_exp_signed_reg <= 0) || tiny_to_denorm_reg) begin
        // 下溢：处理非规格数
        underflow_comb = 1'b1;
        // 下溢时如果有被丢弃的位，则产生不精确标志
        inexact_comb = has_discarded_bits_reg;
        
        if (is_denorm_input_reg && final_exp_signed_reg == 0 && !tiny_to_denorm_reg) begin
            // 输入为非规格化数且结果仍为非规格化数的情况
            fp_out_reg = {sign_in_reg, ZERO_EXP, mant_raw_reg[`FP32_MANT_WIDTH-1+`GUARD_BITS:`GUARD_BITS]};
        end else begin
            if (dn_mant24_rounded[`FP32_MANT_WIDTH]) begin
                // 由舍入进位导致尾数溢出，升级为最小正规数
                // 这是唯一应该提升到最小规格化数的情况（符合IEEE 754）
                fp_out_reg = {sign_in_reg, 8'd1, {`FP32_MANT_WIDTH{1'b0}}};
            end else if (dn_mant24_rounded[`FP32_MANT_WIDTH-1:0] == {`FP32_MANT_WIDTH{1'b0}}) begin
                // 下溢到零：根据舍入模式决定符号
                // 在 RDN 模式下：根据 IEEE 754 标准，舍入到零时应该产生负零（向下舍入）
                // 在 RUP 模式下：根据 IEEE 754 标准，舍入到零时应该产生正零（向上舍入）
                // 其他模式下，符号取决于原始符号
                case (rounding_mode_reg)
                    `RM_RDN: begin
                        // RDN: 舍入到零时总是负零
                        fp_out_reg = {1'b1, ZERO_EXP, {`FP32_MANT_WIDTH{1'b0}}};
                    end
                    `RM_RUP: begin
                        // RUP: 舍入到零时总是正零
                        fp_out_reg = {1'b0, ZERO_EXP, {`FP32_MANT_WIDTH{1'b0}}};
                    end
                    default: begin
                        // 其他模式：使用原始符号
                        fp_out_reg = {sign_in_reg, ZERO_EXP, {`FP32_MANT_WIDTH{1'b0}}};
                    end
                endcase
            end else begin
                // 保持为真正的次正规数：输出23位
                // 符合IEEE 754标准：非规格化数应保持为非规格化数
                fp_out_reg = {sign_in_reg, ZERO_EXP, dn_mant24_rounded[`FP32_MANT_WIDTH-1:0]};
            end
        end
           
    end else begin
        // 正常情况
        fp_out_reg = {sign_in_reg, final_exp_signed_reg[`FP32_EXP_WIDTH-1:0], mant_rounded_reg};
        // 如果有被丢弃的位，则产生不精确标志
        inexact_comb = has_discarded_bits_reg;
    end
end

assign o_zero_out = zero_out_reg;
assign o_overflow = overflow_comb;
assign o_underflow = underflow_comb;
assign o_inexact = inexact_comb;


endmodule