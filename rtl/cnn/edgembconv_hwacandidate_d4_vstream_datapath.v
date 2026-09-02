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
module edgembconv_hwacandidate_d4_vstream_datapath (
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
    reg rq_pending_reg;

    wire output_space = !out_valid || out_ready;
    wire pw_can_accept = pw112_ready && pool_ready_in && !pw_done_pending &&
                         output_space;
    /* The shared pool exposes its result one cycle before this composite
     * boundary copies it into the common output register.  Do not accept a
     * replacement RQ transaction on that copy edge: pool_ready_in is allowed
     * to be high with ready_out=1, but accepting here would re-use the old
     * controller operands while the visible result still belongs to the
     * preceding transaction (base4 consequently observed base0).  This
     * single-cycle fence preserves the pool transaction lifetime and leaves
     * all arithmetic/quantization semantics unchanged. */
    /* The block controller has one RQ context register (rq_base), so expose
     * a one-outstanding RQ contract even though the shared pool is elastic.
     * Without this fence the controller would replay the same rq_base while
     * the nine-stage pool is draining its first result. */
    wire rq_can_accept = pool_ready_in && output_space && !pw_done_pending &&
                         !pool_valid_out;
    assign op_ready = rst_n &&
        (!mode_lock_valid || (mode_lock_rq == op_mode_rq)) &&
        (op_mode_rq ? rq_can_accept : pw_can_accept);
    assign pool_valid_in = op_valid && op_ready;

    edgembconv_hwacandidate_d4_vstream_pw112 u_pw112 (
        .clk(clk), .rst_n(rst_n), .valid_in(pool_valid_in && !op_mode_rq),
        .ready_in(pw112_ready), .first_k(pw_first_k), .last_k(pw_last_k),
        .k_idx(pw_k_idx), .pixel_mask(pw_pixel_mask[6:0]),
        .cout_mask(pw_cout_mask), .act_vec(pw_act_7pixel_vec),
        .wgt_vec(pw_wgt_vec), .ready_out(1'b1), .valid_out(pw112_valid),
        .psum_out(pw112_psum), .lane_mask_out(pw112_mask)
    );

    /* Existing D4 pool: its 16 DSPs are reused in PW or exact RQ mode. */
    edgembconv_hwacandidate_d4_vstream_elastic_rq_pool u_pool (
        .clk(clk), .rst_n(rst_n), .mode_rq(op_mode_rq),
        /* Keep ready/valid acyclic: the elastic pool observes the offered
         * stream valid directly, while pool_valid_in remains the accepted
         * transaction pulse used by the dedicated island/tag pipeline. */
        .valid_in(op_valid), .ready_in(pool_ready_in),
        .rq_acc_vec(rq_acc_vec), .rq_multiplier_vec(rq_multiplier_vec),
        .rq_shift_vec(rq_shift_vec), .rq_zero_point_vec(rq_zero_point_vec),
        .rq_min_vec(rq_min_vec), .rq_max_vec(rq_max_vec),
        .pw_act_vec(pw_act_pool_vec), .pw_wgt_vec(pw_wgt_vec),
        .metadata_in(metadata_in), .valid_out(pool_valid_out),
        .ready_out(1'b1), .mode_rq_out(pool_mode_out),
        .pw_product_vec(pool_pw_product), .rq_product_vec(pool_rq_product),
        .rq_result_vec(pool_rq_result), .metadata_out(pool_metadata)
    );

    /* The pool has a registered DSP boundary.  These tags are delayed to the
     * exact edge at which its visible output is consumed. */
    reg pool_first_d1, pool_first_d2, pool_last_d1, pool_last_d2;
    reg pool_pixel_d1, pool_pixel_d2;
    reg [15:0] pool_cout_d1, pool_cout_d2;
    reg signed [16*32-1:0] pool_acc;
    wire pool_pw_event = pool_valid_out && !pool_mode_out;
    /* The elastic pool carries the controller's k index through all nine
     * stages.  Use that aligned metadata rather than the two-cycle tag delay
     * used by the legacy fixed-latency pool. */
    wire pool_pw_first_event = pool_pw_event && (pool_metadata[5:0] == 0);
    wire pool_pw_last_event = pool_pw_event &&
        (pool_metadata[5:0] == (pool_metadata[19] ? 6'd31 : 6'd15));
    wire [15:0] pool_mask_event = 16'hffff;
    /* The dedicated 112-lane island has one extra observable register edge
     * relative to the shared pool. Hold the pool final until that edge. */
    reg pool_final_pending;
    reg signed [16*32-1:0] pool_final_hold;
    reg [15:0] pool_final_mask_hold;
    reg [31:0] pool_final_metadata_hold;
    reg pw112_final_pending;
    reg signed [112*32-1:0] pw112_final_hold;
    reg [111:0] pw112_final_mask_hold;

    integer pi;
    always @(posedge clk) begin
        if (!rst_n) begin
            mode_lock_valid <= 1'b0;
            mode_lock_rq <= 1'b0;
            pw_done_pending <= 1'b0;
            rq_pending_reg <= 1'b0;
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
            pw112_final_pending <= 1'b0;
            pw112_final_mask_hold <= 112'd0;
            out_valid <= 1'b0;
            out_mode_rq <= 1'b0;
            pw_psum_vec <= 4096'sd0;
            pw_lane_mask <= 128'd0;
            rq_product_vec <= 256'sd0;
            rq_result_vec <= 32'sd0;
            metadata_out <= 32'd0;
            for (pi = 0; pi < 16; pi = pi + 1)
                pool_acc[(pi*32) +: 32] <= 32'sd0;
            for (pi = 0; pi < 16; pi = pi + 1)
                pool_final_hold[(pi*32) +: 32] <= 32'sd0;
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
                    if (pool_pw_first_event)
                        pool_acc[(pi*32) +: 32] <= {{16{pool_pw_product[(pi*16)+15]}},
                                         pool_pw_product[(pi*16) +: 16]};
                    else
                        pool_acc[(pi*32) +: 32] <= pool_acc[(pi*32) +: 32] +
                            {{16{pool_pw_product[(pi*16)+15]}},
                             pool_pw_product[(pi*16) +: 16]};
                end
            end

            if (pool_pw_last_event) begin
                for (pi = 0; pi < 16; pi = pi + 1)
                    pool_final_hold[(pi*32) +: 32] <= pool_pw_first_event
                        ? {{16{pool_pw_product[(pi*16)+15]}},
                           pool_pw_product[(pi*16) +: 16]}
                        : pool_acc[(pi*32) +: 32] +
                          {{16{pool_pw_product[(pi*16)+15]}},
                           pool_pw_product[(pi*16) +: 16]};
                pool_final_mask_hold <= pool_mask_event;
                pool_final_metadata_hold <= pool_metadata;
                pool_final_pending <= 1'b1;
            end

            if (pw112_valid) begin
                for (pi = 0; pi < 112; pi = pi + 1)
                    pw112_final_hold[(pi*32) +: 32] <= pw112_psum[(pi*32) +: 32];
                pw112_final_mask_hold <= pw112_mask;
                pw112_final_pending <= 1'b1;
            end

            if (pool_final_pending && pw112_final_pending) begin
                for (pi = 0; pi < 112; pi = pi + 1)
                    pw_psum_vec[(pi*32) +: 32] <= pw112_final_hold[(pi*32) +: 32];
                for (pi = 0; pi < 16; pi = pi + 1)
                    pw_psum_vec[((112+pi)*32) +: 32] <=
                        pool_final_hold[(pi*32) +: 32];
                pw_lane_mask <= {pool_final_mask_hold, pw112_final_mask_hold};
                metadata_out <= pool_final_metadata_hold;
                out_mode_rq <= 1'b0;
                out_valid <= 1'b1;
                pool_final_pending <= 1'b0;
                pw112_final_pending <= 1'b0;
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
                rq_pending_reg <= 1'b0;
            end

            if (pool_valid_in) begin
                if (!mode_lock_valid) begin
                    mode_lock_valid <= 1'b1;
                    mode_lock_rq <= op_mode_rq;
                end
                if (!op_mode_rq && pw_last_k)
                    pw_done_pending <= 1'b1;
                if (op_mode_rq)
                    rq_pending_reg <= 1'b1;
            end
        end
    end

    edgembconv_hwacandidate_d4_vstream_dw16_legacy_adapter u_dw16 (
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


/*
 * Legacy-shaped adapter for the standalone 16-DSP depthwise tile.
 * The controller schedules one output pixel and one sixteen-channel group
 * per transaction.  The tile primitive still owns the complete 3x3 tap
 * stream and its sixteen DW DSPs; this adapter only translates the narrow
 * controller ABI and keeps the local scratch response decoupled.
 */
module edgembconv_hwacandidate_d4_vstream_dw16_legacy_adapter (
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
    input wire out_ready, output wire out_valid,
    output wire signed [511:0] out_raw_psum_vec,
    output wire [31:0] out_metadata, output wire done
);
    wire tile_done_valid;
    wire [3:0] tile_done_epoch;
    wire [127:0] tile_out_data;
    wire [7:0] tile_out_pixel;
    wire [7:0] tile_out_channel;
    wire [15:0] tile_out_mask;
    wire tile_out_first, tile_out_last;
    wire tile_busy;
    wire [31:0] tile_cycle_count, tile_tap_count, tile_source_count;
    wire [31:0] tile_source_stall, tile_output_stall, tile_protocol_errors;
    wire tile_src_req_valid, tile_src_req_ready, tile_src_resp_ready;
    wire [31:0] tile_src_req_addr;
    /* The legacy controller has one bit of read-pending state and therefore
     * cannot represent response+next-request on one edge.  Insert a single
     * bubble at that boundary; the tile itself remains independently
     * decoupled and the accepted request/response ordering is exact. */
    assign tile_src_req_ready = src_req_ready &&
                                !(src_resp_valid && tile_src_resp_ready);
    assign src_req_valid = tile_src_req_valid;
    assign src_req_addr = tile_src_req_addr;
    assign src_resp_ready = tile_src_resp_ready;
    edgembconv_hwacandidate_d4_dw16_stream_tile u_tile (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_kind(2'd0), .cfg_addr(cfg_addr), .cfg_data({24'd0,cfg_data}),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_in_w(start_in_w), .start_in_h(start_in_h),
        .start_out_w(8'd16), .start_out_h(8'd16),
        .start_stride(start_stride), .start_tile_x(start_out_x),
        .start_tile_y(start_out_y), .start_tile_w(4'd1),
        .start_tile_h(4'd1), .start_channel_base(8'd0),
        .start_channel_mask(16'hffff), .start_padding_value(8'sd0),
        .start_output_zero_point(32'sd0),
        .start_activation_min(-32'sd2147483647),
        .start_activation_max(32'sd2147483647),
        .start_epoch(4'd0), .start_metadata(start_metadata),
        .src_req_valid(tile_src_req_valid), .src_req_ready(tile_src_req_ready),
        .src_req_addr(tile_src_req_addr), .src_req_pixel_idx(),
        .src_req_tap_idx(), .src_req_first_tap(), .src_req_last_tap(),
        .src_req_metadata(), .src_resp_valid(src_resp_valid),
        .src_resp_ready(tile_src_resp_ready), .src_resp_data(src_resp_data),
        .out_ready(out_ready), .out_valid(out_valid),
        .out_data_vec(tile_out_data), .out_raw_psum_vec(out_raw_psum_vec),
        .out_pixel_idx(tile_out_pixel), .out_channel_base(tile_out_channel),
        .out_lane_mask(tile_out_mask), .out_first(tile_out_first),
        .out_last(tile_out_last), .out_metadata(out_metadata),
        .done_valid(tile_done_valid), .done_ready(1'b1),
        .done_epoch(tile_done_epoch), .busy(tile_busy),
        .cycle_count(tile_cycle_count), .tap_count(tile_tap_count),
        .source_word_count(tile_source_count),
        .source_stall_count(tile_source_stall),
        .output_stall_count(tile_output_stall),
        .protocol_errors(tile_protocol_errors)
    );
    assign done = tile_done_valid;
endmodule
`default_nettype wire
