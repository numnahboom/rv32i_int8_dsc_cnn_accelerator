`timescale 1ns/1ps
`default_nettype none

/*
 * Small, reusable channel-interleaved feature tile store.
 *
 * The logical byte address is pixel-major (channels contiguous), while the
 * channel number is interleaved across BANKS byte memories:
 *   bank       = channel % BANKS
 *   bank_addr  = pixel * ceil(MAX_CHANNELS/BANKS) + channel / BANKS
 *
 * Consequently a pixel/channel-group read reads one byte from every bank in
 * one synchronous cycle (including a partially populated tail group).  The
 * write port accepts an unaligned native word and scatters its enabled bytes
 * to the corresponding banks.  Both read data and its metadata are held in a
 * one-entry response queue, so a stalled consumer cannot lose a vector.
 *
 * This is intentionally only storage.  It does not assign ownership to a
 * bank, perform ping-pong/fence sequencing, or interpret the tag.
 */
module feature_tile_vector16_bank #(
    parameter integer MAX_CHANNELS = 48,
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer BANKS = 16,
    parameter integer TAG_WIDTH = 8,
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
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         wr_valid,
    output wire                         wr_ready,
    input  wire [BYTE_ADDR_WIDTH-1:0]   wr_base_byte_addr,
    input  wire [31:0]                  wr_data,
    input  wire [3:0]                   wr_byte_en,

    input  wire                         rd_req_valid,
    output wire                         rd_req_ready,
    input  wire [PIXEL_ADDR_WIDTH-1:0] rd_pixel_idx,
    input  wire [GROUP_ADDR_WIDTH-1:0] rd_channel_group,
    input  wire [BANKS-1:0]             rd_lane_mask,
    input  wire [TAG_WIDTH-1:0]         rd_tag,
    // Optional per-bank local addresses.  This is useful for a spatial
    // gather; when clear, addresses are derived from pixel/group above.
    input  wire                         rd_use_lane_addr,
    input  wire [BANKS*BANK_ADDR_WIDTH-1:0] rd_lane_addr,

    output wire                         rd_resp_valid,
    input  wire                         rd_resp_ready,
    output wire [BANKS*8-1:0]           rd_data_vector,
    output wire [BANKS-1:0]             rd_resp_lane_mask,
    output wire [TAG_WIDTH-1:0]         rd_resp_tag,
    // High only after an accepted command and all registered scatter bytes
    // have reached the bank RAM.  This is separate from wr_ready: aligned
    // commands can be accepted every cycle while the one-entry scatter
    // pipeline still has a final command to drain.
    output wire                         wr_drain_ready
);
    localparam integer PIXELS = MAX_IN_H * MAX_IN_W;
    localparam integer GROUPS = (MAX_CHANNELS + BANKS - 1) / BANKS;
    /* Every bank has one slot for each pixel/channel-group, including the
     * partially populated final group.  This is larger than a simple
     * TOTAL_BYTES/BANKS calculation for MAX_CHANNELS=3 (the Stem case). */
    localparam integer BANK_DEPTH = PIXELS * GROUPS;
    localparam integer BANK_SHIFT = (BANKS > 1) ? $clog2(BANKS) : 0;
    localparam integer CHANNELS_ALIGNED = ((MAX_CHANNELS % BANKS) == 0);

    wire wr_fire;
    wire wr_emit;
    wire rd_fire;
    reg wr_active;
    reg [3:0] wr_pending;
    reg [BYTE_ADDR_WIDTH-1:0] wr_base_reg;
    reg [31:0] wr_data_reg;
    reg [3:0] wr_be_reg;
    reg [1:0] wr_sel;
    reg wr_bypass_valid;
    reg rd_pending;
    reg rd_resp_valid_reg;
    reg [BANKS-1:0] rd_mask_reg;
    reg [TAG_WIDTH-1:0] rd_tag_reg;
    reg [BYTE_ADDR_WIDTH-1:0] rd_linear_base_reg;
    reg [BANKS*8-1:0] rd_data_reg;

    assign wr_ready = rst_n && (CHANNELS_ALIGNED || !wr_active);
    assign wr_drain_ready = rst_n && !wr_active && !wr_bypass_valid;
    assign wr_fire = wr_valid && wr_ready;
    assign wr_emit = wr_active && (|wr_pending);
    /* Bank RAMs are synchronous, so one metadata pipeline entry is enough to
     * sustain one vector per cycle once primed. */
    assign rd_req_ready = rst_n && (!rd_resp_valid_reg || rd_resp_ready);
    assign rd_fire = rd_req_valid && rd_req_ready;
    assign rd_resp_valid = rd_resp_valid_reg;
    assign rd_data_vector = rd_data_reg;
    assign rd_resp_lane_mask = rd_mask_reg;
    assign rd_resp_tag = rd_tag_reg;

    /* Write scatter.  A four-byte word can hit the same bank more than once
     * for the three-channel Stem, so the accepted word is emitted one byte
     * per cycle (wr_sel) rather than silently dropping a byte. */
    reg [BANKS-1:0] wr_bank_en;
    reg [BANKS*BANK_ADDR_WIDTH-1:0] wr_bank_addr;
    reg [BANKS*8-1:0] wr_bank_data;
    reg [BANKS-1:0] wr_direct_en;
    reg [BANKS*BANK_ADDR_WIDTH-1:0] wr_direct_addr;
    reg [BANKS*8-1:0] wr_direct_data;
    wire [BANKS-1:0] wr_mem_en = CHANNELS_ALIGNED ? wr_direct_en : wr_bank_en;
    wire [BANKS*BANK_ADDR_WIDTH-1:0] wr_mem_addr = CHANNELS_ALIGNED ? wr_direct_addr : wr_bank_addr;
    wire [BANKS*8-1:0] wr_mem_data = CHANNELS_ALIGNED ? wr_direct_data : wr_bank_data;
    integer wr_pixel_num;
    integer wr_channel_num;
    integer wr_group_num;
    integer wr_bank_num;
    integer wr_local_num;
    integer wj;
    integer wr_direct_byte_num;
    reg [BYTE_ADDR_WIDTH-1:0] wr_byte_addr_tmp;
    always @* begin
        wr_bank_en = {BANKS{1'b0}};
        wr_bank_addr = {(BANKS*BANK_ADDR_WIDTH){1'b0}};
        wr_bank_data = {(BANKS*8){1'b0}};
        wr_direct_en = {BANKS{1'b0}};
        wr_direct_addr = {(BANKS*BANK_ADDR_WIDTH){1'b0}};
        wr_direct_data = {(BANKS*8){1'b0}};
        wr_direct_byte_num = 0;
        wr_byte_addr_tmp = wr_base_reg + wr_sel;
        /* Logical addresses are pixel-major with channels contiguous;
         * channel modulo BANKS chooses the physical byte bank. */
        if (CHANNELS_ALIGNED) begin
            /* DS channel dimensions are a multiple of sixteen; this keeps
             * the common write path to wiring/shifts rather than a divider. */
            wr_bank_num = wr_byte_addr_tmp[BANK_SHIFT-1:0];
            wr_local_num = wr_byte_addr_tmp >> BANK_SHIFT;
        end else begin
            wr_pixel_num = wr_byte_addr_tmp / MAX_CHANNELS;
            wr_channel_num = wr_byte_addr_tmp - wr_pixel_num * MAX_CHANNELS;
            wr_group_num = wr_channel_num / BANKS;
            wr_bank_num = wr_channel_num % BANKS;
            wr_local_num = wr_pixel_num * GROUPS + wr_group_num;
        end
        if (wr_emit) begin
            wr_bank_en[wr_bank_num] = 1'b1;
            wr_bank_addr[(wr_bank_num*BANK_ADDR_WIDTH) +: BANK_ADDR_WIDTH] = wr_local_num;
            wr_bank_data[(wr_bank_num*8) +: 8] = wr_data_reg[(wr_sel*8) +: 8];
        end
        /* The aligned fast path is intentionally driven only by the
         * registered command record.  Using live write inputs here made the
         * pipe->BRAM scatter cone span the composition boundary.  The record
         * adds one cycle of latency but remains a one-command/cycle pipeline:
         * at a clock edge the previous record is written while the current
         * command is captured for the next edge. */
        if (CHANNELS_ALIGNED && wr_bypass_valid) begin
            for (wj = 0; wj < 4; wj = wj + 1) begin
                wr_direct_byte_num = wr_base_reg + wj;
                if (wr_be_reg[wj]) begin
                    wr_direct_en[wr_direct_byte_num[BANK_SHIFT-1:0]] = 1'b1;
                    wr_direct_addr[(wr_direct_byte_num[BANK_SHIFT-1:0]*BANK_ADDR_WIDTH) +: BANK_ADDR_WIDTH] =
                        wr_direct_byte_num >> BANK_SHIFT;
                    wr_direct_data[(wr_direct_byte_num[BANK_SHIFT-1:0]*8) +: 8] =
                        wr_data_reg[(wj*8) +: 8];
                end
            end
        end
    end

    reg [BANK_ADDR_WIDTH-1:0] rd_addr_lane [0:BANKS-1];
    integer ri;
    integer rd_linear_int;
    always @* begin
        rd_linear_int = rd_pixel_idx * GROUPS + rd_channel_group;
        for (ri = 0; ri < BANKS; ri = ri + 1) begin
            if (rd_use_lane_addr)
                rd_addr_lane[ri] = rd_lane_addr[(ri*BANK_ADDR_WIDTH) +: BANK_ADDR_WIDTH];
            else
                rd_addr_lane[ri] = rd_linear_int;
        end
    end

    wire [7:0] bank_rd_data [0:BANKS-1];
    genvar bg;
    generate
        for (bg = 0; bg < BANKS; bg = bg + 1) begin : gen_byte_bank
            /* One synchronous byte read and one byte write per bank makes
             * the intended BRAM inference explicit to Vivado. */
            (* ram_style = "block" *) reg [7:0] mem [0:BANK_DEPTH-1];
            reg [7:0] rd_data_bank;
            assign bank_rd_data[bg] = rd_data_bank;

            always @(posedge clk) begin
                if (wr_mem_en[bg])
                    mem[wr_mem_addr[(bg*BANK_ADDR_WIDTH) +: BANK_ADDR_WIDTH]] <=
                        wr_mem_data[(bg*8) +: 8];
                if (rd_fire) begin
                    /* The top-level response register forwards an accepted
                     * word when a read collides with its serialized stores;
                     * keeping the BRAM read itself read-first removes a wide
                     * write-address comparator/mux from this critical path. */
                    rd_data_bank <= mem[rd_addr_lane[bg]];
                end
            end
        end
    endgenerate

    integer oi;
    integer bj;
    integer rd_byte_num;
    integer wr_byte_num;
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_active <= 1'b0;
            wr_bypass_valid <= 1'b0;
            wr_pending <= 4'd0;
            wr_base_reg <= {BYTE_ADDR_WIDTH{1'b0}};
            wr_data_reg <= 32'd0;
            wr_be_reg <= 4'd0;
            wr_sel <= 2'd0;
            rd_pending <= 1'b0;
            rd_resp_valid_reg <= 1'b0;
            rd_mask_reg <= {BANKS{1'b0}};
            rd_tag_reg <= {TAG_WIDTH{1'b0}};
            rd_linear_base_reg <= {BYTE_ADDR_WIDTH{1'b0}};
            rd_data_reg <= {(BANKS*8){1'b0}};
        end else begin
            if (wr_fire) begin
                wr_active <= (!CHANNELS_ALIGNED) && (|wr_byte_en);
                wr_bypass_valid <= 1'b1;
                wr_pending <= wr_byte_en;
                wr_base_reg <= wr_base_byte_addr;
                wr_data_reg <= wr_data;
                wr_be_reg <= wr_byte_en;
                if (wr_byte_en[0]) wr_sel <= 2'd0;
                else if (wr_byte_en[1]) wr_sel <= 2'd1;
                else if (wr_byte_en[2]) wr_sel <= 2'd2;
                else wr_sel <= 2'd3;
            end else if (wr_emit) begin
                wr_bypass_valid <= 1'b0;
                wr_pending[wr_sel] <= 1'b0;
                if (wr_pending == (4'b0001 << wr_sel)) begin
                    wr_active <= 1'b0;
                end else if (wr_sel == 2'd0) begin
                    if (wr_pending[1]) wr_sel <= 2'd1;
                    else if (wr_pending[2]) wr_sel <= 2'd2;
                    else wr_sel <= 2'd3;
                end else if (wr_sel == 2'd1) begin
                    if (wr_pending[2]) wr_sel <= 2'd2;
                    else wr_sel <= 2'd3;
                end else if (wr_sel == 2'd2) begin
                    wr_sel <= 2'd3;
                end
            end else begin
                wr_bypass_valid <= 1'b0;
            end
            if (rd_pending) begin
                rd_resp_valid_reg <= 1'b1;
                rd_mask_reg <= rd_mask_reg;
                rd_tag_reg <= rd_tag_reg;
                for (oi = 0; oi < BANKS; oi = oi + 1) begin
                    rd_data_reg[(oi*8) +: 8] <= rd_mask_reg[oi] ? bank_rd_data[oi] : 8'd0;
                    /* A response launched in the same cycle as a word
                     * acceptance may precede the serialized byte stores.
                     * Forward matching logical bytes to make that collision
                     * deterministic and write-first. */
                    rd_byte_num = rd_linear_base_reg + oi;
                    for (bj = 0; bj < 4; bj = bj + 1) begin
                        wr_byte_num = wr_base_reg + bj;
                        if ((wr_active || wr_bypass_valid) && wr_be_reg[bj] &&
                            (wr_byte_num == rd_byte_num) && rd_mask_reg[oi])
                            rd_data_reg[(oi*8) +: 8] <= wr_data_reg[(bj*8) +: 8];
                    end
                end
            end else if (rd_resp_valid_reg && rd_resp_ready) begin
                rd_resp_valid_reg <= 1'b0;
            end

            rd_pending <= rd_fire;
            if (rd_fire) begin
                rd_mask_reg <= rd_lane_mask;
                rd_tag_reg <= rd_tag;
                rd_linear_base_reg <= rd_pixel_idx * MAX_CHANNELS +
                                      rd_channel_group * BANKS;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (BANKS != 16) $error("feature_tile_vector16_bank requires BANKS=16");
        if (MAX_CHANNELS < 1) $error("MAX_CHANNELS must be positive");
        if (MAX_IN_H < 1 || MAX_IN_W < 1) $error("tile dimensions must be positive");
        if (BANK_DEPTH < 1) $error("computed BRAM depth must be positive");
        if ((BANKS & (BANKS-1)) != 0) $error("BANKS must be a power of two");
    end
`endif
endmodule

`default_nettype wire
