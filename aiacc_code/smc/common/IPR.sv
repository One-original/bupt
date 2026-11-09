/*****************************************************************************
** Project  :  AIACC NPU                                                     **
******************************************************************************
**                                      **                                  **
** File name:  IPR.sv                     **             [Company]            **
** Designer :  [Designer Name]            **  [Division]                      **
**                                      **                                  **
******************************************************************************
******************************************************************************
**                                                                          **
** Module Description:                                                      **
**                                                                          **
** Input Pipeline Register (IPR) - VIN0 Module                            **
**                                                                          **
** This module implements a pipeline register that delays the input data   **
** by one clock cycle when the control signal is valid.                    **
**                                                                          **
** Function:                                                               **
**   - When CRU-VIN0[0] (vld) = 1:                                        **
**     DR-VIN0-D <= DVR-VIN0-S (one cycle delay)                           **
**   - When CRU-VIN0[0] (vld) = 0:                                        **
**     DR-VIN0-D holds previous value (no update)                          **
**                                                                          **
******************************************************************************
******************************************************************************
**                                                                          **
** Hierarchy:                                                               **
**                                                                          **
** SMC -> IPR (VIN0)                                                      **
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
** and proprietary information of [Company] and is protected                **
*****************************************************************************/
// $Revision: 1.0 $

`timescale 1ns / 1ps

module IPR #(
    parameter SMC_ID = 5'd0
)(
    // Clock and Reset
    input  wire        clk,
    input  wire        rst_n,
 
    // Control Register Upstream (CRU-VIN0)
    // Bit 0  : vld
    // Bit 5:1: smc_id_en
    input  wire [5:0]  cru_vin0,
    
    // Data Vector Register Source (DVR-VIN0-S)
    input  wire [127:0] dvr_vin0_s,
    
    // Data Register Output (DR-VIN0-D)
    output reg  [127:0] dr_vin0_d,
    
    // Control Register Upstream Output (CRU-VIN0-O)
    output reg  [5:0]  cru_vin0_o
);

// ==========================================================================
// 1. Control Signal Extraction
// ==========================================================================
wire        w_vld_raw    = cru_vin0[0];
wire [4:0]  w_smc_id_en  = cru_vin0[5:1];
wire        w_vld_eff    = w_vld_raw && (w_smc_id_en >= SMC_ID[4:0]);

// ==========================================================================
// 2. Pipeline Register Logic
// ==========================================================================
// When CRU-VIN0 is valid, output DVR-VIN0-S with one cycle delay
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dr_vin0_d <= 128'b0;
    end else begin
        if (w_vld_eff) begin
            dr_vin0_d <= dvr_vin0_s;  // One cycle delay
        end
        // If not valid, hold previous value (no update)
    end
end

// ==========================================================================
// 3. CRU Output (Pass through with optional pipeline)
// ==========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cru_vin0_o <= 6'b0;
    end else begin
        cru_vin0_o <= cru_vin0;  // Pass through CRU input
    end
end

endmodule
