`timescale 1ns/1ps
`default_nettype none

/*
 * One ownership-isolated scratch bank for a complete 8x8 spatial tile.
 *
 * A DW command writes one 16-channel vector at one of 64 pixels.  Four
 * 256-bit simple-dual-port memories hold the four quarters of every
 * 16-channel group; the address is {channel_group,pixel_row} and the write
 * byte enables select the pixel within that row.  A PW read returns eight
 * pixels for one channel, so the pointwise core can consume a whole spatial
 * row with one registered memory response.
 *
 * Ownership is deliberately local: FREE -> DW -> COMMITTED -> PW -> FREE.
 * Epoch and tile tags are checked at every command boundary.  The completion
 * matrix is local to this bank and is only used for the DW commit fence; no
 * live state is broadcast to the PW datapath.
 */
module ds_pw_spatial_tile_bank #(
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH = 8
) (
    input wire clk, input wire rst_n,

    input wire dw_acquire_valid, output wire dw_acquire_ready,
    input wire dw_acquire_bank,
    input wire [EPOCH_WIDTH-1:0] dw_acquire_epoch,
    input wire [TILE_WIDTH-1:0] dw_acquire_tile,
    input wire [63:0] dw_acquire_pixel_mask,
    input wire [7:0] dw_acquire_group_mask,

    input wire dw_write_valid, output wire dw_write_ready,
    input wire dw_write_bank,
    input wire [EPOCH_WIDTH-1:0] dw_write_epoch,
    input wire [TILE_WIDTH-1:0] dw_write_tile,
    input wire [5:0] dw_write_pixel_idx,
    input wire [2:0] dw_write_group,
    input wire [127:0] dw_write_data,
    input wire [15:0] dw_write_lane_mask,

    input wire dw_commit_valid, output wire dw_commit_ready,
    input wire dw_commit_bank,
    input wire [EPOCH_WIDTH-1:0] dw_commit_epoch,
    input wire [TILE_WIDTH-1:0] dw_commit_tile,

    input wire pw_acquire_valid, output wire pw_acquire_ready,
    input wire pw_acquire_bank,
    input wire [EPOCH_WIDTH-1:0] pw_acquire_epoch,
    input wire [TILE_WIDTH-1:0] pw_acquire_tile,

    input wire pw_read_valid, output wire pw_read_ready,
    input wire pw_read_bank,
    input wire [EPOCH_WIDTH-1:0] pw_read_epoch,
    input wire [TILE_WIDTH-1:0] pw_read_tile,
    input wire [6:0] pw_read_channel_idx,
    input wire [5:0] pw_read_pixel_base,
    output reg pw_out_valid, input wire pw_out_ready,
    output reg pw_out_bank,
    output reg [EPOCH_WIDTH-1:0] pw_out_epoch,
    output reg [TILE_WIDTH-1:0] pw_out_tile,
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
    output reg [31:0] read_count,
    output reg [31:0] write_count
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
    reg [511:0] write_seen;
    reg [127:0] channel_valid;

    /* One local registered DW command.  The RAM write enable is derived only
     * from this command, not from a remote ready or ownership expression. */
    reg cmd_valid;
    reg [5:0] cmd_pixel;
    reg [2:0] cmd_group;
    reg [127:0] cmd_data;
    reg [15:0] cmd_mask;
    reg [EPOCH_WIDTH-1:0] cmd_epoch;
    reg [TILE_WIDTH-1:0] cmd_tile;

    wire dw_tag = (owner == OWNER_DW) && (epoch == dw_write_epoch) &&
                  (tile == dw_write_tile);
    wire dw_acq_fire = dw_acquire_valid && dw_acquire_ready;
    wire dw_write_fire = dw_write_valid && dw_write_ready;
    wire cmd_retire = cmd_valid;
    assign dw_acquire_ready = rst_n && (owner == OWNER_FREE);
    assign dw_write_ready = rst_n && dw_tag && (!cmd_valid || cmd_retire);

    function automatic [511:0] expected_matrix;
        input [63:0] pixels; input [7:0] groups;
        integer p, g;
        begin
            expected_matrix = 512'd0;
            for (p = 0; p < 64; p = p + 1)
                for (g = 0; g < 8; g = g + 1)
                    expected_matrix[(p*8)+g] = pixels[p] && groups[g];
        end
    endfunction
    wire [511:0] expected_bits = expected_matrix(expected_pixels, expected_groups);
    wire commit_match = (owner == OWNER_DW) && (epoch == dw_commit_epoch) &&
                        (tile == dw_commit_tile);
    wire commit_complete = ((write_seen & expected_bits) == expected_bits);
    assign dw_commit_ready = rst_n && commit_match && commit_complete &&
                             !cmd_valid && !(dw_write_valid && dw_write_ready);
    wire commit_fire = dw_commit_valid && dw_commit_ready;

    wire pw_commit_match = (owner == OWNER_COMMITTED) &&
                           (epoch == pw_acquire_epoch) &&
                           (tile == pw_acquire_tile);
    assign pw_acquire_ready = rst_n && pw_commit_match;
    wire pw_acq_fire = pw_acquire_valid && pw_acquire_ready;
    wire pw_tag = (owner == OWNER_PW) && (epoch == pw_read_epoch) &&
                  (tile == pw_read_tile);
    assign pw_read_ready = rst_n && pw_tag && !rd_data_pending &&
                           (!pw_out_valid || pw_out_ready);
    wire pw_read_fire = pw_read_valid && pw_read_ready;
    assign pw_release_ready = rst_n && (owner == OWNER_PW) &&
        (epoch == pw_release_epoch) && (tile == pw_release_tile) &&
        !pw_out_valid;
    wire pw_release_fire = pw_release_valid && pw_release_ready;

    wire [255:0] mem_rd_data [0:3];
    wire [255:0] mem_wr_data [0:3];
    wire [31:0] mem_wr_be [0:3];
    wire [5:0] mem_wr_addr = {cmd_group, cmd_pixel[5:3]};
    wire [5:0] mem_rd_addr = {pw_read_channel_idx[6:4], pw_read_pixel_base[5:3]};
    wire [1:0] rd_bank = pw_read_channel_idx[3:2];
    wire [1:0] rd_lane = pw_read_channel_idx[1:0];
    wire [31:0] wr_shifted [0:3];
    genvar b;
    generate for (b = 0; b < 4; b = b + 1) begin : gen_mem
        assign mem_wr_be[b] = (cmd_valid ?
            ({28'd0, cmd_mask[(b*4) +: 4]} << (cmd_pixel[2:0] * 4)) : 32'd0);
        assign mem_wr_data[b] = ({{224{1'b0}}, cmd_data[(b*32) +: 32]} <<
                                 (cmd_pixel[2:0] * 32));
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
            .clka(clk), .clkb(clk), .ena(cmd_valid), .wea(mem_wr_be[b]),
            .addra(mem_wr_addr), .dina(mem_wr_data[b]), .addrb(mem_rd_addr),
            .enb(pw_read_fire && (rd_bank == b[1:0])),
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
                if (cmd_valid)
                    for (bi = 0; bi < 32; bi = bi + 1)
                        if (mem_wr_be[b][bi])
                            mem[mem_wr_addr][bi*8 +: 8] <= mem_wr_data[b][bi*8 +: 8];
                if (pw_read_fire && (rd_bank == b[1:0]))
                    rd_reg <= mem[mem_rd_addr];
            end
        end
        assign mem_rd_data[b] = rd_reg;
`endif
    end endgenerate

    reg [1:0] rd_bank_q;
    reg [1:0] rd_lane_q;
    reg [5:0] rd_pixel_q;
    reg [63:0] rd_pixels_q;
    reg [127:0] rd_channels_q;
    reg rd_data_pending;
    reg [EPOCH_WIDTH-1:0] rd_epoch_q;
    reg [TILE_WIDTH-1:0] rd_tile_q;
    reg [6:0] rd_channel_q;
    integer pi;
    always @(posedge clk) begin
        if (!rst_n) begin
            owner <= OWNER_FREE; epoch <= 0; tile <= 0;
            expected_pixels <= 0; expected_groups <= 0; write_seen <= 0;
            channel_valid <= 0; cmd_valid <= 0; cmd_pixel <= 0; cmd_group <= 0;
            cmd_data <= 0; cmd_mask <= 0; cmd_epoch <= 0; cmd_tile <= 0;
            pw_out_valid <= 0; pw_out_bank <= 0; pw_out_epoch <= 0;
            pw_out_tile <= 0; pw_out_data <= 0; pw_out_lane_mask <= 0;
            rd_bank_q <= 0; rd_lane_q <= 0; rd_pixel_q <= 0;
            rd_pixels_q <= 0; rd_channels_q <= 0; rd_data_pending <= 0;
            rd_epoch_q <= 0; rd_tile_q <= 0; rd_channel_q <= 0;
            commit_pulse <= 0; acquire_pulse <= 0; release_pulse <= 0;
            read_count <= 0; write_count <= 0;
        end else begin
            commit_pulse <= 0; acquire_pulse <= 0; release_pulse <= 0;
            if (pw_out_valid && pw_out_ready) pw_out_valid <= 0;
            if (dw_acq_fire) begin
                owner <= OWNER_DW; epoch <= dw_acquire_epoch;
                tile <= dw_acquire_tile; expected_pixels <= dw_acquire_pixel_mask;
                expected_groups <= dw_acquire_group_mask; write_seen <= 0;
                channel_valid <= 0;
            end
            if (cmd_retire && (cmd_pixel < 64) && (cmd_group < 8) && |cmd_mask) begin
                write_seen[(cmd_pixel*8)+cmd_group] <= 1'b1;
                channel_valid[(cmd_group*16) +: 16] <= cmd_mask;
                write_count <= write_count + 1'b1;
            end
            if (dw_write_fire) begin
                cmd_valid <= 1; cmd_pixel <= dw_write_pixel_idx;
                cmd_group <= dw_write_group; cmd_data <= dw_write_data;
                cmd_mask <= dw_write_lane_mask; cmd_epoch <= dw_write_epoch;
                cmd_tile <= dw_write_tile;
            end else if (cmd_retire) cmd_valid <= 0;
            if (commit_fire) begin owner <= OWNER_COMMITTED; commit_pulse <= 1; end
            if (pw_acq_fire) begin owner <= OWNER_PW; acquire_pulse <= 1; end
            if (pw_read_fire) begin
                /* The BRAM response is registered.  Do not advertise a
                 * response on the request cycle: pw_out_data still belongs
                 * to the preceding request (or is stale on the first one).
                 * rd_data_pending below emits the valid beat exactly one
                 * cycle after the simple-dual-port read. */
                pw_out_valid <= 0; pw_out_bank <= pw_read_bank;
                pw_out_epoch <= pw_read_epoch; pw_out_tile <= pw_read_tile;
                rd_bank_q <= rd_bank; rd_lane_q <= rd_lane;
                rd_pixel_q <= pw_read_pixel_base;
                rd_pixels_q <= expected_pixels; rd_channels_q <= channel_valid;
                rd_data_pending <= 1; rd_epoch_q <= pw_read_epoch;
                rd_tile_q <= pw_read_tile; rd_channel_q <= pw_read_channel_idx;
                read_count <= read_count + 1'b1;
            end else if (rd_data_pending) begin
                pw_out_valid <= 1;
                pw_out_epoch <= rd_epoch_q; pw_out_tile <= rd_tile_q;
                pw_out_data <= 64'd0; pw_out_lane_mask <= 8'd0;
                for (pi = 0; pi < 8; pi = pi + 1) begin
                    if (rd_pixels_q[rd_pixel_q + pi] &&
                        rd_channels_q[(rd_channel_q[6:4]*16) +
                                      (rd_bank_q*4) + rd_lane_q]) begin
                        pw_out_data[(pi*8) +: 8] <=
                            mem_rd_data[rd_bank_q][(pi*32) +
                                                   (rd_lane_q*8) +: 8];
                        pw_out_lane_mask[pi] <= 1'b1;
                    end
                end
                rd_data_pending <= 0;
            end
            if (pw_release_fire) begin owner <= OWNER_FREE; release_pulse <= 1; end
        end
    end

    assign state = owner; assign state_epoch = epoch; assign state_tile = tile;
endmodule

`default_nettype wire
