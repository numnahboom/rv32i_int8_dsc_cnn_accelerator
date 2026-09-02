`timescale 1ns/1ps
`default_nettype none

/* Mechanically extracted seven-pixel dedicated PW island from the D4
 * composition screen.  The arithmetic and reduction boundary are unchanged;
 * only the module namespace is independent of the legacy composite. */
module edgembconv_hwacandidate_d4_vstream_pw112 (
    input wire clk, input wire rst_n, input wire valid_in,
    output wire ready_in, input wire first_k, input wire last_k,
    input wire [7:0] k_idx, input wire [6:0] pixel_mask,
    input wire [15:0] cout_mask, input wire signed [55:0] act_vec,
    input wire signed [127:0] wgt_vec, input wire ready_out,
    output reg valid_out, output reg signed [3583:0] psum_out,
    output reg [111:0] lane_mask_out
);
    localparam integer PIXELS = 7;
    localparam integer COUTS = 16;
    localparam integer LANES = 112;
    reg token_valid, token_first, token_last;
    reg [6:0] token_pixel_mask;
    reg [15:0] token_cout_mask;
    reg signed [55:0] token_act;
    reg signed [127:0] token_wgt;
    reg product_valid, product_first, product_last;
    /* Replicate the reduction boundary tags at the lane island boundary.
     * A single product_first fanout otherwise drives every bit of 112
     * accumulators and becomes a routed timing path.  These copies are
     * captured from token_first/token_last alongside the DSP transaction,
     * preserving the existing product/metadata alignment. */
    (* keep = "true", dont_touch = "true" *) reg [LANES-1:0] product_first_lane;
    (* keep = "true", dont_touch = "true" *) reg [LANES-1:0] product_last_lane;
    (* keep = "true", dont_touch = "true" *) reg [LANES-1:0] product_pixel_mask_lane;
    (* keep = "true", dont_touch = "true" *) reg [LANES-1:0] product_cout_mask_lane;
    (* keep = "true", dont_touch = "true" *) reg signed [LANES*8-1:0] product_act_lane;
    (* keep = "true", dont_touch = "true" *) reg signed [LANES*8-1:0] product_wgt_lane;
    (* keep = "true", dont_touch = "true" *) reg [LANES-1:0] product_valid_lane;
    reg [6:0] product_pixel_mask;
    reg [15:0] product_cout_mask;
    wire input_fire = valid_in && ready_in;
    wire stage_fire = token_valid;
    assign ready_in = rst_n && !token_last && (!valid_out || ready_out);
    wire signed [47:0] dsp_p [0:LANES-1];
    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : gen_d4_pw112_dsp
            localparam integer P = g / COUTS;
            localparam integer C = g % COUTS;
            wire signed [7:0] ma = product_pixel_mask_lane[g]
                ? product_act_lane[g*8 +: 8] : 8'sd0;
            wire signed [7:0] mw = product_cout_mask_lane[g]
                ? product_wgt_lane[g*8 +: 8] : 8'sd0;
            wire [24:0] a_masked = {{17{ma[7]}}, ma};
            wire [17:0] b_masked = {{10{mw[7]}}, mw};
            edgembconv_hwacandidate_d4_dsp_pool_dsp u_dsp (
                .clk(clk), .rst_n(rst_n), .a_in(a_masked),
                .b_in(b_masked), .p_out(dsp_p[g])
            );
        end
    endgenerate
    reg signed [LANES*32-1:0] acc;
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            token_valid <= 1'b0; token_first <= 1'b0; token_last <= 1'b0;
            token_pixel_mask <= 7'd0; token_cout_mask <= 16'd0;
            token_act <= 56'sd0; token_wgt <= 128'sd0;
            product_valid <= 1'b0; product_first <= 1'b0; product_last <= 1'b0;
            product_pixel_mask <= 7'd0; product_cout_mask <= 16'd0;
            valid_out <= 1'b0; psum_out <= 3584'sd0; lane_mask_out <= 112'd0;
            for (i = 0; i < LANES; i = i + 1) begin
                acc[(i*32) +: 32] <= 32'sd0;
                product_first_lane[i] <= 1'b0;
                product_last_lane[i] <= 1'b0;
                product_pixel_mask_lane[i] <= 1'b0;
                product_cout_mask_lane[i] <= 1'b0;
                product_act_lane[(i*8) +: 8] <= 8'sd0;
                product_wgt_lane[(i*8) +: 8] <= 8'sd0;
                product_valid_lane[i] <= 1'b0;
            end
        end else begin
            if (valid_out && ready_out) valid_out <= 1'b0;
            for (i = 0; i < LANES; i = i + 1) begin
                if (product_valid_lane[i]) begin
                    if (product_first_lane[i])
                        acc[(i*32) +: 32] <= $signed(dsp_p[i]);
                    else
                        acc[(i*32) +: 32] <= acc[(i*32) +: 32] + $signed(dsp_p[i]);
                    if (product_last_lane[i])
                        psum_out[(i*32) +: 32] <= product_first_lane[i]
                            ? {{16{dsp_p[i][15]}}, dsp_p[i][15:0]}
                            : acc[(i*32) +: 32] + $signed(dsp_p[i]);
                end
            end
            if (product_last) begin
                for (i = 0; i < LANES; i = i + 1)
                    lane_mask_out[i] <= product_pixel_mask[i/COUTS] &&
                                         product_cout_mask[i%COUTS];
                valid_out <= 1'b1;
            end
            product_valid <= stage_fire;
            for (i = 0; i < LANES; i = i + 1)
                product_valid_lane[i] <= stage_fire;
            if (stage_fire) begin
                product_first <= token_first;
                product_last <= token_last;
                product_pixel_mask <= token_pixel_mask;
                product_cout_mask <= token_cout_mask;
                for (i = 0; i < LANES; i = i + 1) begin
                product_first_lane[i] <= token_first;
                product_last_lane[i] <= token_last;
                end
            end else begin
                product_first <= 1'b0; product_last <= 1'b0;
                for (i = 0; i < LANES; i = i + 1) begin
                    product_first_lane[i] <= 1'b0;
                    product_last_lane[i] <= 1'b0;
                end
            end
            token_valid <= input_fire;
            /* These lane-local operand copies are a free-running register
             * bank.  Gating them with input_fire would put the pool's
             * ready/valid cone on every DSP operand register CE and recreate
             * a long cross-island timing path.  Invalid-cycle values are
             * harmless because product_valid remains the transaction guard. */
            for (i = 0; i < LANES; i = i + 1) begin
                product_pixel_mask_lane[i] <= pixel_mask[i/COUTS];
                product_cout_mask_lane[i] <= cout_mask[i%COUTS];
                product_act_lane[(i*8) +: 8] <= act_vec[(i/COUTS)*8 +: 8];
                product_wgt_lane[(i*8) +: 8] <= wgt_vec[(i%COUTS)*8 +: 8];
            end
            if (input_fire) begin
                token_first <= first_k; token_last <= last_k;
                token_pixel_mask <= pixel_mask; token_cout_mask <= cout_mask;
                token_act <= act_vec; token_wgt <= wgt_vec;
            end else begin
                token_first <= 1'b0; token_last <= 1'b0;
            end
        end
    end
endmodule


`default_nettype wire
