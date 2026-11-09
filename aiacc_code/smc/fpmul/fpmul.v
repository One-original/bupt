`timescale 1ns / 1ps

// Include rounding mode definitions
`include "fp32_defines.vh"


module fpmul  #(
    parameter SMC_ID = 0,                // SMC ID for this module
    parameter IEEE_754 = 1
)(
    // 全局信号
    input  wire         clk,
    input  wire         rst_n,

    input  wire [127:0] dvr_fpmul_s0,
    input  wire [127:0] dvr_fpmul_s1,
    input  wire [7:0]   cru_fpmul,       // [7:3]=smc_id_en, [2]=dst_prec, [1]=src_prec, [0]=inst_valid
    input  wire [2:0]   i_rounding_mode,  // 000=RNE, 001=RTZ, 010=RDN, 011=RUP, 100=RMM

    output reg [7:0]    cru_fpmul_o,
    output  [127:0]     dr_fpmul_d,
    output  [19:0]      o_exception_flags   // Exception flags per lane (flattened 4*5): [4:0]=lane0, [9:5]=lane1, ...
);

    wire [4:0] smc_id_en = cru_fpmul[7:3];
    wire inst_valid = cru_fpmul[0];
    wire inst_valid_eff = inst_valid && (SMC_ID[4:0] <= smc_id_en);
    wire src_precision_is_32b = cru_fpmul[1];
    wire dst_precision_is_32b = cru_fpmul[2];
    wire [127:0] dvr_fpmul_s0_gated = inst_valid_eff ? dvr_fpmul_s0 : 128'd0;
    wire [127:0] dvr_fpmul_s1_gated = inst_valid_eff ? dvr_fpmul_s1 : 128'd0;
    wire [2:0] rounding_mode_gated = inst_valid_eff ? i_rounding_mode : `RM_RNE;

    // 控制信号与有效信号延迟，匹配 5 级子模块流水
    reg [6:0] v_pipe;
    reg [6:0] src32_pipe;
    reg [6:0] dst32_pipe;
    reg [2:0] rounding_mode_pipe [0:4];  // Pipeline rounding mode

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_pipe      <= 7'd0;
            src32_pipe  <= 7'd0;
            dst32_pipe  <= 7'd0;
            cru_fpmul_o <= 8'b0;
            rounding_mode_pipe[0] <= `RM_RNE;
            rounding_mode_pipe[1] <= `RM_RNE;
            rounding_mode_pipe[2] <= `RM_RNE;
            rounding_mode_pipe[3] <= `RM_RNE;
            rounding_mode_pipe[4] <= `RM_RNE;
        end else begin
            v_pipe      <= {v_pipe[5:0], inst_valid_eff};
            src32_pipe  <= {src32_pipe[5:0], src_precision_is_32b};
            dst32_pipe  <= {dst32_pipe[5:0], dst_precision_is_32b};
            cru_fpmul_o <= cru_fpmul;
            rounding_mode_pipe[0] <= rounding_mode_gated;
            rounding_mode_pipe[1] <= rounding_mode_pipe[0];
            rounding_mode_pipe[2] <= rounding_mode_pipe[1];
            rounding_mode_pipe[3] <= rounding_mode_pipe[2];
            rounding_mode_pipe[4] <= rounding_mode_pipe[3];
        end
    end

    wire v_out          = v_pipe[3];
    wire src32_out      = src32_pipe[3];
    wire dst32_out      = dst32_pipe[3];

    wire [127:0] result_comb;
    reg  [127:0] dr_fpmul_d_reg;

    //------------------------------------------------------------------
    // 并行浮点乘法通道生成（Generate 块）
    //------------------------------------------------------------------
    wire [31:0] s0_lane [3:0];
    wire [31:0] s1_lane [3:0];
    wire [31:0] result_32 [3:0];
    wire [15:0] result_16_low [3:0];
    wire [15:0] result_16_high [3:0];
    wire        v_lane_32    [3:0];
    wire        v_lane_16_low    [3:0];
    wire        v_lane_16_high    [3:0];
    wire [4:0]  exception_flags_32 [3:0];
    wire [4:0]  exception_flags_16_low [3:0];
    wire [4:0]  exception_flags_16_high [3:0];
    wire [4:0]  o_exception_flags_arr [3:0];  // internal array, flattened to port
    genvar i;  
    generate
        
        for (i = 0; i < 4; i = i + 1) begin : fpmul_lanes
            
            assign s0_lane[i] = dvr_fpmul_s0_gated[i*32 +: 32];
            assign s1_lane[i] = dvr_fpmul_s1_gated[i*32 +: 32];
            
            // --- 32 位浮点乘法单元实例化 ---
`ifdef USE_FPGA_IP
            floating_point_Mul_FP32_L4_FPMUL u_fp32_mul_ip (
                .aclk(clk),                                  // input wire aclk
                .aresetn(rst_n),                              // input wire aresetn
                .s_axis_a_tvalid(inst_valid_eff),            // input wire s_axis_a_tvalid
                .s_axis_a_tdata(s0_lane[i]),              // input wire [31 : 0] s_axis_a_tdata
                .s_axis_b_tvalid(inst_valid_eff),            // input wire s_axis_b_tvalid
                .s_axis_b_tdata(s1_lane[i]),              // input wire [31 : 0] s_axis_b_tdata
                .m_axis_result_tvalid(v_lane_32[i]),  // output wire m_axis_result_tvalid
                .m_axis_result_tdata(result_32[i])     // output wire [31 : 0] m_axis_result_tdata
            );
            assign exception_flags_32[i] = 5'b0;
`else
            fp32_multiplier #(.IEEE_754(IEEE_754)) u_fp32_mul (
                .clk    (clk),
                .rst_n  (rst_n),
                .valid_i(inst_valid_eff),
                .rounding_mode(rounding_mode_gated),  // Pass gated rounding mode
                .a      (s0_lane[i]),
                .b      (s1_lane[i]),
                .valid_o(v_lane_32[i]),
                .result (result_32[i]),
                .exception_flags(exception_flags_32[i])
            );
`endif

            // --- 16 位浮点乘法单元实例化 ---

`ifdef USE_FPGA_IP
            floating_point_Mul_FP16_L4_FPMUL u_fp16_mul_low_ip (
                .aclk(clk),                                  // input wire aclk
                .aresetn(rst_n),                              // input wire aresetn
                .s_axis_a_tvalid(inst_valid_eff),            // input wire s_axis_a_tvalid
                .s_axis_a_tdata(s0_lane[i][15:0]),              // input wire [15 : 0] s_axis_a_tdata
                .s_axis_b_tvalid(inst_valid_eff),            // input wire s_axis_b_tvalid
                .s_axis_b_tdata(s1_lane[i][15:0]),              // input wire [15 : 0] s_axis_b_tdata
                .m_axis_result_tvalid(v_lane_16_low[i]),  // output wire m_axis_result_tvalid
                .m_axis_result_tdata(result_16_low[i])    // output wire [15 : 0] m_axis_result_tdata
            );
            assign exception_flags_16_low[i] = 5'b0;
`else
            fp16_multiplier #(.IEEE_754(IEEE_754)) u_fp16_mul_low (
                .clk    (clk),
                .rst_n  (rst_n),
                .valid_i(inst_valid_eff),
                .rounding_mode(rounding_mode_gated),  // Pass gated rounding mode
                .a      (s0_lane[i][15:0]),
                .b      (s1_lane[i][15:0]),
                .valid_o(v_lane_16_low[i]),
                .result (result_16_low[i]),
                .exception_flags(exception_flags_16_low[i])
            );
`endif
            
`ifdef USE_FPGA_IP
            floating_point_Mul_FP16_L4_FPMUL u_fp16_mul_high_ip (
                .aclk(clk),                                  // input wire aclk
                .aresetn(rst_n),                              // input wire aresetn
                .s_axis_a_tvalid(inst_valid_eff),            // input wire s_axis_a_tvalid
                .s_axis_a_tdata(s0_lane[i][31:16]),              // input wire [15 : 0] s_axis_a_tdata
                .s_axis_b_tvalid(inst_valid_eff),            // input wire s_axis_b_tvalid
                .s_axis_b_tdata(s1_lane[i][31:16]),              // input wire [15 : 0] s_axis_b_tdata
                .m_axis_result_tvalid(v_lane_16_high[i]),  // output wire m_axis_result_tvalid
                .m_axis_result_tdata(result_16_high[i])    // output wire [15 : 0] m_axis_result_tdata
            );
            assign exception_flags_16_high[i] = 5'b0;
`else
            fp16_multiplier #(.IEEE_754(IEEE_754)) u_fp16_mul_high (
                .clk    (clk),
                .rst_n  (rst_n),
                .valid_i(inst_valid_eff),
                .rounding_mode(rounding_mode_gated),  // Pass gated rounding mode
                .a      (s0_lane[i][31:16]),
                .b      (s1_lane[i][31:16]),
                .valid_o(v_lane_16_high[i]),
                .result (result_16_high[i]),
                .exception_flags(exception_flags_16_high[i])
            );
`endif

            assign result_comb[i*32 +: 32] = 
                (src32_out && dst32_out) ? result_32[i] :  // 都为1时输出32位
                (~src32_out && ~dst32_out) ? {result_16_high[i], result_16_low[i]} :  // 都为0时输出16位
                32'h00000000;  // 其他状态未知，输出未知值
            
            // Exception flags selection based on precision
            // For FP16 mode, combine flags from both lanes (OR operation for each flag bit)
            wire [4:0] exception_flags_16_combined = exception_flags_16_high[i] | exception_flags_16_low[i];
            assign o_exception_flags_arr[i] = 
                (src32_out && dst32_out) ? exception_flags_32[i] :  // FP32 mode
                (~src32_out && ~dst32_out) ? exception_flags_16_combined :  // FP16 mode: combine both lanes
                5'b0;  // Unknown state
        end
    endgenerate
    assign o_exception_flags = {o_exception_flags_arr[3], o_exception_flags_arr[2], o_exception_flags_arr[1], o_exception_flags_arr[0]};
    

    assign dr_fpmul_d = v_out ? result_comb : dr_fpmul_d_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dr_fpmul_d_reg <= 128'b0;
        else if (v_out) 
            dr_fpmul_d_reg <= result_comb;
        else 
            dr_fpmul_d_reg <= dr_fpmul_d_reg;
    end
    // cru_fpmul_o is one-cycle delayed passthrough of cru_fpmul

endmodule

module fp16_multiplier #(
    parameter IEEE_754 = 1    // IEEE 754 mode
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_i,
    input  wire [2:0]  rounding_mode,  // Rounding mode: 000=RNE, 001=RTZ, 010=RDN, 011=RUP, 100=RMM
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg         valid_o,
    output reg  [15:0] result,
    output reg  [4:0]  exception_flags  // Exception flags: [0]=Invalid, [1]=DivZero, [2]=Overflow, [3]=Underflow, [4]=Inexact
);

    localparam FP16_EXP_WIDTH  = 8'd5;          
    localparam FP16_MANT_WIDTH = 8'd10;        
    localparam FP16_BIAS       = 8'sd15;         

    // stage0: 输入与特殊值检测（组合逻辑）
    wire        v_s0;
    wire        sign_a_s0, sign_b_s0;
    wire [FP16_EXP_WIDTH-1:0]  exp_a_s0, exp_b_s0;
    wire [FP16_MANT_WIDTH-1:0] mant_a_s0, mant_b_s0;
    wire        a_is_zero_s0, b_is_zero_s0;
    wire        a_is_inf_s0 , b_is_inf_s0;
    wire        a_is_nan_s0 , b_is_nan_s0;
    wire        a_is_denorm_s0, b_is_denorm_s0;

    // 组合逻辑赋值
    assign v_s0 = valid_i;
    assign sign_a_s0 = a[15];
    assign sign_b_s0 = b[15];
    assign exp_a_s0  = a[14:10];
    assign exp_b_s0  = b[14:10];
    assign mant_a_s0 = a[9:0];
    assign mant_b_s0 = b[9:0];
    assign a_is_zero_s0   = (a[14:10] == 0) && (a[9:0] == 0);
    assign b_is_zero_s0   = (b[14:10] == 0) && (b[9:0] == 0);
    assign a_is_inf_s0    = (a[14:10] == 5'b11111) && (a[9:0] == 0);
    assign b_is_inf_s0    = (b[14:10] == 5'b11111) && (b[9:0] == 0);
    assign a_is_nan_s0    = (a[14:10] == 5'b11111) && (a[9:0] != 0);
    assign b_is_nan_s0    = (b[14:10] == 5'b11111) && (b[9:0] != 0);
    assign a_is_denorm_s0 = (a[14:10] == 0) && (a[9:0] != 0);
    assign b_is_denorm_s0 = (b[14:10] == 0) && (b[9:0] != 0);
    // 共同信号声明
    wire output_is_zero_s0;
    wire output_is_inf_s0;
    wire output_is_nan_s0;
    wire sign_out_s0;
    wire [FP16_MANT_WIDTH:0] mant_a_with_hidden;
    wire [FP16_MANT_WIDTH:0] mant_b_with_hidden;
            wire inf_times_zero_s0;
    generate
        if (IEEE_754 == 1) begin : gen_ieee754
            assign output_is_zero_s0 = a_is_zero_s0 || b_is_zero_s0;
            assign inf_times_zero_s0 = (a_is_inf_s0 && b_is_zero_s0) || (b_is_inf_s0 && a_is_zero_s0);
            assign output_is_inf_s0  = (a_is_inf_s0 || b_is_inf_s0) && !output_is_zero_s0;
            assign output_is_nan_s0  = a_is_nan_s0 || b_is_nan_s0 || inf_times_zero_s0;
            assign sign_out_s0 = output_is_nan_s0 ? 1'b0 : sign_a_s0 ^ sign_b_s0;
            assign mant_a_with_hidden = a_is_denorm_s0 ? {1'b0, mant_a_s0} : {1'b1, mant_a_s0};
            assign mant_b_with_hidden = b_is_denorm_s0 ? {1'b0, mant_b_s0} : {1'b1, mant_b_s0};

        end else begin : gen_non_ieee754
            wire a_is_min_norm_s0;
            wire b_is_min_norm_s0;

            
            assign a_is_min_norm_s0 = (a[14:10] == 5'b00001) && (a[9:0] == 10'b0);
            assign b_is_min_norm_s0 = (b[14:10] == 5'b00001) && (b[9:0] == 10'b0);
            // Denorm and minimum norm inputs are treated as zero, but sign bit is handled normally
            assign output_is_zero_s0 = a_is_zero_s0 || b_is_zero_s0 || a_is_denorm_s0 || b_is_denorm_s0 || a_is_min_norm_s0 || b_is_min_norm_s0;
            assign inf_times_zero_s0 = (a_is_inf_s0 && (b_is_zero_s0 || b_is_denorm_s0 || b_is_min_norm_s0)) || ((a_is_zero_s0 || a_is_denorm_s0 || a_is_min_norm_s0) && b_is_inf_s0);
            assign output_is_inf_s0  = (a_is_inf_s0 || b_is_inf_s0) && !output_is_zero_s0;
            assign output_is_nan_s0  = a_is_nan_s0 || b_is_nan_s0 || inf_times_zero_s0;
            assign sign_out_s0 = output_is_nan_s0 ? 1'b0 : sign_a_s0 ^ sign_b_s0;
            assign mant_a_with_hidden = {1'b1, mant_a_s0};
            assign mant_b_with_hidden = {1'b1, mant_b_s0};

        end
    endgenerate

    // stage1: 尾数乘法
    reg        v_s1;
    reg        output_is_zero_s1, output_is_inf_s1, output_is_nan_s1;
    reg        sign_out_s1;
    reg        denormal_input_s1;
    reg [FP16_EXP_WIDTH-1:0]  exp_a_s1, exp_b_s1;
    reg [21:0] mant_product_s1;


    reg a_is_denorm_s1, b_is_denorm_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s1 <= 1'b0;
            output_is_zero_s1 <= 1'b0;
            output_is_inf_s1 <= 1'b0;
            output_is_nan_s1 <= 1'b0;
            sign_out_s1 <= 1'b0;
            a_is_denorm_s1  <= 1'b0;
            b_is_denorm_s1  <= 1'b0;
            denormal_input_s1 <= 1'b0;
            exp_a_s1 <= 5'b0;
            exp_b_s1 <= 5'b0;
            mant_product_s1 <= 22'b0;
        end else begin
            v_s1 <= v_s0;
            if (v_s0) begin
                mant_product_s1   <= mant_a_with_hidden * mant_b_with_hidden;
                output_is_zero_s1 <= output_is_zero_s0;
                output_is_inf_s1  <= output_is_inf_s0;
                output_is_nan_s1  <= output_is_nan_s0;
                sign_out_s1       <= sign_out_s0;
                a_is_denorm_s1    <= IEEE_754 ? a_is_denorm_s0 : 1'b0;
                b_is_denorm_s1    <= IEEE_754 ? b_is_denorm_s0 : 1'b0;
                denormal_input_s1 <= IEEE_754 ? a_is_denorm_s0 || b_is_denorm_s0 : 1'b0;
                exp_a_s1          <= exp_a_s0;
                exp_b_s1          <= exp_b_s0;
            end
        end
    end

    wire [4:0] leading_zeros;
    leading_zero_counter_fp16_m #(
        .DATA_WIDTH(22),
        .COUNT_WIDTH(5)
    ) lzc_inst (
        .data_in(mant_product_s1),
        .leading_zeros(leading_zeros)
    );

    wire is_normalized_s1 = mant_product_s1[21];
    wire [21:0] normalized_mant_w = denormal_input_s1 ? (mant_product_s1 << leading_zeros) :
                                     is_normalized_s1 ? (mant_product_s1 >> 1) :
                                     mant_product_s1;
    wire [FP16_MANT_WIDTH-1:0] base_mantissa_w = denormal_input_s1 ? normalized_mant_w[20:11] :
                                                  is_normalized_s1 ? mant_product_s1[20:11] :
                                                  mant_product_s1[19:10];
    wire guard_bit_w  = denormal_input_s1 ? normalized_mant_w[10] :
                        is_normalized_s1 ? mant_product_s1[10] :
                        mant_product_s1[9];
    wire round_bit_w  = denormal_input_s1 ? normalized_mant_w[9] :
                        is_normalized_s1 ? mant_product_s1[9] :
                        mant_product_s1[8];
    wire sticky_bit_w = denormal_input_s1 ? (|normalized_mant_w[8:0]) :
                        is_normalized_s1 ? (|mant_product_s1[8:0]) :
                        (|mant_product_s1[7:0]);

    // stage2: 规格化与 GRS（组合逻辑）
    wire        v_s2;
    wire        output_is_zero_s2, output_is_inf_s2, output_is_nan_s2;
    wire        sign_out_s2;
    wire        denormal_input_s2;
    wire [FP16_EXP_WIDTH-1:0]  exp_a_s2, exp_b_s2;
    wire [21:0] mant_product_s2;
    wire signed [4:0]  leading_zeros_s2;
    wire [21:0] normalized_mant_s2;
    wire [FP16_MANT_WIDTH-1:0] base_mantissa_s2;
    wire        guard_bit_s2, round_bit_s2, sticky_bit_s2;
    wire        a_is_denorm_s2, b_is_denorm_s2;

    // 组合逻辑赋值
    assign v_s2 = v_s1;
    assign output_is_zero_s2 = output_is_zero_s1;
    assign output_is_inf_s2  = output_is_inf_s1;
    assign output_is_nan_s2  = output_is_nan_s1;
    assign sign_out_s2       = sign_out_s1;
    assign denormal_input_s2 = denormal_input_s1;
    assign exp_a_s2          = exp_a_s1;
    assign exp_b_s2          = exp_b_s1;
    assign mant_product_s2   = mant_product_s1;
    assign leading_zeros_s2  = leading_zeros;
    assign normalized_mant_s2= normalized_mant_w;
    assign base_mantissa_s2  = base_mantissa_w;
    assign guard_bit_s2      = guard_bit_w;
    assign round_bit_s2      = round_bit_w;
    assign sticky_bit_s2     = sticky_bit_w;
    assign a_is_denorm_s2    = a_is_denorm_s1;
    assign b_is_denorm_s2    = b_is_denorm_s1;

    // stage3: 舍入与指数计算
    reg        v_s3;
    reg        output_is_zero_s3, output_is_inf_s3, output_is_nan_s3;
    reg        sign_out_s3;
    reg [21:0] mant_product_s3;
    reg [FP16_MANT_WIDTH-1:0] base_mantissa_s3;
    reg        guard_bit_s3, round_bit_s3, sticky_bit_s3;
    reg signed [7:0] exp_pre_round_s3;
    reg signed [7:0] exp_out_biased_s3;
    reg        rounding_overflow_s3;
    reg [2:0]  rounding_mode_s3;  // Pipeline rounding mode

    wire signed [7:0] exp_a_unbiased;
    wire signed [7:0] exp_b_unbiased;
    generate
        if (IEEE_754 == 1) begin : gen_ieee754_exp
            assign exp_a_unbiased = a_is_denorm_s2 ? -8'sd14 : {3'd0, exp_a_s2} - FP16_BIAS;
            assign exp_b_unbiased = b_is_denorm_s2 ? -8'sd14 : {3'd0, exp_b_s2} - FP16_BIAS;
        end else begin : gen_non_ieee754_exp
            assign exp_a_unbiased = {3'd0, exp_a_s2} - FP16_BIAS;
            assign exp_b_unbiased = {3'd0, exp_b_s2} - FP16_BIAS;
        end
    endgenerate
    wire signed [7:0] exp_out_unbiased = exp_a_unbiased + exp_b_unbiased;
    wire signed [7:0] exp_adjustment = denormal_input_s2 ?
                                       (8'sd0 - {3'd0, leading_zeros_s2} + {7'b0, normalized_mant_s2[21]}) :
                                       (mant_product_s2[21] ? 8'd1 : 8'd0);
    wire signed [7:0] exp_pre_round_w = exp_out_unbiased + exp_adjustment + FP16_BIAS;

    // Rounding decision based on mode (Stage 2)
    wire bit_lsb_s2 = base_mantissa_s2[0];
    wire has_discarded_bits_s2 = guard_bit_s2 | round_bit_s2 | sticky_bit_s2;
    reg round_up_s2;
    always @(*) begin
        case (rounding_mode)
            `RM_RNE: begin  // Round to Nearest, ties to Even
                round_up_s2 = (guard_bit_s2 & (round_bit_s2 | sticky_bit_s2)) | 
                              (guard_bit_s2 & ~round_bit_s2 & ~sticky_bit_s2 & bit_lsb_s2);
            end
            `RM_RTZ: begin  // Round Towards Zero
                round_up_s2 = 1'b0;
            end
            `RM_RDN: begin  // Round Down (towards -∞)
                round_up_s2 = sign_out_s2 & has_discarded_bits_s2;
            end
            `RM_RUP: begin  // Round Up (towards +∞)
                round_up_s2 = ~sign_out_s2 & has_discarded_bits_s2;
            end
            `RM_RMM: begin  // Round to Nearest, ties to Max magnitude
                round_up_s2 = guard_bit_s2;
            end
            default: begin  // Default to RNE
                round_up_s2 = (guard_bit_s2 & (round_bit_s2 | sticky_bit_s2)) | 
                              (guard_bit_s2 & ~round_bit_s2 & ~sticky_bit_s2 & bit_lsb_s2);
            end
        endcase
    end

    wire [10:0] rounded_mantissa = base_mantissa_s2 + round_up_s2;
    wire rounding_overflow_w = rounded_mantissa[10];
    wire signed [7:0] exp_out_biased_w = exp_pre_round_w + (rounding_overflow_w ? 8'd1 : 8'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s3 <= 1'b0;
            output_is_zero_s3 <= 1'b0;
            output_is_inf_s3 <= 1'b0;
            output_is_nan_s3 <= 1'b0;
            sign_out_s3 <= 1'b0;
            mant_product_s3 <= 22'b0;
            base_mantissa_s3 <= 10'b0;
            guard_bit_s3 <= 1'b0;
            round_bit_s3 <= 1'b0;
            sticky_bit_s3 <= 1'b0;
            exp_pre_round_s3 <= 8'b0;
            exp_out_biased_s3 <= 8'b0;
            rounding_overflow_s3 <= 1'b0;
            rounding_mode_s3 <= `RM_RNE;
        end else begin
            v_s3 <= v_s2;
            if (v_s2) begin
                output_is_zero_s3 <= output_is_zero_s2;
                output_is_inf_s3  <= output_is_inf_s2;
                output_is_nan_s3  <= output_is_nan_s2;
                sign_out_s3       <= sign_out_s2;
                mant_product_s3   <= mant_product_s2;
                base_mantissa_s3  <= base_mantissa_s2;
                guard_bit_s3      <= guard_bit_s2;
                round_bit_s3      <= round_bit_s2;
                sticky_bit_s3     <= sticky_bit_s2;
                exp_pre_round_s3  <= exp_pre_round_w;
                exp_out_biased_s3 <= exp_out_biased_w;
                rounding_overflow_s3 <= rounding_overflow_w;
                rounding_mode_s3  <= rounding_mode;
            end
        end
    end
    wire exponent_overflow = exp_out_biased_s3 > 8'sd30;
    wire exponent_underflow = exp_pre_round_s3 < 8'sd1;
    wire result_is_denormal = (exp_pre_round_s3 <= 0) && (exp_pre_round_s3 >= -8'sd24) && (mant_product_s3 != 0);
    wire signed [5:0] denormal_shift = (exp_pre_round_s3 <= 0) ? (8'sd1 - exp_pre_round_s3) : 6'd0;
    wire [25:0] extended_mantissa = {2'b01, base_mantissa_s3, guard_bit_s3, round_bit_s3, sticky_bit_s3, 11'd0};
    wire [25:0] pre_shifted = (denormal_shift == 6'sd0) ? extended_mantissa : (extended_mantissa >> denormal_shift);
    
    // Overflow handling based on rounding mode
    wire [FP16_EXP_WIDTH-1:0] exp_max = 5'd31;
    wire [FP16_EXP_WIDTH-1:0] exp_max_finite = 5'd30;
    wire [FP16_MANT_WIDTH-1:0] mant_max = {FP16_MANT_WIDTH{1'b1}};
    // stage4: 结果组装
    reg        v_s4;
    reg        output_is_zero_s4, output_is_inf_s4, output_is_nan_s4;
    reg        sign_out_s4;
    reg signed [7:0] exp_pre_round_s4;
    reg signed [7:0] exp_out_biased_s4;
    reg        rounding_overflow_s4;
    reg [FP16_MANT_WIDTH-1:0] base_mantissa_s4;
    reg        guard_bit_s4, round_bit_s4, sticky_bit_s4;
    reg [21:0] mant_product_s4;
    reg        exponent_overflow_s4;
    reg        exponent_underflow_s4;
    reg        result_is_denormal_s4;
    reg signed [5:0] denormal_shift_s4;
    reg [25:0] extended_mantissa_s4;
    reg [25:0] pre_shifted_s4;
    reg [9:0] denormal_mantissa_raw_s4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s4 <= 1'b0;
            output_is_zero_s4 <= 1'b0;
            output_is_inf_s4 <= 1'b0;
            output_is_nan_s4 <= 1'b0;
            sign_out_s4 <= 1'b0;
            exp_pre_round_s4 <= 8'b0;
            exp_out_biased_s4 <= 8'b0;
            rounding_overflow_s4 <= 1'b0;
            base_mantissa_s4 <= 10'b0;
            guard_bit_s4 <= 1'b0;
            round_bit_s4 <= 1'b0;
            sticky_bit_s4 <= 1'b0;
            mant_product_s4 <= 22'b0;
            exponent_overflow_s4 <= 1'b0;
            exponent_underflow_s4 <= 1'b0;
            result_is_denormal_s4 <= 1'b0;
            denormal_shift_s4 <= 6'b0;
            extended_mantissa_s4 <= 26'b0;
            pre_shifted_s4 <= 26'b0;
            denormal_mantissa_raw_s4 <= 10'b0;
        end else begin
            v_s4 <= v_s3;
            if (v_s3) begin
                output_is_zero_s4 <= output_is_zero_s3;
                output_is_inf_s4  <= output_is_inf_s3;
                output_is_nan_s4  <= output_is_nan_s3;
                sign_out_s4       <= sign_out_s3;
                exp_pre_round_s4  <= exp_pre_round_s3;
                exp_out_biased_s4 <= exp_out_biased_s3;
                rounding_overflow_s4 <= rounding_overflow_s3;
                base_mantissa_s4  <= base_mantissa_s3;
                guard_bit_s4      <= guard_bit_s3;
                round_bit_s4      <= round_bit_s3;
                sticky_bit_s4     <= sticky_bit_s3;
                mant_product_s4   <= mant_product_s3;
                exponent_overflow_s4    <= exponent_overflow;
                exponent_underflow_s4    <= exponent_underflow;
                result_is_denormal_s4    <= result_is_denormal;
                denormal_shift_s4    <= denormal_shift;
                extended_mantissa_s4    <= extended_mantissa;
                pre_shifted_s4    <= pre_shifted;
                denormal_mantissa_raw_s4    <= pre_shifted[23:14];

            end
        end
    end

    wire denormal_guard  = pre_shifted_s4[13];
    wire denormal_round  = pre_shifted_s4[12];
    wire denormal_sticky = |pre_shifted_s4[11:0];
    wire denormal_lsb = denormal_mantissa_raw_s4[0];
    wire denormal_has_discarded = denormal_guard | denormal_round | denormal_sticky;
    
    // Denormal rounding decision based on mode
    reg denormal_round_up_s4;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RNE: begin
                denormal_round_up_s4 = (denormal_guard & (denormal_round | denormal_sticky)) | 
                                       (denormal_guard & ~denormal_round & ~denormal_sticky & denormal_lsb);
            end
            `RM_RTZ: begin
                denormal_round_up_s4 = 1'b0;
            end
            `RM_RDN: begin
                denormal_round_up_s4 = sign_out_s4 & denormal_has_discarded;
            end
            `RM_RUP: begin
                denormal_round_up_s4 = ~sign_out_s4 & denormal_has_discarded;
            end
            `RM_RMM: begin
                denormal_round_up_s4 = denormal_guard;
            end
            default: begin
                denormal_round_up_s4 = (denormal_guard & (denormal_round | denormal_sticky)) | 
                                       (denormal_guard & ~denormal_round & ~denormal_sticky & denormal_lsb);
            end
        endcase
    end
    
    wire [10:0] denormal_rounded = denormal_mantissa_raw_s4 + denormal_round_up_s4;
    wire [9:0] denormal_mantissa_temp = denormal_rounded[9:0];
    wire denormal_overflow = denormal_rounded[10];
    wire denormal_rounded_is_zero = (denormal_mantissa_temp == 10'b0);

    // Normal rounding decision based on mode (Stage 4)
    wire bit_lsb_s4 = base_mantissa_s4[0];
    wire has_discarded_bits_s4 = guard_bit_s4 | round_bit_s4 | sticky_bit_s4;
    reg round_up_s4;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RNE: begin
                round_up_s4 = (guard_bit_s4 & (round_bit_s4 | sticky_bit_s4)) | 
                              (guard_bit_s4 & ~round_bit_s4 & ~sticky_bit_s4 & bit_lsb_s4);
            end
            `RM_RTZ: begin
                round_up_s4 = 1'b0;
            end
            `RM_RDN: begin
                round_up_s4 = sign_out_s4 & has_discarded_bits_s4;
            end
            `RM_RUP: begin
                round_up_s4 = ~sign_out_s4 & has_discarded_bits_s4;
            end
            `RM_RMM: begin
                round_up_s4 = guard_bit_s4;
            end
            default: begin
                round_up_s4 = (guard_bit_s4 & (round_bit_s4 | sticky_bit_s4)) | 
                              (guard_bit_s4 & ~round_bit_s4 & ~sticky_bit_s4 & bit_lsb_s4);
            end
        endcase
    end
    
    wire [FP16_MANT_WIDTH:0] rounded_mantissa_s4 = base_mantissa_s4 + round_up_s4;
    wire [FP16_MANT_WIDTH-1:0] final_mantissa = rounding_overflow_s4 ? 10'd0 : rounded_mantissa_s4[9:0];
    
    // Denormal result handling: if rounded to zero, RDN/RUP need special handling
    reg [FP16_MANT_WIDTH-1:0] denormal_mantissa;
    always @(*) begin
        if (denormal_rounded_is_zero) begin
            // Denormal rounded to zero - check rounding mode
            case (rounding_mode_s3)
                `RM_RDN: begin
                    // Round Down: negative -> min negative denormal, positive -> +0
                    denormal_mantissa = sign_out_s4 ? 10'b1 : 10'b0;
                end
                `RM_RUP: begin
                    // Round Up: negative -> -0, positive -> min positive denormal
                    denormal_mantissa = sign_out_s4 ? 10'b0 : 10'b1;
                end
                default: begin
                    // Other modes: output zero
                    denormal_mantissa = 10'b0;
                end
            endcase
        end else begin
            // Denormal rounded to non-zero value
            denormal_mantissa = denormal_mantissa_temp;
        end
    end
    
    wire [FP16_MANT_WIDTH-1:0] computed_mantissa = result_is_denormal_s4 ? denormal_mantissa : final_mantissa;

    // Overflow handling based on rounding mode - 必须在使用前声明
    reg [FP16_EXP_WIDTH-1:0] exponent_out_overflow;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RNE, `RM_RMM: begin
                exponent_out_overflow = exp_max;  // ±Inf
            end
            `RM_RTZ: begin
                exponent_out_overflow = exp_max_finite;  // ±Max
            end
            `RM_RDN: begin
                exponent_out_overflow = sign_out_s4 ? exp_max : exp_max_finite;  // -∞ or +Max
            end
            `RM_RUP: begin
                exponent_out_overflow = sign_out_s4 ? exp_max_finite : exp_max;  // -Max or +∞
            end
            default: begin
                exponent_out_overflow = exp_max;  // Default to ±Inf
            end
        endcase
    end
    
    // Mantissa output for overflow cases - 必须在使用前声明
    reg [FP16_MANT_WIDTH-1:0] mantissa_out_overflow;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RNE, `RM_RMM: begin
                mantissa_out_overflow = {FP16_MANT_WIDTH{1'b0}};  // ±Inf
            end
            `RM_RTZ: begin
                mantissa_out_overflow = mant_max;  // ±Max
            end
            `RM_RDN: begin
                mantissa_out_overflow = sign_out_s4 ? {FP16_MANT_WIDTH{1'b0}} : mant_max;  // -∞ or +Max
            end
            `RM_RUP: begin
                mantissa_out_overflow = sign_out_s4 ? mant_max : {FP16_MANT_WIDTH{1'b0}};  // -Max or +∞
            end
            default: begin
                mantissa_out_overflow = {FP16_MANT_WIDTH{1'b0}};  // Default to ±Inf
            end
        endcase
    end
    
    // Underflow handling based on rounding mode - RDN/RUP需要特殊处理
    reg [FP16_MANT_WIDTH-1:0] mantissa_out_underflow;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RDN: begin
                // Round Down: 负数下溢→最小负非规格化数(0x8001), 正数下溢→+0.0
                mantissa_out_underflow = sign_out_s4 ? 10'b1 : 10'b0;
            end
            `RM_RUP: begin
                // Round Up: 负数下溢→-0.0, 正数下溢→最小正非规格化数(0x0001)
                mantissa_out_underflow = sign_out_s4 ? 10'b0 : 10'b1;
            end
            default: begin
                // RNE, RTZ, RMM: 下溢时输出零
                mantissa_out_underflow = {FP16_MANT_WIDTH{1'b0}};
            end
        endcase
    end

    wire [FP16_MANT_WIDTH-1:0] mantissa_out =
        output_is_nan_s4    ? {1'b1, {(FP16_MANT_WIDTH-1){1'b1}}} :
        output_is_zero_s4   ? {FP16_MANT_WIDTH{1'b0}} :
        output_is_inf_s4    ? {FP16_MANT_WIDTH{1'b0}} :
        exponent_overflow_s4   ? mantissa_out_overflow :
        (exponent_underflow_s4 && !result_is_denormal_s4) ? mantissa_out_underflow :
        (result_is_denormal_s4 && denormal_overflow) ? {FP16_MANT_WIDTH{1'b0}} :
        computed_mantissa;
    
    wire [FP16_EXP_WIDTH-1:0] exponent_out =
        output_is_nan_s4    ? 5'd31 :
        output_is_zero_s4   ? 5'd0 :
        output_is_inf_s4    ? 5'd31 :
        exponent_overflow_s4   ? exponent_out_overflow :
        (exponent_underflow_s4 && !result_is_denormal_s4) ? 5'd0 :
        (result_is_denormal_s4 && denormal_overflow) ? 5'd1 :
        result_is_denormal_s4 ? 5'd0 :
        exp_out_biased_s4[4:0];

    // Exception flags generation
    wire invalid_operation = output_is_nan_s4;  // NaN input or Inf×0
    wire has_discarded_bits_normal = guard_bit_s4 | round_bit_s4 | sticky_bit_s4;
    wire has_discarded_bits_denorm = denormal_guard | denormal_round | denormal_sticky;
    wire inexact_flag = (result_is_denormal_s4 ? has_discarded_bits_denorm : has_discarded_bits_normal) && 
                        !output_is_nan_s4 && !output_is_zero_s4;
    
    wire [4:0] exception_flags_wire;
    assign exception_flags_wire[`EXC_INVALID]   = invalid_operation;
    assign exception_flags_wire[`EXC_DIV_ZERO]  = 1'b0;  // N/A for multiplier
    assign exception_flags_wire[`EXC_OVERFLOW]  = exponent_overflow_s4 && !output_is_nan_s4;
    assign exception_flags_wire[`EXC_UNDERFLOW] = exponent_underflow_s4 && !result_is_denormal_s4 && !output_is_nan_s4;
    assign exception_flags_wire[`EXC_INEXACT]   = inexact_flag;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result  <= 16'b0;
            valid_o <= 1'b0;
            exception_flags <= 5'b0;
        end else begin
            valid_o <= v_s4;
            if (v_s4) begin
                result <= {sign_out_s4, exponent_out, mantissa_out};
                exception_flags <= exception_flags_wire;
            end
        end
    end

endmodule

module fp32_multiplier #(
    parameter IEEE_754 = 1    // IEEE 754 mode
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_i,
    input  wire [2:0]  rounding_mode,  // Rounding mode: 000=RNE, 001=RTZ, 010=RDN, 011=RUP, 100=RMM
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg         valid_o,
    output reg  [31:0] result,
    output reg  [4:0]  exception_flags  // Exception flags: [0]=Invalid, [1]=DivZero, [2]=Overflow, [3]=Underflow, [4]=Inexact
);

    localparam FP32_EXP_WIDTH  = 8;
    localparam FP32_MANT_WIDTH = 23;
    localparam FP32_BIAS       = 10'sd127;

    // stage0: 输入与特殊值检测（组合逻辑）
    wire        v_s0;
    wire        sign_a_s0, sign_b_s0;
    wire [FP32_EXP_WIDTH-1:0]  exp_a_s0, exp_b_s0;
    wire [FP32_MANT_WIDTH-1:0] mant_a_s0, mant_b_s0;
    wire        a_is_zero_s0, b_is_zero_s0;
    wire        a_is_inf_s0 , b_is_inf_s0;
    wire        a_is_nan_s0 , b_is_nan_s0;
    wire        a_is_denorm_s0, b_is_denorm_s0;

    // 组合逻辑赋值
    assign v_s0 = valid_i;
    assign sign_a_s0 = a[31];
    assign sign_b_s0 = b[31];
    assign exp_a_s0  = a[30:23];
    assign exp_b_s0  = b[30:23];
    assign mant_a_s0 = a[22:0];
    assign mant_b_s0 = b[22:0];
    assign a_is_zero_s0   = (a[30:23] == 0) && (a[22:0] == 0);
    assign b_is_zero_s0   = (b[30:23] == 0) && (b[22:0] == 0);
    assign a_is_inf_s0    = (a[30:23] == 8'hFF) && (a[22:0] == 0);
    assign b_is_inf_s0    = (b[30:23] == 8'hFF) && (b[22:0] == 0);
    assign a_is_nan_s0    = (a[30:23] == 8'hFF) && (a[22:0] != 0);
    assign b_is_nan_s0    = (b[30:23] == 8'hFF) && (b[22:0] != 0);
    assign a_is_denorm_s0 = (a[30:23] == 0) && (a[22:0] != 0);
    assign b_is_denorm_s0 = (b[30:23] == 0) && (b[22:0] != 0);
    wire sign_out_s0;
    wire output_is_zero_s0;
    wire output_is_inf_s0;
    wire output_is_nan_s0;
    wire [FP32_MANT_WIDTH:0] mant_a_with_hidden;
    wire [FP32_MANT_WIDTH:0] mant_b_with_hidden;
    generate
        if (IEEE_754 == 1) begin : gen_ieee754
            assign sign_out_s0 = output_is_nan_s0 ? 1'b0 : sign_a_s0 ^ sign_b_s0;
            assign output_is_zero_s0 = a_is_zero_s0 || b_is_zero_s0;
            assign output_is_inf_s0  = (a_is_inf_s0 || b_is_inf_s0) && !output_is_zero_s0;
            wire inf_times_zero_s0 = (a_is_inf_s0 && b_is_zero_s0) || (b_is_inf_s0 && a_is_zero_s0);
            assign output_is_nan_s0  = a_is_nan_s0 || b_is_nan_s0 || inf_times_zero_s0;
            assign mant_a_with_hidden = a_is_denorm_s0 ? {1'b0, mant_a_s0} : {1'b1, mant_a_s0};
            assign mant_b_with_hidden = b_is_denorm_s0 ? {1'b0, mant_b_s0} : {1'b1, mant_b_s0};
        end else begin : gen_non_ieee754
            // Detect minimum normalized values (smallest norm): exp=1, mant=0, which is 0x00800000 for FP32
            wire a_is_min_norm_s0;
            wire b_is_min_norm_s0;
            assign a_is_min_norm_s0 = (a[30:23] == 8'b00000001) && (a[22:0] == 23'b0);
            assign b_is_min_norm_s0 = (b[30:23] == 8'b00000001) && (b[22:0] == 23'b0);
            assign sign_out_s0 = output_is_nan_s0 ? 1'b0 : sign_a_s0 ^ sign_b_s0;
            // Denorm and minimum norm inputs are treated as zero, but sign bit is handled normally
            assign output_is_zero_s0 = a_is_zero_s0 || b_is_zero_s0 || a_is_denorm_s0 || b_is_denorm_s0 || a_is_min_norm_s0 || b_is_min_norm_s0;
            assign output_is_inf_s0  = (a_is_inf_s0 || b_is_inf_s0) && !output_is_zero_s0;
            wire inf_times_zero_s0 = (a_is_inf_s0 && (b_is_zero_s0 || b_is_denorm_s0 || b_is_min_norm_s0)) || ((a_is_zero_s0 || a_is_denorm_s0 || a_is_min_norm_s0) && b_is_inf_s0);
            assign output_is_nan_s0  = a_is_nan_s0 || b_is_nan_s0 || inf_times_zero_s0;
            assign mant_a_with_hidden = {1'b1, mant_a_s0};
            assign mant_b_with_hidden = {1'b1, mant_b_s0};
        end
    endgenerate

    // stage1: 尾数乘法
    reg        v_s1;
    reg        output_is_zero_s1, output_is_inf_s1, output_is_nan_s1;
    reg        sign_out_s1;
    reg        denormal_input_s1;
    reg [FP32_EXP_WIDTH-1:0]  exp_a_s1, exp_b_s1;
    reg [47:0] mant_product_s1;


    reg a_is_denorm_s1, b_is_denorm_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s1 <= 1'b0;
            mant_product_s1 <= 48'b0;
            output_is_zero_s1 <= 1'b0;
            output_is_inf_s1 <= 1'b0;
            output_is_nan_s1 <= 1'b0;
            sign_out_s1 <= 1'b0;
            a_is_denorm_s1 <= 1'b0;
            b_is_denorm_s1 <= 1'b0;
            denormal_input_s1 <= 1'b0;
            exp_a_s1 <= 8'b0;
            exp_b_s1 <= 8'b0;
        end else begin
            v_s1 <= v_s0;
            if (v_s0) begin
                mant_product_s1   <= mant_a_with_hidden * mant_b_with_hidden;
                output_is_zero_s1 <= output_is_zero_s0;
                output_is_inf_s1  <= output_is_inf_s0;
                output_is_nan_s1  <= output_is_nan_s0;
                sign_out_s1       <= sign_out_s0;
                a_is_denorm_s1    <= IEEE_754 ? a_is_denorm_s0 : 1'b0;
                b_is_denorm_s1    <= IEEE_754 ? b_is_denorm_s0 : 1'b0;
                denormal_input_s1 <= IEEE_754 ? a_is_denorm_s0 || b_is_denorm_s0 : 1'b0;
                exp_a_s1          <= exp_a_s0;
                exp_b_s1          <= exp_b_s0;
            end
        end
    end

    // stage2: 规格化与 GRS（组合逻辑）
    wire        v_s2;
    wire        output_is_zero_s2, output_is_inf_s2, output_is_nan_s2;
    wire        sign_out_s2;
    wire        denormal_input_s2;
    wire [FP32_EXP_WIDTH-1:0]  exp_a_s2, exp_b_s2;
    wire [47:0] mant_product_s2;
    wire [5:0]  leading_zeros_s2;
    wire [47:0] normalized_mant_s2;
    wire [FP32_MANT_WIDTH-1:0] base_mantissa_s2;
    wire        guard_bit_s2, round_bit_s2, sticky_bit_s2;
    wire        a_is_denorm_s2, b_is_denorm_s2;

    wire [5:0] leading_zeros;
    leading_zero_counter_fp32_m #(
        .DATA_WIDTH(48),
        .COUNT_WIDTH(6)
    ) lzc_inst (
        .data_in(mant_product_s1),
        .leading_zeros(leading_zeros)
    );

    wire is_normalized_s1 = mant_product_s1[47];
    wire [47:0] normalized_mant_w = denormal_input_s1 ? (mant_product_s1 << leading_zeros) :
                                     is_normalized_s1 ? (mant_product_s1 >> 1) :
                                     mant_product_s1;
    wire [FP32_MANT_WIDTH-1:0] base_mantissa_w = denormal_input_s1 ? normalized_mant_w[46:24] :
                                                  is_normalized_s1 ? mant_product_s1[46:24] :
                                                  mant_product_s1[45:23];
    wire guard_bit_w = denormal_input_s1 ? normalized_mant_w[23] :
                       is_normalized_s1 ? mant_product_s1[23] :
                       mant_product_s1[22];
    wire round_bit_w = denormal_input_s1 ? normalized_mant_w[22] :
                       is_normalized_s1 ? mant_product_s1[22] :
                       mant_product_s1[21];
    wire sticky_bit_w = denormal_input_s1 ? (|normalized_mant_w[21:0]) :
                        is_normalized_s1 ? (|mant_product_s1[21:0]) :
                        (|mant_product_s1[20:0]);

    // 组合逻辑赋值
    assign v_s2 = v_s1;
    assign output_is_zero_s2 = output_is_zero_s1;
    assign output_is_inf_s2  = output_is_inf_s1;
    assign output_is_nan_s2  = output_is_nan_s1;
    assign sign_out_s2       = sign_out_s1;
    assign denormal_input_s2 = denormal_input_s1;
    assign exp_a_s2          = exp_a_s1;
    assign exp_b_s2          = exp_b_s1;
    assign mant_product_s2   = mant_product_s1;
    assign leading_zeros_s2  = leading_zeros;
    assign normalized_mant_s2 = normalized_mant_w;
    assign base_mantissa_s2  = base_mantissa_w;
    assign guard_bit_s2      = guard_bit_w;
    assign round_bit_s2      = round_bit_w;
    assign sticky_bit_s2     = sticky_bit_w;
    assign a_is_denorm_s2    = a_is_denorm_s1;
    assign b_is_denorm_s2    = b_is_denorm_s1;

    // stage3: 舍入与指数计算
    reg        v_s3;
    reg        output_is_zero_s3, output_is_inf_s3, output_is_nan_s3;
    reg        sign_out_s3;
    reg [47:0] mant_product_s3;
    reg [FP32_MANT_WIDTH-1:0] base_mantissa_s3;
    reg        guard_bit_s3, round_bit_s3, sticky_bit_s3;
    reg signed [9:0] exp_pre_round_s3;
    reg signed [9:0] exp_out_biased_s3;
    reg        rounding_overflow_s3;
    reg [2:0]  rounding_mode_s3;  // Pipeline rounding mode
    wire signed [9:0] exp_a_unbiased;
    wire signed [9:0] exp_b_unbiased;
    generate
        if (IEEE_754 == 1) begin : gen_ieee754_exp
            assign exp_a_unbiased = a_is_denorm_s2 ? -10'sd126 : {2'd0, exp_a_s2} - FP32_BIAS;
            assign exp_b_unbiased = b_is_denorm_s2 ? -10'sd126 : {2'd0, exp_b_s2} - FP32_BIAS;
        end else begin : gen_non_ieee754_exp
            assign exp_a_unbiased = {2'd0, exp_a_s2} - FP32_BIAS;
            assign exp_b_unbiased = {2'd0, exp_b_s2} - FP32_BIAS;
        end
    endgenerate
    wire signed [9:0] exp_out_unbiased = exp_a_unbiased + exp_b_unbiased;
    wire signed [9:0] exp_adjustment = denormal_input_s2 ?
                                       (10'sd0 - {4'd0, leading_zeros_s2} + {9'b0, normalized_mant_s2[47]}) :
                                       (mant_product_s2[47] ? 10'd1 : 10'd0);
    wire signed [9:0] exp_pre_round_w = exp_out_unbiased + exp_adjustment + FP32_BIAS;

    // Rounding decision based on mode (Stage 2)
    wire bit_lsb_s2 = base_mantissa_s2[0];
    wire has_discarded_bits_s2 = guard_bit_s2 | round_bit_s2 | sticky_bit_s2;
    reg round_up_s2;
    always @(*) begin
        case (rounding_mode)
            `RM_RNE: begin  // Round to Nearest, ties to Even
                round_up_s2 = (guard_bit_s2 & (round_bit_s2 | sticky_bit_s2)) | 
                              (guard_bit_s2 & ~round_bit_s2 & ~sticky_bit_s2 & bit_lsb_s2);
            end
            `RM_RTZ: begin  // Round Towards Zero
                round_up_s2 = 1'b0;
            end
            `RM_RDN: begin  // Round Down (towards -∞)
                round_up_s2 = sign_out_s2 & has_discarded_bits_s2;
            end
            `RM_RUP: begin  // Round Up (towards +∞)
                round_up_s2 = ~sign_out_s2 & has_discarded_bits_s2;
            end
            `RM_RMM: begin  // Round to Nearest, ties to Max magnitude
                round_up_s2 = guard_bit_s2;
            end
            default: begin  // Default to RNE
                round_up_s2 = (guard_bit_s2 & (round_bit_s2 | sticky_bit_s2)) | 
                              (guard_bit_s2 & ~round_bit_s2 & ~sticky_bit_s2 & bit_lsb_s2);
            end
        endcase
    end

    wire [23:0] rounded_mantissa = base_mantissa_s2 + round_up_s2;
    wire rounding_overflow_w = rounded_mantissa[23];
    wire signed [9:0] exp_out_biased_w = exp_pre_round_w + (rounding_overflow_w ? 10'd1 : 10'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s3 <= 1'b0;
            output_is_zero_s3 <= 1'b0;
            output_is_inf_s3 <= 1'b0;
            output_is_nan_s3 <= 1'b0;
            sign_out_s3 <= 1'b0;
            mant_product_s3 <= 48'b0;
            base_mantissa_s3 <= 23'b0;
            guard_bit_s3 <= 1'b0;
            round_bit_s3 <= 1'b0;
            sticky_bit_s3 <= 1'b0;
            exp_pre_round_s3 <= 10'b0;
            exp_out_biased_s3 <= 10'b0;
            rounding_overflow_s3 <= 1'b0;
            rounding_mode_s3 <= `RM_RNE;
        end else begin
            v_s3 <= v_s2;
            if (v_s2) begin
                output_is_zero_s3 <= output_is_zero_s2;
                output_is_inf_s3  <= output_is_inf_s2;
                output_is_nan_s3  <= output_is_nan_s2;
                sign_out_s3       <= sign_out_s2;
                mant_product_s3   <= mant_product_s2;
                base_mantissa_s3  <= base_mantissa_s2;
                guard_bit_s3      <= guard_bit_s2;
                round_bit_s3      <= round_bit_s2;
                sticky_bit_s3     <= sticky_bit_s2;
                exp_pre_round_s3  <= exp_pre_round_w;
                exp_out_biased_s3 <= exp_out_biased_w;
                rounding_overflow_s3 <= rounding_overflow_w;
                rounding_mode_s3  <= rounding_mode;
            end
        end
    end
    wire exponent_overflow = exp_out_biased_s3 > 10'sd254;
    wire exponent_underflow = exp_pre_round_s3 < 10'sd1;
    wire result_is_denormal = (exp_pre_round_s3 <= 0) && (exp_pre_round_s3 >= -10'sd149) && (mant_product_s3 != 10'sd0);
    wire signed [9:0] denormal_shift = (exp_pre_round_s3 <= 0) ? (10'sd1 - exp_pre_round_s3) : 10'sd0;
    wire [48:0] extended_mantissa = {2'b01, base_mantissa_s3, guard_bit_s3, round_bit_s3, sticky_bit_s3, 21'b0};
    wire [48:0] pre_shifted = (denormal_shift == 10'sd0) ? extended_mantissa : (extended_mantissa >> denormal_shift);
    
    // Overflow handling based on rounding mode
    wire [FP32_EXP_WIDTH-1:0] exp_max = 8'd255;
    wire [FP32_EXP_WIDTH-1:0] exp_max_finite = 8'd254;
    wire [FP32_MANT_WIDTH-1:0] mant_max = {FP32_MANT_WIDTH{1'b1}};

    // stage4: 下溢处理与结果组装
    reg        v_s4;
    reg        output_is_zero_s4, output_is_inf_s4, output_is_nan_s4;
    reg        sign_out_s4;
    reg signed [9:0] exp_pre_round_s4;
    reg signed [9:0] exp_out_biased_s4;
    reg        rounding_overflow_s4;
    reg [FP32_MANT_WIDTH-1:0] base_mantissa_s4;
    reg        guard_bit_s4, round_bit_s4, sticky_bit_s4;
    reg [47:0] mant_product_s4;
    reg exponent_overflow_s4;
    reg exponent_underflow_s4;
    reg result_is_denormal_s4;
    reg signed [9:0] denormal_shift_s4;
    reg [48:0] extended_mantissa_s4;
    reg [48:0] pre_shifted_s4;
    reg [22:0] denormal_mantissa_raw_s4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s4 <= 1'b0;
            output_is_zero_s4 <= 1'b0;
            output_is_inf_s4 <= 1'b0;
            output_is_nan_s4 <= 1'b0;
            sign_out_s4 <= 1'b0;
            exp_pre_round_s4 <= 10'sb0;
            exp_out_biased_s4 <= 10'sb0;
            rounding_overflow_s4 <= 1'b0;
            base_mantissa_s4 <= 23'b0;
            guard_bit_s4 <= 1'b0;
            round_bit_s4 <= 1'b0;
            sticky_bit_s4 <= 1'b0;
            mant_product_s4 <= 48'b0;
            exponent_overflow_s4 <= 1'b0;
            exponent_underflow_s4 <= 1'b0;
            result_is_denormal_s4 <= 1'b0;
            denormal_shift_s4 <= 10'sb0;
            extended_mantissa_s4 <= 49'b0;
            pre_shifted_s4 <= 49'b0;
            denormal_mantissa_raw_s4 <= 23'b0;
        end else begin
            v_s4 <= v_s3;
            if (v_s3) begin
                output_is_zero_s4 <= output_is_zero_s3;
                output_is_inf_s4  <= output_is_inf_s3;
                output_is_nan_s4  <= output_is_nan_s3;
                sign_out_s4       <= sign_out_s3;
                exp_pre_round_s4  <= exp_pre_round_s3;
                exp_out_biased_s4 <= exp_out_biased_s3;
                rounding_overflow_s4 <= rounding_overflow_s3;
                base_mantissa_s4  <= base_mantissa_s3;
                guard_bit_s4      <= guard_bit_s3;
                round_bit_s4      <= round_bit_s3;
                sticky_bit_s4     <= sticky_bit_s3;
                mant_product_s4   <= mant_product_s3;
                exponent_overflow_s4 <= exponent_overflow;
                exponent_underflow_s4 <= exponent_underflow;
                result_is_denormal_s4 <= result_is_denormal;
                denormal_shift_s4 <= denormal_shift;
                extended_mantissa_s4 <= extended_mantissa;
                pre_shifted_s4 <= pre_shifted;
                denormal_mantissa_raw_s4 <= pre_shifted[46:24];
            end
        end
    end



    wire denormal_guard = pre_shifted_s4[23];
    wire denormal_round = pre_shifted_s4[22];
    wire denormal_sticky = |pre_shifted_s4[21:0];
    wire denormal_lsb = denormal_mantissa_raw_s4[0];
    wire denormal_has_discarded = denormal_guard | denormal_round | denormal_sticky;
    
    // Denormal rounding decision based on mode
    reg denormal_round_up_s4;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RNE: begin
                denormal_round_up_s4 = (denormal_guard & (denormal_round | denormal_sticky)) | 
                                       (denormal_guard & ~denormal_round & ~denormal_sticky & denormal_lsb);
            end
            `RM_RTZ: begin
                denormal_round_up_s4 = 1'b0;
            end
            `RM_RDN: begin
                denormal_round_up_s4 = sign_out_s4 & denormal_has_discarded;
            end
            `RM_RUP: begin
                denormal_round_up_s4 = ~sign_out_s4 & denormal_has_discarded;
            end
            `RM_RMM: begin
                denormal_round_up_s4 = denormal_guard;
            end
            default: begin
                denormal_round_up_s4 = (denormal_guard & (denormal_round | denormal_sticky)) | 
                                       (denormal_guard & ~denormal_round & ~denormal_sticky & denormal_lsb);
            end
        endcase
    end
    
    wire [22:0] denormal_rounded = denormal_mantissa_raw_s4 + denormal_round_up_s4;
    wire denormal_rounded_is_zero = (denormal_rounded[22:0] == 23'b0);

    // Normal rounding decision based on mode (Stage 4)
    wire bit_lsb_s4 = base_mantissa_s4[0];
    wire has_discarded_bits_s4 = guard_bit_s4 | round_bit_s4 | sticky_bit_s4;
    reg round_up_s4;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RNE: begin
                round_up_s4 = (guard_bit_s4 & (round_bit_s4 | sticky_bit_s4)) | 
                              (guard_bit_s4 & ~round_bit_s4 & ~sticky_bit_s4 & bit_lsb_s4);
            end
            `RM_RTZ: begin
                round_up_s4 = 1'b0;
            end
            `RM_RDN: begin
                round_up_s4 = sign_out_s4 & has_discarded_bits_s4;
            end
            `RM_RUP: begin
                round_up_s4 = ~sign_out_s4 & has_discarded_bits_s4;
            end
            `RM_RMM: begin
                round_up_s4 = guard_bit_s4;
            end
            default: begin
                round_up_s4 = (guard_bit_s4 & (round_bit_s4 | sticky_bit_s4)) | 
                              (guard_bit_s4 & ~round_bit_s4 & ~sticky_bit_s4 & bit_lsb_s4);
            end
        endcase
    end
    
    wire [FP32_MANT_WIDTH:0] rounded_mantissa_s4 = base_mantissa_s4 + round_up_s4;
    wire [FP32_MANT_WIDTH-1:0] final_mantissa = rounding_overflow_s4 ? 23'b0 : rounded_mantissa_s4[22:0];
    
    // Denormal result handling: if rounded to zero, RDN/RUP need special handling
    reg [FP32_MANT_WIDTH-1:0] denormal_mantissa_final;
    always @(*) begin
        if (denormal_rounded_is_zero) begin
            // Denormal rounded to zero - check rounding mode
            case (rounding_mode_s3)
                `RM_RDN: begin
                    // Round Down: negative -> min negative denormal, positive -> +0
                    denormal_mantissa_final = sign_out_s4 ? 23'b1 : 23'b0;
                end
                `RM_RUP: begin
                    // Round Up: negative -> -0, positive -> min positive denormal
                    denormal_mantissa_final = sign_out_s4 ? 23'b0 : 23'b1;
                end
                default: begin
                    // Other modes: output zero
                    denormal_mantissa_final = 23'b0;
                end
            endcase
        end else begin
            // Denormal rounded to non-zero value
            denormal_mantissa_final = denormal_rounded[22:0];
        end
    end
    
    wire [FP32_MANT_WIDTH-1:0] computed_mantissa = result_is_denormal_s4 ? denormal_mantissa_final : final_mantissa;

    // Overflow handling based on rounding mode - 必须在使用前声明
    reg [FP32_EXP_WIDTH-1:0] exponent_out_overflow;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RNE, `RM_RMM: begin
                exponent_out_overflow = exp_max;  // ±Inf
            end
            `RM_RTZ: begin
                exponent_out_overflow = exp_max_finite;  // ±Max
            end
            `RM_RDN: begin
                exponent_out_overflow = sign_out_s4 ? exp_max : exp_max_finite;  // -∞ or +Max
            end
            `RM_RUP: begin
                exponent_out_overflow = sign_out_s4 ? exp_max_finite : exp_max;  // -Max or +∞
            end
            default: begin
                exponent_out_overflow = exp_max;  // Default to ±Inf
            end
        endcase
    end
    
    // Mantissa output for overflow cases - 必须在使用前声明
    reg [FP32_MANT_WIDTH-1:0] mantissa_out_overflow;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RNE, `RM_RMM: begin
                mantissa_out_overflow = {FP32_MANT_WIDTH{1'b0}};  // ±Inf
            end
            `RM_RTZ: begin
                mantissa_out_overflow = mant_max;  // ±Max
            end
            `RM_RDN: begin
                mantissa_out_overflow = sign_out_s4 ? {FP32_MANT_WIDTH{1'b0}} : mant_max;  // -∞ or +Max
            end
            `RM_RUP: begin
                mantissa_out_overflow = sign_out_s4 ? mant_max : {FP32_MANT_WIDTH{1'b0}};  // -Max or +∞
            end
            default: begin
                mantissa_out_overflow = {FP32_MANT_WIDTH{1'b0}};  // Default to ±Inf
            end
        endcase
    end
    
    // Underflow handling based on rounding mode - RDN/RUP需要特殊处理
    reg [FP32_MANT_WIDTH-1:0] mantissa_out_underflow;
    always @(*) begin
        case (rounding_mode_s3)
            `RM_RDN: begin
                // Round Down: 负数下溢→最小负非规格化数(0x80000001), 正数下溢→+0.0
                mantissa_out_underflow = sign_out_s4 ? 23'b1 : 23'b0;
            end
            `RM_RUP: begin
                // Round Up: 负数下溢→-0.0, 正数下溢→最小正非规格化数(0x00000001)
                mantissa_out_underflow = sign_out_s4 ? 23'b0 : 23'b1;
            end
            default: begin
                // RNE, RTZ, RMM: 下溢时输出零
                mantissa_out_underflow = {FP32_MANT_WIDTH{1'b0}};
            end
        endcase
    end
    
    wire [FP32_MANT_WIDTH-1:0] mantissa_out =
        output_is_nan_s4    ? {1'b1, {(FP32_MANT_WIDTH-1){1'b0}}} :
        output_is_zero_s4   ? {FP32_MANT_WIDTH{1'b0}} :
        output_is_inf_s4    ? {FP32_MANT_WIDTH{1'b0}} :
        exponent_overflow_s4   ? mantissa_out_overflow :
        (exponent_underflow_s4 && !result_is_denormal_s4) ? mantissa_out_underflow :
        computed_mantissa;

    wire [FP32_EXP_WIDTH-1:0] exponent_out =
        output_is_nan_s4    ? 8'd255 :
        output_is_zero_s4   ? 8'd0   :
        output_is_inf_s4    ? 8'd255 :
        exponent_overflow_s4   ? exponent_out_overflow :
        (exponent_underflow_s4 && !result_is_denormal_s4) ? 8'd0 :
        result_is_denormal_s4 ? 8'd0 :
        exp_out_biased_s4[7:0];

    // Exception flags generation
    wire invalid_operation = output_is_nan_s4;  // NaN input or Inf×0
    wire has_discarded_bits_normal = guard_bit_s4 | round_bit_s4 | sticky_bit_s4;
    wire has_discarded_bits_denorm = denormal_guard | denormal_round | denormal_sticky;
    wire inexact_flag = (result_is_denormal_s4 ? has_discarded_bits_denorm : has_discarded_bits_normal) && 
                        !output_is_nan_s4 && !output_is_zero_s4;
    
    wire [4:0] exception_flags_wire;
    assign exception_flags_wire[`EXC_INVALID]   = invalid_operation;
    assign exception_flags_wire[`EXC_DIV_ZERO]  = 1'b0;  // N/A for multiplier
    assign exception_flags_wire[`EXC_OVERFLOW]  = exponent_overflow_s4 && !output_is_nan_s4;
    assign exception_flags_wire[`EXC_UNDERFLOW] = exponent_underflow_s4 && !result_is_denormal_s4 && !output_is_nan_s4;
    assign exception_flags_wire[`EXC_INEXACT]   = inexact_flag;

    generate
        if (IEEE_754 == 1) begin : gen_ieee754_exponent_out
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_o <= 1'b0;
                    result  <= 32'b0;
                    exception_flags <= 5'b0;
                end else begin
                    valid_o <= v_s4;
                    if (v_s4) begin
                        result <= {sign_out_s4, exponent_out, mantissa_out};
                        exception_flags <= exception_flags_wire;
                    end
                end
            end
        end else begin : gen_non_ieee754_exponent_out
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_o <= 1'b0;
                    result  <= 32'b0;
                    exception_flags <= 5'b0;
                end else begin
                    valid_o <= v_s4;
                    if (v_s4) begin
                        if (exponent_out == 0) begin
                            result <= {sign_out_s4, 8'd0, 23'b0};
                        end else begin
                            result <= {sign_out_s4, exponent_out, mantissa_out};
                        end
                        exception_flags <= exception_flags_wire;
                    end
                end
            end
        end
    endgenerate


endmodule
