//===============================================================
// Project: FP32_Accelerator
// File: wallace_tree_8_inputs.v
// Module: wallace_tree_8_inputs
// Author: sunny
// Email: [2042504725@qq.com]
// Created: 2025-6-23
// Modified: 2025-10-25
// Version: 3.2
//===============================================================
// Description:
// 8输入华莱士树乘法器，用于FP32加法树。
// 实现4层压缩：8→6→4→3→2，使用全加器进行压缩。
// 特性：
// - 参数化的数据位宽和输入位宽
// - 内部计算使用零扩展
// - 4级全加器压缩结构
// 参数：
// - NUM_INPUTS : 输入操作数数量（默认：8）
// - WIDTH : 内部计算数据位宽
// - IN_WIDTH : 端口输入数据位宽（内部进行零扩展，默认等于WIDTH）
// 接口端口：
// - i_data_in : 扁平化输入数据 [NUM_INPUTS*IN_WIDTH-1:0]
// - o_final_result : 最终求和结果 [WIDTH:0]
// 依赖：
// - full_adder模块
// - fp32_defines.vh文件
//===============================================================

`include "fp32_defines.vh"


module wallace_tree_8_inputs_8to1 #(
    parameter NUM_INPUTS = 8,                    // 输入操作数数量
    parameter WIDTH      = `FULL_SUM_WIDTH,      // 内部计算位宽
    parameter IN_WIDTH   = WIDTH                 // 端口输入位宽
) (
    // 数据接口
    input  wire [NUM_INPUTS*IN_WIDTH-1:0] i_data_in,   // 扁平化输入数据
    output wire [WIDTH:0]                 o_final_result // 最终结果（含进位）
);

    //===============================================================
    // 内部信号声明
    //===============================================================

    // 输入解包
    wire [IN_WIDTH-1:0] w_in_raw [0:NUM_INPUTS-1];
    wire [WIDTH-1:0]    w_inputs [0:NUM_INPUTS-1];

    // 压缩层级
    wire [WIDTH-1:0] w_layer1 [0:5];  // 第1层：8→6压缩
    wire [WIDTH-1:0] w_layer2 [0:3];  // 第2层：6→4压缩  
    wire [WIDTH-1:0] w_layer3 [0:2];  // 第3层：4→3压缩
    
    // 最终压缩输出
    wire [WIDTH-1:0] w_sum_out;
    wire [WIDTH-1:0] w_carry_out;

    // 生成块变量
    genvar i, b;

    //===============================================================
    // 输入解包和零扩展
    //===============================================================

    generate
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin : g_unpack_inputs
            // 解包扁平化输入
            assign w_in_raw[i] = i_data_in[(i+1)*IN_WIDTH-1 : i*IN_WIDTH];
            
            // 零扩展到内部位宽
            assign w_inputs[i] = {{(WIDTH-IN_WIDTH){1'b0}}, w_in_raw[i]};
        end
    endgenerate

    //===============================================================
    // 第1层压缩：8个输入 → 6个输出
    //===============================================================

    generate
        for (b = 0; b < WIDTH; b = b + 1) begin : g_layer1_compress
            
            if (b < IN_WIDTH) begin : active_bits
                // 按位分组输入信号
                wire [7:0] w_input_bits;
                assign w_input_bits = {
                    w_inputs[7][b], w_inputs[6][b], w_inputs[5][b], w_inputs[4][b],
                    w_inputs[3][b], w_inputs[2][b], w_inputs[1][b], w_inputs[0][b]
                };

                // 全加器1：处理位[2:0]
                wire w_fa1_sum, w_fa1_carry;
                full_adder u_fa1 (
                    .i_a    (w_input_bits[0]),
                    .i_b    (w_input_bits[1]), 
                    .i_cin  (w_input_bits[2]),
                    .o_sum  (w_fa1_sum),
                    .o_cout (w_fa1_carry)
                );

                // 全加器2：处理位[5:3]
                wire w_fa2_sum, w_fa2_carry;
                full_adder u_fa2 (
                    .i_a    (w_input_bits[3]),
                    .i_b    (w_input_bits[4]), 
                    .i_cin  (w_input_bits[5]),
                    .o_sum  (w_fa2_sum),
                    .o_cout (w_fa2_carry)
                );

                // 第1层输出分配
                assign w_layer1[0][b] = w_fa1_sum;       // 全加器1的和输出
                assign w_layer1[1][b] = w_fa2_sum;       // 全加器2的和输出  
                assign w_layer1[2][b] = w_input_bits[6]; // 直通位6
                assign w_layer1[3][b] = w_input_bits[7]; // 直通位7
                assign w_layer1[4][b] = w_fa1_carry;     // 全加器1进位（用于下一位）
                assign w_layer1[5][b] = w_fa2_carry;     // 全加器2进位（用于下一位）

            end else begin : zero_extend
                // 高位区域：零扩展
                assign w_layer1[0][b] = 1'b0;
                assign w_layer1[1][b] = 1'b0;
                assign w_layer1[2][b] = 1'b0;
                assign w_layer1[3][b] = 1'b0;
                assign w_layer1[4][b] = 1'b0;
                assign w_layer1[5][b] = 1'b0;
            end
        end
    endgenerate

    //===============================================================
    // 第2层压缩：6个输入 → 4个输出
    //===============================================================

    generate
        for (b = 0; b < WIDTH; b = b + 1) begin : g_layer2_compress
            
            if (b < IN_WIDTH) begin : active_bits
                // 全加器1：处理第1层输出
                wire w_fa1_sum, w_fa1_carry;
                full_adder u_fa1 (
                    .i_a    (w_layer1[3][b]),
                    .i_b    (w_layer1[2][b]), 
                    .i_cin  (w_layer1[1][b]),
                    .o_sum  (w_fa1_sum),
                    .o_cout (w_fa1_carry)
                );

                if (b == 0) begin : bit0_special
                    // 第0位特例：无前级进位，使用直通
                    assign w_layer2[1][b] = w_layer1[0][b]; // 直通第1层和0
                    assign w_layer2[3][b] = 1'b0;           // 无前级进位
                end else begin : normal_bits
                    // 全加器2：处理带前级进位的情况
                    wire w_fa2_sum, w_fa2_carry;
                    full_adder u_fa2 (
                        .i_a    (w_layer1[0][b]),
                        .i_b    (w_layer1[5][b-1]), 
                        .i_cin  (w_layer1[4][b-1]),
                        .o_sum  (w_fa2_sum),
                        .o_cout (w_fa2_carry)
                    );
                    assign w_layer2[1][b] = w_fa2_sum;   // 全加器2的和输出
                    assign w_layer2[3][b] = w_fa2_carry; // 全加器2的进位输出
                end

                // 第2层输出分配
                assign w_layer2[0][b] = w_fa1_sum;   // 全加器1的和输出
                assign w_layer2[2][b] = w_fa1_carry; // 全加器1的进位输出

            end else if (b == IN_WIDTH && IN_WIDTH < WIDTH) begin : boundary_collect
                // 边界位：仅当IN_WIDTH < WIDTH时收集前一位的进位
                wire w_fa2_sum, w_fa2_carry;
                full_adder u_fa2_high (
                    .i_a    (w_layer1[4][b-1]),
                    .i_b    (w_layer1[5][b-1]), 
                    .i_cin  (1'b0),
                    .o_sum  (w_fa2_sum),
                    .o_cout (w_fa2_carry)
                );

                assign w_layer2[0][b] = 1'b0;        // 此位无和输入
                assign w_layer2[1][b] = w_fa2_sum;   // 进位和
                assign w_layer2[2][b] = 1'b0;        // 此位无进位输入  
                assign w_layer2[3][b] = w_fa2_carry; // 进位输出

            end else begin : high_zero
                // 高位区域：零扩展
                assign w_layer2[0][b] = 1'b0;
                assign w_layer2[1][b] = 1'b0;
                assign w_layer2[2][b] = 1'b0;
                assign w_layer2[3][b] = 1'b0;
            end
        end
    endgenerate

    //===============================================================
    // 第3层压缩：4个输入 → 3个输出
    //===============================================================

    generate
        for (b = 0; b < WIDTH; b = b + 1) begin : g_layer3_compress
            
            if (b <= IN_WIDTH) begin : active_bits
                wire w_fa_sum, w_fa_carry;
                wire w_cin_safe;
                wire w_pass_through_safe;

                // 安全的索引访问：避免 b-1 在 b==0 时越界
                assign w_cin_safe = (b > 0) ? w_layer2[3][b-1] : 1'b0;
                assign w_pass_through_safe = (b > 0) ? w_layer2[2][b-1] : 1'b0;

                full_adder u_fa (
                    .i_a    (w_layer2[1][b]),
                    .i_b    (w_layer2[0][b]), 
                    .i_cin  (w_cin_safe),
                    .o_sum  (w_fa_sum),
                    .o_cout (w_fa_carry)
                );

                // 第3层输出分配
                assign w_layer3[0][b] = w_fa_sum;                      // 全加器和输出
                assign w_layer3[1][b] = w_pass_through_safe;           // 直通位
                assign w_layer3[2][b] = w_fa_carry;                    // 全加器进位输出

            end else begin : high_pass
                // 高位区域：传递剩余进位
                wire w_carry_pass_safe;
                assign w_carry_pass_safe = (b > 0) ? w_layer2[3][b-1] : 1'b0;
                assign w_layer3[0][b] = w_carry_pass_safe;            // 传递进位
                assign w_layer3[1][b] = 1'b0;                         // 零
                assign w_layer3[2][b] = 1'b0;                          // 零
            end
        end
    endgenerate

    //===============================================================
    // 第4层压缩：3个输入 → 2个输出
    //===============================================================

    generate
        for (b = 0; b < WIDTH; b = b + 1) begin : g_layer4_compress
            
            if (b == 0) begin : bit0_special
                
                assign w_sum_out[b]   = w_layer3[0][b]; // 直接传递
                assign w_carry_out[b] = 1'b0;           // 第0位无进位

            end else begin : all_bits
                // 统一处理：b>0 的所有位都用全加器实现（高位同样适用）
                wire w_fa_sum, w_fa_carry;
                full_adder u_fa (
                    .i_a    ((b==0) ? 1'b0 : w_layer3[2][b-1]), // 前级进位（防越界）
                    .i_b    (w_layer3[0][b]),   // 当前和输入  
                    .i_cin  (w_layer3[1][b]),   // 直通位（高位该信号为0）
                    .o_sum  (w_fa_sum),
                    .o_cout (w_fa_carry)
                );
                assign w_sum_out[b]   = w_fa_sum;   // 和输出
                assign w_carry_out[b] = w_fa_carry; // 进位输出
            end
        end
    endgenerate

    //===============================================================
    // 最终加法阶段
    //===============================================================
    // 最终结果 = {1'b0, 和输出} + {进位输出, 1'b0}
    // 确保正确的位宽：WIDTH+1位

    assign o_final_result = {1'b0, w_sum_out} + {w_carry_out, 1'b0};

endmodule