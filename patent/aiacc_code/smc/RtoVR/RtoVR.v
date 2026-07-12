/*****************************************************************************
** Project  :  AIACC NPU                                                     **
******************************************************************************
**                                      **                                  **
** File name:  mux.v                     **             [Company]            **
** Designer :  [designer_name]           **  [Division]                      **
**                                      **                                  **
******************************************************************************
******************************************************************************
**                                                                          **
** Module Description:                                                      **
**                                                                          **
** RtoVR Mux Module: 64-input to 40-output programmable crossbar switch   **
** - 64 inputs (128-bit each), numbered 0-63                              **
** - 40 outputs (128-bit each), numbered 0-39                              **
** - CRU micro-instruction: NUM_OUTPUTS groups of CRU_BITS_PER_OUTPUT-bit {valid, select} **
** - Supports input/output pipeline stages                                  **
** - Supports source mask matrix OUT_FROM_IN_EN for security/functionality  **
**                                                                          **
******************************************************************************
******************************************************************************
**                                                                          **
** Hierarchy:                                                               **
**                                                                          **
** RtoVR (top)                                                              **
**   └─ mux (this module)                                                   **
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
// Include rounding mode and exception flag definitions
`include "fp32_defines.vh"

module RtoVR #(
    // Module identification
    parameter SMC_ID = 0,               // SMC ID for this module
    
    // Interface parameters
    parameter DATA_WIDTH = 128,         // Data width (128-bit)
    parameter NUM_INPUTS = 36,          // Number of inputs (0-63)
    parameter NUM_OUTPUTS = 40,        // Number of outputs (0-39)
    
    // CRU (Control Register Upstream) format parameters
    // Each output uses CRU_BITS_PER_OUTPUT bits: {valid[CRU_BITS_PER_OUTPUT-1], select[CRU_SELECT_BITS-1:0]}
    parameter CRU_VALID_BITS = 1,      // Number of bits for valid signal
    parameter CRU_SELECT_BITS = 6,     // Number of bits for input select (supports 0-63)
    parameter CRU_BITS_PER_OUTPUT = CRU_VALID_BITS + CRU_SELECT_BITS  // Total bits per output (6)
)(
    // Clock and Reset
    input  wire        clk,
    input  wire        rst_n,

    // CRU Micro-instruction (NUM_OUTPUTS × CRU_BITS_PER_OUTPUT bits)
    input  wire [NUM_OUTPUTS*CRU_BITS_PER_OUTPUT-1:0] cru_rtovr,
    output wire [NUM_OUTPUTS*CRU_BITS_PER_OUTPUT-1:0] cru_rtovr_o,
    
    // 64 Inputs (128-bit each) - Input mapping according to PDF Table 1
    input  wire [127:0] dr_intadd_d0,        // Input 0
    input  wire [127:0] dr_intadd_d1,        // Input 1
    input  wire [127:0] dr_intadd_st,        // Input 2
    input  wire [127:0] dr_fpmul_d,          // Input 3
    input  wire [127:0] dr_fpadd_d,          // Input 4
    input  wire [127:0] dr_fpadd_st,         // Input 5
    input  wire [127:0] dr_fptofp_d,         // Input 6
    input  wire [127:0] dr_inttoint_d,       // Input 7
    input  wire [127:0] dr_fptoint_d,        // Input 8
    input  wire [127:0] dr_inttofp_d,        // Input 9
    input  wire [127:0] dr_logic_d,          // Input 10
    input  wire [127:0] dr_vin0_d,           // Input 11
    input  wire [127:0] dr_vin1_d,           // Input 12
    input  wire [127:0] dr_vout0_d,          // Input 13
    input  wire [127:0] dr_int8tofp16_d0,    // Input 14
    input  wire [127:0] dr_int8tofp16_d1,    // Input 15
    input  wire [127:0] dr_int8tofp16_d2,    // Input 16
    input  wire [127:0] dr_int8tofp16_d3,    // Input 17
    input  wire [127:0] dr_fp16mul_d0,       // Input 18
    input  wire [127:0] dr_fp16mul_d1,       // Input 19
    input  wire [127:0] dr_fp16mul_d2,       // Input 20
    input  wire [127:0] dr_fp16mul_d3,       // Input 21
    input  wire [127:0] dr_fp16mul_d4,       // Input 22
    input  wire [127:0] dr_fp16mul_d5,       // Input 23
    input  wire [127:0] dr_fp16mul_d6,       // Input 24
    input  wire [127:0] dr_fp16mul_d7,       // Input 25
    input  wire [127:0] dr_fp32addtree5to1_d0, // Input 26
    input  wire [127:0] dr_fp32addtree5to1_d1, // Input 27
    input  wire [127:0] dr_fp32addtree8to1_d,  // Input 28
    input  wire [127:0] dr_shiftup_d,        // Input 29
    input  wire [127:0] ur_rdata_0,          // Input 30
    input  wire [127:0] ur_rdata_1,          // Input 31
    input  wire [127:0] ur_rdata_2,          // Input 32
    input  wire [127:0] ur_rdata_3,          // Input 33
    // Reserved inputs 34-63 (default to 0)
    
    // 40 Outputs (128-bit each) - Output mapping according to PDF Table 1
    output wire [127:0] dvr_intadd_s0,        // Output 0
    output wire [127:0] dvr_intadd_s1,        // Output 1
    output wire [127:0] dvr_intadd_s2,        // Output 2
    output wire [127:0] dvr_fpmul_s0,         // Output 3
    output wire [127:0] dvr_fpmul_s1,         // Output 4
    output wire [127:0] dvr_fpadd_s0,         // Output 5
    output wire [127:0] dvr_fpadd_s1,         // Output 6
    output wire [127:0] dvr_fptofp_s,         // Output 7
    output wire [127:0] dvr_inttoint_s,       // Output 8
    output wire [127:0] dvr_fptoint_s,        // Output 9
    output wire [127:0] dvr_inttofp_s,        // Output 10
    output wire [127:0] dvr_logic_s0,         // Output 11
    output wire [127:0] dvr_logic_s1,         // Output 12
    output wire [127:0] dvr_logic_st,         // Output 13
    output wire [127:0] dvr_vin0_s,           // Output 14
    output wire [127:0] dvr_vin1_s,           // Output 15
    output wire [127:0] dvr_vout0_s,          // Output 16
    output wire [127:0] dvr_int8tofp16_s0,    // Output 17
    output wire [127:0] dvr_int8tofp16_s1,    // Output 18
    output wire [127:0] dvr_fp16mul_s0,       // Output 19
    output wire [127:0] dvr_fp16mul_s1,       // Output 20
    output wire [127:0] dvr_fp16mul_s2,       // Output 21
    output wire [127:0] dvr_fp16mul_s3,       // Output 22
    output wire [127:0] dvr_fp16mul_s4567,    // Output 23
    output wire [127:0] dvr_fp32addtree5to1_s0,// Output 24
    output wire [127:0] dvr_fp32addtree5to1_s1,// Output 25
    output wire [127:0] dvr_fp32addtree5to1_s2,// Output 26
    output wire [127:0] dvr_fp32addtree5to1_s3,// Output 27
    output wire [127:0] dvr_fp32addtree5to1_s4,// Output 28
    output wire [127:0] dvr_fp32addtree5to1_s5,// Output 29
    output wire [127:0] dvr_fp32addtree5to1_s6,// Output 30
    output wire [127:0] dvr_fp32addtree5to1_s7,// Output 31
    output wire [127:0] dvr_fp32addtree8to1_s0,// Output 32
    output wire [127:0] dvr_fp32addtree8to1_s1,// Output 33
    output wire [127:0] dvr_shiftdn_s,        // Output 34 (CSV列15)
    output wire [127:0] uvr_wdata_0,          // Output 35 (CSV列38)
    output wire [127:0] uvr_wdata_1,          // Output 36 (CSV列39)
    output wire [127:0] uvr_wdata_2,          // Output 37 (CSV列40)
    output wire [127:0] uvr_wdata_3,          // Output 38 (CSV列41)
    output wire [127:0] reserved_out_39        // Output 39 (reserved)
);

// ============================================================================
// Parameters
// ============================================================================
parameter INPUT_PIPE_STAGE = 0;        // Global input pipeline stage (0 or 1)
parameter OUTPUT_PIPE_STAGE = 1;       // Global output pipeline stage (0 or 1)
parameter [NUM_INPUTS-1:0] IN_PIPE_EN = {NUM_INPUTS{1'b0}};   // Per-input pipeline enable bitmap
parameter [NUM_OUTPUTS-1:0] OUT_PIPE_EN = {NUM_OUTPUTS{1'b0}};  // Per-output pipeline enable bitmap

// Input index parameters (according to mapping_table.txt)
parameter [5:0] IN_IDX_DR_INTADD_D0 = 6'd0;
parameter [5:0] IN_IDX_DR_INTADD_D1 = 6'd1;
parameter [5:0] IN_IDX_DR_INTADD_ST = 6'd2;
parameter [5:0] IN_IDX_DR_FPMUL_D = 6'd3;
parameter [5:0] IN_IDX_DR_FPADD_D = 6'd4;
parameter [5:0] IN_IDX_DR_FPADD_ST = 6'd5;
parameter [5:0] IN_IDX_DR_FPTOFP_D = 6'd6;
parameter [5:0] IN_IDX_DR_INTTOINT_D = 6'd7;
parameter [5:0] IN_IDX_DR_FPTOINT_D = 6'd8;
parameter [5:0] IN_IDX_DR_INTTOFP_D = 6'd9;
parameter [5:0] IN_IDX_DR_LOGIC_D = 6'd10;
parameter [5:0] IN_IDX_DR_VIN0_D = 6'd11;
parameter [5:0] IN_IDX_DR_VIN1_D = 6'd12;
parameter [5:0] IN_IDX_DR_VOUT0_D = 6'd13;
parameter [5:0] IN_IDX_DR_INT8TOFP16_D0 = 6'd14;
parameter [5:0] IN_IDX_DR_INT8TOFP16_D1 = 6'd15;
parameter [5:0] IN_IDX_DR_INT8TOFP16_D2 = 6'd16;
parameter [5:0] IN_IDX_DR_INT8TOFP16_D3 = 6'd17;
parameter [5:0] IN_IDX_DR_FP16MUL_D0 = 6'd18;
parameter [5:0] IN_IDX_DR_FP16MUL_D1 = 6'd19;
parameter [5:0] IN_IDX_DR_FP16MUL_D2 = 6'd20;
parameter [5:0] IN_IDX_DR_FP16MUL_D3 = 6'd21;
parameter [5:0] IN_IDX_DR_FP16MUL_D4 = 6'd22;
parameter [5:0] IN_IDX_DR_FP16MUL_D5 = 6'd23;
parameter [5:0] IN_IDX_DR_FP16MUL_D6 = 6'd24;
parameter [5:0] IN_IDX_DR_FP16MUL_D7 = 6'd25;
parameter [5:0] IN_IDX_DR_FP32ADDTREE5TO1_D0 = 6'd26;
parameter [5:0] IN_IDX_DR_FP32ADDTREE5TO1_D1 = 6'd27;
parameter [5:0] IN_IDX_DR_FP32ADDTREE8TO1_D = 6'd28;
parameter [5:0] IN_IDX_DR_SHIFTUP_D = 6'd29;
parameter [5:0] IN_IDX_UR_RDATA_0 = 6'd30;
parameter [5:0] IN_IDX_UR_RDATA_1 = 6'd31;
parameter [5:0] IN_IDX_UR_RDATA_2 = 6'd32;
parameter [5:0] IN_IDX_UR_RDATA_3 = 6'd33;

// Output index parameters (according to mapping_table.txt)
parameter [5:0] OUT_IDX_DVR_INTADD_S0 = 6'd0;
parameter [5:0] OUT_IDX_DVR_INTADD_S1 = 6'd1;
parameter [5:0] OUT_IDX_DVR_INTADD_S2 = 6'd2;
parameter [5:0] OUT_IDX_DVR_FPMUL_S0 = 6'd3;
parameter [5:0] OUT_IDX_DVR_FPMUL_S1 = 6'd4;
parameter [5:0] OUT_IDX_DVR_FPADD_S0 = 6'd5;
parameter [5:0] OUT_IDX_DVR_FPADD_S1 = 6'd6;
parameter [5:0] OUT_IDX_DVR_FPTOFP_S = 6'd7;
parameter [5:0] OUT_IDX_DVR_INTTOINT_S = 6'd8;
parameter [5:0] OUT_IDX_DVR_FPTOINT_S = 6'd9;
parameter [5:0] OUT_IDX_DVR_INTTOFP_S = 6'd10;
parameter [5:0] OUT_IDX_DVR_LOGIC_S0 = 6'd11;
parameter [5:0] OUT_IDX_DVR_LOGIC_S1 = 6'd12;
parameter [5:0] OUT_IDX_DVR_LOGIC_ST = 6'd13;
parameter [5:0] OUT_IDX_DVR_VIN0_S = 6'd14;
parameter [5:0] OUT_IDX_DVR_VIN1_S = 6'd15;
parameter [5:0] OUT_IDX_DVR_VOUT0_S = 6'd16;
parameter [5:0] OUT_IDX_DVR_INT8TOFP16_S0 = 6'd17;
parameter [5:0] OUT_IDX_DVR_INT8TOFP16_S1 = 6'd18;
parameter [5:0] OUT_IDX_DVR_FP16MUL_S0 = 6'd19;
parameter [5:0] OUT_IDX_DVR_FP16MUL_S1 = 6'd20;
parameter [5:0] OUT_IDX_DVR_FP16MUL_S2 = 6'd21;
parameter [5:0] OUT_IDX_DVR_FP16MUL_S3 = 6'd22;
parameter [5:0] OUT_IDX_DVR_FP16MUL_S4567 = 6'd23;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE5TO1_S0 = 6'd24;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE5TO1_S1 = 6'd25;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE5TO1_S2 = 6'd26;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE5TO1_S3 = 6'd27;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE5TO1_S4 = 6'd28;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE5TO1_S5 = 6'd29;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE5TO1_S6 = 6'd30;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE5TO1_S7 = 6'd31;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE8TO1_S0 = 6'd32;
parameter [5:0] OUT_IDX_DVR_FP32ADDTREE8TO1_S1 = 6'd33;
parameter [5:0] OUT_IDX_DVR_SHIFTDN_S = 6'd34;
parameter [5:0] OUT_IDX_UVR_WDATA_0 = 6'd35;
parameter [5:0] OUT_IDX_UVR_WDATA_1 = 6'd36;
parameter [5:0] OUT_IDX_UVR_WDATA_2 = 6'd37;
parameter [5:0] OUT_IDX_UVR_WDATA_3 = 6'd38;
parameter [5:0] OUT_IDX_RESERVED_OUT_39 = 6'd39;

`ifdef USE_FPGA_IP
// Source mask matrix: 40 outputs × 64 inputs
// Extracted from CSV connection matrix (RtoVR连接关系 v0.1.0.csv)
// Each bit in the mask corresponds to an input source (CSV input index - 1)
// Bit position = CSV input index - 1, 1 = allowed, 0 = blocked
// OUT_FROM_IN_EN_X corresponds to CSV column index (X+1)
// For example: OUT_FROM_IN_EN_14 corresponds to CSV column 15 (DVR-SHIFTDN-S)
// Original connection masks (kept for reference):
parameter [63:0] OUT_FROM_IN_EN_0  = 64'h0000000000003000;  // CSV列  1: DVR-INTADD-S0
parameter [63:0] OUT_FROM_IN_EN_1  = 64'h0000000000003000;  // CSV列  2: DVR-INTADD-S1
parameter [63:0] OUT_FROM_IN_EN_2  = 64'h0000000000003000;  // CSV列  3: DVR-INTADD-S2
parameter [63:0] OUT_FROM_IN_EN_3  = 64'h0000000000003000;  // CSV列  4: DVR-FPMUL-S0
parameter [63:0] OUT_FROM_IN_EN_4  = 64'h00000000000037DB;  // CSV列  5: DVR-FPMUL-S1
parameter [63:0] OUT_FROM_IN_EN_5  = 64'h0000000000003000;  // CSV列  6: DVR-FPADD-S0
parameter [63:0] OUT_FROM_IN_EN_6  = 64'h00000000000037DB;  // CSV列  7: DVR-FPADD-S1
parameter [63:0] OUT_FROM_IN_EN_7  = 64'h00000000000037DB;  // CSV列  8: DVR-FPtoFP-S
parameter [63:0] OUT_FROM_IN_EN_8  = 64'h00000000000037DB;  // CSV列  9: DVR-INTtoINT-S
parameter [63:0] OUT_FROM_IN_EN_9  = 64'h00000000000037DB;  // CSV列 10: DVR-FPtoINT-S
parameter [63:0] OUT_FROM_IN_EN_10 = 64'h00000000000037DB;  // CSV列 11: DVR-INTtoFP-S
parameter [63:0] OUT_FROM_IN_EN_11 = 64'h00000000000037DB;  // CSV列 12: DVR-LOGIC-S0
parameter [63:0] OUT_FROM_IN_EN_12 = 64'h00000000000037DB;  // CSV列 13: DVR-LOGIC-S1
parameter [63:0] OUT_FROM_IN_EN_13 = 64'h0000000000003024;  // CSV列 14: DVR-LOGIC-ST
parameter [63:0] OUT_FROM_IN_EN_14 = 64'h0000000F00000000;  // CSV列 15: DVR-SHIFTDN-S
parameter [63:0] OUT_FROM_IN_EN_15 = 64'h0000000F00000000;  // CSV列 16: DVR-VIN0-S
parameter [63:0] OUT_FROM_IN_EN_16 = 64'h0000000F00000000;  // CSV列 17: DVR-VIN1-S
parameter [63:0] OUT_FROM_IN_EN_17 = 64'h00000000000007FF;  // CSV列 18: DVR-VOUT0-S
parameter [63:0] OUT_FROM_IN_EN_18 = 64'h0000000000000001;  // CSV列 19: DVR-INT8toFP16-S0
parameter [63:0] OUT_FROM_IN_EN_19 = 64'h0000000000000002;  // CSV列 20: DVR-INT8toFP16-S1
parameter [63:0] OUT_FROM_IN_EN_20 = 64'h0000000000008000;  // CSV列 21: DVR-FP16MUL-S0
parameter [63:0] OUT_FROM_IN_EN_21 = 64'h0000000000010000;  // CSV列 22: DVR-FP16MUL-S1
parameter [63:0] OUT_FROM_IN_EN_22 = 64'h0000000000020000;  // CSV列 23: DVR-FP16MUL-S2
parameter [63:0] OUT_FROM_IN_EN_23 = 64'h0000000000040000;  // CSV列 24: DVR-FP16MUL-S3
parameter [63:0] OUT_FROM_IN_EN_24 = 64'h0000000000000800;  // CSV列 25: DVR-FP16MUL-S4567
parameter [63:0] OUT_FROM_IN_EN_25 = 64'h0000000000080000;  // CSV列 26: DVR-FP32ADDTREE5TO1-S0
parameter [63:0] OUT_FROM_IN_EN_26 = 64'h0000000000100000;  // CSV列 27: DVR-FP32ADDTREE5TO1-S1
parameter [63:0] OUT_FROM_IN_EN_27 = 64'h0000000000200000;  // CSV列 28: DVR-FP32ADDTREE5TO1-S2
parameter [63:0] OUT_FROM_IN_EN_28 = 64'h0000000000400000;  // CSV列 29: DVR-FP32ADDTREE5TO1-S3
parameter [63:0] OUT_FROM_IN_EN_29 = 64'h0000000000800000;  // CSV列 30: DVR-FP32ADDTREE5TO1-S4
parameter [63:0] OUT_FROM_IN_EN_30 = 64'h0000000001000000;  // CSV列 31: DVR-FP32ADDTREE5TO1-S5
parameter [63:0] OUT_FROM_IN_EN_31 = 64'h0000000002000000;  // CSV列 32: DVR-FP32ADDTREE5TO1-S6
parameter [63:0] OUT_FROM_IN_EN_32 = 64'h0000000004000000;  // CSV列 33: DVR-FP32ADDTREE5TO1-S7
parameter [63:0] OUT_FROM_IN_EN_33 = 64'h0000000008000000;  // CSV列 34: DVR-FP32ADDTREE8TO1-S0
parameter [63:0] OUT_FROM_IN_EN_34 = 64'h0000000010000000;  // CSV列 35: DVR-FP32ADDTREE8TO1-S1
parameter [63:0] OUT_FROM_IN_EN_35 = 64'h0000000020004800;  // CSV列 38: UVR-WDATA-0
parameter [63:0] OUT_FROM_IN_EN_36 = 64'h0000000020004800;  // CSV列 39: UVR-WDATA-1
parameter [63:0] OUT_FROM_IN_EN_37 = 64'h0000000020004800;  // CSV列 40: UVR-WDATA-2
parameter [63:0] OUT_FROM_IN_EN_38 = 64'h0000000020004800;  // CSV列 41: UVR-WDATA-3
parameter [63:0] OUT_FROM_IN_EN_39 = 64'h0000000000000000;  // reserved output (Output 39)
`else 
// Relaxed masks: allow all 64 inputs for every output (all 1s)
parameter [63:0] OUT_FROM_IN_EN_0  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  1: DVR-INTADD-S0
parameter [63:0] OUT_FROM_IN_EN_1  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  2: DVR-INTADD-S1
parameter [63:0] OUT_FROM_IN_EN_2  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  3: DVR-INTADD-S2
parameter [63:0] OUT_FROM_IN_EN_3  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  4: DVR-FPMUL-S0
parameter [63:0] OUT_FROM_IN_EN_4  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  5: DVR-FPMUL-S1
parameter [63:0] OUT_FROM_IN_EN_5  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  6: DVR-FPADD-S0
parameter [63:0] OUT_FROM_IN_EN_6  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  7: DVR-FPADD-S1
parameter [63:0] OUT_FROM_IN_EN_7  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  8: DVR-FPtoFP-S
parameter [63:0] OUT_FROM_IN_EN_8  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列  9: DVR-INTtoINT-S
parameter [63:0] OUT_FROM_IN_EN_9  = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 10: DVR-FPtoINT-S
parameter [63:0] OUT_FROM_IN_EN_10 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 11: DVR-INTtoFP-S
parameter [63:0] OUT_FROM_IN_EN_11 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 12: DVR-LOGIC-S0
parameter [63:0] OUT_FROM_IN_EN_12 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 13: DVR-LOGIC-S1
parameter [63:0] OUT_FROM_IN_EN_13 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 14: DVR-LOGIC-ST
parameter [63:0] OUT_FROM_IN_EN_14 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 15: DVR-SHIFTDN-S
parameter [63:0] OUT_FROM_IN_EN_15 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 16: DVR-VIN0-S
parameter [63:0] OUT_FROM_IN_EN_16 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 17: DVR-VIN1-S
parameter [63:0] OUT_FROM_IN_EN_17 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 18: DVR-VOUT0-S
parameter [63:0] OUT_FROM_IN_EN_18 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 19: DVR-INT8toFP16-S0
parameter [63:0] OUT_FROM_IN_EN_19 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 20: DVR-INT8toFP16-S1
parameter [63:0] OUT_FROM_IN_EN_20 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 21: DVR-FP16MUL-S0
parameter [63:0] OUT_FROM_IN_EN_21 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 22: DVR-FP16MUL-S1
parameter [63:0] OUT_FROM_IN_EN_22 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 23: DVR-FP16MUL-S2
parameter [63:0] OUT_FROM_IN_EN_23 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 24: DVR-FP16MUL-S3
parameter [63:0] OUT_FROM_IN_EN_24 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 25: DVR-FP16MUL-S4567
parameter [63:0] OUT_FROM_IN_EN_25 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 26: DVR-FP32ADDTREE5TO1-S0
parameter [63:0] OUT_FROM_IN_EN_26 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 27: DVR-FP32ADDTREE5TO1-S1
parameter [63:0] OUT_FROM_IN_EN_27 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 28: DVR-FP32ADDTREE5TO1-S2
parameter [63:0] OUT_FROM_IN_EN_28 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 29: DVR-FP32ADDTREE5TO1-S3
parameter [63:0] OUT_FROM_IN_EN_29 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 30: DVR-FP32ADDTREE5TO1-S4
parameter [63:0] OUT_FROM_IN_EN_30 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 31: DVR-FP32ADDTREE5TO1-S5
parameter [63:0] OUT_FROM_IN_EN_31 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 32: DVR-FP32ADDTREE5TO1-S6
parameter [63:0] OUT_FROM_IN_EN_32 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 33: DVR-FP32ADDTREE5TO1-S7
parameter [63:0] OUT_FROM_IN_EN_33 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 34: DVR-FP32ADDTREE8TO1-S0
parameter [63:0] OUT_FROM_IN_EN_34 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 35: DVR-FP32ADDTREE8TO1-S1
parameter [63:0] OUT_FROM_IN_EN_35 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 38: UVR-WDATA-0
parameter [63:0] OUT_FROM_IN_EN_36 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 39: UVR-WDATA-1
parameter [63:0] OUT_FROM_IN_EN_37 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 40: UVR-WDATA-2
parameter [63:0] OUT_FROM_IN_EN_38 = 64'hFFFF_FFFF_FFFF_FFFF;  // CSV列 41: UVR-WDATA-3
parameter [63:0] OUT_FROM_IN_EN_39 = 64'hFFFF_FFFF_FFFF_FFFF;  // reserved output (Output 39)
`endif 

// ============================================================================
// Local Parameters
// ============================================================================
// DATA_WIDTH, NUM_INPUTS, NUM_OUTPUTS, CRU_VALID_BITS, CRU_SELECT_BITS, CRU_BITS_PER_OUTPUT
// are now defined in module parameter list

// ============================================================================
// Wire Declarations
// ============================================================================
// Input array (64 × 128-bit)
wire [DATA_WIDTH*NUM_INPUTS-1:0] input_array;
wire [DATA_WIDTH*NUM_INPUTS-1:0] input_array_comb;

// Output: mux 结果为组合逻辑(mux_result)；en=1 的路按 vld 锁存到 output_array_reg，en=0 的路组合直通
reg  [DATA_WIDTH*NUM_OUTPUTS-1:0] output_array_reg;    // 输出寄存器，仅打拍使能的输出路按 vld 锁存/保持
wire [DATA_WIDTH*NUM_OUTPUTS-1:0] output_array_pipe;

// Pipeline registers
reg  [DATA_WIDTH*NUM_INPUTS-1:0] input_array_dff;

// CRU pipeline register
reg  [NUM_OUTPUTS*CRU_BITS_PER_OUTPUT-1:0] cru_rtovr_dff;

// Per-input pipeline enable
wire [NUM_INPUTS-1:0] input_pipe_en;

// CRU decode: NUM_OUTPUTS outputs × CRU_BITS_PER_OUTPUT bits each
wire [NUM_OUTPUTS-1:0] mv_out_vld;
wire [NUM_OUTPUTS*CRU_SELECT_BITS-1:0] mv_out_sel;
        
`ifdef USE_FPGA_IP

`else 
// ============================================================================
// Debug Signals: Individual sel_latch for each output with interface name
// ============================================================================
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_intadd_s0;        // Output 0
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_intadd_s1;        // Output 1
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_intadd_s2;        // Output 2
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fpmul_s0;         // Output 3
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fpmul_s1;         // Output 4
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fpadd_s0;         // Output 5
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fpadd_s1;         // Output 6
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fptofp_s;         // Output 7
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_inttoint_s;       // Output 8
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fptoint_s;        // Output 9
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_inttofp_s;        // Output 10
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_logic_s0;         // Output 11
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_logic_s1;         // Output 12
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_logic_st;         // Output 13
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_vin0_s;           // Output 14
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_vin1_s;           // Output 15
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_vout0_s;          // Output 16
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_int8tofp16_s0;    // Output 17
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_int8tofp16_s1;    // Output 18
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp16mul_s0;      // Output 19
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp16mul_s1;       // Output 20
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp16mul_s2;       // Output 21
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp16mul_s3;       // Output 22
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp16mul_s4567;    // Output 23
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree5to1_s0; // Output 24
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree5to1_s1; // Output 25
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree5to1_s2; // Output 26
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree5to1_s3; // Output 27
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree5to1_s4; // Output 28
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree5to1_s5; // Output 29
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree5to1_s6; // Output 30
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree5to1_s7; // Output 31
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree8to1_s0; // Output 32
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_fp32addtree8to1_s1; // Output 33
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_dvr_shiftdn_s;        // Output 34
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_uvr_wdata_0;          // Output 35
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_uvr_wdata_1;          // Output 36
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_uvr_wdata_2;          // Output 37
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_uvr_wdata_3;          // Output 38
wire [CRU_SELECT_BITS-1:0] dbg_sel_latch_reserved_out_39;      // Output 39
`endif

// ============================================================================
// Input Array Mapping
// ============================================================================
// Map all inputs to input_array according to mapping_table.txt input indices
// Bit range calculation: input_array[idx*DATA_WIDTH + DATA_WIDTH-1 : idx*DATA_WIDTH]
assign input_array[IN_IDX_DR_INTADD_D0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTADD_D0*DATA_WIDTH] = dr_intadd_d0;
assign input_array[IN_IDX_DR_INTADD_D1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTADD_D1*DATA_WIDTH] = dr_intadd_d1;
assign input_array[IN_IDX_DR_INTADD_ST*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTADD_ST*DATA_WIDTH] = dr_intadd_st;
assign input_array[IN_IDX_DR_FPMUL_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPMUL_D*DATA_WIDTH] = dr_fpmul_d;
assign input_array[IN_IDX_DR_FPADD_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPADD_D*DATA_WIDTH] = dr_fpadd_d;
assign input_array[IN_IDX_DR_FPADD_ST*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPADD_ST*DATA_WIDTH] = dr_fpadd_st;
assign input_array[IN_IDX_DR_FPTOFP_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPTOFP_D*DATA_WIDTH] = dr_fptofp_d;
assign input_array[IN_IDX_DR_INTTOINT_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTTOINT_D*DATA_WIDTH] = dr_inttoint_d;
assign input_array[IN_IDX_DR_FPTOINT_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPTOINT_D*DATA_WIDTH] = dr_fptoint_d;
assign input_array[IN_IDX_DR_INTTOFP_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTTOFP_D*DATA_WIDTH] = dr_inttofp_d;
assign input_array[IN_IDX_DR_LOGIC_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_LOGIC_D*DATA_WIDTH] = dr_logic_d;
assign input_array[IN_IDX_DR_VIN0_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_VIN0_D*DATA_WIDTH] = dr_vin0_d;
assign input_array[IN_IDX_DR_VIN1_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_VIN1_D*DATA_WIDTH] = dr_vin1_d;
assign input_array[IN_IDX_DR_VOUT0_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_VOUT0_D*DATA_WIDTH] = dr_vout0_d;
assign input_array[IN_IDX_DR_INT8TOFP16_D0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INT8TOFP16_D0*DATA_WIDTH] = dr_int8tofp16_d0;
assign input_array[IN_IDX_DR_INT8TOFP16_D1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INT8TOFP16_D1*DATA_WIDTH] = dr_int8tofp16_d1;
assign input_array[IN_IDX_DR_INT8TOFP16_D2*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INT8TOFP16_D2*DATA_WIDTH] = dr_int8tofp16_d2;
assign input_array[IN_IDX_DR_INT8TOFP16_D3*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INT8TOFP16_D3*DATA_WIDTH] = dr_int8tofp16_d3;
assign input_array[IN_IDX_DR_FP16MUL_D0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D0*DATA_WIDTH] = dr_fp16mul_d0;
assign input_array[IN_IDX_DR_FP16MUL_D1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D1*DATA_WIDTH] = dr_fp16mul_d1;
assign input_array[IN_IDX_DR_FP16MUL_D2*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D2*DATA_WIDTH] = dr_fp16mul_d2;
assign input_array[IN_IDX_DR_FP16MUL_D3*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D3*DATA_WIDTH] = dr_fp16mul_d3;
assign input_array[IN_IDX_DR_FP16MUL_D4*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D4*DATA_WIDTH] = dr_fp16mul_d4;
assign input_array[IN_IDX_DR_FP16MUL_D5*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D5*DATA_WIDTH] = dr_fp16mul_d5;
assign input_array[IN_IDX_DR_FP16MUL_D6*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D6*DATA_WIDTH] = dr_fp16mul_d6;
assign input_array[IN_IDX_DR_FP16MUL_D7*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D7*DATA_WIDTH] = dr_fp16mul_d7;
assign input_array[IN_IDX_DR_FP32ADDTREE5TO1_D0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP32ADDTREE5TO1_D0*DATA_WIDTH] = dr_fp32addtree5to1_d0;
assign input_array[IN_IDX_DR_FP32ADDTREE5TO1_D1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP32ADDTREE5TO1_D1*DATA_WIDTH] = dr_fp32addtree5to1_d1;
assign input_array[IN_IDX_DR_FP32ADDTREE8TO1_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP32ADDTREE8TO1_D*DATA_WIDTH] = dr_fp32addtree8to1_d;
assign input_array[IN_IDX_DR_SHIFTUP_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_SHIFTUP_D*DATA_WIDTH] = dr_shiftup_d;
assign input_array[IN_IDX_UR_RDATA_0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_UR_RDATA_0*DATA_WIDTH] = ur_rdata_0;
assign input_array[IN_IDX_UR_RDATA_1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_UR_RDATA_1*DATA_WIDTH] = ur_rdata_1;
assign input_array[IN_IDX_UR_RDATA_2*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_UR_RDATA_2*DATA_WIDTH] = ur_rdata_2;
assign input_array[IN_IDX_UR_RDATA_3*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_UR_RDATA_3*DATA_WIDTH] = ur_rdata_3;
// Inputs 34-63: reserved (default to 0)
genvar reserved_in_idx;
generate
    for (reserved_in_idx = 34; reserved_in_idx < NUM_INPUTS; reserved_in_idx = reserved_in_idx + 1) begin : gen_reserved_inputs
        assign input_array[reserved_in_idx*DATA_WIDTH + DATA_WIDTH-1 : reserved_in_idx*DATA_WIDTH] = {DATA_WIDTH{1'b0}};
    end
endgenerate

// ============================================================================
// CRU Decode: Extract valid and select for each output
// ============================================================================
// CRU format: OUTk control word is at cru_rtovr[(CRU_BITS_PER_OUTPUT*(k+1)-1):CRU_BITS_PER_OUTPUT*k]
// Each control word (7 bits): {select[6:1], valid[0]}
//   - bit 0: valid (vld)
//   - bit 6:1: select (sel, 6 bits)
// CRU select field directly uses CSV input index (1-36), then subtract 1 to get input_array position
// CSV input indices: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36
// CRU select is 6-bit, supports 0-63, so all CSV input indices (1-36) can be represented
// Simple mapping: input_array position = CSV input index - 1
genvar k;
generate
    for (k = 0; k < NUM_OUTPUTS; k = k + 1) begin : gen_cru_decode
        // k=0: cru_rtovr[6:0], bit 0=vld, bit[6:1]=sel
        // k=1: cru_rtovr[13:7], bit 7=vld, bit[13:8]=sel
        // ..., k=39: cru_rtovr[279:273], bit 273=vld, bit[279:274]=sel
        assign mv_out_vld[k] = cru_rtovr[CRU_BITS_PER_OUTPUT*k + 0];  // bit 0 (vld)
        assign mv_out_sel[CRU_SELECT_BITS*k + CRU_SELECT_BITS - 1:CRU_SELECT_BITS*k] = cru_rtovr[CRU_BITS_PER_OUTPUT*k + CRU_SELECT_BITS:CRU_BITS_PER_OUTPUT*k + 1];  // bit[6:1] (sel)
    end
endgenerate

// ============================================================================
// Input Pipeline Stage
// ============================================================================
// Per-input pipeline enable: use_pipe = (INPUT_PIPE_STAGE==1) || IN_PIPE_EN[i]
genvar i;
generate
    for (i = 0; i < NUM_INPUTS; i = i + 1) begin : gen_input_pipe_en
        assign input_pipe_en[i] = (INPUT_PIPE_STAGE == 1) || IN_PIPE_EN[i];
    end
endgenerate

// Input pipeline registers
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        input_array_dff <= {(DATA_WIDTH*NUM_INPUTS){1'b0}};
    end else begin
        input_array_dff <= input_array;
    end
end

// Input combinational: in*_comb = IN-PIPE-STAGE-* ? in*_dff : in*
generate
    for (i = 0; i < NUM_INPUTS; i = i + 1) begin : gen_input_comb
        assign input_array_comb[(i+1)*DATA_WIDTH-1:i*DATA_WIDTH] = 
               input_pipe_en[i] ? 
               input_array_dff[(i+1)*DATA_WIDTH-1:i*DATA_WIDTH] : 
               input_array[(i+1)*DATA_WIDTH-1:i*DATA_WIDTH];
    end
endgenerate

// CRU pipeline: if input pipeline is enabled, cru_rtovr_o is also pipelined
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cru_rtovr_dff <= {(NUM_OUTPUTS*CRU_BITS_PER_OUTPUT){1'b0}};
    end else begin
        cru_rtovr_dff <= cru_rtovr;
    end
end

assign cru_rtovr_o = cru_rtovr_dff;

// ============================================================================
// Output Mux Logic (64:1 MUX for each output) + Output Register Latch
// ============================================================================
// - 组合逻辑：用当前 mv_out_sel 和 mask 从 input_array_comb 中选出 128bit -> mux_result
// - 资源裁剪：按编译期参数(OUTPUT_PIPE_STAGE/OUT_PIPE_EN) generate-if，使能则锁存寄存器，否则组合直通
genvar j;
generate
    for (j = 0; j < NUM_OUTPUTS; j = j + 1) begin : gen_output_mux
        // Get the source mask for this output (64-bit: one bit per input source)
        // Each output has its own 64-bit mask to control which of the 64 inputs are allowed
        // In generate loop, j is a compile-time constant, so we use generate case to select
        // the corresponding parameter directly. This creates a 40×64 source mask matrix.
        wire [63:0] out_mask;
        
        case (j)
            OUT_IDX_DVR_INTADD_S0:  assign out_mask = OUT_FROM_IN_EN_0;
            OUT_IDX_DVR_INTADD_S1:  assign out_mask = OUT_FROM_IN_EN_1;
            OUT_IDX_DVR_INTADD_S2:  assign out_mask = OUT_FROM_IN_EN_2;
            OUT_IDX_DVR_FPMUL_S0:  assign out_mask = OUT_FROM_IN_EN_3;
            OUT_IDX_DVR_FPMUL_S1:  assign out_mask = OUT_FROM_IN_EN_4;
            OUT_IDX_DVR_FPADD_S0:  assign out_mask = OUT_FROM_IN_EN_5;
            OUT_IDX_DVR_FPADD_S1:  assign out_mask = OUT_FROM_IN_EN_6;
            OUT_IDX_DVR_FPTOFP_S:  assign out_mask = OUT_FROM_IN_EN_7;
            OUT_IDX_DVR_INTTOINT_S:  assign out_mask = OUT_FROM_IN_EN_8;
            OUT_IDX_DVR_FPTOINT_S:  assign out_mask = OUT_FROM_IN_EN_9;
            OUT_IDX_DVR_INTTOFP_S:  assign out_mask = OUT_FROM_IN_EN_10;
            OUT_IDX_DVR_LOGIC_S0:  assign out_mask = OUT_FROM_IN_EN_11;
            OUT_IDX_DVR_LOGIC_S1:  assign out_mask = OUT_FROM_IN_EN_12;
            OUT_IDX_DVR_LOGIC_ST:  assign out_mask = OUT_FROM_IN_EN_13;
            OUT_IDX_DVR_VIN0_S:  assign out_mask = OUT_FROM_IN_EN_14;
            OUT_IDX_DVR_VIN1_S:  assign out_mask = OUT_FROM_IN_EN_15;
            OUT_IDX_DVR_VOUT0_S:  assign out_mask = OUT_FROM_IN_EN_16;
            OUT_IDX_DVR_INT8TOFP16_S0:  assign out_mask = OUT_FROM_IN_EN_17;
            OUT_IDX_DVR_INT8TOFP16_S1:  assign out_mask = OUT_FROM_IN_EN_18;
            OUT_IDX_DVR_FP16MUL_S0:  assign out_mask = OUT_FROM_IN_EN_19;
            OUT_IDX_DVR_FP16MUL_S1:  assign out_mask = OUT_FROM_IN_EN_20;
            OUT_IDX_DVR_FP16MUL_S2:  assign out_mask = OUT_FROM_IN_EN_21;
            OUT_IDX_DVR_FP16MUL_S3:  assign out_mask = OUT_FROM_IN_EN_22;
            OUT_IDX_DVR_FP16MUL_S4567:  assign out_mask = OUT_FROM_IN_EN_23;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S0:  assign out_mask = OUT_FROM_IN_EN_24;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S1:  assign out_mask = OUT_FROM_IN_EN_25;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S2:  assign out_mask = OUT_FROM_IN_EN_26;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S3:  assign out_mask = OUT_FROM_IN_EN_27;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S4:  assign out_mask = OUT_FROM_IN_EN_28;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S5:  assign out_mask = OUT_FROM_IN_EN_29;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S6:  assign out_mask = OUT_FROM_IN_EN_30;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S7:  assign out_mask = OUT_FROM_IN_EN_31;
            OUT_IDX_DVR_FP32ADDTREE8TO1_S0:  assign out_mask = OUT_FROM_IN_EN_32;
            OUT_IDX_DVR_FP32ADDTREE8TO1_S1:  assign out_mask = OUT_FROM_IN_EN_33;
            OUT_IDX_DVR_SHIFTDN_S:  assign out_mask = OUT_FROM_IN_EN_34;
            OUT_IDX_UVR_WDATA_0:  assign out_mask = OUT_FROM_IN_EN_35;
            OUT_IDX_UVR_WDATA_1:  assign out_mask = OUT_FROM_IN_EN_36;
            OUT_IDX_UVR_WDATA_2:  assign out_mask = OUT_FROM_IN_EN_37;
            OUT_IDX_UVR_WDATA_3:  assign out_mask = OUT_FROM_IN_EN_38;
            OUT_IDX_RESERVED_OUT_39:  assign out_mask = OUT_FROM_IN_EN_39;
            default: assign out_mask = 64'h0;
        endcase
        
        // 64:1 MUX with source mask（使用当前拍 sel）
        wire [CRU_SELECT_BITS-1:0] sel = mv_out_sel[(j+1)*CRU_SELECT_BITS-1:j*CRU_SELECT_BITS];
        
`ifdef USE_FPGA_IP

`else 
        // Debug signal assignment: 当前拍 sel
        case (j)
            OUT_IDX_DVR_INTADD_S0:  assign dbg_sel_latch_dvr_intadd_s0 = sel;
            OUT_IDX_DVR_INTADD_S1:  assign dbg_sel_latch_dvr_intadd_s1 = sel;
            OUT_IDX_DVR_INTADD_S2:  assign dbg_sel_latch_dvr_intadd_s2 = sel;
            OUT_IDX_DVR_FPMUL_S0:  assign dbg_sel_latch_dvr_fpmul_s0 = sel;
            OUT_IDX_DVR_FPMUL_S1:  assign dbg_sel_latch_dvr_fpmul_s1 = sel;
            OUT_IDX_DVR_FPADD_S0:  assign dbg_sel_latch_dvr_fpadd_s0 = sel;
            OUT_IDX_DVR_FPADD_S1:  assign dbg_sel_latch_dvr_fpadd_s1 = sel;
            OUT_IDX_DVR_FPTOFP_S:  assign dbg_sel_latch_dvr_fptofp_s = sel;
            OUT_IDX_DVR_INTTOINT_S:  assign dbg_sel_latch_dvr_inttoint_s = sel;
            OUT_IDX_DVR_FPTOINT_S:  assign dbg_sel_latch_dvr_fptoint_s = sel;
            OUT_IDX_DVR_INTTOFP_S:  assign dbg_sel_latch_dvr_inttofp_s = sel;
            OUT_IDX_DVR_LOGIC_S0:  assign dbg_sel_latch_dvr_logic_s0 = sel;
            OUT_IDX_DVR_LOGIC_S1:  assign dbg_sel_latch_dvr_logic_s1 = sel;
            OUT_IDX_DVR_LOGIC_ST:  assign dbg_sel_latch_dvr_logic_st = sel;
            OUT_IDX_DVR_VIN0_S:  assign dbg_sel_latch_dvr_vin0_s = sel;
            OUT_IDX_DVR_VIN1_S:  assign dbg_sel_latch_dvr_vin1_s = sel;
            OUT_IDX_DVR_VOUT0_S:  assign dbg_sel_latch_dvr_vout0_s = sel;
            OUT_IDX_DVR_INT8TOFP16_S0:  assign dbg_sel_latch_dvr_int8tofp16_s0 = sel;
            OUT_IDX_DVR_INT8TOFP16_S1:  assign dbg_sel_latch_dvr_int8tofp16_s1 = sel;
            OUT_IDX_DVR_FP16MUL_S0:  assign dbg_sel_latch_dvr_fp16mul_s0 = sel;
            OUT_IDX_DVR_FP16MUL_S1:  assign dbg_sel_latch_dvr_fp16mul_s1 = sel;
            OUT_IDX_DVR_FP16MUL_S2:  assign dbg_sel_latch_dvr_fp16mul_s2 = sel;
            OUT_IDX_DVR_FP16MUL_S3:  assign dbg_sel_latch_dvr_fp16mul_s3 = sel;
            OUT_IDX_DVR_FP16MUL_S4567:  assign dbg_sel_latch_dvr_fp16mul_s4567 = sel;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S0:  assign dbg_sel_latch_dvr_fp32addtree5to1_s0 = sel;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S1:  assign dbg_sel_latch_dvr_fp32addtree5to1_s1 = sel;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S2:  assign dbg_sel_latch_dvr_fp32addtree5to1_s2 = sel;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S3:  assign dbg_sel_latch_dvr_fp32addtree5to1_s3 = sel;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S4:  assign dbg_sel_latch_dvr_fp32addtree5to1_s4 = sel;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S5:  assign dbg_sel_latch_dvr_fp32addtree5to1_s5 = sel;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S6:  assign dbg_sel_latch_dvr_fp32addtree5to1_s6 = sel;
            OUT_IDX_DVR_FP32ADDTREE5TO1_S7:  assign dbg_sel_latch_dvr_fp32addtree5to1_s7 = sel;
            OUT_IDX_DVR_FP32ADDTREE8TO1_S0:  assign dbg_sel_latch_dvr_fp32addtree8to1_s0 = sel;
            OUT_IDX_DVR_FP32ADDTREE8TO1_S1:  assign dbg_sel_latch_dvr_fp32addtree8to1_s1 = sel;
            OUT_IDX_DVR_SHIFTDN_S:  assign dbg_sel_latch_dvr_shiftdn_s = sel;
            OUT_IDX_UVR_WDATA_0:  assign dbg_sel_latch_uvr_wdata_0 = sel;
            OUT_IDX_UVR_WDATA_1:  assign dbg_sel_latch_uvr_wdata_1 = sel;
            OUT_IDX_UVR_WDATA_2:  assign dbg_sel_latch_uvr_wdata_2 = sel;
            OUT_IDX_UVR_WDATA_3:  assign dbg_sel_latch_uvr_wdata_3 = sel;
            OUT_IDX_RESERVED_OUT_39:  assign dbg_sel_latch_reserved_out_39 = sel;
            default: ; // No assignment for invalid j
        endcase
`endif     
        // Generate 64-way mux using case statement for better synthesis
        // sel 为当前拍 CRU 的 select，mux_result 为组合选出的 128bit（供 vld 有效时锁存）
        reg [127:0] mux_result;
        always @(*) begin
            case (sel)
                    IN_IDX_DR_INTADD_D0:  mux_result = out_mask[IN_IDX_DR_INTADD_D0]  ? input_array_comb[IN_IDX_DR_INTADD_D0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTADD_D0*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_INTADD_D1:  mux_result = out_mask[IN_IDX_DR_INTADD_D1]  ? input_array_comb[IN_IDX_DR_INTADD_D1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTADD_D1*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_INTADD_ST:  mux_result = out_mask[IN_IDX_DR_INTADD_ST]  ? input_array_comb[IN_IDX_DR_INTADD_ST*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTADD_ST*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FPMUL_D:  mux_result = out_mask[IN_IDX_DR_FPMUL_D]  ? input_array_comb[IN_IDX_DR_FPMUL_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPMUL_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FPADD_D:  mux_result = out_mask[IN_IDX_DR_FPADD_D]  ? input_array_comb[IN_IDX_DR_FPADD_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPADD_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FPADD_ST:  mux_result = out_mask[IN_IDX_DR_FPADD_ST]  ? input_array_comb[IN_IDX_DR_FPADD_ST*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPADD_ST*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FPTOFP_D:  mux_result = out_mask[IN_IDX_DR_FPTOFP_D]  ? input_array_comb[IN_IDX_DR_FPTOFP_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPTOFP_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_INTTOINT_D:  mux_result = out_mask[IN_IDX_DR_INTTOINT_D]  ? input_array_comb[IN_IDX_DR_INTTOINT_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTTOINT_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FPTOINT_D:  mux_result = out_mask[IN_IDX_DR_FPTOINT_D]  ? input_array_comb[IN_IDX_DR_FPTOINT_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FPTOINT_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_INTTOFP_D:  mux_result = out_mask[IN_IDX_DR_INTTOFP_D]  ? input_array_comb[IN_IDX_DR_INTTOFP_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INTTOFP_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_LOGIC_D:  mux_result = out_mask[IN_IDX_DR_LOGIC_D]  ? input_array_comb[IN_IDX_DR_LOGIC_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_LOGIC_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_VIN0_D:  mux_result = out_mask[IN_IDX_DR_VIN0_D]  ? input_array_comb[IN_IDX_DR_VIN0_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_VIN0_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_VIN1_D:  mux_result = out_mask[IN_IDX_DR_VIN1_D]  ? input_array_comb[IN_IDX_DR_VIN1_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_VIN1_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_VOUT0_D:  mux_result = out_mask[IN_IDX_DR_VOUT0_D]  ? input_array_comb[IN_IDX_DR_VOUT0_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_VOUT0_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_INT8TOFP16_D0:  mux_result = out_mask[IN_IDX_DR_INT8TOFP16_D0]  ? input_array_comb[IN_IDX_DR_INT8TOFP16_D0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INT8TOFP16_D0*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_INT8TOFP16_D1:  mux_result = out_mask[IN_IDX_DR_INT8TOFP16_D1]  ? input_array_comb[IN_IDX_DR_INT8TOFP16_D1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INT8TOFP16_D1*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_INT8TOFP16_D2:  mux_result = out_mask[IN_IDX_DR_INT8TOFP16_D2]  ? input_array_comb[IN_IDX_DR_INT8TOFP16_D2*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INT8TOFP16_D2*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_INT8TOFP16_D3:  mux_result = out_mask[IN_IDX_DR_INT8TOFP16_D3]  ? input_array_comb[IN_IDX_DR_INT8TOFP16_D3*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_INT8TOFP16_D3*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP16MUL_D0:  mux_result = out_mask[IN_IDX_DR_FP16MUL_D0]  ? input_array_comb[IN_IDX_DR_FP16MUL_D0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D0*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP16MUL_D1:  mux_result = out_mask[IN_IDX_DR_FP16MUL_D1]  ? input_array_comb[IN_IDX_DR_FP16MUL_D1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D1*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP16MUL_D2:  mux_result = out_mask[IN_IDX_DR_FP16MUL_D2]  ? input_array_comb[IN_IDX_DR_FP16MUL_D2*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D2*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP16MUL_D3:  mux_result = out_mask[IN_IDX_DR_FP16MUL_D3]  ? input_array_comb[IN_IDX_DR_FP16MUL_D3*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D3*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP16MUL_D4:  mux_result = out_mask[IN_IDX_DR_FP16MUL_D4]  ? input_array_comb[IN_IDX_DR_FP16MUL_D4*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D4*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP16MUL_D5:  mux_result = out_mask[IN_IDX_DR_FP16MUL_D5]  ? input_array_comb[IN_IDX_DR_FP16MUL_D5*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D5*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP16MUL_D6:  mux_result = out_mask[IN_IDX_DR_FP16MUL_D6]  ? input_array_comb[IN_IDX_DR_FP16MUL_D6*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D6*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP16MUL_D7:  mux_result = out_mask[IN_IDX_DR_FP16MUL_D7]  ? input_array_comb[IN_IDX_DR_FP16MUL_D7*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP16MUL_D7*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP32ADDTREE5TO1_D0:  mux_result = out_mask[IN_IDX_DR_FP32ADDTREE5TO1_D0]  ? input_array_comb[IN_IDX_DR_FP32ADDTREE5TO1_D0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP32ADDTREE5TO1_D0*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP32ADDTREE5TO1_D1:  mux_result = out_mask[IN_IDX_DR_FP32ADDTREE5TO1_D1]  ? input_array_comb[IN_IDX_DR_FP32ADDTREE5TO1_D1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP32ADDTREE5TO1_D1*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_FP32ADDTREE8TO1_D:  mux_result = out_mask[IN_IDX_DR_FP32ADDTREE8TO1_D]  ? input_array_comb[IN_IDX_DR_FP32ADDTREE8TO1_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_FP32ADDTREE8TO1_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_DR_SHIFTUP_D:  mux_result = out_mask[IN_IDX_DR_SHIFTUP_D]  ? input_array_comb[IN_IDX_DR_SHIFTUP_D*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_DR_SHIFTUP_D*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_UR_RDATA_0:  mux_result = out_mask[IN_IDX_UR_RDATA_0]  ? input_array_comb[IN_IDX_UR_RDATA_0*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_UR_RDATA_0*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_UR_RDATA_1:  mux_result = out_mask[IN_IDX_UR_RDATA_1]  ? input_array_comb[IN_IDX_UR_RDATA_1*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_UR_RDATA_1*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_UR_RDATA_2:  mux_result = out_mask[IN_IDX_UR_RDATA_2]  ? input_array_comb[IN_IDX_UR_RDATA_2*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_UR_RDATA_2*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    IN_IDX_UR_RDATA_3:  mux_result = out_mask[IN_IDX_UR_RDATA_3]  ? input_array_comb[IN_IDX_UR_RDATA_3*DATA_WIDTH + DATA_WIDTH-1 : IN_IDX_UR_RDATA_3*DATA_WIDTH]     : {DATA_WIDTH{1'b0}};
                    default: mux_result = {DATA_WIDTH{1'b0}};
                endcase
        end
        
        // 按编译期参数裁剪资源：
        //   en=1 -> 仅生成 vld 锁存寄存器(1 拍, 带 vld 保持)，不生成组合直通
        //   en=0 -> 仅生成组合直通(0 拍)，不生成输出寄存器
        if ((OUTPUT_PIPE_STAGE == 1) || OUT_PIPE_EN[j]) begin : gen_out_pipe
            // 输出寄存器：vld 有效时锁存 mux_result，vld 无效时保持自身
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    output_array_reg[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH] <= {DATA_WIDTH{1'b0}};
                else if (mv_out_vld[j])
                    output_array_reg[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH] <= mux_result;
                else
                    output_array_reg[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH] <= output_array_reg[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH];
            end
            assign output_array_pipe[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH] = output_array_reg[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH];
        end else begin : gen_out_comb
            // 组合直通：直接输出 mux 结果
            assign output_array_pipe[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH] = mux_result;
        end
    end
endgenerate

// ============================================================================
// Output Mapping
// ============================================================================
// Map output_array_pipe to individual outputs according to mapping_table.txt output indices
// Bit range calculation: output_array_pipe[idx*DATA_WIDTH + DATA_WIDTH-1 : idx*DATA_WIDTH]
assign dvr_intadd_s0         = output_array_pipe[OUT_IDX_DVR_INTADD_S0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_INTADD_S0*DATA_WIDTH];
assign dvr_intadd_s1         = output_array_pipe[OUT_IDX_DVR_INTADD_S1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_INTADD_S1*DATA_WIDTH];
assign dvr_intadd_s2         = output_array_pipe[OUT_IDX_DVR_INTADD_S2*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_INTADD_S2*DATA_WIDTH];
assign dvr_fpmul_s0          = output_array_pipe[OUT_IDX_DVR_FPMUL_S0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FPMUL_S0*DATA_WIDTH];
assign dvr_fpmul_s1          = output_array_pipe[OUT_IDX_DVR_FPMUL_S1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FPMUL_S1*DATA_WIDTH];
assign dvr_fpadd_s0          = output_array_pipe[OUT_IDX_DVR_FPADD_S0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FPADD_S0*DATA_WIDTH];
assign dvr_fpadd_s1          = output_array_pipe[OUT_IDX_DVR_FPADD_S1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FPADD_S1*DATA_WIDTH];
assign dvr_fptofp_s          = output_array_pipe[OUT_IDX_DVR_FPTOFP_S*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FPTOFP_S*DATA_WIDTH];
assign dvr_inttoint_s        = output_array_pipe[OUT_IDX_DVR_INTTOINT_S*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_INTTOINT_S*DATA_WIDTH];
assign dvr_fptoint_s         = output_array_pipe[OUT_IDX_DVR_FPTOINT_S*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FPTOINT_S*DATA_WIDTH];
assign dvr_inttofp_s         = output_array_pipe[OUT_IDX_DVR_INTTOFP_S*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_INTTOFP_S*DATA_WIDTH];
assign dvr_logic_s0          = output_array_pipe[OUT_IDX_DVR_LOGIC_S0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_LOGIC_S0*DATA_WIDTH];
assign dvr_logic_s1          = output_array_pipe[OUT_IDX_DVR_LOGIC_S1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_LOGIC_S1*DATA_WIDTH];
assign dvr_logic_st          = output_array_pipe[OUT_IDX_DVR_LOGIC_ST*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_LOGIC_ST*DATA_WIDTH];
assign dvr_vin0_s            = output_array_pipe[OUT_IDX_DVR_VIN0_S*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_VIN0_S*DATA_WIDTH];
assign dvr_vin1_s            = output_array_pipe[OUT_IDX_DVR_VIN1_S*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_VIN1_S*DATA_WIDTH];
assign dvr_vout0_s           = output_array_pipe[OUT_IDX_DVR_VOUT0_S*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_VOUT0_S*DATA_WIDTH];
assign dvr_int8tofp16_s0     = output_array_pipe[OUT_IDX_DVR_INT8TOFP16_S0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_INT8TOFP16_S0*DATA_WIDTH];
assign dvr_int8tofp16_s1     = output_array_pipe[OUT_IDX_DVR_INT8TOFP16_S1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_INT8TOFP16_S1*DATA_WIDTH];
assign dvr_fp16mul_s0        = output_array_pipe[OUT_IDX_DVR_FP16MUL_S0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP16MUL_S0*DATA_WIDTH];
assign dvr_fp16mul_s1        = output_array_pipe[OUT_IDX_DVR_FP16MUL_S1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP16MUL_S1*DATA_WIDTH];
assign dvr_fp16mul_s2        = output_array_pipe[OUT_IDX_DVR_FP16MUL_S2*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP16MUL_S2*DATA_WIDTH];
assign dvr_fp16mul_s3        = output_array_pipe[OUT_IDX_DVR_FP16MUL_S3*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP16MUL_S3*DATA_WIDTH];
assign dvr_fp16mul_s4567     = output_array_pipe[OUT_IDX_DVR_FP16MUL_S4567*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP16MUL_S4567*DATA_WIDTH];
assign dvr_fp32addtree5to1_s0 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE5TO1_S0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE5TO1_S0*DATA_WIDTH];
assign dvr_fp32addtree5to1_s1 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE5TO1_S1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE5TO1_S1*DATA_WIDTH];
assign dvr_fp32addtree5to1_s2 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE5TO1_S2*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE5TO1_S2*DATA_WIDTH];
assign dvr_fp32addtree5to1_s3 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE5TO1_S3*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE5TO1_S3*DATA_WIDTH];
assign dvr_fp32addtree5to1_s4 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE5TO1_S4*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE5TO1_S4*DATA_WIDTH];
assign dvr_fp32addtree5to1_s5 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE5TO1_S5*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE5TO1_S5*DATA_WIDTH];
assign dvr_fp32addtree5to1_s6 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE5TO1_S6*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE5TO1_S6*DATA_WIDTH];
assign dvr_fp32addtree5to1_s7 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE5TO1_S7*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE5TO1_S7*DATA_WIDTH];
assign dvr_fp32addtree8to1_s0 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE8TO1_S0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE8TO1_S0*DATA_WIDTH];
assign dvr_fp32addtree8to1_s1 = output_array_pipe[OUT_IDX_DVR_FP32ADDTREE8TO1_S1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_FP32ADDTREE8TO1_S1*DATA_WIDTH];
assign dvr_shiftdn_s         = output_array_pipe[OUT_IDX_DVR_SHIFTDN_S*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_DVR_SHIFTDN_S*DATA_WIDTH];
assign uvr_wdata_0           = output_array_pipe[OUT_IDX_UVR_WDATA_0*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_UVR_WDATA_0*DATA_WIDTH];
assign uvr_wdata_1           = output_array_pipe[OUT_IDX_UVR_WDATA_1*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_UVR_WDATA_1*DATA_WIDTH];
assign uvr_wdata_2           = output_array_pipe[OUT_IDX_UVR_WDATA_2*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_UVR_WDATA_2*DATA_WIDTH];
assign uvr_wdata_3           = output_array_pipe[OUT_IDX_UVR_WDATA_3*DATA_WIDTH + DATA_WIDTH-1 : OUT_IDX_UVR_WDATA_3*DATA_WIDTH];
assign reserved_out_39       = {DATA_WIDTH{1'b0}}; // Output 39 (reserved)



endmodule

