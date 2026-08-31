`timescale 1ns/1ps
`default_nettype none

/*
 * Integration shell for the group-ready partial-K prototype.
 *
 * Unlike the standalone prototype, this module does not preseed stream4
 * beats.  The source words pass through the real word-window DW producer and
 * its real four-lane requant adapter before entering the assembler.  The
 * producer is kept in STREAM4_ONLY mode so its legacy scratch sink is not in
 * the datapath under test.  This is a validation shell, not a production
 * replacement for cnn_layer_runner.
 */
module ds_group_ready_real_producer #(
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH = 8,
    parameter integer FIFO_DEPTH = 2,
    parameter integer USE_QUADLOCAL_CORE = 1,
    parameter integer USE_LOCAL_REQUANT = 1,
    parameter integer OUTPUT_HEIGHT = 1,
    parameter integer OUTPUT_WIDTH = 8,
    parameter integer MAX_PIXELS = 17,
    parameter integer MAX_CIN = 64,
    parameter integer MAX_BUNDLES = 8,
    parameter integer MAX_ROWS = 8,
    parameter integer MAX_GROUPS = 16,
    parameter integer DESC_DEPTH = 32
) (
    input wire clk, input wire rst_n,

    input wire start_valid, output wire start_ready,
    input wire [7:0] start_cin, input wire [7:0] start_pixels,
    input wire [7:0] start_cout, input wire start_bank,
    input wire [1:0] start_session, input wire [3:0] start_epoch,
    input wire weight_load_valid, output wire weight_load_ready,
    input wire [7:0] weight_load_k, input wire [63:0] weight_load_vec,
    output wire out_valid, input wire out_ready,
    output wire signed [2047:0] out_psum,
    output wire [7:0] out_pixel_mask, output wire [7:0] out_cout_mask,
    output wire [63:0] out_lane_mask, output wire [3:0] out_group_count,
    output wire done, output wire error,
    output wire [31:0] perf_total_cycles,
    output wire [31:0] perf_half_writes,
    output wire [31:0] perf_group_descriptors,
    output wire [31:0] perf_pw_tokens,
    output wire [31:0] perf_output_groups,
    output wire [31:0] perf_first_output_cycle,

    input wire fill_start_valid, output wire fill_start_ready,
    input wire fill_start_bank,
    input wire [EPOCH_WIDTH-1:0] fill_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill_start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] fill_start_word_count,
    output wire fill_done_valid, input wire fill_done_ready,
    output wire fill_done_bank,
    output wire [EPOCH_WIDTH-1:0] fill_done_epoch,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,

    input wire cfg_valid, output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,

    input wire dw_job_valid, output wire dw_job_ready,
    input wire dw_source_bank,
    input wire [EPOCH_WIDTH-1:0] dw_source_epoch,
    input wire [ADDR_WIDTH-1:0] dw_source_base_addr,
    input wire [15:0] dw_source_lane_mask,
    input wire [1:0] dw_source_stride,
    input wire [7:0] dw_footprint_height,
    input wire [7:0] dw_footprint_width,
    input wire [7:0] dw_footprint_pitch,
    input wire dw_target_bank,
    input wire [EPOCH_WIDTH-1:0] dw_target_epoch,
    input wire [TILE_WIDTH-1:0] dw_target_tile,
    input wire [2:0] dw_channel_group,
    input wire [3:0] dw_group_count,
    input wire [7:0] dw_pixel_count,
    input wire [31:0] dw_output_zero_point,
    input wire [31:0] dw_activation_min,
    input wire [31:0] dw_activation_max,
    output wire dw_done_valid, input wire dw_done_ready,
    output wire dw_done_bank,
    output wire [EPOCH_WIDTH-1:0] dw_done_epoch,
    output wire [TILE_WIDTH-1:0] dw_done_tile,
    output wire [2:0] dw_done_group
);
    reg [2:0] producer_group_q;
    reg producer_group_valid_q;
    wire producer_group_fire = dw_job_valid && dw_job_ready;

    wire stream4_valid;
    wire stream4_ready;
    wire [5:0] stream4_pixel;
    wire [1:0] stream4_lane_base;
    wire [31:0] stream4_data;
    wire [3:0] stream4_lane_mask;

    ds_word_window_dw_tagless_stream4_4x8 #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .ADDR_WIDTH(ADDR_WIDTH), .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH),
        .EPOCH_WIDTH(EPOCH_WIDTH), .TILE_WIDTH(TILE_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH), .USE_QUADLOCAL_CORE(USE_QUADLOCAL_CORE),
        .USE_LOCAL_REQUANT(USE_LOCAL_REQUANT), .STREAM4_ONLY(1),
        .OUTPUT_HEIGHT(OUTPUT_HEIGHT)
    ) u_real_producer (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr),
        .fill_start_word_count(fill_start_word_count),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .dw_job_valid(dw_job_valid),
        .dw_job_ready(dw_job_ready), .dw_source_bank(dw_source_bank),
        .dw_source_epoch(dw_source_epoch), .dw_source_base_addr(dw_source_base_addr),
        .dw_source_lane_mask(dw_source_lane_mask), .dw_source_stride(dw_source_stride),
        .dw_footprint_height(dw_footprint_height),
        .dw_footprint_width(dw_footprint_width), .dw_footprint_pitch(dw_footprint_pitch),
        .dw_target_bank(dw_target_bank), .dw_target_epoch(dw_target_epoch),
        .dw_target_tile(dw_target_tile), .dw_channel_group(dw_channel_group),
        .dw_group_count(dw_group_count), .dw_pixel_count(dw_pixel_count),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min), .dw_activation_max(dw_activation_max),
        .dw_done_valid(dw_done_valid), .dw_done_ready(dw_done_ready),
        .dw_done_bank(dw_done_bank), .dw_done_epoch(dw_done_epoch),
        .dw_done_tile(dw_done_tile), .dw_done_group(dw_done_group),
        .read_acquire_valid(1'b0), .read_acquire_ready(), .read_bank(1'b0),
        .read_epoch('0), .read_tile('0), .read_valid(1'b0), .read_ready(),
        .read_channel_idx(7'd0), .read_pixel_base(6'd0), .read_out_valid(),
        .read_out_ready(1'b1), .read_out_data(), .read_out_lane_mask(),
        .read_release_valid(1'b0), .read_release_ready(), .scratch0_state(),
        .scratch1_state(), .dw_write_count(), .overlap_cycles(), .read_count(),
        .stream4_valid(stream4_valid), .stream4_ready(stream4_ready),
        .stream4_pixel(stream4_pixel), .stream4_lane_base(stream4_lane_base),
        .stream4_data(stream4_data), .stream4_lane_mask(stream4_lane_mask)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            producer_group_q <= 3'd0;
            producer_group_valid_q <= 1'b0;
        end else begin
            if (producer_group_fire) begin
                producer_group_q <= dw_channel_group;
                producer_group_valid_q <= 1'b1;
            end
            if (dw_done_valid && dw_done_ready)
                producer_group_valid_q <= 1'b0;
        end
    end

    ds_group_ready_partial_k_pipeline #(
        .MAX_PIXELS(MAX_PIXELS), .MAX_CIN(MAX_CIN), .MAX_BUNDLES(MAX_BUNDLES),
        .MAX_ROWS(MAX_ROWS), .MAX_GROUPS(MAX_GROUPS), .DESC_DEPTH(DESC_DEPTH),
        .FENCE_MODE(0)
    ) u_group_ready (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid), .start_ready(start_ready),
        .start_cin(start_cin), .start_pixels(start_pixels), .start_cout(start_cout),
        .start_bank(start_bank), .start_session(start_session), .start_epoch(start_epoch),
        .stream_valid(stream4_valid), .stream_ready(stream4_ready),
        .stream_pixel(stream4_pixel), .stream_bundle(producer_group_q),
        .stream_lane_base(stream4_lane_base), .stream_data(stream4_data),
        .stream_lane_mask(stream4_lane_mask), .weight_load_valid(weight_load_valid),
        .weight_load_ready(weight_load_ready), .weight_load_k(weight_load_k),
        .weight_load_vec(weight_load_vec), .out_valid(out_valid), .out_ready(out_ready),
        .out_psum(out_psum), .out_pixel_mask(out_pixel_mask),
        .out_cout_mask(out_cout_mask), .out_lane_mask(out_lane_mask),
        .out_group_count(out_group_count), .done(done), .error(error),
        .perf_total_cycles(perf_total_cycles), .perf_half_writes(perf_half_writes),
        .perf_group_descriptors(perf_group_descriptors), .perf_pw_tokens(perf_pw_tokens),
        .perf_output_groups(perf_output_groups),
        .perf_first_output_cycle(perf_first_output_cycle)
    );
endmodule

`default_nettype wire
