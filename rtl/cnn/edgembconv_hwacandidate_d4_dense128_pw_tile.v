`timescale 1ns/1ps
`default_nettype none

/*
 * D4 hardware-aware candidate: one 8-pixel x 16-Cout pointwise tile.
 *
 * The tile is deliberately an independent primitive.  It is not a wrapper
 * around two legacy 8x8 engines: the 128 output-stationary accumulators are
 * owned here and receive one common K token per cycle.  This keeps the D4
 * validation contract explicit while still reusing the signed INT8 -> INT32
 * multiply/accumulate cell used by the existing PW datapath.
 *
 * A token is one reduction position.  first_k and last_k delimit the whole
 * reduction (not a partial-K group), k_idx is carried as a protocol tag, and
 * metadata is captured with the final token.  The input elastic register and
 * one-entry output register make all source and result fields stable while
 * their corresponding ready is low.  Masked lanes are cleared/accumulated as
 * zero on every token, so a partial tile cannot leak a previous transaction.
 */
module edgembconv_hwacandidate_d4_dense128_pw_tile #(
    parameter integer PIXELS = 8,
    parameter integer COUTS = 16
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    valid_in,
    output wire                    ready_in,
    input  wire                    first_k,
    input  wire                    last_k,
    input  wire [7:0]              k_idx,
    input  wire [PIXELS-1:0]       pixel_mask,
    input  wire [COUTS-1:0]        cout_mask,
    input  wire signed [PIXELS*8-1:0] act_vec,
    input  wire signed [COUTS*8-1:0]  wgt_vec,
    input  wire [31:0]             metadata_in,
    input  wire                    ready_out,
    output reg                     valid_out,
    output reg signed [PIXELS*COUTS*32-1:0] psum_out,
    output reg [PIXELS*COUTS-1:0]  lane_mask_out,
    output reg [31:0]              metadata_out,
    output reg [7:0]               k_idx_out,
    output reg                     first_k_out,
    output reg                     last_k_out
);
    localparam integer LANES = PIXELS * COUTS;

    reg                              token_valid;
    reg                              token_first;
    reg                              token_last;
    reg [7:0]                        token_k_idx;
    reg [PIXELS-1:0]                 token_pixel_mask;
    reg [COUTS-1:0]                  token_cout_mask;
    reg signed [PIXELS*8-1:0]        token_act_masked;
    reg signed [COUTS*8-1:0]         token_wgt_masked;
    reg [31:0]                       token_metadata;
    wire                             input_fire;
    wire                             stage_fire;
    /* Explicit operand and DSP product/M stages.  The token register and
     * these stages are elastic; the product stage can capture one K token
     * every cycle while the accumulator consumes the preceding product. */
    reg                              pending_valid;
    reg                              pending_first;
    reg                              pending_last;
    reg [7:0]                        pending_k_idx;
    reg [PIXELS-1:0]                 pending_pixel_mask;
    reg [COUTS-1:0]                  pending_cout_mask;
    reg [31:0]                       pending_metadata;
    reg                              product_valid;
    reg                              product_first;
    reg                              product_last;
    reg [7:0]                        product_k_idx;
    reg [PIXELS-1:0]                 product_pixel_mask;
    reg [COUTS-1:0]                  product_cout_mask;
    reg [31:0]                       product_metadata;
    /* Replicate the stage enable at row granularity.  A single enable net
     * driving all 128 DSP CEs creates a long post-route control path; these
     * preserved fanout islands let Vivado place eight local control nets
     * without changing the token timing or arithmetic contract. */
    (* keep = "true", max_fanout = 16 *) wire [PIXELS-1:0] row_stage_fire;
    genvar en_row;
    generate
        for (en_row = 0; en_row < PIXELS; en_row = en_row + 1) begin : gen_stage_enable
            assign row_stage_fire[en_row] = stage_fire;
        end
    endgenerate

    /* A final token is never replaced in the input register until its
     * result has been accepted.  Non-final tokens may be replaced every
     * cycle, allowing one accepted K token per clock after startup. */
    assign ready_in = rst_n && !token_last && (!valid_out || ready_out);
    assign input_fire = valid_in && ready_in;
    assign stage_fire = token_valid;

    wire signed [31:0] sum_next [0:PIXELS-1][0:COUTS-1];
    genvar p, c;
    generate
        for (p = 0; p < PIXELS; p = p + 1) begin : gen_pixel
            for (c = 0; c < COUTS; c = c + 1) begin : gen_cout
                localparam integer LANE = p*COUTS + c;
                /* Masking operands, instead of gating the cell, also clears
                 * an inactive lane on first_k and prevents stale sums from
                 * surviving a partial output tile. */
                wire signed [7:0] cell_act = token_act_masked[p*8 +: 8];
                wire signed [7:0] cell_wgt = token_wgt_masked[c*8 +: 8];
                edgembconv_hwacandidate_d4_mac_cell u_mac (
                    .clk(clk), .rst_n(rst_n), .en(row_stage_fire[p]),
                    .clear_acc(token_first), .act_in(cell_act),
                    .wgt_in(cell_wgt), .sum_next(sum_next[p][c])
                );
            end
        end
    endgenerate

    integer i, j;
    always @(posedge clk) begin
        if (!rst_n) begin
            token_valid <= 1'b0;
            token_first <= 1'b0;
            token_last <= 1'b0;
            token_k_idx <= 8'd0;
            token_pixel_mask <= {PIXELS{1'b0}};
            token_cout_mask <= {COUTS{1'b0}};
            token_act_masked <= {(PIXELS*8){1'b0}};
            token_wgt_masked <= {(COUTS*8){1'b0}};
            token_metadata <= 32'd0;
            pending_valid <= 1'b0;
            pending_first <= 1'b0;
            pending_last <= 1'b0;
            pending_k_idx <= 8'd0;
            pending_pixel_mask <= {PIXELS{1'b0}};
            pending_cout_mask <= {COUTS{1'b0}};
            pending_metadata <= 32'd0;
            product_valid <= 1'b0;
            product_first <= 1'b0;
            product_last <= 1'b0;
            product_k_idx <= 8'd0;
            product_pixel_mask <= {PIXELS{1'b0}};
            product_cout_mask <= {COUTS{1'b0}};
            product_metadata <= 32'd0;
            valid_out <= 1'b0;
            psum_out <= {(LANES*32){1'b0}};
            lane_mask_out <= {LANES{1'b0}};
            metadata_out <= 32'd0;
            k_idx_out <= 8'd0;
            first_k_out <= 1'b0;
            last_k_out <= 1'b0;
        end else begin
            if (valid_out && ready_out)
                valid_out <= 1'b0;

            /* Consume the old registered product.  sum_next is combinational
             * from the pre-clock accumulator plus this product, hence the
             * product-stage last tag includes the final product in psum_out. */
            if (product_valid && product_last) begin
                for (i = 0; i < PIXELS; i = i + 1) begin
                    for (j = 0; j < COUTS; j = j + 1) begin
                        lane_mask_out[i*COUTS+j] <=
                            product_pixel_mask[i] && product_cout_mask[j];
                        /* Masked operands were zeroed at token capture and
                         * carried through the product stage, so
                         * sum_next is already zero for an inactive lane.
                         * Avoiding a second mask mux here keeps the final
                         * DSP-to-output register path short. */
                        psum_out[((i*COUTS+j)*32) +: 32] <= sum_next[i][j];
                    end
                end
                metadata_out <= product_metadata;
                k_idx_out <= product_k_idx;
                first_k_out <= product_first;
                last_k_out <= product_last;
                valid_out <= 1'b1;
            end

            /* Capture transaction tags through the operand and product
             * stages.  The two delayed tag records are aligned with the
             * operand and product registers in every MAC cell. */
            product_valid <= pending_valid;
            if (pending_valid) begin
                product_first <= pending_first;
                product_last <= pending_last;
                product_k_idx <= pending_k_idx;
                product_pixel_mask <= pending_pixel_mask;
                product_cout_mask <= pending_cout_mask;
                product_metadata <= pending_metadata;
            end else begin
                product_first <= 1'b0;
                product_last <= 1'b0;
            end
            pending_valid <= stage_fire;
            if (stage_fire) begin
                pending_first <= token_first;
                pending_last <= token_last;
                pending_k_idx <= token_k_idx;
                pending_pixel_mask <= token_pixel_mask;
                pending_cout_mask <= token_cout_mask;
                pending_metadata <= token_metadata;
            end else begin
                pending_first <= 1'b0;
                pending_last <= 1'b0;
            end

            /* The current token is consumed regardless of input_fire.  If a
             * replacement token is accepted in this cycle it becomes the
             * next staged token through nonblocking assignments. */
            token_valid <= input_fire;
            if (input_fire) begin
                token_first <= first_k;
                token_last <= last_k;
                token_k_idx <= k_idx;
                token_pixel_mask <= pixel_mask;
                token_cout_mask <= cout_mask;
                for (i = 0; i < PIXELS; i = i + 1)
                    if (pixel_mask[i])
                        token_act_masked[i*8 +: 8] <= act_vec[i*8 +: 8];
                    else
                        token_act_masked[i*8 +: 8] <= 8'sd0;
                for (j = 0; j < COUTS; j = j + 1)
                    if (cout_mask[j])
                        token_wgt_masked[j*8 +: 8] <= wgt_vec[j*8 +: 8];
                    else
                        token_wgt_masked[j*8 +: 8] <= 8'sd0;
                token_metadata <= metadata_in;
            end else begin
                token_first <= 1'b0;
                token_last <= 1'b0;
            end
        end
    end
endmodule

/* One signed INT8 product plus a signed INT32 output-stationary accumulator.
 * The explicit operand registers feed the DSP product/M stage.  The
 * accumulator consumes the preceding product while the next product is
 * captured, preserving II=1 after startup and separating the activation
 * operand path from the accumulator C input. */
module edgembconv_hwacandidate_d4_mac_cell (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 en,
    input  wire                 clear_acc,
    input  wire signed [7:0]    act_in,
    input  wire signed [7:0]    wgt_in,
    output wire signed [31:0]   sum_next
);
    (* keep = "true" *) reg signed [7:0] act_reg;
    (* keep = "true" *) reg signed [7:0] wgt_reg;
    reg operand_valid;
    reg operand_clear;
    (* use_dsp = "yes" *) wire signed [15:0] product = act_reg * wgt_reg;
    (* keep = "true" *) reg signed [15:0] product_reg;
    reg product_valid;
    reg product_clear;
    wire signed [31:0] product_ext = {{16{product_reg[15]}}, product_reg};
    reg signed [31:0] psum_reg;
    assign sum_next = product_clear ? product_ext : (psum_reg + product_ext);

    always @(posedge clk) begin
        if (!rst_n) begin
            act_reg <= 8'sd0;
            wgt_reg <= 8'sd0;
            operand_valid <= 1'b0;
            operand_clear <= 1'b0;
            product_reg <= 16'sd0;
            product_valid <= 1'b0;
            product_clear <= 1'b0;
            psum_reg <= 32'sd0;
        end else begin
            /* The old product is consumed while the new product is
             * captured, and the next operands are captured concurrently.
             * Both stages therefore sustain II=1. */
            if (product_valid)
                psum_reg <= sum_next;
            product_valid <= operand_valid;
            if (operand_valid) begin
                product_reg <= product;
                product_clear <= operand_clear;
            end
            operand_valid <= en;
            if (en) begin
                act_reg <= act_in;
                wgt_reg <= wgt_in;
                operand_clear <= clear_acc;
            end
        end
    end
endmodule

`default_nettype wire
