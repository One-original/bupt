`include "fp32_defines.vh"

module fp32_normalizer_rounder_5to1 #(
    parameter IN_WIDTH = `FULL_SUM_WIDTH 
) (
    input  wire clk,
    input  wire rst_n,
    input  wire [IN_WIDTH-1:0]         mant_raw,
    input  wire [`FP32_EXP_WIDTH-1:0]  exp_in,     
    input  wire                        sign_in,
    input  wire [2:0]                  rounding_mode,  // NEW: Rounding mode control
    
    output wire [`FP32_WIDTH-1:0]      fp_out,     
    output wire                        overflow,   
    output wire                        underflow,  
    output wire                        zero_out,
    output wire                        inexact     // NEW: Inexact flag
);

localparam TARGET_POS        = `FP32_MANT_WIDTH + 1;        
localparam TARGET_POS_GUARD  = TARGET_POS + `GUARD_BITS; 
localparam NORM_MANT_WIDTH   = TARGET_POS + `GUARD_BITS;     
localparam EXP_MAX           = 255;                      
localparam ZERO_EXP          = {`FP32_EXP_WIDTH{1'b0}};    

reg [`FP32_WIDTH-1:0]      fp_out_reg;    
assign fp_out = fp_out_reg;

reg signed [9:0]           exp_adj_s;
reg [NORM_MANT_WIDTH-1:0]  mant_norm;
integer                    msb_pos;
integer                    shift_amt;
reg signed [10:0]          shift_amt_s;
reg                        sticky_tmp;
reg                        sticky;
reg                        is_denorm_input;
integer                    sticky_i;
integer                    shift_left_cnt;

localparam integer EXT_WIDTH = (NORM_MANT_WIDTH > IN_WIDTH) ? NORM_MANT_WIDTH : IN_WIDTH;
wire [EXT_WIDTH-1:0] mant_ext_full = (EXT_WIDTH > IN_WIDTH) ? 
                                      {{(EXT_WIDTH-IN_WIDTH){1'b0}}, mant_raw} : mant_raw;

reg [`FP32_MANT_WIDTH:0]   dn_mant24_pre;
reg [`FP32_MANT_WIDTH:0]   dn_mant24_rounded;
reg                        dn_g, dn_r, dn_s, dn_lsb, dn_round_up;

reg zero_out_comb;
reg overflow_comb;
reg underflow_comb;
reg inexact_comb;

// ============================================================================
// Main Normalization Logic
// ============================================================================
always @(*) begin : NORMALIZE_BLOCK
    reg [EXT_WIDTH-1:0] mant_shifted_full;
    
    mant_shifted_full = {EXT_WIDTH{1'b0}}; 
    zero_out_comb   = 1'b0;
    exp_adj_s  = 0;
    mant_norm  = {NORM_MANT_WIDTH{1'b0}};
    msb_pos    = -1;
    sticky     = 1'b0;
    sticky_tmp = 1'b0;
    is_denorm_input = (exp_in == 0 && mant_raw != 0);

    if (mant_raw == 0) begin
        zero_out_comb = 1'b1;
    end else begin
        begin : FIND_MSB
            integer i;
            msb_pos = -1;
            for (i = IN_WIDTH-1; i >= 0; i = i - 1) begin
                if (mant_raw[i]) begin
                    if (msb_pos == -1) msb_pos = i;
                end
            end
        end

        if (msb_pos >= 0 && msb_pos < `FP32_MANT_WIDTH) begin
            shift_amt_s = 0;
            shift_amt   = 0;
        end else begin
            shift_amt = msb_pos - (TARGET_POS_GUARD - 1);
            shift_amt_s = shift_amt;
        end

        if (shift_amt_s > 0) begin
            sticky_tmp = 1'b0;
            for (sticky_i = 0; sticky_i < shift_amt_s; sticky_i = sticky_i + 1) begin
                if (sticky_i < EXT_WIDTH) sticky_tmp = sticky_tmp | mant_ext_full[sticky_i];
            end
            mant_shifted_full = (mant_ext_full >> shift_amt_s);
            sticky = sticky_tmp;
        end else if (shift_amt_s < 0) begin
            shift_left_cnt = -shift_amt_s;
            mant_shifted_full = (mant_ext_full << shift_left_cnt);
            sticky = 1'b0; 
        end else begin
            mant_shifted_full = mant_ext_full;
            sticky = 1'b0;
        end

        mant_norm = mant_shifted_full[NORM_MANT_WIDTH-1:0];

        if (msb_pos >= 0 && msb_pos < `FP32_MANT_WIDTH) begin
            exp_adj_s = 0;
        end else if (is_denorm_input) begin
            if (msb_pos < (TARGET_POS_GUARD - 1)) begin
                exp_adj_s = 0;
            end else begin
                exp_adj_s = 11'sd1 + shift_amt_s;
            end
        end else begin
            exp_adj_s = $signed({3'b000, exp_in}) + shift_amt_s;
        end
    end
end

// ============================================================================
// Enhanced Rounding Logic with Multiple Rounding Modes
// ============================================================================
wire [`FP32_MANT_WIDTH-1:0] mant_rounded;
wire [TARGET_POS-1:0] mant_main_pre = mant_norm[NORM_MANT_WIDTH-1:`GUARD_BITS];
wire bit_g  = mant_norm[`GUARD_BITS-1];
wire bit_r  = mant_norm[`GUARD_BITS-2];
wire bits_sticky_low = (|mant_norm[`GUARD_BITS-3:0]) | sticky;
wire bit_lsb = mant_main_pre[0];

// Inexact detection: any discarded bits are non-zero
wire has_discarded_bits = bit_g | bit_r | bits_sticky_low;

// Rounding decision based on mode
reg round_up_w;
always @(*) begin
    case (rounding_mode)
        `RM_RNE: begin  // Round to Nearest, ties to Even
            round_up_w = (bit_g & (bit_r | bits_sticky_low)) | 
                         (bit_g & ~bit_r & ~bits_sticky_low & bit_lsb);
        end
        
        `RM_RTZ: begin  // Round Towards Zero
            round_up_w = 1'b0;
        end
        
        `RM_RDN: begin  // Round Down (towards -∞)
            round_up_w = sign_in & has_discarded_bits;
        end
        
        `RM_RUP: begin  // Round Up (towards +∞)
            round_up_w = ~sign_in & has_discarded_bits;
        end
        
        `RM_RMM: begin  // Round to Nearest, ties to Max magnitude
            round_up_w = bit_g;
        end
        
        default: begin  // Default to RNE
            round_up_w = (bit_g & (bit_r | bits_sticky_low)) | 
                         (bit_g & ~bit_r & ~bits_sticky_low & bit_lsb);
        end
    endcase
end

wire mant_overflow_round = round_up_w & (&mant_main_pre);
wire [TARGET_POS-1:0] mant_main_rounded = mant_overflow_round ?
    {1'b1, {(`FP32_MANT_WIDTH){1'b0}}} :
    (mant_main_pre + {{(TARGET_POS-1){1'b0}}, (round_up_w ? 1'b1 : 1'b0)});

wire tiny_to_denorm = (mant_main_pre == {TARGET_POS{1'b0}}) && has_discarded_bits;

assign mant_rounded = mant_main_rounded[`FP32_MANT_WIDTH-1:0];

wire signed [9:0] final_exp_signed = exp_adj_s + (mant_overflow_round ? 10'sd1 : 10'sd0);

// Registers
reg signed [9:0] final_exp_signed_reg;
reg [NORM_MANT_WIDTH-1:0] mant_norm_reg;
reg sticky_reg;
reg is_denorm_input_reg;
reg zero_out_reg;
reg tiny_to_denorm_reg;
reg sign_in_reg;
reg [`FP32_EXP_WIDTH-1:0] exp_in_reg;
reg [IN_WIDTH-1:0] mant_raw_reg;
reg [`FP32_MANT_WIDTH-1:0] mant_rounded_reg;
reg has_discarded_bits_reg;
reg [2:0] rounding_mode_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sign_in_reg <= 1'b0;
        exp_in_reg <= {`FP32_EXP_WIDTH{1'b0}};
        mant_raw_reg <= {IN_WIDTH{1'b0}};
        mant_norm_reg <= {NORM_MANT_WIDTH{1'b0}};
        final_exp_signed_reg <= 10'd0;
        sticky_reg <= 1'b0;
        is_denorm_input_reg <= 1'b0;
        zero_out_reg <= 1'b0;
        tiny_to_denorm_reg <= 1'b0;
        mant_rounded_reg <= {`FP32_MANT_WIDTH{1'b0}};
        has_discarded_bits_reg <= 1'b0;
        rounding_mode_reg <= `RM_RNE;
    end else begin
        mant_norm_reg <= mant_norm;
        final_exp_signed_reg <= final_exp_signed;
        sticky_reg <= sticky;
        is_denorm_input_reg <= is_denorm_input;
        zero_out_reg <= zero_out_comb;
        tiny_to_denorm_reg <= tiny_to_denorm;
        sign_in_reg <= sign_in;
        exp_in_reg <= exp_in;
        mant_raw_reg <= mant_raw;
        mant_rounded_reg <= mant_rounded;
        has_discarded_bits_reg <= has_discarded_bits;
        rounding_mode_reg <= rounding_mode;
    end
end

// ============================================================================
// Denormal Path
// ============================================================================
always @(*) begin : DENORM_COMB_BLOCK
    integer den_shift_local;
    reg [NORM_MANT_WIDTH-1:0] dm_window;
    reg [NORM_MANT_WIDTH-1:0] dm_shifted;
    reg sticky_den_extra;
    integer msb_in_norm;
    reg [`FP32_MANT_WIDTH:0] denorm_mant;

    dm_window = {NORM_MANT_WIDTH{1'b0}};
    dm_shifted = {NORM_MANT_WIDTH{1'b0}};
    sticky_den_extra = 1'b0;
    msb_in_norm = -1;
    denorm_mant = {(`FP32_MANT_WIDTH+1){1'b0}};
    
    dn_mant24_pre = {(`FP32_MANT_WIDTH+1){1'b0}};
    dn_mant24_rounded = {(`FP32_MANT_WIDTH+1){1'b0}};
    dn_g = 1'b0;
    dn_r = 1'b0;
    dn_s = 1'b0;
    dn_lsb = 1'b0;
    dn_round_up = 1'b0;

    if (tiny_to_denorm_reg) begin
        den_shift_local = 0;
    end else begin
        den_shift_local = (final_exp_signed_reg <= 0) ? (1 - final_exp_signed_reg) : 0;
    end

    dm_window = mant_norm_reg;

    if (den_shift_local <= 0) begin
        sticky_den_extra = 1'b0;
        dm_shifted = dm_window;
    end else begin
        if (den_shift_local > NORM_MANT_WIDTH) begin
            sticky_den_extra = |dm_window;
            dm_shifted = {NORM_MANT_WIDTH{1'b0}};
        end else begin
            sticky_den_extra = 1'b0;
            begin : CALC_STICKY
                integer i;
                for (i = 0; i < NORM_MANT_WIDTH && i < den_shift_local; i = i + 1) begin
                    sticky_den_extra = sticky_den_extra | dm_window[i];
                end
            end
            dm_shifted = dm_window >> den_shift_local;
        end
    end

    if (tiny_to_denorm_reg) begin
        begin : FIND_MSB_IN_NORM
            integer i;
            for (i = `GUARD_BITS-1; i >= 0; i = i - 1) begin
                if (mant_norm_reg[i] && msb_in_norm == -1) begin
                    msb_in_norm = i;
                end
            end
        end
        if (msb_in_norm >= 0) begin
            begin : COPY_DENORM_MANT
                integer i;
                for (i = 0; i <= `FP32_MANT_WIDTH; i = i + 1) begin
                    if (i <= msb_in_norm)
                        denorm_mant[i] = mant_norm_reg[i];
                end
            end
            dn_mant24_pre = {1'b0, denorm_mant[`FP32_MANT_WIDTH-1:0]};
            dn_mant24_rounded = dn_mant24_pre;
        end else begin
            dn_mant24_pre = dm_shifted[NORM_MANT_WIDTH-1:`GUARD_BITS];
            dn_g = dm_shifted[`GUARD_BITS-1];
            dn_r = dm_shifted[`GUARD_BITS-2];
            dn_s = (|dm_shifted[`GUARD_BITS-3:0]) | sticky_den_extra;
            dn_lsb = dn_mant24_pre[0];
            
            // Apply rounding mode for denormal path
            case (rounding_mode_reg)
                `RM_RNE: 
                    dn_round_up = (dn_g & (dn_r | dn_s)) | (dn_g & ~dn_r & ~dn_s & dn_lsb);
                `RM_RTZ: 
                    dn_round_up = 1'b0;
                `RM_RDN: 
                    dn_round_up = sign_in_reg & (dn_g | dn_r | dn_s);
                `RM_RUP: 
                    dn_round_up = ~sign_in_reg & (dn_g | dn_r | dn_s);
                `RM_RMM: 
                    dn_round_up = dn_g;
                default: 
                    dn_round_up = (dn_g & (dn_r | dn_s)) | (dn_g & ~dn_r & ~dn_s & dn_lsb);
            endcase
            
            dn_mant24_rounded = dn_mant24_pre + (dn_round_up ? 1'b1 : 1'b0);
        end
    end else begin
        dn_mant24_pre = dm_shifted[NORM_MANT_WIDTH-1:`GUARD_BITS];
        dn_g = dm_shifted[`GUARD_BITS-1];
        dn_r = dm_shifted[`GUARD_BITS-2];
        dn_s = (|dm_shifted[`GUARD_BITS-3:0]) | sticky_den_extra;
        dn_lsb = dn_mant24_pre[0];
        
        // Apply rounding mode
        case (rounding_mode_reg)
            `RM_RNE: 
                dn_round_up = (dn_g & (dn_r | dn_s)) | (dn_g & ~dn_r & ~dn_s & dn_lsb);
            `RM_RTZ: 
                dn_round_up = 1'b0;
            `RM_RDN: 
                dn_round_up = sign_in_reg & (dn_g | dn_r | dn_s);
            `RM_RUP: 
                dn_round_up = ~sign_in_reg & (dn_g | dn_r | dn_s);
            `RM_RMM: 
                dn_round_up = dn_g;
            default: 
                dn_round_up = (dn_g & (dn_r | dn_s)) | (dn_g & ~dn_r & ~dn_s & dn_lsb);
        endcase
        
        dn_mant24_rounded = dn_mant24_pre + (dn_round_up ? 1'b1 : 1'b0);
    end
end

// ============================================================================
// Final Result Packing
// ============================================================================
wire near_min_normal = tiny_to_denorm_reg && 
                       (dn_mant24_rounded != {(`FP32_MANT_WIDTH+1){1'b0}});

always @(*) begin
    fp_out_reg = {sign_in_reg, ZERO_EXP, {`FP32_MANT_WIDTH{1'b0}}};
    overflow_comb = 1'b0;
    underflow_comb = 1'b0;
    inexact_comb = has_discarded_bits_reg;

    if (zero_out_reg) begin
        fp_out_reg = {sign_in_reg, ZERO_EXP, {`FP32_MANT_WIDTH{1'b0}}};
        inexact_comb = 1'b0;
        
    end else if (final_exp_signed_reg >= EXP_MAX) begin
        // Overflow handling depends on rounding mode
        overflow_comb = 1'b1;
        inexact_comb = 1'b1;
        
        case (rounding_mode_reg)
            `RM_RNE, `RM_RMM: begin
                // Round to infinity
                fp_out_reg = {sign_in_reg, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
            end
            `RM_RTZ: begin
                // Round to max finite value
                fp_out_reg = {sign_in_reg, 8'd254, {`FP32_MANT_WIDTH{1'b1}}};
            end
            `RM_RDN: begin
                if (sign_in_reg)
                    fp_out_reg = {sign_in_reg, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
                else
                    fp_out_reg = {sign_in_reg, 8'd254, {`FP32_MANT_WIDTH{1'b1}}};
            end
            `RM_RUP: begin
                if (sign_in_reg)
                    fp_out_reg = {sign_in_reg, 8'd254, {`FP32_MANT_WIDTH{1'b1}}};
                else
                    fp_out_reg = {sign_in_reg, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
            end
            default: begin
                fp_out_reg = {sign_in_reg, {`FP32_EXP_WIDTH{1'b1}}, {`FP32_MANT_WIDTH{1'b0}}};
            end
        endcase
        
    end else if ((final_exp_signed_reg <= 0) || tiny_to_denorm_reg) begin
        underflow_comb = 1'b1;
        
        if (is_denorm_input_reg && final_exp_signed_reg == 0 && !tiny_to_denorm_reg) begin
            fp_out_reg = {sign_in_reg, ZERO_EXP, mant_raw_reg[`FP32_MANT_WIDTH-1+`GUARD_BITS:`GUARD_BITS]};
        end else begin
            if (dn_mant24_rounded[`FP32_MANT_WIDTH]) begin
                fp_out_reg = {sign_in_reg, 8'd1, {`FP32_MANT_WIDTH{1'b0}}};
            end else if (near_min_normal) begin
                fp_out_reg = {sign_in_reg, 8'd1, {`FP32_MANT_WIDTH{1'b0}}};
            end else begin
                fp_out_reg = {sign_in_reg, ZERO_EXP, dn_mant24_rounded[`FP32_MANT_WIDTH-1:0]};
            end
        end
           
    end else begin
        fp_out_reg = {sign_in_reg, final_exp_signed_reg[`FP32_EXP_WIDTH-1:0], mant_rounded_reg};
    end
end

assign zero_out = zero_out_reg;
assign overflow = overflow_comb;
assign underflow = underflow_comb;
assign inexact = inexact_comb;

endmodule