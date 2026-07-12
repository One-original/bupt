// 全加器模块 
module full_adder (
    input wire i_a,
    input wire i_b,
    input wire i_cin,
    output wire o_sum,
    output wire o_cout
);
    assign o_sum = i_a ^ i_b ^ i_cin;
    assign o_cout = (i_a & i_b) | (i_a & i_cin) | (i_b & i_cin);
endmodule