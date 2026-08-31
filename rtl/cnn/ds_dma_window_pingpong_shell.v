`timescale 1ns/1ps
`default_nettype none

/*
 * Feasibility shell joining the native-word DMA writer to the window-reuse
 * depthwise scheduler.  This is intentionally not the production DS engine.
 * Each bank owns a complete ds_tile_dma_writer (and hence its own 128-bit
 * BRAM).  A small registered bridge copies one active-bank vector into the
 * scheduler's tile-local input RAM as four 32-bit commands.  The bridge is
 * also the explicit fence: a bank is only made READY by the writer's
 * registered fill completion and is only made FREE after scheduler done.
 *
 * The inactive writer can therefore run while the active bank is being
 * copied/consumed.  No global ready or live bank/address broadcast exists;
 * the selected fill and active bank are captured at their command edges.
 */
module ds_dma_window_pingpong_shell #(
    parameter integer LAYOUT_CIN = 16,
    parameter integer MAX_CIN = 128,
    parameter integer LANES = 16,
    parameter integer MAX_IN_H = 10,
    parameter integer MAX_IN_W = 10,
    parameter integer ADDR_WIDTH = 24,
    parameter integer EXTENT_WIDTH = 16,
    parameter integer LINEAR_ADDR_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,

    input wire fill_start_valid,
    output wire fill_start_ready,
    input wire fill_start_bank,
    input wire [3:0] fill_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill_base_byte_addr,
    input wire [EXTENT_WIDTH-1:0] fill_extent,
    output reg fill_done_valid,
    input wire fill_done_ready,
    output reg fill_done_bank,
    output reg [3:0] fill_done_epoch,

    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,

    input wire cfg_valid,
    output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,

    input wire compute_start_valid,
    output wire compute_start_ready,
    input wire compute_bank,
    input wire [3:0] compute_epoch,
    input wire [8:0] compute_channel_tile,
    input wire [15:0] compute_lane_mask,
    input wire compute_last_tile,
    output reg compute_done_valid,
    input wire compute_done_ready,
    output reg compute_done_bank,
    output reg [3:0] compute_done_epoch,

    output wire valid_out,
    input wire ready_out,
    output wire [7:0] out_pixel_idx,
    output wire [15:0] out_lane_mask,
    output wire signed [511:0] out_raw_vec,
    output wire signed [511:0] out_bias_vec,
    output wire signed [511:0] out_multiplier_vec,
    output wire [95:0] out_shift_vec,

    output reg [1:0] bank0_state,
    output reg [1:0] bank1_state,
    output wire compute_busy,
    output reg [31:0] active_read_count,
    output reg [31:0] scheduler_write_count,
    output wire [15:0] scheduler_buffer_read_count,
    output wire [15:0] scheduler_core_token_count,
    output wire [7:0] scheduler_output_count,
    output reg [31:0] overlap_cycles,
    output reg [31:0] stale_compute_count
);
    localparam [1:0] S_FREE = 2'd0;
    localparam [1:0] S_FILL = 2'd1;
    localparam [1:0] S_READY = 2'd2;
    localparam [1:0] S_ACTIVE = 2'd3;
    localparam integer FOOTPRINT_PIXELS = 100;

    reg [3:0] bank_epoch [0:1];
    reg fill_inflight;
    reg fill_bank_reg;
    reg active_bank_reg;
    reg [3:0] active_epoch_reg;
    reg compute_last_reg;

    wire dma0_start_ready, dma1_start_ready;
    wire dma0_done_valid, dma1_done_valid;
    wire dma0_done_bank, dma1_done_bank;
    wire [3:0] dma0_done_epoch, dma1_done_epoch;
    wire dma0_req_valid, dma1_req_valid;
    wire [ADDR_WIDTH-1:0] dma0_req_addr, dma1_req_addr;
    wire dma0_rd_valid, dma1_rd_valid;
    wire signed [127:0] dma0_rd_data, dma1_rd_data;
    wire dma0_busy, dma1_busy;
    wire [31:0] dma0_stale, dma1_stale;
    wire [31:0] dma0_issue, dma1_issue;

    wire fill0_start_valid = fill_start_valid && !fill_start_bank && fill_start_ready;
    wire fill1_start_valid = fill_start_valid &&  fill_start_bank && fill_start_ready;
    wire fill0_done_ready = fill_done_ready && !fill_done_bank;
    wire fill1_done_ready = fill_done_ready &&  fill_done_bank;

    assign fill_start_ready = rst_n && !fill_inflight && !fill_done_valid &&
        ((fill_start_bank ? bank1_state : bank0_state) == S_FREE) &&
        (fill_start_bank ? dma1_start_ready : dma0_start_ready);

    ds_tile_dma_writer #(
        .MAX_CIN(MAX_CIN), .LAYOUT_CIN(LAYOUT_CIN),
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W), .LANES(LANES),
        .ADDR_WIDTH(ADDR_WIDTH), .EXTENT_WIDTH(EXTENT_WIDTH),
        .LINEAR_ADDR_WIDTH(LINEAR_ADDR_WIDTH)
    ) u_dma0 (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill0_start_valid), .fill_start_ready(dma0_start_ready),
        .fill_bank(1'b0), .fill_epoch(fill_start_epoch),
        .fill_base_byte_addr(fill_base_byte_addr), .fill_extent(fill_extent),
        .mem_req_valid(dma0_req_valid), .mem_req_ready(mem_req_ready && !fill_bank_reg),
        .mem_req_addr(dma0_req_addr), .mem_resp_valid(mem_resp_valid && !fill_bank_reg),
        .mem_resp_data(mem_resp_data), .fill_done_valid(dma0_done_valid),
        .fill_done_ready(fill0_done_ready), .fill_done_bank(dma0_done_bank),
        .fill_done_epoch(dma0_done_epoch), .rd_en(active_rd_en && !active_bank_reg),
        .rd_pixel_idx(active_rd_pixel), .rd_channel_tile(active_rd_channel),
        .rd_valid(dma0_rd_valid), .rd_data_vector(dma0_rd_data), .busy(dma0_busy),
        .stale_resp_count(dma0_stale), .issue_count(dma0_issue),
        .response_count(), .write_count()
    );
    ds_tile_dma_writer #(
        .MAX_CIN(MAX_CIN), .LAYOUT_CIN(LAYOUT_CIN),
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W), .LANES(LANES),
        .ADDR_WIDTH(ADDR_WIDTH), .EXTENT_WIDTH(EXTENT_WIDTH),
        .LINEAR_ADDR_WIDTH(LINEAR_ADDR_WIDTH)
    ) u_dma1 (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill1_start_valid), .fill_start_ready(dma1_start_ready),
        .fill_bank(1'b1), .fill_epoch(fill_start_epoch),
        .fill_base_byte_addr(fill_base_byte_addr), .fill_extent(fill_extent),
        .mem_req_valid(dma1_req_valid), .mem_req_ready(mem_req_ready && fill_bank_reg),
        .mem_req_addr(dma1_req_addr), .mem_resp_valid(mem_resp_valid && fill_bank_reg),
        .mem_resp_data(mem_resp_data), .fill_done_valid(dma1_done_valid),
        .fill_done_ready(fill1_done_ready), .fill_done_bank(dma1_done_bank),
        .fill_done_epoch(dma1_done_epoch), .rd_en(active_rd_en && active_bank_reg),
        .rd_pixel_idx(active_rd_pixel), .rd_channel_tile(active_rd_channel),
        .rd_valid(dma1_rd_valid), .rd_data_vector(dma1_rd_data), .busy(dma1_busy),
        .stale_resp_count(dma1_stale), .issue_count(dma1_issue),
        .response_count(), .write_count()
    );

    assign mem_req_valid = fill_bank_reg ? dma1_req_valid : dma0_req_valid;
    assign mem_req_addr = fill_bank_reg ? dma1_req_addr : dma0_req_addr;

    /* Completion descriptors are muxed only after the writer has drained all
     * response/parser state.  Their bank and epoch are held in registers. */
    wire dma_done_any = dma0_done_valid || dma1_done_valid;

    /* Scheduler staging bridge.  The four vec4 writes are deliberately
     * serialized at the scheduler's existing write ABI; the source vector
     * read itself is one native 128-bit transaction. */
    localparam [2:0] C_IDLE = 3'd0, C_REQ = 3'd1, C_CAPTURE = 3'd2,
                     C_WRITE = 3'd3, C_ARM = 3'd4, C_RUN = 3'd5;
    reg [2:0] copy_state;
    reg [6:0] copy_pixel;
    reg [6:0] pending_pixel;
    reg [2:0] copy_chunk;
    reg [8:0] copy_channel_tile;
    reg [15:0] copy_lane_mask;
    reg signed [127:0] copy_vec;
    reg active_rd_en;
    reg [8:0] active_rd_pixel;
    reg [8:0] active_rd_channel;
    wire active_rd_valid = active_bank_reg ? dma1_rd_valid : dma0_rd_valid;
    wire signed [127:0] active_rd_data = active_bank_reg ? dma1_rd_data : dma0_rd_data;
    assign active_rd_en = (copy_state == C_REQ) ||
                          ((copy_state == C_WRITE) && (copy_chunk == 3) &&
                           (copy_pixel < FOOTPRINT_PIXELS-1));
    always @* begin
        /* On the last vec4 write of a pixel, issue the next read.  The read
         * address is therefore one pixel ahead of the write cursor; the
         * pending cursor below labels its synchronous response. */
        active_rd_pixel = ((copy_state == C_WRITE) && (copy_chunk == 3)) ?
                          (copy_pixel + 1'b1) : copy_pixel;
        active_rd_channel = copy_channel_tile;
    end

    wire sched_wr_vec4_en = (copy_state == C_WRITE);
    wire [LINEAR_ADDR_WIDTH-1:0] sched_wr_vec4_idx =
        (copy_pixel * MAX_CIN) + (copy_channel_tile * LANES) +
        (copy_chunk * 4);
    wire [31:0] sched_wr_vec4_data = copy_vec[(copy_chunk*32) +: 32];
    wire sched_start = (copy_state == C_ARM);
    wire sched_busy, sched_done;

    dw_window_reuse_scheduler #(
        .MAX_CIN(MAX_CIN), .MAX_IN_H(17), .MAX_IN_W(17), .LANES(LANES),
        .TILE_H(8), .TILE_W(8), .STRIDE(1),
        .LINEAR_ADDR_WIDTH(LINEAR_ADDR_WIDTH)
    ) u_sched (
        .clk(clk), .rst_n(rst_n),
        .wr_en(1'b0), .wr_linear_idx('0), .wr_data_int8('0),
        .wr_vec4_en(sched_wr_vec4_en), .wr_vec4_linear_idx(sched_wr_vec4_idx),
        .wr_vec4_data_int8(sched_wr_vec4_data),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .start(sched_start), .start_channel_tile(copy_channel_tile),
        .start_lane_mask(copy_lane_mask), .busy(sched_busy), .done(sched_done),
        .valid_out(valid_out), .ready_out(ready_out), .out_pixel_idx(out_pixel_idx),
        .out_lane_mask(out_lane_mask), .out_raw_vec(out_raw_vec),
        .out_bias_vec(out_bias_vec), .out_multiplier_vec(out_multiplier_vec),
        .out_shift_vec(out_shift_vec), .buffer_read_count(scheduler_buffer_read_count),
        .core_token_count(scheduler_core_token_count),
        .output_count(scheduler_output_count)
    );
    assign compute_start_ready = rst_n && !compute_done_valid &&
        (copy_state == C_IDLE) &&
        ((compute_bank ? bank1_state : bank0_state) == S_READY) &&
        (compute_epoch == (compute_bank ? bank_epoch[1] : bank_epoch[0]));
    assign compute_busy = (copy_state != C_IDLE) || sched_busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            bank0_state <= S_FREE;
            bank1_state <= S_FREE;
            bank_epoch[0] <= 4'd0;
            bank_epoch[1] <= 4'd0;
            fill_inflight <= 1'b0;
            fill_bank_reg <= 1'b0;
            fill_done_valid <= 1'b0;
            fill_done_bank <= 1'b0;
            fill_done_epoch <= 4'd0;
            copy_state <= C_IDLE;
            copy_pixel <= 0;
            pending_pixel <= 0;
            copy_chunk <= 0;
            copy_channel_tile <= 0;
            copy_lane_mask <= 0;
            copy_vec <= 0;
            active_bank_reg <= 0;
            active_epoch_reg <= 0;
            compute_last_reg <= 1'b1;
            compute_done_valid <= 1'b0;
            compute_done_bank <= 0;
            compute_done_epoch <= 0;
            active_read_count <= 0;
            scheduler_write_count <= 0;
            overlap_cycles <= 0;
            stale_compute_count <= 0;
        end else begin
            if (fill_done_valid && fill_done_ready)
                fill_done_valid <= 1'b0;
            if (fill_start_valid && fill_start_ready) begin
                fill_inflight <= 1'b1;
                fill_bank_reg <= fill_start_bank;
                if (fill_start_bank) begin
                    bank1_state <= S_FILL;
                    bank_epoch[1] <= fill_start_epoch;
                end else begin
                    bank0_state <= S_FILL;
                    bank_epoch[0] <= fill_start_epoch;
                end
            end
            if (dma_done_any && !fill_done_valid) begin
                fill_done_valid <= 1'b1;
                fill_done_bank <= dma1_done_valid;
                fill_done_epoch <= dma1_done_valid ? dma1_done_epoch : dma0_done_epoch;
                fill_inflight <= 1'b0;
                if (dma1_done_valid) bank1_state <= S_READY;
                else bank0_state <= S_READY;
            end
            if (compute_done_valid && compute_done_ready)
                compute_done_valid <= 1'b0;
            if (compute_start_valid && !compute_start_ready &&
                ((compute_bank ? bank1_state : bank0_state) == S_READY))
                stale_compute_count <= stale_compute_count + 1'b1;

            if (compute_start_valid && compute_start_ready) begin
                active_bank_reg <= compute_bank;
                active_epoch_reg <= compute_epoch;
                compute_last_reg <= compute_last_tile;
                copy_channel_tile <= compute_channel_tile;
                copy_lane_mask <= compute_lane_mask;
                copy_pixel <= 0;
                pending_pixel <= 0;
                copy_chunk <= 0;
                copy_state <= C_REQ;
                active_read_count <= 0;
                scheduler_write_count <= 0;
                if (compute_bank) bank1_state <= S_ACTIVE;
                else bank0_state <= S_ACTIVE;
            end

            if (active_rd_en && (copy_state == C_REQ ||
                (copy_state == C_WRITE && copy_chunk == 3)))
                active_read_count <= active_read_count + 1'b1;
            if (active_rd_en && (copy_state == C_REQ ||
                (copy_state == C_WRITE && copy_chunk == 3)))
                pending_pixel <= ((copy_state == C_WRITE) && (copy_chunk == 3)) ?
                                 (copy_pixel + 1'b1) : copy_pixel;

            if (copy_state == C_REQ)
                copy_state <= C_CAPTURE;
            if ((copy_state == C_CAPTURE) && active_rd_valid) begin
                copy_vec <= active_rd_data;
                copy_chunk <= 0;
                copy_pixel <= pending_pixel;
                copy_state <= C_WRITE;
            end
            if (copy_state == C_WRITE) begin
                scheduler_write_count <= scheduler_write_count + 1'b1;
                if (copy_chunk == 3) begin
                    if (copy_pixel == FOOTPRINT_PIXELS-1) begin
                        copy_state <= C_ARM;
                    end else begin
                        copy_state <= C_CAPTURE;
                    end
                end else begin
                    copy_chunk <= copy_chunk + 1'b1;
                end
            end
            if (copy_state == C_ARM)
                copy_state <= C_RUN;
            if (sched_done) begin
                compute_done_valid <= 1'b1;
                compute_done_bank <= active_bank_reg;
                compute_done_epoch <= active_epoch_reg;
                copy_state <= C_IDLE;
                if (active_bank_reg) begin
                    bank1_state <= compute_last_reg ? S_FREE : S_READY;
                    if (compute_last_reg) bank_epoch[1] <= 0;
                end else begin
                    bank0_state <= compute_last_reg ? S_FREE : S_READY;
                    if (compute_last_reg) bank_epoch[0] <= 0;
                end
            end
            if (compute_busy && (active_bank_reg ? dma0_busy : dma1_busy))
                overlap_cycles <= overlap_cycles + 1'b1;
        end
    end
endmodule

`default_nettype wire
