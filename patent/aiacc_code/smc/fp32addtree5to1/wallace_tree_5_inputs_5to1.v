//===============================================================
// Project: FP32_Accelerator
// File: wallace_tree_5_inputs.v
// Module: wallace_tree_5_inputs
// Author: sunny
// Email: [2042504725@qq.com]
// Created: 2025-08-13
// Modified: 2025-10-27
// Version: 3.0
//===============================================================
// Description:
// 5输入华莱士树，用于FP32加法树。
// 压缩路径：5→4→3→2，使用全加器进行压缩。
// 特性：
// - 参数化的数据位宽与输入位宽
// - 扁平化输入，内部零扩展到WIDTH
// - 3级全加器压缩结构
// 参数：
// - NUM_INPUTS : 输入操作数数量（默认：5）
// - WIDTH      : 内部计算数据位宽（默认：`FULL_SUM_WIDTH）
// - IN_WIDTH   : 端口输入数据位宽（默认等于WIDTH）
// 接口端口：
// - data_in       : 扁平化输入数据 [NUM_INPUTS*IN_WIDTH-1:0]
// - final_result  : 最终求和结果 [WIDTH:0]（含进位，WIDTH+1 位）
// 依赖：
// - full_adder 模块（端口：a,b,c,sum,carry）
// - fp32_defines.vh 文件
//===============================================================

`include "fp32_defines.vh"

module wallace_tree_5_inputs_5to1 #(
    parameter NUM_INPUTS = 5,
    parameter WIDTH      = `FULL_SUM_WIDTH,
    parameter IN_WIDTH   = WIDTH
) (
    input  wire [NUM_INPUTS*IN_WIDTH-1:0] data_in,    // 扁平化输入
    output wire [WIDTH:0]                 final_result // 瘦身后：WIDTH+1 位
);

    //===============================================================
    // 内部信号声明
    //===============================================================

    // 输入解包与零扩展
    wire [IN_WIDTH-1:0] w_in_raw [0:NUM_INPUTS-1];
    wire [WIDTH-1:0]    w_inputs [0:NUM_INPUTS-1];

    // 压缩层级
    wire [WIDTH-1:0] w_layer1 [0:3];  // 第1层：5→4
    wire [WIDTH-1:0] w_layer2 [0:2];  // 第2层：4→3

    // 最终压缩输出
    wire [WIDTH-1:0] w_sum_out;
    wire [WIDTH-1:0] w_carry_out;

    // 生成块变量
    genvar i, b;

    //===============================================================
    // 输入解包与零扩展
    //===============================================================
    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : g_unpack_inputs
            assign w_in_raw[i] = data_in[(i+1)*IN_WIDTH-1 : i*IN_WIDTH];
            assign w_inputs[i] = {{(WIDTH-IN_WIDTH){1'b0}}, w_in_raw[i]};
        end
    endgenerate

    //===============================================================
    // 第1层压缩：5个输入 → 4个输出
    //===============================================================
    generate
        for (b = 0; b < WIDTH; b = b + 1) begin : g_layer1_compress
            if (b < IN_WIDTH) begin : active_bits
                // 按位收集输入（低于 IN_WIDTH 的有效位）
                wire [4:0] w_input_bits;
                assign w_input_bits = {
                    w_inputs[4][b], w_inputs[3][b], w_inputs[2][b], w_inputs[1][b], w_inputs[0][b]
                };

                // 全加器：处理位[2:0]
                wire w_fa_sum, w_fa_carry;
                full_adder u_fa (
                    .i_a   (w_input_bits[0]),
                    .i_b   (w_input_bits[1]), 
                    .i_cin (w_input_bits[2]),
                    .o_sum (w_fa_sum),
                    .o_cout(w_fa_carry)
                );

                // 第1层输出分配
                assign w_layer1[0][b] = w_fa_sum;       // 和
                assign w_layer1[1][b] = w_input_bits[3]; // 直通
                assign w_layer1[2][b] = w_input_bits[4]; // 直通
                assign w_layer1[3][b] = w_fa_carry;     // 进位（用于下一位）
            end else begin : high_zero
                // 最高列无原始输入，保持为0，由下一层承接来自 b-1 的进位
                assign w_layer1[0][b] = 1'b0;
                assign w_layer1[1][b] = 1'b0;
                assign w_layer1[2][b] = 1'b0;
                assign w_layer1[3][b] = 1'b0;
            end
        end
    endgenerate

    //===============================================================
    // 第2层压缩：4个输入 → 3个输出
    //===============================================================
    generate
        for (b = 0; b < WIDTH; b = b + 1) begin : g_layer2_compress
            if (b == 0) begin : bit0
                // b==0：无来自前一位的进位，直接以0作为 cin
                wire w_fa_sum, w_fa_carry;
                full_adder u_fa (
                    .i_a   (1'b0),
                    .i_b   (w_layer1[0][b]), 
                    .i_cin (w_layer1[1][b]),
                    .o_sum (w_fa_sum),
                    .o_cout(w_fa_carry)
                );
                assign w_layer2[0][b] = w_fa_sum;       // 和
                assign w_layer2[1][b] = w_layer1[2][b]; // 直通
                assign w_layer2[2][b] = w_fa_carry;     // 进位
            end else begin : bitN
                // b>0：cin 取自上一位的进位通道
                wire w_fa_sum, w_fa_carry;
                wire w_carry_from_prev_safe;
                
                // 安全的索引访问：避免 b-1 在 b==0 时越界（虽然这里 b>0，但工具可能仍会检查）
                assign w_carry_from_prev_safe = (b > 0) ? w_layer1[3][b-1] : 1'b0;
                
                full_adder u_fa (
                    .i_a   (w_carry_from_prev_safe),
                    .i_b   (w_layer1[0][b]), 
                    .i_cin (w_layer1[1][b]),
                    .o_sum (w_fa_sum),
                    .o_cout(w_fa_carry)
                );
                assign w_layer2[0][b] = w_fa_sum;       // 和
                assign w_layer2[1][b] = w_layer1[2][b]; // 直通
                assign w_layer2[2][b] = w_fa_carry;     // 进位
            end
        end
    endgenerate

    //===============================================================
    // 第3层压缩：3个输入 → 2个输出
    //===============================================================
    generate
        for (b = 0; b < WIDTH; b = b + 1) begin : g_layer3_compress
            if (b == 0) begin : bit0_special
                // pragma coverage off
                // 第0位：直接传递和，进位为0
                assign w_sum_out[b]   = w_layer2[0][b];
                assign w_carry_out[b] = 1'b0;
                // pragma coverage on
            end else begin : all_bits
                // 统一处理：前级进位、当前和、直通位
                wire w_fa_sum, w_fa_carry;
                wire w_carry_from_prev_safe;
                
                // 安全的索引访问：避免 b-1 在 b==0 时越界（虽然这里 b>0，但工具可能仍会检查）
                assign w_carry_from_prev_safe = (b > 0) ? w_layer2[2][b-1] : 1'b0;
                
                full_adder u_fa (
                    .i_a   (w_carry_from_prev_safe), // 前级进位
                    .i_b   (w_layer2[0][b]),   // 当前和
                    .i_cin (w_layer2[1][b]),   // 直通位
                    .o_sum (w_fa_sum),
                    .o_cout(w_fa_carry)
                );
                assign w_sum_out[b]   = w_fa_sum;
                assign w_carry_out[b] = w_fa_carry;
            end
        end
    endgenerate

    //===============================================================
    // 最终加法阶段
    // 输出位宽为 WIDTH+1，对应端口 [WIDTH:0]
    assign final_result = {1'b0, w_sum_out} + {w_carry_out, 1'b0};

endmodule