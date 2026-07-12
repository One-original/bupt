//=========================================================================
// Project   : FP32 Adder Tree (Pipelined Version)
// File      : fp32_adder_tree_8_inputs.v
// Module    : fp32_adder_tree_8_inputs
// Author    : sunny
// Email     : 
// Created   : 2025-08-20
// Modified  : 2025-01-XX
// Version   : v3.0 (Pipelined for 100MHz)
//=========================================================================
// Description:
// - Top-level 8-input FP32 adder tree with 5-stage pipeline
// - Pipeline stages:
//   Stage 0: Data reorganization + Unpack
//   Stage 1: Special value detection + Mantissa alignment
//   Stage 2: Sign separation + Wallace tree accumulation
//   Stage 3: Sign combination + Normalization/Rounding
//   Stage 4: Packing + Output
// - Verilog-2001 compliant
// - Designed for 100MHz operation
//
// IO Ports:
// - Inputs : clk, rst_n, dvr_fp32addtree8to1_s0, dvr_fp32addtree8to1_s1, cru_fp32addtree8to1
// - Outputs: dr_fp32addtree8to1_d
//
// Dependencies:
// - `../define/fp32_defines.vh`
// - fp32_unpacker, fp32_aligner, wallace_tree_8_inputs, fp32_normalizer_rounder, fp32_packer
//
// Revision History:
// - v2.1 (2025-11-06): adopt standard header/comments; no logic change
// - v3.0 (2025-01-XX): add 5-stage pipeline for timing closure
//=========================================================================
`include "fp32_defines.vh"

module fp32_adder_tree_8_inputs_8to1 #(
    parameter SMC_ID = 0,    // SMC ID for this module
    parameter IEEE_754 = 1
)(

    input  wire        i_clk,                                   // 时钟
    input  wire        i_rst_n,                                 // 低电平有效的复位信号
	
	
    input  wire [127:0] i_dvr_fp32addtree8to1_s0,               // 计算输入数据0 
    input  wire [127:0] i_dvr_fp32addtree8to1_s1,               // 计算输入数据1  
    input  wire [7:0]   i_cru_fp32addtree8to1,                  // [7:3]=smc_id_en, [2:1]=dest_reg_idx, [0]=inst_valid
    input  wire [2:0]   i_rounding_mode,                        // Rounding mode: 000=RNE, 001=RTZ, 010=RDN, 011=RUP, 100=RMM
    
    output reg  [127:0] o_dr_fp32addtree8to1_d,                // 输出数据 
    output reg  [7:0]   o_cru_fp32addtree8to1_o,               // CRU输出（打一拍直通）
    
    // IEEE-754 Exception Flags Output - per adder
    // [4:0] = {Inexact, Underflow, Overflow, DivByZero, Invalid}
    output wire [4:0]   o_exception_flags                       // Exception flags
);

    localparam NUM_INPUTS = 8;
    genvar i, j, k;
    

    
    // 指令解析
    wire [4:0] w_smc_id_en;
    wire w_cmd_valid;
    wire w_cmd_valid_eff;
    wire [1:0] w_dest_reg_idx;
    wire [1:0] w_dest_reg_idx_raw;
    wire [2:0] w_rounding_mode_gated;
    wire [127:0] i_dvr_fp32addtree8to1_s0_gated;
    wire [127:0] i_dvr_fp32addtree8to1_s1_gated;
    assign w_smc_id_en = i_cru_fp32addtree8to1[7:3];
    assign w_cmd_valid = i_cru_fp32addtree8to1[0];          // 指令有效位
    assign w_cmd_valid_eff = w_cmd_valid && (SMC_ID[4:0] <= w_smc_id_en);
    assign w_dest_reg_idx_raw = i_cru_fp32addtree8to1[2:1];     // 目的寄存器编码
    assign w_dest_reg_idx = w_cmd_valid_eff ? w_dest_reg_idx_raw : 2'b0;
    assign w_rounding_mode_gated = w_cmd_valid_eff ? i_rounding_mode : `RM_RNE;
    assign i_dvr_fp32addtree8to1_s0_gated = w_cmd_valid_eff ? i_dvr_fp32addtree8to1_s0 : 128'd0;
    assign i_dvr_fp32addtree8to1_s1_gated = w_cmd_valid_eff ? i_dvr_fp32addtree8to1_s1 : 128'd0;
     // ====================================================================
    // 流水线控制信号
    // ====================================================================
    reg [4:0] valid_pipe;  // 5级流水线valid信号
    reg [2:0] rounding_mode_pipe [0:4];  // Pipeline rounding mode (5 stages)
    
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            valid_pipe <= 5'd0;
            o_cru_fp32addtree8to1_o <= 8'd0;
            rounding_mode_pipe[0] <= `RM_RNE;
            rounding_mode_pipe[1] <= `RM_RNE;
            rounding_mode_pipe[2] <= `RM_RNE;
            rounding_mode_pipe[3] <= `RM_RNE;
            rounding_mode_pipe[4] <= `RM_RNE;
        end else begin
            valid_pipe <= {valid_pipe[3:0], w_cmd_valid_eff};
            o_cru_fp32addtree8to1_o <= i_cru_fp32addtree8to1;
            rounding_mode_pipe[0] <= w_rounding_mode_gated;
            rounding_mode_pipe[1] <= rounding_mode_pipe[0];
            rounding_mode_pipe[2] <= rounding_mode_pipe[1];
            rounding_mode_pipe[3] <= rounding_mode_pipe[2];
            rounding_mode_pipe[4] <= rounding_mode_pipe[3];
        end
    end   
    // 输入拆分（对齐 v0.4.12 5.3.5）
    // 每个源寄存器 128bit 拆成 4 个 FP32：
    // S0 = {S0[3],S0[2],S0[1],S0[0]}, S1 = {S1[3],S1[2],S1[1],S1[0]}
    // 8 输入依次为：S0[0..3], S1[0..3]
    wire [`FP32_WIDTH-1:0] w_current_fp_input [0:NUM_INPUTS-1];
    assign w_current_fp_input[0] = i_dvr_fp32addtree8to1_s0_gated[0*32 +: 32];
    assign w_current_fp_input[1] = i_dvr_fp32addtree8to1_s0_gated[1*32 +: 32];
    assign w_current_fp_input[2] = i_dvr_fp32addtree8to1_s0_gated[2*32 +: 32];
    assign w_current_fp_input[3] = i_dvr_fp32addtree8to1_s0_gated[3*32 +: 32];
    assign w_current_fp_input[4] = i_dvr_fp32addtree8to1_s1_gated[0*32 +: 32];
    assign w_current_fp_input[5] = i_dvr_fp32addtree8to1_s1_gated[1*32 +: 32];
    assign w_current_fp_input[6] = i_dvr_fp32addtree8to1_s1_gated[2*32 +: 32];
    assign w_current_fp_input[7] = i_dvr_fp32addtree8to1_s1_gated[3*32 +: 32];

`ifdef USE_FPGA_IP
    // 8-input sum implemented as a 4-2-1 adder tree:
    // level0: (0+1), (2+3), (4+5), (6+7)
    // level1: (01+23), (45+67)
    // level2: (0123+4567)
    wire        add_l0_valid [0:3];
    wire [`FP32_WIDTH-1:0] add_l0_sum   [0:3];
    wire        add_l1_valid [0:1];
    wire [`FP32_WIDTH-1:0] add_l1_sum   [0:1];
    wire        add_l2_valid;
    wire [`FP32_WIDTH-1:0] add_l2_sum;

    reg [1:0] dest_reg_idx_l0;
    reg [1:0] dest_reg_idx_l1;
    reg [1:0] dest_reg_idx_l2;
    reg [4:0] exception_flags_reg;

    floating_point_Add_FP32_L1_FP5TO1 add_l0_0 (
        .aclk(i_clk),
        .aresetn(i_rst_n),
        .s_axis_a_tvalid(w_cmd_valid_eff),
        .s_axis_a_tdata(w_current_fp_input[0]),
        .s_axis_b_tvalid(w_cmd_valid_eff),
        .s_axis_b_tdata(w_current_fp_input[1]),
        .m_axis_result_tvalid(add_l0_valid[0]),
        .m_axis_result_tdata(add_l0_sum[0])
    );

    floating_point_Add_FP32_L1_FP5TO1 add_l0_1 (
        .aclk(i_clk),
        .aresetn(i_rst_n),
        .s_axis_a_tvalid(w_cmd_valid_eff),
        .s_axis_a_tdata(w_current_fp_input[2]),
        .s_axis_b_tvalid(w_cmd_valid_eff),
        .s_axis_b_tdata(w_current_fp_input[3]),
        .m_axis_result_tvalid(add_l0_valid[1]),
        .m_axis_result_tdata(add_l0_sum[1])
    );

    floating_point_Add_FP32_L1_FP5TO1 add_l0_2 (
        .aclk(i_clk),
        .aresetn(i_rst_n),
        .s_axis_a_tvalid(w_cmd_valid_eff),
        .s_axis_a_tdata(w_current_fp_input[4]),
        .s_axis_b_tvalid(w_cmd_valid_eff),
        .s_axis_b_tdata(w_current_fp_input[5]),
        .m_axis_result_tvalid(add_l0_valid[2]),
        .m_axis_result_tdata(add_l0_sum[2])
    );

    floating_point_Add_FP32_L1_FP5TO1 add_l0_3 (
        .aclk(i_clk),
        .aresetn(i_rst_n),
        .s_axis_a_tvalid(w_cmd_valid_eff),
        .s_axis_a_tdata(w_current_fp_input[6]),
        .s_axis_b_tvalid(w_cmd_valid_eff),
        .s_axis_b_tdata(w_current_fp_input[7]),
        .m_axis_result_tvalid(add_l0_valid[3]),
        .m_axis_result_tdata(add_l0_sum[3])
    );

    wire level1_fire_0 = add_l0_valid[0] & add_l0_valid[1];
    wire level1_fire_1 = add_l0_valid[2] & add_l0_valid[3];

    floating_point_Add_FP32_L1_FP5TO1 add_l1_0 (
        .aclk(i_clk),
        .aresetn(i_rst_n),
        .s_axis_a_tvalid(level1_fire_0),
        .s_axis_a_tdata(add_l0_sum[0]),
        .s_axis_b_tvalid(level1_fire_0),
        .s_axis_b_tdata(add_l0_sum[1]),
        .m_axis_result_tvalid(add_l1_valid[0]),
        .m_axis_result_tdata(add_l1_sum[0])
    );

    floating_point_Add_FP32_L1_FP5TO1 add_l1_1 (
        .aclk(i_clk),
        .aresetn(i_rst_n),
        .s_axis_a_tvalid(level1_fire_1),
        .s_axis_a_tdata(add_l0_sum[2]),
        .s_axis_b_tvalid(level1_fire_1),
        .s_axis_b_tdata(add_l0_sum[3]),
        .m_axis_result_tvalid(add_l1_valid[1]),
        .m_axis_result_tdata(add_l1_sum[1])
    );

    wire level2_fire = add_l1_valid[0] & add_l1_valid[1];
    floating_point_Add_FP32_L1_FP5TO1 add_l2 (
        .aclk(i_clk),
        .aresetn(i_rst_n),
        .s_axis_a_tvalid(level2_fire),
        .s_axis_a_tdata(add_l1_sum[0]),
        .s_axis_b_tvalid(level2_fire),
        .s_axis_b_tdata(add_l1_sum[1]),
        .m_axis_result_tvalid(add_l2_valid),
        .m_axis_result_tdata(add_l2_sum)
    );

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            dest_reg_idx_l0 <= 2'b0;
            dest_reg_idx_l1 <= 2'b0;
            dest_reg_idx_l2 <= 2'b0;
        end else begin
            dest_reg_idx_l0 <= w_dest_reg_idx;
            dest_reg_idx_l1 <= dest_reg_idx_l0;
            dest_reg_idx_l2 <= dest_reg_idx_l1;
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_dr_fp32addtree8to1_d <= 128'b0;
            exception_flags_reg <= 5'b0;
        end else if (add_l2_valid) begin
            case (dest_reg_idx_l2)
                2'b00: o_dr_fp32addtree8to1_d[31:0]   <= add_l2_sum;
                2'b01: o_dr_fp32addtree8to1_d[63:32]  <= add_l2_sum;
                2'b10: o_dr_fp32addtree8to1_d[95:64]  <= add_l2_sum;
                2'b11: o_dr_fp32addtree8to1_d[127:96] <= add_l2_sum;
                default: o_dr_fp32addtree8to1_d <= 128'b0;
            endcase
            exception_flags_reg <= 5'b0;
        end
    end

    assign o_exception_flags = exception_flags_reg;

`else
    // Unpack 
    wire [`FP32_EXP_WIDTH-1:0] w_temp_exponent [0:NUM_INPUTS-1];
    wire [`FP32_MANT_WIDTH-1:0] w_temp_mantissa [0:NUM_INPUTS-1];
    wire [NUM_INPUTS-1:0] w_signs;
    wire [NUM_INPUTS*`FP32_EXP_WIDTH-1:0] w_exponents_flat;
    wire [NUM_INPUTS*`FP32_MANT_WIDTH-1:0] w_mantissas_flat;
    wire [NUM_INPUTS-1:0] w_is_zeros;
    wire [NUM_INPUTS-1:0] w_is_infs;
    wire [NUM_INPUTS-1:0] w_is_nans;

    // 判断是否有任何有效正输入 
    wire w_any_valid_positive;
    wire w_no_positive_contribution_present;
    assign w_any_valid_positive = |(~w_is_nans & ~w_is_infs & ~w_signs);
    assign w_no_positive_contribution_present = ~w_any_valid_positive;
    
    // 判断是否有任何有效负输入（非零、非NaN、非Inf的负数）
    wire w_any_valid_negative;
    wire w_no_negative_contribution_present;
    assign w_any_valid_negative = |(~w_is_nans & ~w_is_infs & w_signs & ~w_is_zeros);
    assign w_no_negative_contribution_present = ~w_any_valid_negative;
    
    // 判断是否有任何非零的正数（排除正零）
    wire w_any_nonzero_positive;
    assign w_any_nonzero_positive = |(~w_is_nans & ~w_is_infs & ~w_signs & ~w_is_zeros);
    
    // 判断是否所有输入都是零（正零或负零）
    wire w_all_zeros;
    assign w_all_zeros = &w_is_zeros;
    
    // 判断是否所有输入都是正零
    // 条件：所有输入都是零，且所有零的符号位都是0，且没有非零的正数，且没有非零的负数
    wire w_all_pos_zeros;
    assign w_all_pos_zeros = w_all_zeros && 
                             (~|(w_signs & w_is_zeros)) &&  // 所有零的符号位都是0
                             ~w_any_nonzero_positive &&       // 没有非零的正数
                             w_no_negative_contribution_present;  // 没有非零的负数
    
    // 判断是否所有输入都是负零
    // 条件：所有输入都是零，且所有零的符号位都是1，且没有非零的正数，且没有非零的负数
    wire w_all_neg_zeros;
    assign w_all_neg_zeros = w_all_zeros && 
                             (&(w_signs | ~w_is_zeros)) &&   // 所有零的符号位都是1
                             ~w_any_nonzero_positive &&      // 没有非零的正数
                             w_no_negative_contribution_present;  // 没有非零的负数

    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : unpack_gen
            fp32_unpacker_8to1 # (.IEEE_754(IEEE_754)) unpacker_inst (
                .i_fp_in   (w_current_fp_input[i]),
                .o_sign    (w_signs[i]),
                .o_exponent(w_temp_exponent[i]),
                .o_mantissa(w_temp_mantissa[i]),
                .o_is_zero (w_is_zeros[i]),
                .o_is_inf  (w_is_infs[i]),
                .o_is_nan  (w_is_nans[i])
            );

            assign w_exponents_flat[(i+1)*`FP32_EXP_WIDTH-1 : i*`FP32_EXP_WIDTH] = w_temp_exponent[i];
            assign w_mantissas_flat[(i+1)*`FP32_MANT_WIDTH-1 : i*`FP32_MANT_WIDTH] = w_temp_mantissa[i];
        end
    endgenerate

    // ====================================================================
    // Stage 0: 数据重组 + 拆包
    // ====================================================================
    // Stage 0 组合逻辑（原为寄存器，现改为组合逻辑）
    wire [NUM_INPUTS*`FP32_EXP_WIDTH-1:0] exponents_flat_s0;
    wire [NUM_INPUTS*`FP32_MANT_WIDTH-1:0] mantissas_flat_s0;
    wire [NUM_INPUTS-1:0] signs_s0, is_zeros_s0, is_infs_s0, is_nans_s0;
    wire no_positive_contribution_present_s0;
    wire w_any_valid_negative_s0, w_all_pos_zeros_s0, w_all_neg_zeros_s0;
    wire [1:0] dest_reg_idx_s0;

    // 组合逻辑赋值（直接传递）
    assign exponents_flat_s0 = w_exponents_flat;
    assign mantissas_flat_s0 = w_mantissas_flat;
    assign signs_s0 = w_signs;
    assign is_zeros_s0 = w_is_zeros;
    assign is_infs_s0 = w_is_infs;
    assign is_nans_s0 = w_is_nans;
    assign no_positive_contribution_present_s0 = w_no_positive_contribution_present;
    assign w_any_valid_negative_s0 = w_any_valid_negative;
    assign w_all_pos_zeros_s0 = w_all_pos_zeros;
    assign w_all_neg_zeros_s0 = w_all_neg_zeros;
    assign dest_reg_idx_s0 = w_dest_reg_idx;

    // ====================================================================
    // Stage 1: 特殊值检测 + 尾数对齐
    // ====================================================================
    // 处理输入特殊值 
    wire any_nan_in;
    wire [NUM_INPUTS-1:0] is_pos_inf;
    wire [NUM_INPUTS-1:0] is_neg_inf;
    wire any_pos_inf;
    wire any_neg_inf;
    wire result_is_nan_condition;
    wire result_is_inf_condition;
    wire result_inf_sign;
    
    assign any_nan_in = |is_nans_s0;
    assign is_pos_inf = is_infs_s0 & ~signs_s0;
    assign is_neg_inf = is_infs_s0 & signs_s0;
    assign any_pos_inf = |is_pos_inf;
    assign any_neg_inf = |is_neg_inf;
    
    // Invalid operation: NaN input or (+Inf) + (-Inf)
    wire invalid_operation = any_nan_in || (any_pos_inf && any_neg_inf);
    
    assign result_is_nan_condition = invalid_operation;
    assign result_is_inf_condition = !result_is_nan_condition && (any_pos_inf ^ any_neg_inf);
    assign result_inf_sign = any_neg_inf;

    // 对齐
    wire [`FP32_EXP_WIDTH-1:0] max_exponent;
    wire [NUM_INPUTS*`ALIGNED_MANT_WIDTH-1:0] aligned_mantissas_flat;
    wire [NUM_INPUTS-1:0] effective_signs;

    fp32_aligner_8to1 #(
        .NUM_INPUTS(NUM_INPUTS)
    ) aligner_inst (
        .i_signs               (signs_s0),
        .i_exponents_flat      (exponents_flat_s0),
        .i_mantissas_flat      (mantissas_flat_s0),
        .i_is_zeros            (is_zeros_s0),
        .i_is_infs             (is_infs_s0),
        .i_is_nans             (is_nans_s0),
        .o_max_exponent        (max_exponent),
        .o_aligned_mantissas_flat(aligned_mantissas_flat),
        .o_effective_signs     (effective_signs)
    );

    // Stage 1 寄存器
    reg [`FP32_EXP_WIDTH-1:0] max_exponent_s1;
    reg [NUM_INPUTS*`ALIGNED_MANT_WIDTH-1:0] aligned_mantissas_flat_s1;
    reg [NUM_INPUTS-1:0] effective_signs_s1;
    reg result_is_nan_condition_s1, result_is_inf_condition_s1;
    reg result_inf_sign_s1, no_positive_contribution_present_s1;
    reg any_valid_negative_s1, all_pos_zeros_s1, all_neg_zeros_s1;
    reg [1:0] dest_reg_idx_s1;
    reg invalid_operation_s1;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            max_exponent_s1 <= {`FP32_EXP_WIDTH{1'b0}};
            aligned_mantissas_flat_s1 <= {(NUM_INPUTS*`ALIGNED_MANT_WIDTH){1'b0}};
            effective_signs_s1 <= {NUM_INPUTS{1'b0}};
            result_is_nan_condition_s1 <= 1'b0;
            result_is_inf_condition_s1 <= 1'b0;
            result_inf_sign_s1 <= 1'b0;
            no_positive_contribution_present_s1 <= 1'b0;
            any_valid_negative_s1 <= 1'b0;
            all_pos_zeros_s1 <= 1'b0;
            all_neg_zeros_s1 <= 1'b0;
            dest_reg_idx_s1 <= 2'b0;
            invalid_operation_s1 <= 1'b0;
        end else if (w_cmd_valid_eff) begin
            max_exponent_s1 <= max_exponent;
            aligned_mantissas_flat_s1 <= aligned_mantissas_flat;
            effective_signs_s1 <= effective_signs;
            result_is_nan_condition_s1 <= result_is_nan_condition;
            result_is_inf_condition_s1 <= result_is_inf_condition;
            result_inf_sign_s1 <= result_inf_sign;
            no_positive_contribution_present_s1 <= no_positive_contribution_present_s0;
            any_valid_negative_s1 <= w_any_valid_negative_s0;
            all_pos_zeros_s1 <= w_all_pos_zeros_s0;
            all_neg_zeros_s1 <= w_all_neg_zeros_s0;
            dest_reg_idx_s1 <= dest_reg_idx_s0;
            invalid_operation_s1 <= invalid_operation;
        end
    end

    // ====================================================================
    // Stage 2: 正负分离 + 华莱士树累加
    // ====================================================================
    // 正负尾数分离
    wire [`ALIGNED_MANT_WIDTH-1:0] pos_mants_narrow [0:NUM_INPUTS-1];
    wire [`ALIGNED_MANT_WIDTH-1:0] neg_mants_narrow [0:NUM_INPUTS-1];
    
    generate
        for (j = 0; j < NUM_INPUTS; j = j + 1) begin : pos_neg_group
            wire [`ALIGNED_MANT_WIDTH-1:0] this_aligned_mantissa;
            assign this_aligned_mantissa = aligned_mantissas_flat_s1[(j+1)*`ALIGNED_MANT_WIDTH-1 : j*`ALIGNED_MANT_WIDTH];
            assign pos_mants_narrow[j] = (effective_signs_s1[j] == 1'b0) ? this_aligned_mantissa : {`ALIGNED_MANT_WIDTH{1'b0}};
            assign neg_mants_narrow[j] = (effective_signs_s1[j] == 1'b1) ? this_aligned_mantissa : {`ALIGNED_MANT_WIDTH{1'b0}};
        end
    endgenerate

    // 准备华莱士树输入数据 
    wire [NUM_INPUTS*`ALIGNED_MANT_WIDTH-1:0] pos_mants_flat_narrow;
    wire [NUM_INPUTS*`ALIGNED_MANT_WIDTH-1:0] neg_mants_flat_narrow;

    generate
        for (k = 0; k < NUM_INPUTS; k = k + 1) begin : flatten_mants
            assign pos_mants_flat_narrow[(k+1)*`ALIGNED_MANT_WIDTH-1 : k*`ALIGNED_MANT_WIDTH] = pos_mants_narrow[k];
            assign neg_mants_flat_narrow[(k+1)*`ALIGNED_MANT_WIDTH-1 : k*`ALIGNED_MANT_WIDTH] = neg_mants_narrow[k];
        end
    endgenerate

    // 使用华莱士树累加正负尾数 
    wire [`FULL_SUM_WIDTH:0] pos_sum;
    wire [`FULL_SUM_WIDTH:0] neg_sum;

    wallace_tree_8_inputs_8to1 #(
        .NUM_INPUTS(NUM_INPUTS),
        .WIDTH(`FULL_SUM_WIDTH),
        .IN_WIDTH(`ALIGNED_MANT_WIDTH)
    ) wallace_pos_sum_inst (
        .i_data_in(pos_mants_flat_narrow),
        .o_final_result(pos_sum)
    );

    wallace_tree_8_inputs_8to1 #(
        .NUM_INPUTS(NUM_INPUTS),
        .WIDTH(`FULL_SUM_WIDTH),
        .IN_WIDTH(`ALIGNED_MANT_WIDTH)
    ) wallace_neg_sum_inst (
        .i_data_in(neg_mants_flat_narrow),
        .o_final_result(neg_sum)
    );

    // Stage 2 寄存器
    reg [`FULL_SUM_WIDTH:0] pos_sum_s2, neg_sum_s2;
    reg [`FP32_EXP_WIDTH-1:0] max_exponent_s2;
    reg result_is_nan_condition_s2, result_is_inf_condition_s2;
    reg result_inf_sign_s2, no_positive_contribution_present_s2;
    reg any_valid_negative_s2, all_pos_zeros_s2, all_neg_zeros_s2;
    reg [1:0] dest_reg_idx_s2;
    reg [2:0] rounding_mode_s2;
    reg invalid_operation_s2;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            pos_sum_s2 <= {(`FULL_SUM_WIDTH+1){1'b0}};
            neg_sum_s2 <= {(`FULL_SUM_WIDTH+1){1'b0}};
            max_exponent_s2 <= {`FP32_EXP_WIDTH{1'b0}};
            result_is_nan_condition_s2 <= 1'b0;
            result_is_inf_condition_s2 <= 1'b0;
            result_inf_sign_s2 <= 1'b0;
            no_positive_contribution_present_s2 <= 1'b0;
            any_valid_negative_s2 <= 1'b0;
            all_pos_zeros_s2 <= 1'b0;
            all_neg_zeros_s2 <= 1'b0;
            dest_reg_idx_s2 <= 2'b0;
            rounding_mode_s2 <= `RM_RNE;
            invalid_operation_s2 <= 1'b0;
        end else if (valid_pipe[0]) begin
            pos_sum_s2 <= pos_sum;
            neg_sum_s2 <= neg_sum;
            max_exponent_s2 <= max_exponent_s1;
            result_is_nan_condition_s2 <= result_is_nan_condition_s1;
            result_is_inf_condition_s2 <= result_is_inf_condition_s1;
            result_inf_sign_s2 <= result_inf_sign_s1;
            no_positive_contribution_present_s2 <= no_positive_contribution_present_s1;
            any_valid_negative_s2 <= any_valid_negative_s1;
            all_pos_zeros_s2 <= all_pos_zeros_s1;
            all_neg_zeros_s2 <= all_neg_zeros_s1;
            dest_reg_idx_s2 <= dest_reg_idx_s1;
            rounding_mode_s2 <= rounding_mode_pipe[1];  // Stage 2 使用 Stage 1 的舍入模式
            invalid_operation_s2 <= invalid_operation_s1;
        end
    end

    // ====================================================================
    // Stage 3: 正负合成 + 规格化舍入
    // ====================================================================
    // 正负合成
    wire signed [`FULL_SUM_WIDTH+1:0] wallace_final_signed = $signed({1'b0, pos_sum_s2}) - $signed({1'b0, neg_sum_s2});
    wire [`FULL_SUM_WIDTH:0] abs_wallace_result = (wallace_final_signed < 0)
            ? -wallace_final_signed[`FULL_SUM_WIDTH:0]
            :  wallace_final_signed[`FULL_SUM_WIDTH:0];
    wire [`FULL_SUM_WIDTH:0] result_mant_raw = abs_wallace_result;
    
    // ====================================================================
    // 精确零结果的符号计算（符合IEEE 754标准）
    // ====================================================================
    // 当结果为精确零时（wallace_final_signed == 0），符号根据舍入模式和输入决定：
    // 
    // RDN模式（Round Down, towards -∞）:
    //   - 如果所有输入都是正零 → 正零（保持）
    //   - 如果所有输入都是负零 → 负零（保持）
    //   - 如果输入有正有负（x + (-x)）→ 负零（向下舍入）
    //
    // RUP模式（Round Up, towards +∞）:
    //   - 如果所有输入都是正零 → 正零（保持）
    //   - 如果所有输入都是负零 → 负零（保持）
    //   - 如果输入有正有负（x + (-x)）→ 正零（向上舍入）
    //
    // 其他模式（RNE, RTZ, RMM）:
    //   - 如果所有输入都是正零 → 正零
    //   - 如果所有输入都是负零 → 负零
    //   - 其他情况：根据no_positive_contribution_present_s2决定
    // ====================================================================
    wire result_sign;
    assign result_sign = (wallace_final_signed == 0) ? 
                         ((rounding_mode_s2 == `RM_RDN) ? 
                          // RDN模式：全正零保持正零，全负零保持负零，正负混合产生负零
                          (all_pos_zeros_s2 ? 1'b0 : 
                           (all_neg_zeros_s2 ? 1'b1 : 1'b1)) :  // 正负混合或全负零都产生负零
                          (rounding_mode_s2 == `RM_RUP) ? 
                          // RUP模式：全正零保持正零，全负零保持负零，正负混合产生正零
                          (all_pos_zeros_s2 ? 1'b0 : 
                           (all_neg_zeros_s2 ? 1'b1 : 1'b0)) :  // 正负混合产生正零
                          // 其他模式：全正零保持正零，全负零保持负零，其他根据输入决定
                          (all_pos_zeros_s2 ? 1'b0 : 
                           (all_neg_zeros_s2 ? 1'b1 : no_positive_contribution_present_s2))) :
                         // 非零结果：根据符号决定
                         (wallace_final_signed < 0);

    // 规格化与舍入 
    wire [`FP32_WIDTH-1:0] normalized_fp_out;
    wire norm_overflow;
    wire norm_underflow;
    wire norm_zero_out;
    wire norm_inexact;

    fp32_normalizer_rounder_8to1 #(
        .IN_WIDTH(`FULL_SUM_WIDTH+1) 
    ) normalizer_rounder_inst (
        .clk            (i_clk),
        .rst_n          (i_rst_n),
        .i_mant_raw     (result_mant_raw),   
        .i_exp          (max_exponent_s2),
        .i_sign         (result_sign),
        .i_rounding_mode(rounding_mode_s2),  // 传递舍入模式
        .o_fp_out       (normalized_fp_out),
        .o_overflow     (norm_overflow),
        .o_underflow    (norm_underflow),
        .o_zero_out     (norm_zero_out),
        .o_inexact      (norm_inexact)  // Inexact标志
    );

    // Stage 3 寄存器
    wire [`FP32_WIDTH-1:0] normalized_fp_out_s3;
    wire norm_overflow_s3, norm_underflow_s3, norm_zero_out_s3, norm_inexact_s3;
    reg result_is_nan_condition_s3, result_is_inf_condition_s3;
    reg result_inf_sign_s3, result_sign_s3;
    reg [1:0] dest_reg_idx_s3;
    reg invalid_operation_s3;

    // 组合逻辑赋值（来自fp32_normalizer_rounder的输出）
    assign normalized_fp_out_s3 = normalized_fp_out;
    assign norm_overflow_s3 = norm_overflow;
    assign norm_underflow_s3 = norm_underflow;
    assign norm_zero_out_s3 = norm_zero_out;
    assign norm_inexact_s3 = norm_inexact;
    
    // 时序逻辑赋值（Stage 2的控制信号）
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            result_is_nan_condition_s3 <= 1'b0;
            result_is_inf_condition_s3 <= 1'b0;
            result_inf_sign_s3 <= 1'b0;
            result_sign_s3 <= 1'b0;
            dest_reg_idx_s3 <= 2'b0;
            invalid_operation_s3 <= 1'b0;
        end else if (valid_pipe[1]) begin
            result_is_nan_condition_s3 <= result_is_nan_condition_s2;
            result_is_inf_condition_s3 <= result_is_inf_condition_s2;
            result_inf_sign_s3 <= result_inf_sign_s2;
            result_sign_s3 <= result_sign;
            dest_reg_idx_s3 <= dest_reg_idx_s2;
            invalid_operation_s3 <= invalid_operation_s2;
        end
    end

    // ====================================================================
    // Stage 4: 打包 + 输出
    // ====================================================================
    // 打包最终结果
    wire packer_sign = normalized_fp_out_s3[`FP32_WIDTH-1];
    wire [`FP32_EXP_WIDTH-1:0] packer_exp  = normalized_fp_out_s3[`FP32_WIDTH-2 : `FP32_MANT_WIDTH];
    wire [`FP32_MANT_WIDTH-1:0] packer_mant = normalized_fp_out_s3[`FP32_MANT_WIDTH-1 : 0];

    wire is_special_case = result_is_nan_condition_s3 || result_is_inf_condition_s3 || norm_overflow_s3 || norm_underflow_s3;
    wire is_zero_out     = !is_special_case && norm_zero_out_s3;

    wire final_sign_for_packer = (result_is_inf_condition_s3 || norm_overflow_s3) ?
                                   (result_is_inf_condition_s3 ? result_inf_sign_s3 : result_sign_s3) :
                                   (is_zero_out ? result_sign_s3 : packer_sign);

    wire [`FP32_WIDTH-1:0] fp_sum_result_wire;
    fp32_packer_8to1 # (.IEEE_754(IEEE_754)) packer_inst (
        .i_final_sign     (final_sign_for_packer),
        .i_final_exponent (packer_exp),  
        .i_final_mantissa (packer_mant),
        .i_result_is_zero (is_zero_out),
        .i_result_is_inf  (result_is_inf_condition_s3 || norm_overflow_s3),
        .i_result_is_nan  (result_is_nan_condition_s3),
        .o_fp_out         (fp_sum_result_wire)
    );
    
    // ====================================================================
    // Exception Flags Generation
    // ====================================================================
    wire [4:0] exception_flags_wire;
    assign exception_flags_wire[`EXC_INVALID]   = invalid_operation_s3;
    assign exception_flags_wire[`EXC_DIV_ZERO]  = 1'b0;  // N/A for adder
    assign exception_flags_wire[`EXC_OVERFLOW]  = norm_overflow_s3 && !result_is_nan_condition_s3;
    assign exception_flags_wire[`EXC_UNDERFLOW] = norm_underflow_s3 && !result_is_nan_condition_s3;
    assign exception_flags_wire[`EXC_INEXACT]   = norm_inexact_s3 && !result_is_nan_condition_s3 && !is_zero_out;



    // ====================================================================
    // Stage 4: 打包 + 输出（组合逻辑）
    // ====================================================================
    // 输出选择逻辑（直接使用Stage 3的组合逻辑输出）
    // 使用valid_pipe[3]作为cmd_valid的延迟版本
    reg [4:0] exception_flags_reg;
    
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_dr_fp32addtree8to1_d <= 128'b0;
            exception_flags_reg <= 5'b0;
        end else if (valid_pipe[2]) begin
            case (dest_reg_idx_s3)
                2'b00: o_dr_fp32addtree8to1_d[31:0]   <= fp_sum_result_wire;
                2'b01: o_dr_fp32addtree8to1_d[63:32]  <= fp_sum_result_wire;
                2'b10: o_dr_fp32addtree8to1_d[95:64]  <= fp_sum_result_wire;
                2'b11: o_dr_fp32addtree8to1_d[127:96] <= fp_sum_result_wire;
                default: o_dr_fp32addtree8to1_d <= 128'b0;
            endcase
            exception_flags_reg <= exception_flags_wire;
        end
    end
    
    assign o_exception_flags = exception_flags_reg;

`endif

endmodule
