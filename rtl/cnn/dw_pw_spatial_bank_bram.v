`timescale 1ns/1ps
`default_nettype none

/*
 * One physically local half of the spatial DW/PW block buffer.
 *
 * This module deliberately owns one bank's protocol state, command register,
 * completion matrix, and four BRAMs.  The parent only supplies registered
 * transaction payloads through a narrow valid/ready boundary; no parent
 * ownership mux or end-to-end ready signal reaches an inferred BRAM enable.
 */
module dw_pw_spatial_bank_bram #(
    parameter EPOCH_WIDTH = 2,
    parameter BLOCK_ID_WIDTH = 8
) (
    input wire clk, input wire rst_n,
    input wire dw_acquire_valid, output wire dw_acquire_ready,
    input wire [EPOCH_WIDTH-1:0] dw_acquire_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_acquire_block_id,
    input wire [7:0] dw_acquire_pixel_mask,
    input wire [7:0] dw_acquire_group_mask,
    input wire dw_write_valid, output wire dw_write_ready,
    input wire [EPOCH_WIDTH-1:0] dw_write_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_write_block_id,
    input wire [2:0] dw_write_pixel_idx,
    input wire dw_write_pixel_valid,
    input wire [2:0] dw_write_channel_group,
    input wire [127:0] dw_write_data,
    input wire [15:0] dw_write_lane_mask,
    input wire dw_commit_valid, output wire dw_commit_ready,
    input wire [EPOCH_WIDTH-1:0] dw_commit_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_commit_block_id,
    input wire pw_acquire_valid, output wire pw_acquire_ready,
    input wire [EPOCH_WIDTH-1:0] pw_acquire_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_acquire_block_id,
    input wire pw_read_valid, output wire pw_read_ready,
    input wire [EPOCH_WIDTH-1:0] pw_read_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_read_block_id,
    input wire [6:0] pw_read_channel_idx,
    output reg pw_out_valid, input wire pw_out_ready,
    output reg [EPOCH_WIDTH-1:0] pw_out_epoch,
    output reg [BLOCK_ID_WIDTH-1:0] pw_out_block_id,
    output wire [63:0] pw_out_data, output wire [7:0] pw_out_lane_mask,
    input wire pw_release_valid, output wire pw_release_ready,
    input wire [EPOCH_WIDTH-1:0] pw_release_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_release_block_id,
    output reg commit_pulse, output reg acquire_pulse, output reg release_pulse,
    output wire [1:0] state,
    output wire [EPOCH_WIDTH-1:0] state_epoch,
    output wire [BLOCK_ID_WIDTH-1:0] state_block_id
);
    localparam OWNER_FREE = 2'd0;
    localparam OWNER_DW = 2'd1;
    localparam OWNER_COMMITTED = 2'd2;
    localparam OWNER_PW = 2'd3;
    reg [1:0] owner;
    reg [EPOCH_WIDTH-1:0] epoch;
    reg [BLOCK_ID_WIDTH-1:0] block_id;
    reg [7:0] expected_pixels, expected_groups;
    reg [63:0] write_seen;
    reg [127:0] channel_valid;
`ifndef SYNTHESIS
    reg [15:0] group_lane_mask [0:7];
`endif

    /* Local one-entry elastic DW command queue. */
    reg cmd_valid;
    reg [EPOCH_WIDTH-1:0] cmd_epoch;
    reg [BLOCK_ID_WIDTH-1:0] cmd_block_id;
    reg [2:0] cmd_pixel_idx;
    reg cmd_pixel_valid;
    reg [2:0] cmd_channel_group;
    reg [127:0] cmd_data;
    reg [15:0] cmd_lane_mask;
    wire cmd_retire = cmd_valid;

    assign state = owner;
    assign state_epoch = epoch;
    assign state_block_id = block_id;
    wire tag_dw = (owner == OWNER_DW) &&
                  (epoch == dw_write_epoch) &&
                  (block_id == dw_write_block_id);
    wire acq_fire = dw_acquire_valid && dw_acquire_ready;
    assign dw_acquire_ready = rst_n && (owner == OWNER_FREE);
    assign dw_write_ready = rst_n && tag_dw && (!cmd_valid || cmd_retire);
    wire write_fire = dw_write_valid && dw_write_ready;

    function automatic [63:0] make_completion_mask;
        input [7:0] pixel_mask; input [7:0] group_mask;
        integer p, g;
        begin
            make_completion_mask = 64'd0;
            for (p = 0; p < 8; p = p + 1)
                for (g = 0; g < 8; g = g + 1)
                    make_completion_mask[(p*8)+g] = pixel_mask[p] && group_mask[g];
        end
    endfunction
    wire [63:0] expected_bits = make_completion_mask(expected_pixels, expected_groups);
    wire commit_match = (owner == OWNER_DW) &&
                        (epoch == dw_commit_epoch) &&
                        (block_id == dw_commit_block_id);
    wire commit_complete = ((write_seen & expected_bits) == expected_bits);
    /* The separation from the last command is intentional: completion is
     * observed only after the registered BRAM write has retired. */
    assign dw_commit_ready = rst_n && commit_match && commit_complete &&
                             !cmd_valid && !(dw_write_valid && dw_write_ready);
    wire commit_fire = dw_commit_valid && dw_commit_ready;
    wire pw_commit_match = (owner == OWNER_COMMITTED) &&
                           (epoch == pw_acquire_epoch) &&
                           (block_id == pw_acquire_block_id);
    assign pw_acquire_ready = rst_n && pw_commit_match;
    wire pw_acquire_fire = pw_acquire_valid && pw_acquire_ready;
    wire pw_tag_match = (owner == OWNER_PW) &&
                        (epoch == pw_read_epoch) &&
                        (block_id == pw_read_block_id);
    assign pw_read_ready = rst_n && pw_tag_match && (!pw_out_valid || pw_out_ready);
    wire pw_read_fire = pw_read_valid && pw_read_ready;
    wire pw_release_match = (owner == OWNER_PW) &&
                            (epoch == pw_release_epoch) &&
                            (block_id == pw_release_block_id) && !pw_out_valid;
    assign pw_release_ready = rst_n && pw_release_match;
    wire pw_release_fire = pw_release_valid && pw_release_ready;

    wire [255:0] mem_rd_data [0:3];
    wire [255:0] mem_wr_data [0:3];
    wire [31:0] mem_wr_be [0:3];
    wire [2:0] mem_wr_addr = cmd_channel_group;
    wire [2:0] mem_rd_addr = pw_read_channel_idx[6:4];
    wire [1:0] mem_rd_bank = pw_read_channel_idx[3:2];
    reg [1:0] read_physical_bank;
    reg [2:0] read_physical_addr;
    reg [1:0] read_channel_lane;
    reg [7:0] read_pixel_mask;
    reg [127:0] read_channel_valid;

    genvar wb;
    generate for (wb = 0; wb < 4; wb = wb + 1) begin : gen_write_lanes
        assign mem_wr_be[wb] = (cmd_valid && cmd_pixel_valid && |cmd_lane_mask) ?
            (({28'd0, cmd_lane_mask[(wb*4) +: 4]}) << (cmd_pixel_idx * 4)) : 32'd0;
        assign mem_wr_data[wb] = {{224{1'b0}}, cmd_data[(wb*32) +: 32]} <<
                                 (cmd_pixel_idx * 32);
    end endgenerate
    genvar mb;
    generate for (mb = 0; mb < 4; mb = mb + 1) begin : gen_mem_bank
        /* Only the local command register controls write CE/WE. */
        wire mem_write_enable = cmd_valid;
        wire mem_read_enable = pw_read_fire && (mem_rd_bank == mb[1:0]);
`ifdef SYNTHESIS
        xpm_memory_sdpram #(
            .ADDR_WIDTH_A(3), .ADDR_WIDTH_B(3), .AUTO_SLEEP_TIME(0),
            .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
            .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
            .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
            .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
            .MEMORY_SIZE(2048), .MESSAGE_CONTROL(0),
            .READ_DATA_WIDTH_B(256), .READ_LATENCY_B(1),
            .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
            .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
            .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
            .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(256),
            .WRITE_MODE_B("read_first")
        ) u_memory (
            .clka(clk), .clkb(clk), .ena(mem_write_enable),
            .enb(mem_read_enable), .addra(mem_wr_addr), .addrb(mem_rd_addr),
            .dina(mem_wr_data[mb]), .wea(mem_wr_be[mb]),
            .doutb(mem_rd_data[mb]), .rstb(!rst_n), .regceb(1'b1),
            .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
            .dbiterrb(), .sbiterrb()
        );
`else
        reg [255:0] mem [0:7]; reg [255:0] rd_data_reg; integer byte_i;
        always @(posedge clk) begin
            if (mem_write_enable)
                for (byte_i = 0; byte_i < 32; byte_i = byte_i + 1)
                    if (mem_wr_be[mb][byte_i])
                        mem[mem_wr_addr][(byte_i*8) +: 8] <=
                            mem_wr_data[mb][(byte_i*8) +: 8];
            if (!rst_n) rd_data_reg <= 256'd0;
            else if (mem_read_enable) rd_data_reg <= mem[mem_rd_addr];
        end
        assign mem_rd_data[mb] = rd_data_reg;
`endif
    end endgenerate

    integer rp;
    reg [63:0] pw_data_comb; reg [7:0] pw_mask_comb;
    always @* begin
        pw_data_comb = 64'd0; pw_mask_comb = 8'd0;
        for (rp = 0; rp < 8; rp = rp + 1) begin
            if (read_pixel_mask[rp] && read_channel_valid[(read_physical_addr*16) +
                    (read_physical_bank*4) + read_channel_lane]) begin
                pw_data_comb[(rp*8) +: 8] =
                    mem_rd_data[read_physical_bank][(rp*32) +
                                                     (read_channel_lane*8) +: 8];
                pw_mask_comb[rp] = 1'b1;
            end
        end
    end
    assign pw_out_data = pw_data_comb;
    assign pw_out_lane_mask = pw_mask_comb;

    integer gi;
    always @(posedge clk) begin
        if (!rst_n) begin
            owner <= OWNER_FREE; epoch <= 0; block_id <= 0;
            expected_pixels <= 0; expected_groups <= 0; write_seen <= 0;
            channel_valid <= 0; cmd_valid <= 0; cmd_epoch <= 0;
            cmd_block_id <= 0; cmd_pixel_idx <= 0; cmd_pixel_valid <= 0;
            cmd_channel_group <= 0; cmd_data <= 0; cmd_lane_mask <= 0;
            pw_out_valid <= 0; pw_out_epoch <= 0; pw_out_block_id <= 0;
            read_physical_bank <= 0; read_physical_addr <= 0;
            read_channel_lane <= 0; read_pixel_mask <= 0;
            read_channel_valid <= 0; commit_pulse <= 0;
            acquire_pulse <= 0; release_pulse <= 0;
`ifndef SYNTHESIS
            for (gi = 0; gi < 8; gi = gi + 1) group_lane_mask[gi] <= 0;
`endif
        end else begin
            commit_pulse <= 0; acquire_pulse <= 0; release_pulse <= 0;
            if (pw_out_valid && pw_out_ready) pw_out_valid <= 0;
            if (acq_fire) begin
                owner <= OWNER_DW; epoch <= dw_acquire_epoch;
                block_id <= dw_acquire_block_id;
                expected_pixels <= dw_acquire_pixel_mask;
                expected_groups <= dw_acquire_group_mask;
                write_seen <= 0; channel_valid <= 0;
`ifndef SYNTHESIS
                for (gi = 0; gi < 8; gi = gi + 1) group_lane_mask[gi] <= 0;
`endif
            end
            if (cmd_retire && cmd_pixel_valid && (cmd_pixel_idx < 8) &&
                (cmd_channel_group < 8) && |cmd_lane_mask) begin
                write_seen[(cmd_pixel_idx*8) + cmd_channel_group] <= 1'b1;
                channel_valid[(cmd_channel_group*16) +: 16] <= cmd_lane_mask;
`ifndef SYNTHESIS
                if ((group_lane_mask[cmd_channel_group] != 0) &&
                    (group_lane_mask[cmd_channel_group] != cmd_lane_mask))
                    $error("inconsistent tail mask for DW channel group %0d", cmd_channel_group);
                group_lane_mask[cmd_channel_group] <= cmd_lane_mask;
`endif
            end
            if (write_fire) begin
                cmd_valid <= 1; cmd_epoch <= dw_write_epoch;
                cmd_block_id <= dw_write_block_id; cmd_pixel_idx <= dw_write_pixel_idx;
                cmd_pixel_valid <= dw_write_pixel_valid;
                cmd_channel_group <= dw_write_channel_group;
                cmd_data <= dw_write_data; cmd_lane_mask <= dw_write_lane_mask;
            end else if (cmd_retire) cmd_valid <= 0;
            if (commit_fire) begin owner <= OWNER_COMMITTED; commit_pulse <= 1; end
            if (pw_acquire_fire) begin owner <= OWNER_PW; acquire_pulse <= 1; end
            if (pw_read_fire) begin
                pw_out_valid <= 1; pw_out_epoch <= pw_read_epoch;
                pw_out_block_id <= pw_read_block_id;
                read_physical_bank <= mem_rd_bank; read_physical_addr <= mem_rd_addr;
                read_channel_lane <= pw_read_channel_idx[1:0];
                read_pixel_mask <= expected_pixels; read_channel_valid <= channel_valid;
            end
            if (pw_release_fire) begin owner <= OWNER_FREE; release_pulse <= 1; end
        end
    end
endmodule
`default_nettype wire
