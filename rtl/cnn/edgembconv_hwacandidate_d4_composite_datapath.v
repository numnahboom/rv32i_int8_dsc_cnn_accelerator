`timescale 1ns/1ps
`default_nettype none

/*
 * D4 physical-composition screen.
 *
 * This file is deliberately separate from the D4 block shell and from C0.
 * It is a physical datapath candidate, not a complete block scheduler:
 *
 *   112 dedicated PW DSP lanes (seven 16-channel pixels)
 *   + the existing 16-DSP dual-mode pool (the eighth PW pixel or four RQ
 *     lanes)
 *   + one 18-DSP DW16 source-scheduler island.
 *
 * The 112-lane PW side is implemented here instead of instantiating the old
 * 128-lane tile.  Thus synthesis can prove the intended 112+16+18 mapping.
 * All outputs are registered and observable through the top-level contract.
 */
module edgembconv_hwacandidate_d4_composite_datapath (
    input  wire                         clk,
    input  wire                         rst_n,

    /* One transaction stream.  mode=0 is a PW reduction token; mode=1 is
     * one exact four-lane requant transaction in the shared pool. */
    input  wire                         op_mode_rq,
    input  wire                         op_valid,
    output wire                         op_ready,

    input  wire [55:0]                  pw_act_7pixel_vec,
    input  wire [127:0]                 pw_act_pool_vec,
    input  wire [127:0]                 pw_wgt_vec,
    input  wire [7:0]                   pw_pixel_mask,
    input  wire [15:0]                  pw_cout_mask,
    input  wire                         pw_first_k,
    input  wire                         pw_last_k,
    input  wire [7:0]                   pw_k_idx,

    input  wire signed [127:0]           rq_acc_vec,
    input  wire signed [127:0]           rq_multiplier_vec,
    input  wire [23:0]                  rq_shift_vec,
    input  wire signed [127:0]           rq_zero_point_vec,
    input  wire signed [127:0]           rq_min_vec,
    input  wire signed [127:0]           rq_max_vec,
    input  wire [31:0]                  metadata_in,

    input  wire                         out_ready,
    output reg                          out_valid,
    output reg                          out_mode_rq,
    output reg signed [4095:0]          pw_psum_vec,
    output reg [127:0]                  pw_lane_mask,
    output reg signed [255:0]           rq_product_vec,
    output reg signed [31:0]            rq_result_vec,
    output reg [31:0]                  metadata_out,

    /* DW16 island, intentionally exposed as a future block-pair interface. */
    input  wire                         dw_cfg_valid,
    output wire                         dw_cfg_ready,
    input  wire [7:0]                   dw_cfg_addr,
    input  wire signed [7:0]            dw_cfg_data,
    input  wire                         dw_start_valid,
    output wire                         dw_start_ready,
    input  wire [7:0]                   dw_in_w,
    input  wire [7:0]                   dw_in_h,
    input  wire [7:0]                   dw_out_x,
    input  wire [7:0]                   dw_out_y,
    input  wire [1:0]                   dw_stride,
    input  wire [31:0]                  dw_metadata_in,
    output wire                         dw_src_req_valid,
    input  wire                         dw_src_req_ready,
    output wire [31:0]                  dw_src_req_addr,
    input  wire                         dw_src_resp_valid,
    output wire                         dw_src_resp_ready,
    input  wire [127:0]                 dw_src_resp_data,
    input  wire                         dw_out_ready,
    output wire                         dw_out_valid,
    output wire signed [511:0]          dw_raw_psum_vec,
    output wire [31:0]                  dw_metadata_out,
    output wire                         dw_done
);
    wire pw112_ready;
    wire pw112_valid;
    wire signed [3583:0] pw112_psum;
    wire [111:0] pw112_mask;

    wire pool_valid_in;
    wire pool_ready_in;
    wire pool_valid_out;
    wire pool_mode_out;
    wire [255:0] pool_pw_product;
    wire signed [255:0] pool_rq_product;
    wire signed [31:0] pool_rq_result;
    wire [31:0] pool_metadata;

    reg mode_lock_valid;
    reg mode_lock_rq;
    reg pw_done_pending;

    wire output_space = !out_valid || out_ready;
    wire pw_can_accept = pw112_ready && pool_ready_in && !pw_done_pending &&
                         output_space;
    wire rq_can_accept = pool_ready_in && output_space && !pw_done_pending;
    assign op_ready = rst_n &&
        (!mode_lock_valid || (mode_lock_rq == op_mode_rq)) &&
        (op_mode_rq ? rq_can_accept : pw_can_accept);
    assign pool_valid_in = op_valid && op_ready;

    edgembconv_hwacandidate_d4_composite_pw112 u_pw112 (
        .clk(clk), .rst_n(rst_n), .valid_in(pool_valid_in && !op_mode_rq),
        .ready_in(pw112_ready), .first_k(pw_first_k), .last_k(pw_last_k),
        .k_idx(pw_k_idx), .pixel_mask(pw_pixel_mask[6:0]),
        .cout_mask(pw_cout_mask), .act_vec(pw_act_7pixel_vec),
        .wgt_vec(pw_wgt_vec), .ready_out(1'b1), .valid_out(pw112_valid),
        .psum_out(pw112_psum), .lane_mask_out(pw112_mask)
    );

    /* Existing D4 pool: its 16 DSPs are reused in PW or exact RQ mode. */
    edgembconv_hwacandidate_d4_dsp_pool u_pool (
        .clk(clk), .rst_n(rst_n), .mode_rq(op_mode_rq),
        .valid_in(pool_valid_in), .ready_in(pool_ready_in),
        .pw_act_vec(pw_act_pool_vec), .pw_wgt_vec(pw_wgt_vec),
        .rq_acc_vec(rq_acc_vec), .rq_multiplier_vec(rq_multiplier_vec),
        .rq_shift_vec(rq_shift_vec), .rq_zero_point_vec(rq_zero_point_vec),
        .rq_min_vec(rq_min_vec), .rq_max_vec(rq_max_vec),
        .metadata_in(metadata_in), .ready_out(1'b1),
        .valid_out(pool_valid_out), .mode_rq_out(pool_mode_out),
        .pw_product_vec(pool_pw_product), .rq_product0(), .rq_product1(),
        .rq_product2(), .rq_product3(), .rq_product_vec(pool_rq_product),
        .rq_result_vec(pool_rq_result), .metadata_out(pool_metadata)
    );

    /* The pool has a registered DSP boundary.  These tags are delayed to the
     * exact edge at which its visible output is consumed. */
    reg pool_first_d1, pool_first_d2, pool_last_d1, pool_last_d2;
    reg pool_pixel_d1, pool_pixel_d2;
    reg [15:0] pool_cout_d1, pool_cout_d2;
    reg signed [31:0] pool_acc [0:15];
    wire pool_pw_event = pool_valid_out && !pool_mode_out;
    wire pool_pw_last_event = pool_pw_event && pool_last_d2;
    wire [15:0] pool_mask_event = pool_cout_d2 & {16{pool_pixel_d2}};
    /* The dedicated 112-lane island has one extra observable register edge
     * relative to the shared pool. Hold the pool final until that edge. */
    reg pool_final_pending;
    reg signed [31:0] pool_final_hold [0:15];
    reg [15:0] pool_final_mask_hold;
    reg [31:0] pool_final_metadata_hold;

    integer pi;
    always @(posedge clk) begin
        if (!rst_n) begin
            mode_lock_valid <= 1'b0;
            mode_lock_rq <= 1'b0;
            pw_done_pending <= 1'b0;
            pool_first_d1 <= 1'b0;
            pool_first_d2 <= 1'b0;
            pool_last_d1 <= 1'b0;
            pool_last_d2 <= 1'b0;
            pool_pixel_d1 <= 1'b0;
            pool_pixel_d2 <= 1'b0;
            pool_cout_d1 <= 16'd0;
            pool_cout_d2 <= 16'd0;
            pool_final_pending <= 1'b0;
            pool_final_mask_hold <= 16'd0;
            pool_final_metadata_hold <= 32'd0;
            out_valid <= 1'b0;
            out_mode_rq <= 1'b0;
            pw_psum_vec <= 4096'sd0;
            pw_lane_mask <= 128'd0;
            rq_product_vec <= 256'sd0;
            rq_result_vec <= 32'sd0;
            metadata_out <= 32'd0;
            for (pi = 0; pi < 16; pi = pi + 1)
                pool_acc[pi] <= 32'sd0;
            for (pi = 0; pi < 16; pi = pi + 1)
                pool_final_hold[pi] <= 32'sd0;
        end else begin
            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
                mode_lock_valid <= 1'b0;
                pw_done_pending <= 1'b0;
            end

            pool_first_d2 <= pool_first_d1;
            pool_last_d2 <= pool_last_d1;
            pool_pixel_d2 <= pool_pixel_d1;
            pool_cout_d2 <= pool_cout_d1;
            pool_first_d1 <= pool_valid_in && !op_mode_rq && pw_first_k;
            pool_last_d1 <= pool_valid_in && !op_mode_rq && pw_last_k;
            pool_pixel_d1 <= pool_valid_in && !op_mode_rq && pw_pixel_mask[7];
            pool_cout_d1 <= pw_cout_mask;

            if (pool_pw_event) begin
                for (pi = 0; pi < 16; pi = pi + 1) begin
                    if (pool_first_d2)
                        pool_acc[pi] <= {{16{pool_pw_product[(pi*16)+15]}},
                                         pool_pw_product[(pi*16) +: 16]};
                    else
                        pool_acc[pi] <= pool_acc[pi] +
                            {{16{pool_pw_product[(pi*16)+15]}},
                             pool_pw_product[(pi*16) +: 16]};
                end
            end

            if (pool_pw_last_event) begin
                for (pi = 0; pi < 16; pi = pi + 1)
                    pool_final_hold[pi] <= pool_first_d2
                        ? {{16{pool_pw_product[(pi*16)+15]}},
                           pool_pw_product[(pi*16) +: 16]}
                        : pool_acc[pi] +
                          {{16{pool_pw_product[(pi*16)+15]}},
                           pool_pw_product[(pi*16) +: 16]};
                pool_final_mask_hold <= pool_mask_event;
                pool_final_metadata_hold <= pool_metadata;
                pool_final_pending <= 1'b1;
            end

            if (pool_final_pending && pw112_valid) begin
                for (pi = 0; pi < 112; pi = pi + 1)
                    pw_psum_vec[(pi*32) +: 32] <= pw112_psum[(pi*32) +: 32];
                for (pi = 0; pi < 16; pi = pi + 1)
                    pw_psum_vec[((112+pi)*32) +: 32] <=
                        pool_final_hold[pi];
                pw_lane_mask <= {pool_final_mask_hold, pw112_mask};
                metadata_out <= pool_final_metadata_hold;
                out_mode_rq <= 1'b0;
                out_valid <= 1'b1;
                pool_final_pending <= 1'b0;
            end

            /* RQ results are already exact and registered by the existing
             * pool.  The composite register provides common backpressure and
             * makes mode transitions observable at one boundary. */
            if (pool_valid_out && pool_mode_out) begin
                rq_product_vec <= pool_rq_product;
                rq_result_vec <= pool_rq_result;
                metadata_out <= pool_metadata;
                out_mode_rq <= 1'b1;
                out_valid <= 1'b1;
            end

            if (pool_valid_in) begin
                if (!mode_lock_valid) begin
                    mode_lock_valid <= 1'b1;
                    mode_lock_rq <= op_mode_rq;
                end
                if (!op_mode_rq && pw_last_k)
                    pw_done_pending <= 1'b1;
            end
        end
    end

    edgembconv_hwacandidate_d4_dw16_raw_scheduler u_dw16 (
        .clk(clk), .rst_n(rst_n), .cfg_valid(dw_cfg_valid),
        .cfg_ready(dw_cfg_ready), .cfg_addr(dw_cfg_addr),
        .cfg_data(dw_cfg_data), .start_valid(dw_start_valid),
        .start_ready(dw_start_ready), .start_in_w(dw_in_w),
        .start_in_h(dw_in_h), .start_out_x(dw_out_x),
        .start_out_y(dw_out_y), .start_stride(dw_stride),
        .start_metadata(dw_metadata_in), .src_req_valid(dw_src_req_valid),
        .src_req_ready(dw_src_req_ready), .src_req_addr(dw_src_req_addr),
        .src_resp_valid(dw_src_resp_valid),
        .src_resp_ready(dw_src_resp_ready), .src_resp_data(dw_src_resp_data),
        .out_ready(dw_out_ready), .out_valid(dw_out_valid),
        .out_raw_psum_vec(dw_raw_psum_vec),
        .out_metadata(dw_metadata_out), .done(dw_done)
    );
endmodule

/* Seven pixels x sixteen Cout = 112 dedicated INT8 DSP lanes. */
module edgembconv_hwacandidate_d4_composite_pw112 (
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
    (* keep = "true", dont_touch = "true" *) reg product_first_lane [0:LANES-1];
    (* keep = "true", dont_touch = "true" *) reg product_last_lane [0:LANES-1];
    (* keep = "true", dont_touch = "true" *) reg product_pixel_mask_lane [0:LANES-1];
    (* keep = "true", dont_touch = "true" *) reg product_cout_mask_lane [0:LANES-1];
    (* keep = "true", dont_touch = "true" *) reg signed [7:0] product_act_lane [0:LANES-1];
    (* keep = "true", dont_touch = "true" *) reg signed [7:0] product_wgt_lane [0:LANES-1];
    (* keep = "true", dont_touch = "true" *) reg product_valid_lane [0:LANES-1];
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
                ? product_act_lane[g] : 8'sd0;
            wire signed [7:0] mw = product_cout_mask_lane[g]
                ? product_wgt_lane[g] : 8'sd0;
            wire [24:0] a_masked = {{17{ma[7]}}, ma};
            wire [17:0] b_masked = {{10{mw[7]}}, mw};
            edgembconv_hwacandidate_d4_dsp_pool_dsp u_dsp (
                .clk(clk), .rst_n(rst_n), .a_in(a_masked),
                .b_in(b_masked), .p_out(dsp_p[g])
            );
        end
    endgenerate
    reg signed [31:0] acc [0:LANES-1];
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
                acc[i] <= 32'sd0;
                product_first_lane[i] <= 1'b0;
                product_last_lane[i] <= 1'b0;
                product_pixel_mask_lane[i] <= 1'b0;
                product_cout_mask_lane[i] <= 1'b0;
                product_act_lane[i] <= 8'sd0;
                product_wgt_lane[i] <= 8'sd0;
                product_valid_lane[i] <= 1'b0;
            end
        end else begin
            if (valid_out && ready_out) valid_out <= 1'b0;
            for (i = 0; i < LANES; i = i + 1) begin
                if (product_valid_lane[i]) begin
                    if (product_first_lane[i])
                        acc[i] <= $signed(dsp_p[i]);
                    else
                        acc[i] <= acc[i] + $signed(dsp_p[i]);
                    if (product_last_lane[i])
                        psum_out[(i*32) +: 32] <= product_first_lane[i]
                            ? {{16{dsp_p[i][15]}}, dsp_p[i][15:0]}
                            : acc[i] + $signed(dsp_p[i]);
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
                product_act_lane[i] <= act_vec[(i/COUTS)*8 +: 8];
                product_wgt_lane[i] <= wgt_vec[(i%COUTS)*8 +: 8];
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

/*
 * DW16 raw-sum island with a synchronous one-outstanding source interface.
 * Sixteen DSPs calculate channel products.  Two additional DSPs calculate
 * x*stride and y*input_width for the source scheduler; the resulting
 * registered coordinates feed every observable source address.  No dense or
 * LUT multiplier is used for address generation.
 */
module edgembconv_hwacandidate_d4_dw16_raw_scheduler (
    input wire clk, input wire rst_n,
    input wire cfg_valid, output wire cfg_ready, input wire [7:0] cfg_addr,
    input wire signed [7:0] cfg_data,
    input wire start_valid, output wire start_ready,
    input wire [7:0] start_in_w, input wire [7:0] start_in_h,
    input wire [7:0] start_out_x, input wire [7:0] start_out_y,
    input wire [1:0] start_stride, input wire [31:0] start_metadata,
    output wire src_req_valid, input wire src_req_ready,
    output wire [31:0] src_req_addr,
    input wire src_resp_valid, output wire src_resp_ready,
    input wire [127:0] src_resp_data,
    input wire out_ready, output reg out_valid,
    output reg signed [511:0] out_raw_psum_vec,
    output reg [31:0] out_metadata, output reg done
);
    reg signed [7:0] weight_mem [0:143];
    reg active, req_pending, addr_pending, addr_ready, product_pending;
    reg req_desc_valid, req_desc_in_bounds;
    reg [31:0] req_desc_addr;
    reg [3:0] req_desc_tap_idx;
    reg [8:0] tap_bounds_mask;
    reg [31:0] tap_addr_table [0:8];
    /* The halo decision is captured before it is consumed.  In particular,
     * tap_idx is no longer in the combinational pad-event -> tap_idx feedback
     * cone; this is the scheduler's explicit one-cycle event fence. */
    reg pad_pending;
    reg tap_ingress_valid, tap_ingress_last;
    reg [127:0] tap_ingress_data;
    reg [3:0] tap_ingress_idx;
    /* Per-event weight lookup registers keep the distributed weight-memory
     * mux out of the DSP input timing endpoint. */
    reg signed [7:0] tap_weight_reg [0:15];
    /* Physically shifted nine-tap schedule: the current tap is always at
     * index zero, so the weight capture edge has no tap_idx mux cone. */
    reg signed [7:0] weight_schedule [0:15][0:8];
    reg [7:0] in_w, in_h, out_x, out_y;
    reg [1:0] stride;
    reg [3:0] tap_idx;
    reg [31:0] metadata_reg;
    reg signed [47:0] x_base_reg, y_row_reg;
    reg product_last;
    reg signed [31:0] acc [0:15];
    wire cfg_fire = cfg_valid && cfg_ready;
    wire start_fire = start_valid && start_ready;
    assign cfg_ready = rst_n && !active && !out_valid;
    assign start_ready = rst_n && !active && !out_valid && !addr_pending;
    wire signed [47:0] addr_x_product;
    wire signed [47:0] addr_y_product;
    /* The start bus is held by the source until start_ready.  Feeding it
     * directly into the two PREG DSPs makes the address products correspond
     * to the accepted start edge, while the registered scheduler state below
     * carries them through the one-cycle arithmetic boundary. */
    wire [24:0] addr_x_a = {17'd0, start_out_x};
    wire [17:0] addr_x_b = {16'd0, start_stride};
    wire [7:0] start_y_scaled = (start_stride == 2) ?
                                (start_out_y << 1) : start_out_y;
    wire [24:0] addr_y_a = {17'd0, start_y_scaled};
    wire [17:0] addr_y_b = {10'd0, start_in_w};
    edgembconv_hwacandidate_d4_dsp_pool_dsp u_addr_x (
        .clk(clk), .rst_n(rst_n), .a_in(addr_x_a), .b_in(addr_x_b),
        .p_out(addr_x_product)
    );
    edgembconv_hwacandidate_d4_dsp_pool_dsp u_addr_y (
        .clk(clk), .rst_n(rst_n), .a_in(addr_y_a), .b_in(addr_y_b),
        .p_out(addr_y_product)
    );

    integer tap_table_i, tap_table_row_i, tap_table_col_i;
    integer tap_table_x_i, tap_table_y_i;
    reg [8:0] tap_bounds_mask_calc;
    reg [31:0] tap_addr_table_calc [0:8];
    always @* begin
        tap_table_x_i = addr_x_product;
        tap_table_y_i = (stride == 2) ? (out_y <<< 1) : out_y;
        for (tap_table_i = 0; tap_table_i < 9; tap_table_i = tap_table_i + 1) begin
            tap_table_row_i = tap_table_i / 3;
            tap_table_col_i = tap_table_i % 3;
            tap_bounds_mask_calc[tap_table_i] =
                (tap_table_x_i + tap_table_col_i - 1 >= 0) &&
                (tap_table_x_i + tap_table_col_i - 1 < in_w) &&
                (tap_table_y_i + tap_table_row_i - 1 >= 0) &&
                (tap_table_y_i + tap_table_row_i - 1 < in_h);
            tap_addr_table_calc[tap_table_i] =
                addr_y_product + ((tap_table_row_i == 0) ? -in_w :
                                   (tap_table_row_i == 1) ? 0 : in_w) +
                tap_table_col_i - 1 + addr_x_product;
        end
    end
    wire tap_in_bounds = tap_bounds_mask[tap_idx];
    integer next_tap_idx_i, next_addr_i;
    always @* begin
        next_tap_idx_i = (tap_idx == 4'd8) ? 0 : tap_idx + 1;
        next_addr_i = tap_addr_table[next_tap_idx_i];
    end
    wire next_tap_in_bounds = tap_bounds_mask[next_tap_idx_i];
    wire request_allowed = active && addr_ready && !req_pending && !out_valid &&
                           req_desc_valid;
    assign src_req_valid = request_allowed && req_desc_in_bounds;
    assign src_req_addr = req_desc_addr;
    assign src_resp_ready = active && req_pending && !out_valid;
    wire request_fire = src_req_valid && src_req_ready;
    wire response_fire = src_resp_valid && src_resp_ready;
    /* Out-of-bounds taps are emitted only from the registered decision.  A
     * new decision is captured in the sequential block while the scheduler
     * is idle, so one pending halo event cannot be duplicated. */
    wire pad_fire = active && addr_ready && !req_pending && !out_valid &&
                    req_desc_valid && pad_pending;
    wire tap_fire = response_fire || pad_fire;
    wire [127:0] tap_data = response_fire ? src_resp_data : 128'd0;
    wire signed [15:0] dw_product [0:15];
    genvar d;
    generate
        for (d = 0; d < 16; d = d + 1) begin : gen_d4_dw16_dsp
            wire signed [7:0] a_lane = $signed(tap_ingress_data[(d*8) +: 8]);
            wire signed [7:0] w_lane = tap_weight_reg[d];
            wire [24:0] a_op = {{17{a_lane[7]}}, a_lane};
            wire [17:0] w_op = {{10{w_lane[7]}}, w_lane};
            wire signed [47:0] p_wide;
            edgembconv_hwacandidate_d4_dsp_pool_dsp u_dsp (
                .clk(clk), .rst_n(rst_n), .a_in(a_op), .b_in(w_op),
                .p_out(p_wide)
            );
            assign dw_product[d] = p_wide[15:0];
        end
    endgenerate

    integer i, j;
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0; req_pending <= 1'b0; addr_pending <= 1'b0;
            addr_ready <= 1'b0; product_pending <= 1'b0; tap_idx <= 4'd0;
            req_desc_valid <= 1'b0; req_desc_in_bounds <= 1'b0;
            req_desc_addr <= 32'd0; req_desc_tap_idx <= 4'd0;
            tap_bounds_mask <= 9'd0;
            pad_pending <= 1'b0;
            tap_ingress_valid <= 1'b0; tap_ingress_last <= 1'b0;
            tap_ingress_data <= 128'd0; tap_ingress_idx <= 4'd0;
            in_w <= 0; in_h <= 0; out_x <= 0; out_y <= 0; stride <= 1;
            metadata_reg <= 0; x_base_reg <= 0; y_row_reg <= 0;
            product_last <= 1'b0; out_valid <= 1'b0; done <= 1'b0;
            out_raw_psum_vec <= 512'sd0; out_metadata <= 0;
            for (i = 0; i < 144; i = i + 1) weight_mem[i] <= 8'sd0;
            for (i = 0; i < 16; i = i + 1) begin
                acc[i] <= 32'sd0;
                tap_weight_reg[i] <= 8'sd0;
                for (j = 0; j < 9; j = j + 1)
                    weight_schedule[i][j] <= 8'sd0;
            end
            for (i = 0; i < 9; i = i + 1)
                tap_addr_table[i] <= 32'd0;
        end else begin
            done <= 1'b0;
            if (cfg_fire) weight_mem[cfg_addr] <= cfg_data;
            if (start_fire) begin
                active <= 1'b1; addr_pending <= 1'b1; addr_ready <= 1'b0;
                req_pending <= 1'b0; product_pending <= 1'b0; tap_idx <= 4'd0;
                req_desc_valid <= 1'b0; req_desc_in_bounds <= 1'b0;
                req_desc_addr <= 32'd0; req_desc_tap_idx <= 4'd0;
                tap_bounds_mask <= 9'd0;
                pad_pending <= 1'b0; tap_ingress_valid <= 1'b0;
                tap_ingress_last <= 1'b0; tap_ingress_data <= 128'd0;
                tap_ingress_idx <= 4'd0;
                in_w <= start_in_w; in_h <= start_in_h; out_x <= start_out_x;
                out_y <= start_out_y; stride <= start_stride;
                metadata_reg <= start_metadata; out_metadata <= start_metadata;
                for (i = 0; i < 16; i = i + 1) begin
                    acc[i] <= 32'sd0;
                    tap_weight_reg[i] <= weight_mem[i*9];
                    for (j = 0; j < 9; j = j + 1)
                        weight_schedule[i][j] <= weight_mem[i*9+j];
                end
            end
            if (addr_pending) begin
                x_base_reg <= addr_x_product;
                y_row_reg <= addr_y_product;
                tap_bounds_mask <= tap_bounds_mask_calc;
                for (i = 0; i < 9; i = i + 1)
                    tap_addr_table[i] <= tap_addr_table_calc[i];
                addr_pending <= 1'b0; addr_ready <= 1'b1;
            end
            if (request_fire) req_pending <= 1'b1;
            if (response_fire) req_pending <= 1'b0;

            /* Fill one registered source descriptor.  The descriptor is
             * consumed directly by the source handshake, so tap_idx no
             * longer drives request_fire/req_pending combinationally. */
            if (active && addr_ready && !req_desc_valid && !req_pending &&
                !out_valid) begin
                req_desc_valid <= 1'b1;
                req_desc_in_bounds <= tap_in_bounds;
                req_desc_addr <= tap_addr_table[tap_idx];
                req_desc_tap_idx <= tap_idx;
                pad_pending <= !tap_in_bounds;
            end
            if (request_fire) begin
                req_desc_valid <= 1'b0;
                pad_pending <= 1'b0;
            end
            if (pad_fire)
                req_desc_valid <= 1'b0;
            if (pad_fire || response_fire)
                pad_pending <= 1'b0;
            if (product_pending) begin
                for (i = 0; i < 16; i = i + 1) begin
                    if (product_last)
                        out_raw_psum_vec[(i*32) +: 32] <=
                            acc[i] + {{16{dw_product[i][15]}}, dw_product[i]};
                    acc[i] <= acc[i] + {{16{dw_product[i][15]}}, dw_product[i]};
                end
                if (product_last) begin
                    out_valid <= 1'b1;
                    active <= 1'b0;
                    out_metadata <= metadata_reg;
                end
            end
            /* Tap data, tap number, and end-of-pixel marker are captured at
             * the event edge.  The DSP inputs below therefore see only the
             * registered ingress values and no response/pad fanout. */
            tap_ingress_valid <= tap_fire;
            if (tap_fire) begin
                tap_ingress_data <= tap_data;
                tap_ingress_idx <= tap_idx;
                tap_ingress_last <= (tap_idx == 4'd8);
                for (i = 0; i < 16; i = i + 1)
                    tap_weight_reg[i] <= weight_schedule[i][0];
                for (i = 0; i < 16; i = i + 1)
                    for (j = 0; j < 8; j = j + 1)
                        weight_schedule[i][j] <= weight_schedule[i][j+1];
            end else begin
                tap_ingress_last <= 1'b0;
            end
            product_pending <= tap_ingress_valid;
            product_last <= tap_ingress_valid && tap_ingress_last;
            if (tap_fire) begin
                if (tap_idx == 4'd8) begin
                    tap_idx <= 4'd0;
                    req_desc_valid <= 1'b0;
                    req_desc_in_bounds <= 1'b0;
                    pad_pending <= 1'b0;
                end else begin
                    tap_idx <= tap_idx + 1'b1;
                    req_desc_valid <= 1'b1;
                    req_desc_in_bounds <= next_tap_in_bounds;
                    req_desc_addr <= next_addr_i[31:0];
                    req_desc_tap_idx <= next_tap_idx_i[3:0];
                    pad_pending <= !next_tap_in_bounds;
                end
            end
            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
