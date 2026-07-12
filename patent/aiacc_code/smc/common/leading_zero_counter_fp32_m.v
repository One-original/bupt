/*****************************************************************************
** Project  :  AIACC NPU                                                     **
******************************************************************************
**                                      **                                  **
** File name:  leading_zero_counter_fp32_m.v  **             AIACC Team          **
** Designer :  AIACC RTL Generator      **  NPU Design Division            **
**                                      **                                  **
******************************************************************************
******************************************************************************
**                                                                          **
** Module Description:                                                      **
**                                                                          **
** Leading Zero Counter for FP32 Multiplier                                **
**                                                                          **
** This module counts the number of leading zeros in a data word.         **
** Used for normalization in floating-point multiplication.                **
**                                                                          **
******************************************************************************
******************************************************************************
**                                                                          **
** Hierarchy:                                                               **
**                                                                          **
** leading_zero_counter_fp32_m                                              **
**                                                                          **
******************************************************************************
******************************************************************************
**                                                                          **
**   Revision        Date            By               Reason                **
** ------------   ------------   ------------      ------------             **
**     1.0                                           Creation               **
**                                                                          **
******************************************************************************
****************************************************************************** 
** This file has been provided pursuant to a License Agreement containing   **
** restrictions on its use. This data contains valuable trade secrets       **
** and proprietary information of AIACC and is protected                    **
*****************************************************************************/
// $Revision: 1.0 $

module leading_zero_counter_fp32_m #(
    parameter DATA_WIDTH  = 48,
    parameter COUNT_WIDTH = 6
)(
    input  wire [DATA_WIDTH-1:0]  data_in,
    output reg [COUNT_WIDTH-1:0] leading_zeros
);

    integer i;
    reg found;

    always @* begin
        leading_zeros   = 6'd48;
        found = 1'b0;
        for (i = 47; i >= 0; i = i - 1) begin
            if (!found && data_in[i]) begin
                leading_zeros   = 47 - i;
                found = 1'b1;
            end
        end
    end

endmodule
