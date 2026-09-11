`timescale 1ns/1ps
`default_nettype none
/* Widths in the small simulation-only sequence checker intentionally mix
 * loop indices and packed fields. */
/* verilator lint_off WIDTHEXPAND */

/*
 * Session scratch bank for the tagless spatial-tile prototype.
 *
 * Epoch/tile are admission metadata only.  They are checked when a DW
 * session is acquired, when its final beat is committed, when PW acquires a
 * committed session, and when PW releases it.  Once admitted, the data plane
 * carries no epoch/tile fields and consequently no wide compare/fanout tree.
 *
 * The producer emits four channels per beat.  Four beats cover one sixteen
 * channel DW result; lane_base selects the local 4-channel quarter.  A beat
 * is retired in program order (pixel, group, lane quarter).  The completion
 * fence is therefore a pair of small counters, rather than a 512-bit
 * write_seen/expected matrix.  Simulation keeps an exactly-once sequence
 * assertion at this boundary; synthesis removes the assertion state.
 */
module ds_pw_spatial_tile_bank_tagless #(
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH = 8,
    parameter integer PIXEL_WIDTH = 6,
    parameter integer GROUP_WIDTH = 3,
    parameter integer BANK_ID = 0
) (
    input wire clk, input wire rst_n,

    input wire dw_acquire_valid, output wire dw_acquire_ready,
    input wire dw_acquire_bank,
    input wire [EPOCH_WIDTH-1:0] dw_acquire_epoch,
    input wire [TILE_WIDTH-1:0] dw_acquire_tile,
    input wire [63:0] dw_acquire_pixel_mask,
    input wire [7:0] dw_acquire_group_mask,
    input wire [31:0] dw_acquire_expected_count,

    input wire dw_write_valid, output wire dw_write_ready,
    input wire [PIXEL_WIDTH-1:0] dw_write_pixel_idx,
    input wire [GROUP_WIDTH-1:0] dw_write_group,
    input wire [1:0] dw_write_lane_base,
    input wire [31:0] dw_write_data,
    input wire [3:0] dw_write_lane_mask,

    input wire dw_commit_valid, output wire dw_commit_ready,
    input wire dw_commit_bank,
    input wire [EPOCH_WIDTH-1:0] dw_commit_epoch,
    input wire [TILE_WIDTH-1:0] dw_commit_tile,

    input wire pw_acquire_valid, output wire pw_acquire_ready,
    input wire pw_acquire_bank,
    input wire [EPOCH_WIDTH-1:0] pw_acquire_epoch,
    input wire [TILE_WIDTH-1:0] pw_acquire_tile,

    input wire pw_read_valid, output wire pw_read_ready,
    input wire [6:0] pw_read_channel_idx,
    input wire [5:0] pw_read_pixel_base,
    output reg pw_out_valid, input wire pw_out_ready,
    output reg [63:0] pw_out_data,
    output reg [7:0] pw_out_lane_mask,

    input wire pw_release_valid, output wire pw_release_ready,
    input wire pw_release_bank,
    input wire [EPOCH_WIDTH-1:0] pw_release_epoch,
    input wire [TILE_WIDTH-1:0] pw_release_tile,

    output wire [1:0] state,
    output wire [EPOCH_WIDTH-1:0] state_epoch,
    output wire [TILE_WIDTH-1:0] state_tile,
    output reg commit_pulse,
    output reg acquire_pulse,
    output reg release_pulse,
    output reg [31:0] retired_write_count,
    output reg [31:0] expected_count,
    output reg [31:0] read_count
);
    localparam [1:0] OWNER_FREE = 2'd0;
    localparam [1:0] OWNER_DW = 2'd1;
    localparam [1:0] OWNER_COMMITTED = 2'd2;
    localparam [1:0] OWNER_PW = 2'd3;

    reg [1:0] owner;
    reg [EPOCH_WIDTH-1:0] epoch;
    reg [TILE_WIDTH-1:0] tile;
    reg [63:0] expected_pixels;
    reg [7:0] expected_groups;

    /* Registered one-beat write boundary, keeping BRAM enables local. */
    reg cmd_valid;
    reg [PIXEL_WIDTH-1:0] cmd_pixel;
    reg [GROUP_WIDTH-1:0] cmd_group;
    reg [1:0] cmd_lane_base;
    reg [31:0] cmd_data;
    reg [3:0] cmd_mask;

    localparam BANK_SELECT = (BANK_ID != 0) ? 1'b1 : 1'b0;
    wire acq_match = (dw_acquire_bank == BANK_SELECT);
    wire dw_acq_fire = dw_acquire_valid && dw_acquire_ready;
    wire cmd_retire = cmd_valid;
    assign dw_acquire_ready = rst_n && (owner == OWNER_FREE) && acq_match;
    assign dw_write_ready = rst_n && (owner == OWNER_DW) &&
                            (!cmd_valid || cmd_retire);

    /* Four quarter memories, each storing eight pixels per row.  A memory
     * word is 256 bits: 8 pixel bytes for four adjacent channels. */
    wire [255:0] mem_rd_data [0:3];
    wire [255:0] mem_wr_data [0:3];
    wire [31:0] mem_wr_be [0:3];
    wire [5:0] mem_wr_addr = {cmd_group[2:0], cmd_pixel[5:3]};
    wire [5:0] mem_rd_addr = {pw_read_channel_idx[6:4], pw_read_pixel_base[5:3]};
    wire [1:0] rd_bank = pw_read_channel_idx[3:2];
    wire [1:0] rd_lane = pw_read_channel_idx[1:0];
    /* Must be visible to the generated memory read enables below. */
    wire pw_read_fire = pw_read_valid && pw_read_ready;
    genvar b;
    generate for (b = 0; b < 4; b = b + 1) begin : gen_mem
        wire selected = cmd_valid && (cmd_lane_base == b[1:0]);
        assign mem_wr_be[b] = selected ?
            ({28'd0, cmd_mask} << (cmd_pixel[2:0] * 4)) : 32'd0;
        assign mem_wr_data[b] = selected ?
            ({{224{1'b0}}, cmd_data} << (cmd_pixel[2:0] * 32)) : 256'd0;
`ifdef SYNTHESIS
        xpm_memory_sdpram #(
            .ADDR_WIDTH_A(6), .ADDR_WIDTH_B(6), .AUTO_SLEEP_TIME(0),
            .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"),
            .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
            .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
            .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(16384),
            .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(256),
            .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
            .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
            .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
            .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(256),
            .WRITE_MODE_B("read_first")
        ) u_mem (
            .clka(clk), .clkb(clk), .ena(cmd_valid && selected),
            .wea(mem_wr_be[b]), .addra(mem_wr_addr), .dina(mem_wr_data[b]),
            .addrb(mem_rd_addr), .enb(pw_read_fire && (rd_bank == b[1:0])),
            .doutb(mem_rd_data[b]), .regceb(1'b1), .rstb(!rst_n),
            .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
            .dbiterrb(), .sbiterrb()
        );
`else
        reg [255:0] mem [0:63];
        reg [255:0] rd_reg;
        integer bi;
        always @(posedge clk) begin
            if (!rst_n) rd_reg <= 256'd0;
            else begin
                if (cmd_valid && selected)
                    for (bi = 0; bi < 32; bi = bi + 1)
                        if (mem_wr_be[b][bi])
                            mem[mem_wr_addr][bi*8 +: 8] <=
                                mem_wr_data[b][bi*8 +: 8];
                if (pw_read_fire && (rd_bank == b[1:0]))
                    rd_reg <= mem[mem_rd_addr];
            end
        end
        assign mem_rd_data[b] = rd_reg;
`endif
    end endgenerate

    wire commit_match = (owner == OWNER_DW) &&
        (dw_commit_bank == BANK_SELECT) && (epoch == dw_commit_epoch) &&
        (tile == dw_commit_tile);
    wire commit_complete = (retired_write_count >= expected_count);
    assign dw_commit_ready = rst_n && commit_match && commit_complete &&
                             !cmd_valid && !(dw_write_valid && dw_write_ready);
    wire commit_fire = dw_commit_valid && dw_commit_ready;

    wire pw_commit_match = (owner == OWNER_COMMITTED) &&
        (pw_acquire_bank == BANK_SELECT) && (epoch == pw_acquire_epoch) &&
        (tile == pw_acquire_tile);
    assign pw_acquire_ready = rst_n && pw_commit_match;
    wire pw_acq_fire = pw_acquire_valid && pw_acquire_ready;

    reg rd_data_pending;
    reg [1:0] rd_bank_q;
    reg [1:0] rd_lane_q;
    reg [2:0] rd_group_q;
    reg [5:0] rd_pixel_q;
    reg [63:0] rd_pixels_q;
    reg [127:0] rd_channels_q;
    assign pw_read_ready = rst_n && (owner == OWNER_PW) && !rd_data_pending &&
                           (!pw_out_valid || pw_out_ready);
    wire pw_release_match = (owner == OWNER_PW) &&
        (pw_release_bank == BANK_SELECT) && (epoch == pw_release_epoch) &&
        (tile == pw_release_tile);
    assign pw_release_ready = rst_n && pw_release_match && !pw_out_valid &&
                              !rd_data_pending;
    wire pw_release_fire = pw_release_valid && pw_release_ready;

    integer pi;
`ifndef SYNTHESIS
    reg [31:0] sim_sequence_errors;
    function automatic [31:0] sim_sequence_rank;
        input [PIXEL_WIDTH-1:0] pixel_value;
        input [GROUP_WIDTH-1:0] group_value;
        input [1:0] lane_value;
        integer sp, sg, sl;
        begin
            sim_sequence_rank = 0;
            /* The producer schedules one complete channel group at a time,
             * hence the legal retirement order is group-major (pixel, lane)
             * rather than pixel-major across all groups. */
            for (sg = 0; sg < 8; sg = sg + 1)
                for (sp = 0; sp < 64; sp = sp + 1)
                    for (sl = 0; sl < 4; sl = sl + 1) begin
                        if (expected_pixels[sp] && expected_groups[sg]) begin
                            if ((sg < group_value) ||
                                ((sg == group_value) && (sp < pixel_value)) ||
                                ((sg == group_value) && (sp == pixel_value) &&
                                 (sl < lane_value)))
                                sim_sequence_rank = sim_sequence_rank + 1'b1;
                        end
                    end
        end
    endfunction
`endif
    always @(posedge clk) begin
        if (!rst_n) begin
            owner <= OWNER_FREE; epoch <= 0; tile <= 0;
            expected_pixels <= 0; expected_groups <= 0;
            cmd_valid <= 1'b0; cmd_pixel <= 0; cmd_group <= 0;
            cmd_lane_base <= 0; cmd_data <= 0; cmd_mask <= 0;
            pw_out_valid <= 1'b0; pw_out_data <= 0; pw_out_lane_mask <= 0;
            rd_data_pending <= 1'b0; rd_bank_q <= 0; rd_lane_q <= 0;
            rd_group_q <= 0;
            rd_pixel_q <= 0; rd_pixels_q <= 0; rd_channels_q <= 0;
            commit_pulse <= 0; acquire_pulse <= 0; release_pulse <= 0;
            retired_write_count <= 0; expected_count <= 0; read_count <= 0;
`ifndef SYNTHESIS
            sim_sequence_errors <= 0;
`endif
        end else begin
            commit_pulse <= 1'b0; acquire_pulse <= 1'b0; release_pulse <= 1'b0;
            if (pw_out_valid && pw_out_ready) pw_out_valid <= 1'b0;

            if (dw_acq_fire) begin
                owner <= OWNER_DW;
                epoch <= dw_acquire_epoch; tile <= dw_acquire_tile;
                expected_pixels <= dw_acquire_pixel_mask;
                expected_groups <= dw_acquire_group_mask;
                /* There are four ordered quarter-beats per pixel/group. */
                expected_count <= dw_acquire_expected_count;
                retired_write_count <= 0;
                acquire_pulse <= 1'b1;
`ifndef SYNTHESIS
                sim_sequence_errors <= 0;
`endif
            end
            if (dw_write_valid && dw_write_ready) begin
                cmd_valid <= 1'b1; cmd_pixel <= dw_write_pixel_idx;
                cmd_group <= dw_write_group; cmd_lane_base <= dw_write_lane_base;
                cmd_data <= dw_write_data; cmd_mask <= dw_write_lane_mask;
            end else if (cmd_retire) begin
                cmd_valid <= 1'b0;
            end
            if (cmd_retire) begin
                retired_write_count <= retired_write_count + 1'b1;
`ifndef SYNTHESIS
                if ((cmd_pixel >= 64) || (cmd_group >= 8) ||
                    (cmd_lane_base >= 4) ||
                    !expected_pixels[cmd_pixel] ||
                    !expected_groups[cmd_group] ||
                    (sim_sequence_rank(cmd_pixel, cmd_group, cmd_lane_base) !=
                     retired_write_count)) begin
                    $display("TAGLESS_BANK_ASSERT bank=%0d pixel=%0d group=%0d lane=%0d rank=%0d retired=%0d",
                        BANK_SELECT, cmd_pixel, cmd_group, cmd_lane_base,
                        sim_sequence_rank(cmd_pixel, cmd_group, cmd_lane_base),
                        retired_write_count);
                    sim_sequence_errors <= sim_sequence_errors + 1'b1;
                end
`endif
            end
            if (commit_fire) begin owner <= OWNER_COMMITTED; commit_pulse <= 1'b1; end
            if (pw_acq_fire) begin owner <= OWNER_PW; acquire_pulse <= 1'b1; end

            if (pw_read_fire) begin
                rd_data_pending <= 1'b1;
                rd_bank_q <= rd_bank; rd_lane_q <= rd_lane;
                rd_group_q <= pw_read_channel_idx[6:4];
                rd_pixel_q <= pw_read_pixel_base; rd_pixels_q <= expected_pixels;
                rd_channels_q <= 128'd0;
                /* A committed tile has exactly the requested channel groups. */
                for (pi = 0; pi < 128; pi = pi + 1)
                    rd_channels_q[pi] <= expected_groups[pi/16];
                read_count <= read_count + 1'b1;
            end else if (rd_data_pending) begin
                pw_out_valid <= 1'b1; pw_out_data <= 64'd0;
                pw_out_lane_mask <= 8'd0;
                for (pi = 0; pi < 8; pi = pi + 1) begin
                    if (rd_pixels_q[rd_pixel_q + pi] &&
                        rd_channels_q[(rd_group_q * 16) +
                                      (rd_bank_q * 4) + rd_lane_q]) begin
                        pw_out_data[(pi*8) +: 8] <=
                            mem_rd_data[rd_bank_q][(pi*32) +
                                                   (rd_lane_q*8) +: 8];
                        pw_out_lane_mask[pi] <= 1'b1;
                    end
                end
                rd_data_pending <= 1'b0;
            end
            if (pw_release_fire) begin owner <= OWNER_FREE; release_pulse <= 1'b1; end
        end
    end
    assign state = owner; assign state_epoch = epoch; assign state_tile = tile;
endmodule

`default_nettype wire
