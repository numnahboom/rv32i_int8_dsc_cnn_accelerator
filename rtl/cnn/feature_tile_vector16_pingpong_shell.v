`timescale 1ns/1ps
`default_nettype none

/*
 * Ownership-aware two-bank feature-tile shell.
 *
 * feature_tile_pingpong_ctrl owns the lifetime of each tile.  The two
 * feature_tile_vector16_bank instances are deliberately kept as dumb
 * storage: a word command is accepted only for the controller's FILLING
 * bank and a vector request is accepted only for its ACTIVE bank.  The
 * selected read bank is registered with the request, so a consume/release
 * command cannot change the response mux while a synchronous read is in
 * flight.  The storage has no external SRAM response protocol or datapath.
 *
 * The five ownership channels below are the controller ABI, kept separate so
 * a producer can fill one bank while a consumer drains the other.  Descriptor
 * responses are held by the controller until their ready input is asserted.
 */
module feature_tile_vector16_pingpong_shell #(
    parameter integer MAX_CHANNELS = 48,
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer BANKS = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TAG_WIDTH = 8,
    parameter integer EXTENT_WIDTH = 16,
    parameter integer BYTE_ADDR_WIDTH =
        ((MAX_IN_H*MAX_IN_W*MAX_CHANNELS + 3) > 1) ?
        $clog2(MAX_IN_H*MAX_IN_W*MAX_CHANNELS + 3) : 1,
    parameter integer PIXEL_ADDR_WIDTH =
        ((MAX_IN_H*MAX_IN_W) > 1) ? $clog2(MAX_IN_H*MAX_IN_W) : 1,
    parameter integer GROUP_ADDR_WIDTH =
        ((((MAX_CHANNELS + BANKS - 1) / BANKS)) > 1) ?
        $clog2((MAX_CHANNELS + BANKS - 1) / BANKS) : 1,
    parameter integer BANK_ADDR_WIDTH =
        (((MAX_IN_H*MAX_IN_W*((MAX_CHANNELS + BANKS - 1) / BANKS)) > 1) ?
        $clog2(MAX_IN_H*MAX_IN_W*((MAX_CHANNELS + BANKS - 1) / BANKS)) : 1)
) (
    input wire clk,
    input wire rst_n,

    input wire fill_start_valid,
    output wire fill_start_ready,
    input wire fill_start_bank,
    input wire [EPOCH_WIDTH-1:0] fill_start_epoch,
    input wire [TAG_WIDTH-1:0] fill_start_tag,
    input wire [EXTENT_WIDTH-1:0] fill_start_extent,
    output wire fill_start_resp_valid,
    input wire fill_start_resp_ready,
    output wire fill_start_resp_ok,
    output wire [2:0] fill_start_resp_error,

    input wire fill_done_valid,
    output wire fill_done_ready,
    input wire fill_done_bank,
    input wire [EPOCH_WIDTH-1:0] fill_done_epoch,
    input wire [TAG_WIDTH-1:0] fill_done_tag,
    input wire [EXTENT_WIDTH-1:0] fill_done_extent,
    output wire fill_done_desc_valid,
    input wire fill_done_desc_ready,
    output wire fill_done_desc_bank,
    output wire [EPOCH_WIDTH-1:0] fill_done_desc_epoch,
    output wire [TAG_WIDTH-1:0] fill_done_desc_tag,
    output wire [EXTENT_WIDTH-1:0] fill_done_desc_extent,
    output wire fill_done_ok,
    output wire [2:0] fill_done_error,

    input wire acquire_valid,
    output wire acquire_ready,
    input wire acquire_bank,
    input wire [EPOCH_WIDTH-1:0] acquire_epoch,
    input wire [TAG_WIDTH-1:0] acquire_tag,
    input wire [EXTENT_WIDTH-1:0] acquire_extent,
    output wire active_desc_valid,
    input wire active_desc_ready,
    output wire active_desc_bank,
    output wire [EPOCH_WIDTH-1:0] active_desc_epoch,
    output wire [TAG_WIDTH-1:0] active_desc_tag,
    output wire [EXTENT_WIDTH-1:0] active_desc_extent,
    output wire acquire_ok,
    output wire [2:0] acquire_error,

    input wire consume_done_valid,
    output wire consume_done_ready,
    input wire consume_done_bank,
    input wire [EPOCH_WIDTH-1:0] consume_done_epoch,
    input wire [TAG_WIDTH-1:0] consume_done_tag,
    input wire [EXTENT_WIDTH-1:0] consume_done_extent,
    output wire consume_done_resp_valid,
    input wire consume_done_resp_ready,
    output wire consume_done_ok,
    output wire [2:0] consume_done_error,

    input wire release_valid,
    output wire release_ready,
    input wire release_bank,
    input wire [EPOCH_WIDTH-1:0] release_epoch,
    input wire [TAG_WIDTH-1:0] release_tag,
    input wire [EXTENT_WIDTH-1:0] release_extent,
    output wire release_resp_valid,
    input wire release_resp_ready,
    output wire release_ok,
    output wire [2:0] release_error,

    /* Storage commands.  wr_bank identifies the controller FILLING bank. */
    input wire wr_valid,
    output wire wr_ready,
    // True when the selected bank's accepted write command has fully
    // serialized through the storage primitive.
    output wire wr_drain_ready,
    input wire wr_bank,
    input wire [BYTE_ADDR_WIDTH-1:0] wr_base_byte_addr,
    input wire [31:0] wr_data,
    input wire [3:0] wr_byte_en,

    /* Reads always target the controller ACTIVE bank; no bank selector is
     * exposed to prevent accidental reads from a filling bank. */
    input wire rd_req_valid,
    output wire rd_req_ready,
    input wire [PIXEL_ADDR_WIDTH-1:0] rd_pixel_idx,
    input wire [GROUP_ADDR_WIDTH-1:0] rd_channel_group,
    input wire [BANKS-1:0] rd_lane_mask,
    input wire [TAG_WIDTH-1:0] rd_tag,
    input wire rd_use_lane_addr,
    input wire [BANKS*BANK_ADDR_WIDTH-1:0] rd_lane_addr,
    output wire rd_resp_valid,
    input wire rd_resp_ready,
    output wire [BANKS*8-1:0] rd_data_vector,
    output wire [BANKS-1:0] rd_resp_lane_mask,
    output wire [TAG_WIDTH-1:0] rd_resp_tag,

    output wire [2:0] bank0_state,
    output wire [2:0] bank1_state,
    output wire fill_active,
    output wire active_valid,
    output wire fill_bank,
    output wire active_bank
);
    localparam [2:0] S_FILL = 3'd1;
    localparam [2:0] S_ACTIVE = 3'd3;

    wire b0_wr_ready, b1_wr_ready;
    wire b0_wr_drain_ready, b1_wr_drain_ready;
    wire b0_rd_ready, b1_rd_ready;
    wire b0_rd_valid, b1_rd_valid;
    wire [BANKS*8-1:0] b0_rd_data, b1_rd_data;
    wire [BANKS-1:0] b0_rd_mask, b1_rd_mask;
    wire [TAG_WIDTH-1:0] b0_rd_tag, b1_rd_tag;
    reg rd_bank_reg;
    wire fill0 = (bank0_state == S_FILL);
    wire fill1 = (bank1_state == S_FILL);
    wire active0 = (bank0_state == S_ACTIVE);
    wire active1 = (bank1_state == S_ACTIVE);
    wire rd_fire = rd_req_valid && rd_req_ready;

    assign fill_active = fill0 || fill1;
    assign active_valid = active0 || active1;
    assign fill_bank = fill1;
    assign active_bank = active1;

    feature_tile_pingpong_ctrl #(
        .EPOCH_WIDTH(EPOCH_WIDTH), .TAG_WIDTH(TAG_WIDTH),
        .EXTENT_WIDTH(EXTENT_WIDTH)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_tag(fill_start_tag), .fill_start_extent(fill_start_extent),
        .fill_start_resp_valid(fill_start_resp_valid),
        .fill_start_resp_ready(fill_start_resp_ready),
        .fill_start_resp_ok(fill_start_resp_ok),
        .fill_start_resp_error(fill_start_resp_error),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .fill_done_tag(fill_done_tag), .fill_done_extent(fill_done_extent),
        .fill_done_desc_valid(fill_done_desc_valid),
        .fill_done_desc_ready(fill_done_desc_ready),
        .fill_done_desc_bank(fill_done_desc_bank),
        .fill_done_desc_epoch(fill_done_desc_epoch),
        .fill_done_desc_tag(fill_done_desc_tag),
        .fill_done_desc_extent(fill_done_desc_extent),
        .fill_done_ok(fill_done_ok), .fill_done_error(fill_done_error),
        .acquire_valid(acquire_valid), .acquire_ready(acquire_ready),
        .acquire_bank(acquire_bank), .acquire_epoch(acquire_epoch),
        .acquire_tag(acquire_tag), .acquire_extent(acquire_extent),
        .active_desc_valid(active_desc_valid),
        .active_desc_ready(active_desc_ready),
        .active_desc_bank(active_desc_bank),
        .active_desc_epoch(active_desc_epoch),
        .active_desc_tag(active_desc_tag),
        .active_desc_extent(active_desc_extent), .acquire_ok(acquire_ok),
        .acquire_error(acquire_error),
        .consume_done_valid(consume_done_valid),
        .consume_done_ready(consume_done_ready),
        .consume_done_bank(consume_done_bank),
        .consume_done_epoch(consume_done_epoch),
        .consume_done_tag(consume_done_tag),
        .consume_done_extent(consume_done_extent),
        .consume_done_resp_valid(consume_done_resp_valid),
        .consume_done_resp_ready(consume_done_resp_ready),
        .consume_done_ok(consume_done_ok),
        .consume_done_error(consume_done_error),
        .release_valid(release_valid), .release_ready(release_ready),
        .release_bank(release_bank), .release_epoch(release_epoch),
        .release_tag(release_tag), .release_extent(release_extent),
        .release_resp_valid(release_resp_valid),
        .release_resp_ready(release_resp_ready), .release_ok(release_ok),
        .release_error(release_error), .bank0_state(bank0_state),
        .bank1_state(bank1_state)
    );

    /* A command is rejected by backpressure unless its selected bank is
     * FILLING/ACTIVE.  The bank module supplies the additional ready bubble
     * required while serializing an unaligned three-channel word. */
    assign wr_ready = rst_n &&
        (wr_bank ? (fill1 && b1_wr_ready) : (fill0 && b0_wr_ready));
    assign wr_drain_ready = rst_n &&
        (wr_bank ? b1_wr_drain_ready : b0_wr_drain_ready);
    assign rd_req_ready = rst_n &&
        (active_bank ? (active1 && b1_rd_ready) : (active0 && b0_rd_ready));

    feature_tile_vector16_bank #(
        .MAX_CHANNELS(MAX_CHANNELS), .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .BANKS(BANKS), .TAG_WIDTH(TAG_WIDTH),
        .BYTE_ADDR_WIDTH(BYTE_ADDR_WIDTH), .PIXEL_ADDR_WIDTH(PIXEL_ADDR_WIDTH),
        .GROUP_ADDR_WIDTH(GROUP_ADDR_WIDTH), .BANK_ADDR_WIDTH(BANK_ADDR_WIDTH)
    ) u_bank0 (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid && wr_bank == 1'b0 && fill0), .wr_ready(b0_wr_ready),
        .wr_drain_ready(b0_wr_drain_ready),
        .wr_base_byte_addr(wr_base_byte_addr), .wr_data(wr_data),
        .wr_byte_en(wr_byte_en),
        .rd_req_valid(rd_req_valid && active0), .rd_req_ready(b0_rd_ready),
        .rd_pixel_idx(rd_pixel_idx), .rd_channel_group(rd_channel_group),
        .rd_lane_mask(rd_lane_mask), .rd_tag(rd_tag),
        .rd_use_lane_addr(rd_use_lane_addr), .rd_lane_addr(rd_lane_addr),
        .rd_resp_valid(b0_rd_valid), .rd_resp_ready(rd_resp_ready && !rd_bank_reg),
        .rd_data_vector(b0_rd_data), .rd_resp_lane_mask(b0_rd_mask),
        .rd_resp_tag(b0_rd_tag)
    );
    feature_tile_vector16_bank #(
        .MAX_CHANNELS(MAX_CHANNELS), .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .BANKS(BANKS), .TAG_WIDTH(TAG_WIDTH),
        .BYTE_ADDR_WIDTH(BYTE_ADDR_WIDTH), .PIXEL_ADDR_WIDTH(PIXEL_ADDR_WIDTH),
        .GROUP_ADDR_WIDTH(GROUP_ADDR_WIDTH), .BANK_ADDR_WIDTH(BANK_ADDR_WIDTH)
    ) u_bank1 (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid && wr_bank == 1'b1 && fill1), .wr_ready(b1_wr_ready),
        .wr_drain_ready(b1_wr_drain_ready),
        .wr_base_byte_addr(wr_base_byte_addr), .wr_data(wr_data),
        .wr_byte_en(wr_byte_en),
        .rd_req_valid(rd_req_valid && active1), .rd_req_ready(b1_rd_ready),
        .rd_pixel_idx(rd_pixel_idx), .rd_channel_group(rd_channel_group),
        .rd_lane_mask(rd_lane_mask), .rd_tag(rd_tag),
        .rd_use_lane_addr(rd_use_lane_addr), .rd_lane_addr(rd_lane_addr),
        .rd_resp_valid(b1_rd_valid), .rd_resp_ready(rd_resp_ready && rd_bank_reg),
        .rd_data_vector(b1_rd_data), .rd_resp_lane_mask(b1_rd_mask),
        .rd_resp_tag(b1_rd_tag)
    );

    /* The active-bank selector is part of the registered read transaction,
     * not a live ownership mux.  This is the safe swap/fence boundary. */
    always @(posedge clk) begin
        if (!rst_n)
            rd_bank_reg <= 1'b0;
        else if (rd_fire)
            rd_bank_reg <= active_bank;
    end

    assign rd_resp_valid = rd_bank_reg ? b1_rd_valid : b0_rd_valid;
    assign rd_data_vector = rd_bank_reg ? b1_rd_data : b0_rd_data;
    assign rd_resp_lane_mask = rd_bank_reg ? b1_rd_mask : b0_rd_mask;
    assign rd_resp_tag = rd_bank_reg ? b1_rd_tag : b0_rd_tag;

`ifndef SYNTHESIS
    initial begin
        if (BANKS != 16) $error("feature tile shell requires BANKS=16");
        if (MAX_CHANNELS < 1 || MAX_IN_H < 1 || MAX_IN_W < 1)
            $error("feature tile dimensions must be positive");
    end
`endif
endmodule

`default_nettype wire
