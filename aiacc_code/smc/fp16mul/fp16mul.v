//==============================================================================
// FP16转FP32乘法器阵列模块
// 支持32组并行FP16乘法计算，结果输出为FP32格式
// 符合IEEE 754-2008标准
//==============================================================================

module fp16mul #(
    parameter SMC_ID = 0,    // SMC ID for this module
    parameter IEEE_754 = 1    // IEEE 754 mode
)(

    // 时钟和复位
    input  wire        clk,
    input  wire        rst_n,
    
    // 数据输入接口
    input  wire [127:0] dvr_fp16mul_s0,    // S0数据输入 (FP16_A[3:0])
    input  wire [127:0] dvr_fp16mul_s1,    // S1数据输入 (FP16_A[7:4])
    input  wire [127:0] dvr_fp16mul_s2,    // S2数据输入 (FP16_A[11:8])
    input  wire [127:0] dvr_fp16mul_s3,    // S3数据输入 (FP16_A[15:12])
    input  wire [127:0] dvr_fp16mul_s4567, // S4-S7复用数据输入 (FP16_B)
    
    // 控制信号（对齐 v0.4.12 指令表字段名）
    // cru_fp16mul      : [7:3]=smc_id_en, [2]=src_1_id, [1]=src_0_id, [0]=vld
    // cru_fp16mul_s0123: [6:2]=smc_id_en, [1]=src3210_high_id, [0]=vld
    // cru_fp16mul_s4567: [8:4]=smc_id_en, [3:2]=src7654_low_id, [1]=src7654_high_id, [0]=vld
    input  wire [6:0]   cru_fp16mul_s0123, // S0-S3控制信号（带smc_id_en）
    input  wire [8:0]   cru_fp16mul_s4567, // S4-S7控制信号（带smc_id_en）
    input  wire [7:0]   cru_fp16mul,       // 乘法控制信号（带 smc_id_en）
    input  wire [2:0]   i_rounding_mode,   // Rounding mode: 000=RNE, 001=RTZ, 010=RDN, 011=RUP, 100=RMM
    
    // 结果输出寄存器
    output reg  [127:0] dr_fp16mul_d0,     // FP32结果[3:0]
    output reg  [127:0] dr_fp16mul_d1,     // FP32结果[7:4]
    output reg  [127:0] dr_fp16mul_d2,     // FP32结果[11:8]
    output reg  [127:0] dr_fp16mul_d3,     // FP32结果[15:12]
    output reg  [127:0] dr_fp16mul_d4,     // FP32结果[19:16]
    output reg  [127:0] dr_fp16mul_d5,     // FP32结果[23:20]
    output reg  [127:0] dr_fp16mul_d6,     // FP32结果[27:24]
    output reg  [127:0] dr_fp16mul_d7,    // FP32结果[31:28]
    output reg  [6:0]   cru_fp16mul_s0123_o, // cru_fp16mul_s0123打一拍输出（带smc_id_en）
    output reg  [8:0]   cru_fp16mul_s4567_o, // cru_fp16mul_s4567打一拍输出（带smc_id_en）
    output reg  [7:0]   cru_fp16mul_o,       // cru_fp16mul打一拍输出
    
    // 异常标志输出（扁平化 32*5=160 位，避免数组端口）
    output wire [159:0]  o_exception_flags   // [4:0]=mul0, [9:5]=mul1, ... [159:155]=mul31
);

//==============================================================================
// 设计参数
//==============================================================================
localparam PARAM_DR_FP16MUL_CNT = 32;      // fp16乘法器数量
localparam PARAM_DR_FP16MUL_S0_CNT = 2;    // s0-s3寄存器数量  
localparam PARAM_DR_FP16MUL_S1_CNT = 2;    // s4-s7寄存器数量

//==============================================================================
// 内部信号定义
//==============================================================================

// 源寄存器组A (S0-S3)
reg [127:0] s0_bank0_r, s0_bank1_r;
reg [127:0] s1_bank0_r, s1_bank1_r;
reg [127:0] s2_bank0_r, s2_bank1_r;
reg [127:0] s3_bank0_r, s3_bank1_r;

// 源寄存器组B (S4-S7)
reg [127:0] s4_bank0_r, s4_bank1_r;
reg [127:0] s5_bank0_r, s5_bank1_r;
reg [127:0] s6_bank0_r, s6_bank1_r;
reg [127:0] s7_bank0_r, s7_bank1_r;

// 锁存寄存器
reg [127:0] selected_s0_r, selected_s1_r, selected_s2_r, selected_s3_r;
reg [127:0] selected_s4_r, selected_s5_r, selected_s6_r, selected_s7_r;

// 计算有效信号
reg [4:0]   compute_valid_r;

// 乘法器输入信号
wire [15:0] fp16_a [31:0];
wire [15:0] fp16_b [31:0];
wire [31:0] fp32_result [31:0];
wire        mul_valid_o [31:0];  // Multiplier output valid signals
wire [4:0]  exception_flags_per_mul [31:0];  // Exception flags from each multiplier

//==============================================================================
// 源寄存器组A (S0-S3) 写入逻辑
//==============================================================================
//==============================================================================
// 控制信号解析
//==============================================================================
// cru_fp16mul_s0123 信号解析（bit 位对齐 spec：vld + src3210_high_id + smc_id_en）
wire [4:0] smc_id_en_s0123       = cru_fp16mul_s0123[6:2];
wire       cru_s0123_vld_in      = cru_fp16mul_s0123[0];
wire       cru_s0123_high_id     = cru_fp16mul_s0123[1];  // 等价于选择 {S3,S2,S1,S0}_0 / _1
// 结合SMC过滤后的有效写入使能
wire       cru_s0123_write_enable = cru_s0123_vld_in && (SMC_ID[4:0] <= smc_id_en_s0123);

// cru_fp16mul_s4567 信号解析（bit 位对齐 spec：vld + src7654_high_id + src7654_low_id + smc_id_en）
wire [4:0] smc_id_en_s4567       = cru_fp16mul_s4567[8:4];
wire       cru_s4567_vld_in      = cru_fp16mul_s4567[0];
wire       cru_s4567_high_id     = cru_fp16mul_s4567[1];    // 等价于选择 bank0/bank1
wire [1:0] cru_s4567_low_id      = cru_fp16mul_s4567[3:2];  // 00=S4, 01=S5, 10=S6, 11=S7
// 结合SMC过滤后的有效写入使能
wire       cru_s4567_write_enable = cru_s4567_vld_in && (SMC_ID[4:0] <= smc_id_en_s4567);
// S0寄存器组写入
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s0_bank0_r <= 128'd0;
        s0_bank1_r <= 128'd0;
    end else if (cru_s0123_write_enable) begin
        if (cru_s0123_high_id) begin
            s0_bank1_r <= dvr_fp16mul_s0;
    end else begin
            s0_bank0_r <= dvr_fp16mul_s0;
        end
    end
end

// S1寄存器组写入
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s1_bank0_r <= 128'd0;
        s1_bank1_r <= 128'd0;
    end else if (cru_s0123_write_enable) begin
        if (cru_s0123_high_id) begin
            s1_bank1_r <= dvr_fp16mul_s1;
        end else begin
            s1_bank0_r <= dvr_fp16mul_s1;
        end
    end
end

// S2寄存器组写入
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s2_bank0_r <= 128'd0;
        s2_bank1_r <= 128'd0;
    end else if (cru_s0123_write_enable) begin
        if (cru_s0123_high_id) begin
            s2_bank1_r <= dvr_fp16mul_s2;
        end else begin
            s2_bank0_r <= dvr_fp16mul_s2;
        end
    end
end

// S3寄存器组写入
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s3_bank0_r <= 128'd0;
        s3_bank1_r <= 128'd0;
    end else if (cru_s0123_write_enable) begin
        if (cru_s0123_high_id) begin
            s3_bank1_r <= dvr_fp16mul_s3;
        end else begin
            s3_bank0_r <= dvr_fp16mul_s3;
        end
    end
end

//==============================================================================
// 源寄存器组B (S4-S7) 写入逻辑
//==============================================================================

// S4寄存器组写入
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s4_bank0_r <= 128'd0;
        s4_bank1_r <= 128'd0;
    end else if (cru_s4567_write_enable && (cru_s4567_low_id == 2'b00)) begin
        if (cru_s4567_high_id) begin
            s4_bank1_r <= dvr_fp16mul_s4567;
        end else begin
            s4_bank0_r <= dvr_fp16mul_s4567;
        end
    end
end

// S5寄存器组写入
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s5_bank0_r <= 128'd0;
        s5_bank1_r <= 128'd0;
    end else if (cru_s4567_write_enable && (cru_s4567_low_id == 2'b01)) begin
        if (cru_s4567_high_id) begin
            s5_bank1_r <= dvr_fp16mul_s4567;
        end else begin
            s5_bank0_r <= dvr_fp16mul_s4567;
        end
    end
end

// S6寄存器组写入
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s6_bank0_r <= 128'd0;
        s6_bank1_r <= 128'd0;
    end else if (cru_s4567_write_enable && (cru_s4567_low_id == 2'b10)) begin
        if (cru_s4567_high_id) begin
            s6_bank1_r <= dvr_fp16mul_s4567;
        end else begin
            s6_bank0_r <= dvr_fp16mul_s4567;
        end
    end
end

// S7寄存器组写入
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s7_bank0_r <= 128'd0;
        s7_bank1_r <= 128'd0;
    end else if (cru_s4567_write_enable && (cru_s4567_low_id == 2'b11)) begin
        if (cru_s4567_high_id) begin
            s7_bank1_r <= dvr_fp16mul_s4567;
        end else begin
            s7_bank0_r <= dvr_fp16mul_s4567;
        end
    end
end



// cru_fp16mul 信号解析
wire [4:0] smc_id_en = cru_fp16mul[7:3];
wire inst_valid = cru_fp16mul[0];
wire inst_valid_eff = inst_valid && (SMC_ID[4:0] <= smc_id_en);
wire inst_bank_sel_a = inst_valid_eff ? cru_fp16mul[1] : 1'b0;
wire inst_bank_sel_b = inst_valid_eff ? cru_fp16mul[2] : 1'b0;
wire [2:0] rounding_mode_gated = inst_valid_eff ? i_rounding_mode : 3'b000;

//==============================================================================
// 数据锁存逻辑
//==============================================================================
// 选择S0-S3数据
always @(*) begin
    if (inst_valid_eff) begin
        if (inst_bank_sel_a) begin
            selected_s0_r = s0_bank1_r;
            selected_s1_r = s1_bank1_r;
            selected_s2_r = s2_bank1_r;
            selected_s3_r = s3_bank1_r;
        end else begin
            selected_s0_r = s0_bank0_r;
            selected_s1_r = s1_bank0_r;
            selected_s2_r = s2_bank0_r;
            selected_s3_r = s3_bank0_r;
        end
    end else begin
        selected_s0_r = 128'd0;
        selected_s1_r = 128'd0;
        selected_s2_r = 128'd0;
        selected_s3_r = 128'd0;
    end
end

// 选择S4-S7数据
always @(*) begin
    if (inst_valid_eff) begin
        if (inst_bank_sel_b) begin
            selected_s4_r = s4_bank1_r;
            selected_s5_r = s5_bank1_r;
            selected_s6_r = s6_bank1_r;
            selected_s7_r = s7_bank1_r;
        end else begin
            selected_s4_r = s4_bank0_r;
            selected_s5_r = s5_bank0_r;
            selected_s6_r = s6_bank0_r;
            selected_s7_r = s7_bank0_r;
        end
    end else begin
        selected_s4_r = 128'd0;
        selected_s5_r = 128'd0;
        selected_s6_r = 128'd0;
        selected_s7_r = 128'd0;
    end
end

// 计算有效信号延迟
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        compute_valid_r <= 5'd0;
        cru_fp16mul_s0123_o <= 7'b0;
        cru_fp16mul_s4567_o <= 9'b0;
        cru_fp16mul_o <= 8'b0;
    end else begin
        compute_valid_r <= {compute_valid_r[3:0], inst_valid_eff};
        cru_fp16mul_s0123_o <= cru_fp16mul_s0123;
        cru_fp16mul_s4567_o <= cru_fp16mul_s4567;
        cru_fp16mul_o <= cru_fp16mul;
    end
end

//==============================================================================
// 数据重组逻辑（对齐 v0.4.12 FP16MUL 功能说明）
// 每个 S* 为 128bit = 8 组 16bit lane
// x = 0..3:
// D0[x] = mul(S0[x],   S4[x])      D1[x] = mul(S0[x+4], S4[x+4])
// D2[x] = mul(S1[x],   S5[x])      D3[x] = mul(S1[x+4], S5[x+4])
// D4[x] = mul(S2[x],   S6[x])      D5[x] = mul(S2[x+4], S6[x+4])
// D6[x] = mul(S3[x],   S7[x])      D7[x] = mul(S3[x+4], S7[x+4])
//==============================================================================

wire [15:0] s0_lane [0:7];
wire [15:0] s1_lane [0:7];
wire [15:0] s2_lane [0:7];
wire [15:0] s3_lane [0:7];
wire [15:0] s4_lane [0:7];
wire [15:0] s5_lane [0:7];
wire [15:0] s6_lane [0:7];
wire [15:0] s7_lane [0:7];

genvar lane_i;
generate
    for (lane_i = 0; lane_i < 8; lane_i = lane_i + 1) begin : gen_fp16_lane_unpack
        assign s0_lane[lane_i] = selected_s0_r[16*lane_i +: 16];
        assign s1_lane[lane_i] = selected_s1_r[16*lane_i +: 16];
        assign s2_lane[lane_i] = selected_s2_r[16*lane_i +: 16];
        assign s3_lane[lane_i] = selected_s3_r[16*lane_i +: 16];
        assign s4_lane[lane_i] = selected_s4_r[16*lane_i +: 16];
        assign s5_lane[lane_i] = selected_s5_r[16*lane_i +: 16];
        assign s6_lane[lane_i] = selected_s6_r[16*lane_i +: 16];
        assign s7_lane[lane_i] = selected_s7_r[16*lane_i +: 16];
    end
endgenerate

genvar x;
generate
    for (x = 0; x < 4; x = x + 1) begin : gen_fp16mul_map
        // D0[x], D1[x]
        assign fp16_a[x]      = s0_lane[x];
        assign fp16_b[x]      = s4_lane[x];
        assign fp16_a[4+x]    = s0_lane[x+4];
        assign fp16_b[4+x]    = s4_lane[x+4];

        // D2[x], D3[x]
        assign fp16_a[8+x]    = s1_lane[x];
        assign fp16_b[8+x]    = s5_lane[x];
        assign fp16_a[12+x]   = s1_lane[x+4];
        assign fp16_b[12+x]   = s5_lane[x+4];

        // D4[x], D5[x]
        assign fp16_a[16+x]   = s2_lane[x];
        assign fp16_b[16+x]   = s6_lane[x];
        assign fp16_a[20+x]   = s2_lane[x+4];
        assign fp16_b[20+x]   = s6_lane[x+4];

        // D6[x], D7[x]
        assign fp16_a[24+x]   = s3_lane[x];
        assign fp16_b[24+x]   = s7_lane[x];
        assign fp16_a[28+x]   = s3_lane[x+4];
        assign fp16_b[28+x]   = s7_lane[x+4];
    end
endgenerate

//==============================================================================
// 32个FP16乘法器实例化
//==============================================================================
genvar i;
generate

    for (i = 0; i < 32; i = i + 1) begin : gen_fp16_mul_units
        /*
        fp16_mul_unit u_fp16_mul_unit (
            .fp16_a(fp16_a[i]),
            .fp16_b(fp16_b[i]),
            .fp32_result(fp32_result[i])
        );
*/
    fp16tofp32_multiplier #(
        .IEEE_754(IEEE_754)
    ) u_fp16tofp32_multiplier (
        .clk(clk),
        .rst_n(rst_n),
        .valid_i(inst_valid_eff),
        .rounding_mode(rounding_mode_gated),  // Pass gated rounding mode to multiplier
        .a(fp16_a[i]),
        .b(fp16_b[i]),
        .valid_o(mul_valid_o[i]),         // Multiplier output valid signal
        .result(fp32_result[i]),
        .exception_flags(exception_flags_per_mul[i])  // Get exception flags from multiplier
    );
    
    // Output exception flags (flattened: lane i -> o_exception_flags[i*5 +: 5])
    assign o_exception_flags[i*5 +: 5] = exception_flags_per_mul[i];
    end
endgenerate

//==============================================================================
// 结果输出逻辑 - 8个D寄存器，每个寄存器4组32bit
//==============================================================================

// 结果输出寄存器更新
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dr_fp16mul_d0 <= 128'd0;
        dr_fp16mul_d1 <= 128'd0;
        dr_fp16mul_d2 <= 128'd0;
        dr_fp16mul_d3 <= 128'd0;
        dr_fp16mul_d4 <= 128'd0;
        dr_fp16mul_d5 <= 128'd0;
        dr_fp16mul_d6 <= 128'd0;
        dr_fp16mul_d7 <= 128'd0;
    end else if (compute_valid_r[3]) begin
        // 每个D寄存器打包4组32bit结果（x=3..0）
        dr_fp16mul_d0 <= {fp32_result[3],  fp32_result[2],  fp32_result[1],  fp32_result[0]};
        dr_fp16mul_d1 <= {fp32_result[7],  fp32_result[6],  fp32_result[5],  fp32_result[4]};
        dr_fp16mul_d2 <= {fp32_result[11], fp32_result[10], fp32_result[9],  fp32_result[8]};
        dr_fp16mul_d3 <= {fp32_result[15], fp32_result[14], fp32_result[13], fp32_result[12]};
        dr_fp16mul_d4 <= {fp32_result[19], fp32_result[18], fp32_result[17], fp32_result[16]};
        dr_fp16mul_d5 <= {fp32_result[23], fp32_result[22], fp32_result[21], fp32_result[20]};
        dr_fp16mul_d6 <= {fp32_result[27], fp32_result[26], fp32_result[25], fp32_result[24]};
        dr_fp16mul_d7 <= {fp32_result[31], fp32_result[30], fp32_result[29], fp32_result[28]};
    end
end

endmodule

