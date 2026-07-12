// Include rounding mode and exception flag definitions
`include "fp32_defines.vh"

module fp16tofp32_multiplier  #(
    parameter IEEE_754 = 1
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_i,
    input  wire [2:0]  rounding_mode,  // Rounding mode: 000=RNE, 001=RTZ, 010=RDN, 011=RUP, 100=RMM
    input  wire [15:0] a,
    input  wire [15:0] b,
    output wire         valid_o,
    output wire  [31:0] result,
    output wire  [4:0]  exception_flags  // Exception flags: [0]=Invalid, [1]=DivZero, [2]=Overflow, [3]=Underflow, [4]=Inexact
);

`ifdef USE_FPGA_IP

    wire [31:0] a_fp32;
    wire [31:0] b_fp32;

    wire        sign_a_s0 = a[15];
    wire        sign_b_s0 = b[15];
    wire [7:0]  exp_a_s0  = {3'd0,a[14:10]};
    wire [7:0]  exp_b_s0  = {3'd0,b[14:10]};
    wire [22:0] mant_a_s0 = {a[9:0],13'd0};
    wire [22:0] mant_b_s0 = {b[9:0],13'd0};
    wire        a_is_zero_s0   = (a[14:10] == 0) && (a[9:0] == 0);
    wire        b_is_zero_s0   = (b[14:10] == 0) && (b[9:0] == 0);
    wire        a_is_inf_s0    = (a[14:10] == 5'b11111) && (a[9:0] == 0);
    wire        b_is_inf_s0    = (b[14:10] == 5'b11111) && (b[9:0] == 0);
    wire        a_is_nan_s0    = (a[14:10] == 5'b11111) && (a[9:0] != 0);
    wire        b_is_nan_s0    = (b[14:10] == 5'b11111) && (b[9:0] != 0);
    wire        a_is_denorm_s0 = (a[14:10] == 0) && (a[9:0] != 0);
    wire        b_is_denorm_s0 = (b[14:10] == 0) && (b[9:0] != 0);

    assign a_fp32 = a_is_zero_s0   ? {sign_a_s0, 8'h00, 23'h0} :
                    a_is_inf_s0    ? {sign_a_s0, 8'hFF, 23'h0} :
                    a_is_nan_s0    ? {sign_a_s0, 8'hFF, mant_a_s0} :
                    a_is_denorm_s0 ? {sign_a_s0, 8'h00, mant_a_s0} : // If IP supports denormal natively, otherwise this is sufficient basic mapping
                                     {sign_a_s0, exp_a_s0 + 8'd112, mant_a_s0};

    assign b_fp32 = b_is_zero_s0   ? {sign_b_s0, 8'h00, 23'h0} :
                    b_is_inf_s0    ? {sign_b_s0, 8'hFF, 23'h0} :
                    b_is_nan_s0    ? {sign_b_s0, 8'hFF, mant_b_s0} :
                    b_is_denorm_s0 ? {sign_b_s0, 8'h00, mant_b_s0} : 
                                     {sign_b_s0, exp_b_s0 + 8'd112, mant_b_s0};

    wire m_axis_result_tvalid;
    wire [31:0] m_axis_result_tdata;
    wire        result_is_nan = (m_axis_result_tdata[30:23] == 8'hFF) && (m_axis_result_tdata[22:0] != 23'd0);

    floating_point_Mul_FP32_L3_FP16MUL u_fp32_mul_ip (
        .aclk(clk),
        .aresetn(rst_n),
        .s_axis_a_tvalid(valid_i),
        .s_axis_a_tdata(a_fp32),
        .s_axis_b_tvalid(valid_i),
        .s_axis_b_tdata(b_fp32),
        .m_axis_result_tvalid(m_axis_result_tvalid),
        .m_axis_result_tdata(m_axis_result_tdata)
    );

    assign valid_o = m_axis_result_tvalid;
    assign result = result_is_nan ? 32'h7FFFFFFF : m_axis_result_tdata;
    assign exception_flags = 5'b0;

`else

    localparam FP32_EXP_WIDTH  = 8;
    localparam FP32_MANT_WIDTH = 23;
    localparam FP32_BIAS       = 10'sd127;
     
    localparam FP16_BIAS       = 10'sd15;
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
    assign sign_a_s0 = a[15];
    assign sign_b_s0 = b[15];
    assign exp_a_s0  = {3'd0,a[14:10]};
    assign exp_b_s0  = {3'd0,b[14:10]};
    assign mant_a_s0 = {a[9:0],13'd0};
    assign mant_b_s0 = {b[9:0],13'd0};
    assign a_is_zero_s0   = (a[14:10] == 0) && (a[9:0] == 0);
    assign b_is_zero_s0   = (b[14:10] == 0) && (b[9:0] == 0);
    assign a_is_inf_s0    = (a[14:10] == 5'b11111) && (a[9:0] == 0);
    assign b_is_inf_s0    = (b[14:10] == 5'b11111) && (b[9:0] == 0);
    assign a_is_nan_s0    = (a[14:10] == 5'b11111) && (a[9:0] != 0);
    assign b_is_nan_s0    = (b[14:10] == 5'b11111) && (b[9:0] != 0);
    assign a_is_denorm_s0 = (a[14:10] == 0) && (a[9:0] != 0);
    assign b_is_denorm_s0 = (b[14:10] == 0) && (b[9:0] != 0);
    
    // 声明所有需要的 wire（在 generate 块外）
    wire sign_out_s0;
    wire output_is_zero_s0;
    wire output_is_inf_s0;
    wire inf_times_zero_s0;
    wire output_is_nan_s0;
    wire a_is_min_norm_s0;
    wire b_is_min_norm_s0;
    
    // 使用 generate 块进行条件编译
    generate
        if (IEEE_754 == 1) begin : gen_ieee754
            assign sign_out_s0 = output_is_nan_s0 ? 1'b0 : sign_a_s0 ^ sign_b_s0;
            assign output_is_zero_s0 = a_is_zero_s0 || b_is_zero_s0;
            assign output_is_inf_s0  = (a_is_inf_s0 || b_is_inf_s0) && !output_is_zero_s0;
            assign inf_times_zero_s0 = (a_is_inf_s0 && b_is_zero_s0) || (b_is_inf_s0 && a_is_zero_s0);
            assign output_is_nan_s0  = a_is_nan_s0 || b_is_nan_s0 || inf_times_zero_s0;
            // 非 IEEE_754 模式下不需要的信号设为 0
            assign a_is_min_norm_s0 = 1'b0;
            assign b_is_min_norm_s0 = 1'b0;
        end else begin : gen_non_ieee754
            // Detect minimum normalized value (0x400): exp=1, mant=0 for FP16
            assign a_is_min_norm_s0 = (a[14:10] == 5'b00001) && (a[9:0] == 10'b0);
            assign b_is_min_norm_s0 = (b[14:10] == 5'b00001) && (b[9:0] == 10'b0);
            assign sign_out_s0 = output_is_nan_s0 ? 1'b0 : sign_a_s0 ^ sign_b_s0;
            // Denorm and minimum norm inputs are treated as zero, but sign bit is handled normally
            assign output_is_zero_s0 = a_is_zero_s0 || b_is_zero_s0 || a_is_denorm_s0 || b_is_denorm_s0 || a_is_min_norm_s0 || b_is_min_norm_s0;
            assign output_is_inf_s0  = (a_is_inf_s0 || b_is_inf_s0) && !output_is_zero_s0;
            assign inf_times_zero_s0 = (a_is_inf_s0 && (b_is_zero_s0 || b_is_denorm_s0 || b_is_min_norm_s0)) || ((a_is_zero_s0 || a_is_denorm_s0 || a_is_min_norm_s0) && b_is_inf_s0);
            assign output_is_nan_s0  = a_is_nan_s0 || b_is_nan_s0 || inf_times_zero_s0;
        end
    endgenerate

    // stage1: 尾数乘法
    reg        v_s1;
    reg        output_is_zero_s1, output_is_inf_s1, output_is_nan_s1;
    reg        sign_out_s1;
    reg        denormal_input_s1;
    reg [FP32_EXP_WIDTH-1:0]  exp_a_s1, exp_b_s1;
    reg [47:0] mant_product_s1;

    wire [FP32_MANT_WIDTH:0] mant_a_with_hidden = a_is_denorm_s0 ? {1'b0, mant_a_s0} : {1'b1, mant_a_s0};
    wire [FP32_MANT_WIDTH:0] mant_b_with_hidden = b_is_denorm_s0 ? {1'b0, mant_b_s0} : {1'b1, mant_b_s0};

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
                a_is_denorm_s1    <= a_is_denorm_s0;
                b_is_denorm_s1    <= b_is_denorm_s0;
                denormal_input_s1 <= a_is_denorm_s0 || b_is_denorm_s0;
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
    wire [2:0]  rounding_mode_s2;  // Rounding mode for Stage 2

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
    assign rounding_mode_s2  = rounding_mode;  // Pass rounding mode to Stage 2

    // stage3: 舍入与指数计算
    reg        v_s3;
    reg        output_is_zero_s3, output_is_inf_s3, output_is_nan_s3;
    reg        sign_out_s3;
    reg [47:0] mant_product_s3;
    reg [FP32_MANT_WIDTH-1:0] base_mantissa_s3;
    reg        guard_bit_s3, round_bit_s3, sticky_bit_s3;
    reg [2:0]  rounding_mode_s3;  // Rounding mode for Stage 3
    reg signed [9:0] exp_pre_round_s3;
    reg signed [9:0] exp_out_biased_s3;
    reg        rounding_overflow_s3;

    wire signed [9:0] exp_a_unbiased = a_is_denorm_s2 ? -10'sd14 : {2'd0, exp_a_s2} - FP16_BIAS;
    wire signed [9:0] exp_b_unbiased = b_is_denorm_s2 ? -10'sd14 : {2'd0, exp_b_s2} - FP16_BIAS;
    wire signed [9:0] exp_out_unbiased = exp_a_unbiased + exp_b_unbiased;
    wire signed [9:0] exp_adjustment = denormal_input_s2 ?
                                       (10'sd0 - {4'd0, leading_zeros_s2} + {9'b0, normalized_mant_s2[47]}) :
                                       (mant_product_s2[47] ? 10'd1 : 10'd0);
    wire signed [9:0] exp_pre_round_w = exp_out_unbiased + exp_adjustment + FP32_BIAS;

    // ====================================================================
    // Stage 2: 舍入决策逻辑（支持5种IEEE 754舍入模式）
    // ====================================================================
    wire bit_lsb_s2 = base_mantissa_s2[0];  // LSB of base mantissa
    wire has_discarded_bits_s2 = guard_bit_s2 | round_bit_s2 | sticky_bit_s2;
    reg round_up_s2;
    
    always @(*) begin
        case (rounding_mode_s2)
            `RM_RNE: begin
                // Round to Nearest, ties to Even
                round_up_s2 = (guard_bit_s2 & (round_bit_s2 | sticky_bit_s2)) | 
                             (guard_bit_s2 & ~round_bit_s2 & ~sticky_bit_s2 & bit_lsb_s2);
            end
            `RM_RTZ: begin
                // Round Towards Zero (truncate)
                round_up_s2 = 1'b0;
            end
            `RM_RDN: begin
                // Round Down (towards -∞)
                round_up_s2 = sign_out_s2 & has_discarded_bits_s2;
            end
            `RM_RUP: begin
                // Round Up (towards +∞)
                round_up_s2 = ~sign_out_s2 & has_discarded_bits_s2;
            end
            `RM_RMM: begin
                // Round to Nearest, ties to Max magnitude
                round_up_s2 = guard_bit_s2;
            end
            default: begin
                // Default to RNE
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
            mant_product_s3 <= 22'b0;
            base_mantissa_s3 <= 10'b0;
            guard_bit_s3 <= 1'b0;
            round_bit_s3 <= 1'b0;
            sticky_bit_s3 <= 1'b0;
            rounding_mode_s3 <= `RM_RNE;
            exp_pre_round_s3 <= 10'b0;
            exp_out_biased_s3 <= 10'b0;
            rounding_overflow_s3 <= 1'b0;
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
                rounding_mode_s3 <= rounding_mode_s2;  // Pass rounding mode to Stage 3
                exp_pre_round_s3  <= exp_pre_round_w;
                exp_out_biased_s3 <= exp_out_biased_w;
                rounding_overflow_s3 <= rounding_overflow_w;
            end
        end
    end
    wire exponent_overflow = exp_out_biased_s3 > 10'sd254;
    wire exponent_underflow = exp_pre_round_s3 < 10'sd1;
    wire result_is_denormal = (exp_pre_round_s3 <= 0) && (exp_pre_round_s3 >= -10'sd149) && (mant_product_s3 != 10'sd0);
    wire signed [9:0] denormal_shift = (exp_pre_round_s3 <= 0) ? (10'sd1 - exp_pre_round_s3) : 10'sd0;
    wire [48:0] extended_mantissa = {2'b01, base_mantissa_s3, guard_bit_s3, round_bit_s3, sticky_bit_s3, 21'b0};
    wire [48:0] pre_shifted = (denormal_shift == 8'sd0) ? extended_mantissa : (extended_mantissa >> denormal_shift);

    // stage4: 下溢处理与结果组装
    reg        v_s4;
    reg        output_is_zero_s4, output_is_inf_s4, output_is_nan_s4;
    reg        sign_out_s4;
    reg [2:0]  rounding_mode_s4;  // Rounding mode for Stage 4
    reg signed [9:0] exp_pre_round_s4;
    reg signed [9:0] exp_out_biased_s4;
    reg        rounding_overflow_s4;
    reg [FP32_MANT_WIDTH-1:0] base_mantissa_s4;
    reg        guard_bit_s4, round_bit_s4, sticky_bit_s4;
    reg [47:0] mant_product_s4;
    reg exponent_overflow_s4;
    reg exponent_underflow_s4;
    reg result_is_denormal_s4;
    reg [7:0] denormal_shift_s4;
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
            exp_pre_round_s4 <= 8'b0;
            exp_out_biased_s4 <= 8'b0;
            rounding_overflow_s4 <= 1'b0;
            base_mantissa_s4 <= 10'b0;
            guard_bit_s4 <= 1'b0;
            round_bit_s4 <= 1'b0;
            sticky_bit_s4 <= 1'b0;
            rounding_mode_s4 <= `RM_RNE;
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
                rounding_mode_s4  <= rounding_mode_s3;  // Pass rounding mode to Stage 4
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



    // ====================================================================
    // Stage 4: 非规格化数舍入决策（支持5种舍入模式）
    // ====================================================================
    wire denormal_guard = pre_shifted_s4[23];
    wire denormal_round = pre_shifted_s4[22];
    wire denormal_sticky = |pre_shifted_s4[21:0];
    wire denormal_lsb = denormal_mantissa_raw_s4[0];
    wire denormal_has_discarded = denormal_guard | denormal_round | denormal_sticky;
    
    reg denormal_round_up_s4;
    always @(*) begin
        case (rounding_mode_s4)
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
    
    // ====================================================================
    // Stage 4: 正常数舍入决策（重新计算，支持5种舍入模式）
    // ====================================================================
    wire bit_lsb_s4 = base_mantissa_s4[0];
    wire has_discarded_bits_s4 = guard_bit_s4 | round_bit_s4 | sticky_bit_s4;
    reg round_up_s4;
    
    always @(*) begin
        case (rounding_mode_s4)
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
    wire rounding_overflow_s4_recalc = rounded_mantissa_s4[23];
    wire [FP32_MANT_WIDTH-1:0] final_mantissa = rounding_overflow_s4_recalc ? 23'b0 : rounded_mantissa_s4[22:0];
    
    // 非规格化数舍入到零的特殊处理（RDN/RUP）
    reg [FP32_MANT_WIDTH-1:0] denormal_mantissa_final;
    always @(*) begin
        if (denormal_rounded_is_zero) begin
            case (rounding_mode_s4)
                `RM_RDN: begin
                    // Round Down: 负数→最小负非规格化数, 正数→+0
                    denormal_mantissa_final = sign_out_s4 ? 23'b1 : 23'b0;
                end
                `RM_RUP: begin
                    // Round Up: 负数→-0, 正数→最小正非规格化数
                    denormal_mantissa_final = sign_out_s4 ? 23'b0 : 23'b1;
                end
                default: begin
                    denormal_mantissa_final = 23'b0;
                end
            endcase
        end else begin
            denormal_mantissa_final = denormal_rounded[22:0];
        end
    end
    
    wire [FP32_MANT_WIDTH-1:0] computed_mantissa = result_is_denormal_s4 ? denormal_mantissa_final : final_mantissa;

    // ====================================================================
    // Stage 4: 溢出处理（基于舍入模式）
    // ====================================================================
    localparam EXP_MAX = 8'd255;
    localparam EXP_MAX_FINITE = 8'd254;
    localparam MANT_MAX = 23'h7FFFFF;
    
    reg [FP32_EXP_WIDTH-1:0] exponent_out_overflow;
    reg [FP32_MANT_WIDTH-1:0] mantissa_out_overflow;
    
    always @(*) begin
        case (rounding_mode_s4)
            `RM_RNE, `RM_RMM: begin
                exponent_out_overflow = EXP_MAX;  // ±Inf
                mantissa_out_overflow = {FP32_MANT_WIDTH{1'b0}};
            end
            `RM_RTZ: begin
                exponent_out_overflow = EXP_MAX_FINITE;  // ±Max
                mantissa_out_overflow = MANT_MAX;
            end
            `RM_RDN: begin
                exponent_out_overflow = sign_out_s4 ? EXP_MAX : EXP_MAX_FINITE;  // -∞ or +Max
                mantissa_out_overflow = sign_out_s4 ? {FP32_MANT_WIDTH{1'b0}} : MANT_MAX;
            end
            `RM_RUP: begin
                exponent_out_overflow = sign_out_s4 ? EXP_MAX_FINITE : EXP_MAX;  // -Max or +∞
                mantissa_out_overflow = sign_out_s4 ? MANT_MAX : {FP32_MANT_WIDTH{1'b0}};
            end
            default: begin
                exponent_out_overflow = EXP_MAX;
                mantissa_out_overflow = {FP32_MANT_WIDTH{1'b0}};
            end
        endcase
    end
    
    // ====================================================================
    // Stage 4: 下溢处理（基于舍入模式）
    // ====================================================================
    reg [FP32_MANT_WIDTH-1:0] mantissa_out_underflow;
    
    always @(*) begin
        case (rounding_mode_s4)
            `RM_RDN: begin
                // Round Down: 负数下溢→最小负非规格化数, 正数下溢→+0.0
                mantissa_out_underflow = sign_out_s4 ? 23'b1 : 23'b0;
            end
            `RM_RUP: begin
                // Round Up: 负数下溢→-0.0, 正数下溢→最小正非规格化数
                mantissa_out_underflow = sign_out_s4 ? 23'b0 : 23'b1;
            end
            default: begin
                // RNE, RTZ, RMM: 下溢时输出零
                mantissa_out_underflow = {FP32_MANT_WIDTH{1'b0}};
            end
        endcase
    end
    
    // ====================================================================
    // Stage 4: 最终结果选择
    // ====================================================================
    wire [FP32_MANT_WIDTH-1:0] mantissa_out =
        output_is_nan_s4    ? {1'b1, {(FP32_MANT_WIDTH-1){1'b0}}} :  // NaN: 0x7FFFFF
        output_is_zero_s4   ? {FP32_MANT_WIDTH{1'b0}} :
        output_is_inf_s4    ? {FP32_MANT_WIDTH{1'b0}} :
        exponent_overflow_s4 ? mantissa_out_overflow :
        (exponent_underflow_s4 && !result_is_denormal_s4) ? mantissa_out_underflow :
        (result_is_denormal_s4 && denormal_rounded_is_zero && (rounding_mode_s4 == `RM_RDN || rounding_mode_s4 == `RM_RUP)) ? denormal_mantissa_final :
        computed_mantissa;

    wire [FP32_EXP_WIDTH-1:0] exponent_out =
        output_is_nan_s4    ? EXP_MAX :
        output_is_zero_s4   ? 8'd0   :
        output_is_inf_s4    ? EXP_MAX :
        exponent_overflow_s4 ? exponent_out_overflow :
        (exponent_underflow_s4 && !result_is_denormal_s4) ? 8'd0 :
        result_is_denormal_s4 ? 8'd0 :
        exp_out_biased_s4[7:0];

    // ====================================================================
    // Stage 4: 异常检测
    // ====================================================================
    wire invalid_operation = output_is_nan_s4;  // NaN input or Inf×0
    wire div_zero = 1'b0;  // N/A for multiplier
    wire overflow_flag = exponent_overflow_s4 && !output_is_nan_s4;
    wire underflow_flag = exponent_underflow_s4 && 
                         !result_is_denormal_s4 && 
                         !output_is_nan_s4;
    
    // 正常数的丢弃位检测
    wire has_discarded_bits_normal = guard_bit_s4 | round_bit_s4 | sticky_bit_s4;
    // 非规格化数的丢弃位检测
    wire has_discarded_bits_denorm = denormal_guard | denormal_round | denormal_sticky;
    // 不精确标志
    wire inexact_flag = (result_is_denormal_s4 ? has_discarded_bits_denorm : has_discarded_bits_normal) && 
                       !output_is_nan_s4 && 
                       !output_is_zero_s4;
    
    wire [4:0] exception_flags_wire;
    assign exception_flags_wire[`EXC_INVALID]   = invalid_operation;
    assign exception_flags_wire[`EXC_DIV_ZERO]  = div_zero;
    assign exception_flags_wire[`EXC_OVERFLOW]  = overflow_flag;
    assign exception_flags_wire[`EXC_UNDERFLOW] = underflow_flag;
    assign exception_flags_wire[`EXC_INEXACT]   = inexact_flag;

    reg        valid_o_reg;
    reg [31:0] result_reg;
    reg [4:0]  exception_flags_reg;

generate
    if (IEEE_754 == 1) begin : gen_ieee754_exponent_out
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                valid_o_reg <= 1'b0;
                result_reg  <= 32'b0;
                exception_flags_reg <= 5'b0;
            end else begin
                valid_o_reg <= v_s4;
                if (v_s4) begin
                    result_reg <= {sign_out_s4, exponent_out, mantissa_out};
                    exception_flags_reg <= exception_flags_wire;
                end
            end
        end
    end else begin : gen_non_ieee754_exponent_out
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                valid_o_reg <= 1'b0;
                result_reg  <= 32'b0;
                exception_flags_reg <= 5'b0;
            end else begin
                valid_o_reg <= v_s4;
                if (v_s4) begin
                    if (exponent_out == 0) begin
                        result_reg <= {sign_out_s4, 8'd0, 23'b0};
                    end else begin
                        result_reg <= {sign_out_s4, exponent_out, mantissa_out};
                    end
                    exception_flags_reg <= exception_flags_wire;
                end
            end
        end
    end
endgenerate

    assign valid_o = valid_o_reg;
    assign result = ((result_reg[30:23] == 8'hFF) && (result_reg[22:0] != 23'd0)) ? 32'h7FFFFFFF : result_reg;
    assign exception_flags = exception_flags_reg;

`endif

endmodule