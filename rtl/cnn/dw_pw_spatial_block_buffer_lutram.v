`timescale 1ns/1ps
`default_nettype none

/*
 * LUTRAM-backed twin-bank DW/PW block buffer candidate.
 *
 * The externally visible protocol is intentionally identical to
 * dw_pw_spatial_block_buffer.  Each physical memory is only 8 x 256 bits;
 * the explicit ram_style attribute keeps this shallow storage in distributed
 * RAM instead of consuming RAMB36 tiles.  A registered DW command separates
 * the scheduler from the write byte enables and permits capture and retire in
 * the same cycle.
 */
module dw_pw_spatial_block_buffer_lutram #(
    parameter EPOCH_WIDTH = 2,
    parameter BLOCK_ID_WIDTH = 8
) (
    input wire clk, input wire rst_n,
    input wire dw_acquire_valid, output wire dw_acquire_ready,
    input wire dw_acquire_bank,
    input wire [EPOCH_WIDTH-1:0] dw_acquire_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_acquire_block_id,
    input wire [7:0] dw_acquire_pixel_mask,
    input wire [7:0] dw_acquire_group_mask,
    input wire dw_write_valid, output wire dw_write_ready,
    input wire dw_write_bank,
    input wire [EPOCH_WIDTH-1:0] dw_write_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_write_block_id,
    input wire [2:0] dw_write_pixel_idx,
    input wire dw_write_pixel_valid,
    input wire [2:0] dw_write_channel_group,
    input wire [127:0] dw_write_data,
    input wire [15:0] dw_write_lane_mask,
    input wire dw_commit_valid, output wire dw_commit_ready,
    input wire dw_commit_bank,
    input wire [EPOCH_WIDTH-1:0] dw_commit_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_commit_block_id,
    input wire pw_acquire_valid, output wire pw_acquire_ready,
    input wire pw_acquire_bank,
    input wire [EPOCH_WIDTH-1:0] pw_acquire_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_acquire_block_id,
    input wire pw_read_valid, output wire pw_read_ready,
    input wire pw_read_bank,
    input wire [EPOCH_WIDTH-1:0] pw_read_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_read_block_id,
    input wire [6:0] pw_read_channel_idx,
    output reg pw_out_valid, input wire pw_out_ready,
    output reg [EPOCH_WIDTH-1:0] pw_out_epoch,
    output reg [BLOCK_ID_WIDTH-1:0] pw_out_block_id,
    output reg pw_out_bank,
    output wire [63:0] pw_out_data,
    output wire [7:0] pw_out_lane_mask,
    input wire pw_release_valid, output wire pw_release_ready,
    input wire pw_release_bank,
    input wire [EPOCH_WIDTH-1:0] pw_release_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_release_block_id,
    output reg dw_commit_pulse, output reg pw_acquire_pulse,
    output reg pw_release_pulse,
    output wire [1:0] bank0_state, output wire [1:0] bank1_state,
    output wire [EPOCH_WIDTH-1:0] bank0_epoch,
    output wire [EPOCH_WIDTH-1:0] bank1_epoch,
    output wire [BLOCK_ID_WIDTH-1:0] bank0_block_id,
    output wire [BLOCK_ID_WIDTH-1:0] bank1_block_id
);
    localparam OWNER_FREE = 2'd0;
    localparam OWNER_DW = 2'd1;
    localparam OWNER_COMMITTED = 2'd2;
    localparam OWNER_PW = 2'd3;

    reg [1:0] owner [0:1];
    reg [EPOCH_WIDTH-1:0] epoch [0:1];
    reg [BLOCK_ID_WIDTH-1:0] block_id [0:1];
    reg [7:0] expected_pixels [0:1];
    reg [7:0] expected_groups [0:1];
    reg [63:0] write_seen [0:1];
    reg [127:0] channel_valid [0:1];
`ifndef SYNTHESIS
    reg [15:0] group_lane_mask [0:1][0:7];
`endif

    assign bank0_state = owner[0];
    assign bank1_state = owner[1];
    assign bank0_epoch = epoch[0];
    assign bank1_epoch = epoch[1];
    assign bank0_block_id = block_id[0];
    assign bank1_block_id = block_id[1];

    wire acquire_bank_free = (owner[dw_acquire_bank] == OWNER_FREE);
    assign dw_acquire_ready = rst_n && acquire_bank_free;
    wire dw_acquire_fire = dw_acquire_valid && dw_acquire_ready;

    wire dw_tag_match = (owner[dw_write_bank] == OWNER_DW) &&
                        (epoch[dw_write_bank] == dw_write_epoch) &&
                        (block_id[dw_write_bank] == dw_write_block_id);
    reg dw_cmd_valid;
    reg dw_cmd_bank;
    reg [EPOCH_WIDTH-1:0] dw_cmd_epoch;
    reg [BLOCK_ID_WIDTH-1:0] dw_cmd_block_id;
    reg [2:0] dw_cmd_pixel_idx;
    reg dw_cmd_pixel_valid;
    reg [2:0] dw_cmd_channel_group;
    reg [127:0] dw_cmd_data;
    reg [15:0] dw_cmd_lane_mask;
    wire dw_cmd_retire = dw_cmd_valid;
    wire dw_cmd_capacity = !dw_cmd_valid || dw_cmd_retire;
    assign dw_write_ready = rst_n && dw_tag_match && dw_cmd_capacity;
    wire dw_write_fire = dw_write_valid && dw_write_ready;

    function automatic [63:0] completion_mask;
        input [7:0] pixel_mask;
        input [7:0] group_mask;
        integer p, g;
        begin
            completion_mask = 64'd0;
            for (p = 0; p < 8; p = p + 1)
                for (g = 0; g < 8; g = g + 1)
                    completion_mask[(p*8)+g] = pixel_mask[p] && group_mask[g];
        end
    endfunction

    wire [63:0] expected_bits_0 = completion_mask(expected_pixels[0], expected_groups[0]);
    wire [63:0] expected_bits_1 = completion_mask(expected_pixels[1], expected_groups[1]);
    wire commit_tag_match = (owner[dw_commit_bank] == OWNER_DW) &&
                            (epoch[dw_commit_bank] == dw_commit_epoch) &&
                            (block_id[dw_commit_bank] == dw_commit_block_id);
    wire commit_complete = ((write_seen[dw_commit_bank] &
                             (dw_commit_bank ? expected_bits_1 : expected_bits_0)) ==
                            (dw_commit_bank ? expected_bits_1 : expected_bits_0));
    assign dw_commit_ready = rst_n && commit_tag_match && commit_complete &&
                             !dw_cmd_valid && !(dw_write_valid && dw_write_ready);
    wire dw_commit_fire = dw_commit_valid && dw_commit_ready;

    wire pw_commit_match = (owner[pw_acquire_bank] == OWNER_COMMITTED) &&
                           (epoch[pw_acquire_bank] == pw_acquire_epoch) &&
                           (block_id[pw_acquire_bank] == pw_acquire_block_id);
    assign pw_acquire_ready = rst_n && pw_commit_match;
    wire pw_acquire_fire = pw_acquire_valid && pw_acquire_ready;

    wire pw_tag_match = (owner[pw_read_bank] == OWNER_PW) &&
                        (epoch[pw_read_bank] == pw_read_epoch) &&
                        (block_id[pw_read_bank] == pw_read_block_id);
    assign pw_read_ready = rst_n && pw_tag_match && (!pw_out_valid || pw_out_ready);
    wire pw_read_fire = pw_read_valid && pw_read_ready;
    wire pw_release_match = (owner[pw_release_bank] == OWNER_PW) &&
                            (epoch[pw_release_bank] == pw_release_epoch) &&
                            (block_id[pw_release_bank] == pw_release_block_id) &&
                            !pw_out_valid;
    assign pw_release_ready = rst_n && pw_release_match;
    wire pw_release_fire = pw_release_valid && pw_release_ready;

    wire [255:0] mem_rd_data [0:1][0:3];
    wire [255:0] mem_wr_data [0:3];
    wire [31:0] mem_wr_be [0:3];
    wire [2:0] mem_wr_addr = dw_cmd_channel_group;
    wire [2:0] mem_rd_addr = pw_read_channel_idx[6:4];
    wire [1:0] mem_rd_bank = pw_read_channel_idx[3:2];

    reg [1:0] read_physical_bank;
    reg [2:0] read_physical_addr;
    reg [1:0] read_channel_lane;
    reg [7:0] read_pixel_mask;
    reg [127:0] read_channel_valid;

    genvar wb;
    generate for (wb = 0; wb < 4; wb = wb + 1) begin : gen_write_lanes
        assign mem_wr_be[wb] = (dw_cmd_valid && dw_cmd_pixel_valid &&
                                (|dw_cmd_lane_mask))
            ? (({28'd0, dw_cmd_lane_mask[(wb*4) +: 4]}) <<
               (dw_cmd_pixel_idx * 4)) : 32'd0;
        assign mem_wr_data[wb] =
            ({{224{1'b0}}, dw_cmd_data[(wb*32) +: 32]} <<
             (dw_cmd_pixel_idx * 32));
    end endgenerate

    genvar ms, mb;
    generate
        for (ms = 0; ms < 2; ms = ms + 1) begin : gen_mem_set
            for (mb = 0; mb < 4; mb = mb + 1) begin : gen_mem_bank
                /* 8 x 256-bit memories are deliberately inferred as LUTRAM. */
                (* ram_style = "distributed" *) reg [255:0] mem [0:7];
                reg [255:0] rd_data_reg;
                integer byte_i;
                wire mem_write_enable = dw_cmd_valid &&
                                         (dw_cmd_bank == ms[0:0]);
                wire mem_read_enable = pw_read_fire &&
                                        (pw_read_bank == ms[0:0]) &&
                                        (mem_rd_bank == mb[1:0]);
                always @(posedge clk) begin
                    if (mem_write_enable)
                        for (byte_i = 0; byte_i < 32; byte_i = byte_i + 1)
                            if (mem_wr_be[mb][byte_i])
                                mem[mem_wr_addr][(byte_i*8) +: 8] <=
                                    mem_wr_data[mb][(byte_i*8) +: 8];
                    if (!rst_n)
                        rd_data_reg <= 256'd0;
                    else if (mem_read_enable)
                        rd_data_reg <= mem[mem_rd_addr];
                end
                assign mem_rd_data[ms][mb] = rd_data_reg;
            end
        end
    endgenerate

    integer rp;
    reg [63:0] pw_data_comb;
    reg [7:0] pw_mask_comb;
    always @* begin
        pw_data_comb = 64'd0;
        pw_mask_comb = 8'd0;
        for (rp = 0; rp < 8; rp = rp + 1) begin
            if (read_pixel_mask[rp] &&
                read_channel_valid[(read_physical_addr*16) +
                                   (read_physical_bank*4) + read_channel_lane]) begin
                pw_data_comb[(rp*8) +: 8] =
                    mem_rd_data[pw_out_bank][read_physical_bank][(rp*32) +
                    (read_channel_lane*8) +: 8];
                pw_mask_comb[rp] = 1'b1;
            end
        end
    end
    assign pw_out_data = pw_data_comb;
    assign pw_out_lane_mask = pw_mask_comb;

    integer si, gi;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (si = 0; si < 2; si = si + 1) begin
                owner[si] <= OWNER_FREE;
                epoch[si] <= {EPOCH_WIDTH{1'b0}};
                block_id[si] <= {BLOCK_ID_WIDTH{1'b0}};
                expected_pixels[si] <= 8'd0;
                expected_groups[si] <= 8'd0;
                write_seen[si] <= 64'd0;
                channel_valid[si] <= 128'd0;
`ifndef SYNTHESIS
                for (gi = 0; gi < 8; gi = gi + 1)
                    group_lane_mask[si][gi] <= 16'd0;
`endif
            end
            dw_cmd_valid <= 1'b0;
            dw_cmd_bank <= 1'b0;
            dw_cmd_epoch <= 0;
            dw_cmd_block_id <= 0;
            dw_cmd_pixel_idx <= 0;
            dw_cmd_pixel_valid <= 1'b0;
            dw_cmd_channel_group <= 0;
            dw_cmd_data <= 0;
            dw_cmd_lane_mask <= 0;
            pw_out_valid <= 1'b0;
            pw_out_epoch <= 0; pw_out_block_id <= 0; pw_out_bank <= 0;
            read_physical_bank <= 0; read_physical_addr <= 0;
            read_channel_lane <= 0; read_pixel_mask <= 0;
            read_channel_valid <= 0;
            dw_commit_pulse <= 1'b0;
            pw_acquire_pulse <= 1'b0;
            pw_release_pulse <= 1'b0;
        end else begin
            dw_commit_pulse <= 1'b0;
            pw_acquire_pulse <= 1'b0;
            pw_release_pulse <= 1'b0;
            if (pw_out_valid && pw_out_ready)
                pw_out_valid <= 1'b0;
            if (dw_acquire_fire) begin
                owner[dw_acquire_bank] <= OWNER_DW;
                epoch[dw_acquire_bank] <= dw_acquire_epoch;
                block_id[dw_acquire_bank] <= dw_acquire_block_id;
                expected_pixels[dw_acquire_bank] <= dw_acquire_pixel_mask;
                expected_groups[dw_acquire_bank] <= dw_acquire_group_mask;
                write_seen[dw_acquire_bank] <= 64'd0;
                channel_valid[dw_acquire_bank] <= 128'd0;
`ifndef SYNTHESIS
                for (gi = 0; gi < 8; gi = gi + 1)
                    group_lane_mask[dw_acquire_bank][gi] <= 16'd0;
`endif
            end
            if (dw_cmd_valid && dw_cmd_pixel_valid &&
                (dw_cmd_pixel_idx < 8) && (dw_cmd_channel_group < 8) &&
                (|dw_cmd_lane_mask)) begin
                write_seen[dw_cmd_bank][(dw_cmd_pixel_idx*8) +
                                         dw_cmd_channel_group] <= 1'b1;
                channel_valid[dw_cmd_bank][(dw_cmd_channel_group*16) +: 16]
                    <= dw_cmd_lane_mask;
`ifndef SYNTHESIS
                if ((group_lane_mask[dw_cmd_bank][dw_cmd_channel_group] != 0) &&
                    (group_lane_mask[dw_cmd_bank][dw_cmd_channel_group] !=
                     dw_cmd_lane_mask))
                    $error("inconsistent tail mask for DW channel group %0d",
                           dw_cmd_channel_group);
                group_lane_mask[dw_cmd_bank][dw_cmd_channel_group] <=
                    dw_cmd_lane_mask;
`endif
            end
            if (dw_write_fire) begin
                dw_cmd_valid <= 1'b1;
                dw_cmd_bank <= dw_write_bank;
                dw_cmd_epoch <= dw_write_epoch;
                dw_cmd_block_id <= dw_write_block_id;
                dw_cmd_pixel_idx <= dw_write_pixel_idx;
                dw_cmd_pixel_valid <= dw_write_pixel_valid;
                dw_cmd_channel_group <= dw_write_channel_group;
                dw_cmd_data <= dw_write_data;
                dw_cmd_lane_mask <= dw_write_lane_mask;
            end else if (dw_cmd_valid) begin
                dw_cmd_valid <= 1'b0;
            end
            if (dw_commit_fire) begin
                owner[dw_commit_bank] <= OWNER_COMMITTED;
                dw_commit_pulse <= 1'b1;
            end
            if (pw_acquire_fire) begin
                owner[pw_acquire_bank] <= OWNER_PW;
                pw_acquire_pulse <= 1'b1;
            end
            if (pw_read_fire) begin
                pw_out_valid <= 1'b1;
                pw_out_epoch <= pw_read_epoch;
                pw_out_block_id <= pw_read_block_id;
                pw_out_bank <= pw_read_bank;
                read_physical_bank <= mem_rd_bank;
                read_physical_addr <= mem_rd_addr;
                read_channel_lane <= pw_read_channel_idx[1:0];
                read_pixel_mask <= expected_pixels[pw_read_bank];
                read_channel_valid <= channel_valid[pw_read_bank];
            end
            if (pw_release_fire) begin
                owner[pw_release_bank] <= OWNER_FREE;
                pw_release_pulse <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    integer ai;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dw_write_fire && (!dw_write_pixel_valid || !(|dw_write_lane_mask)))
                $error("DW write accepted without a valid pixel/lane mask");
            if (dw_commit_fire && !commit_complete)
                $error("commit accepted before all pixel/group writes");
            if (pw_read_fire && owner[pw_read_bank] != OWNER_PW)
                $error("PW read accepted from non-PW-owned bank");
            if (pw_release_fire && pw_out_valid)
                $error("PW release accepted before output completion");
            for (ai = 0; ai < 2; ai = ai + 1)
                if (owner[ai] == OWNER_PW && owner[ai] == OWNER_DW)
                    $error("bank has conflicting DW/PW ownership");
        end
    end
`endif
endmodule

`default_nettype wire

/* Compatibility shell for the unmodified exhaustive buffer testbench. */
module dw_pw_spatial_block_buffer #(
    parameter EPOCH_WIDTH = 2,
    parameter BLOCK_ID_WIDTH = 8
) (
    input wire clk, input wire rst_n,
    input wire dw_acquire_valid, output wire dw_acquire_ready,
    input wire dw_acquire_bank, input wire [EPOCH_WIDTH-1:0] dw_acquire_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_acquire_block_id,
    input wire [7:0] dw_acquire_pixel_mask, input wire [7:0] dw_acquire_group_mask,
    input wire dw_write_valid, output wire dw_write_ready,
    input wire dw_write_bank, input wire [EPOCH_WIDTH-1:0] dw_write_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_write_block_id, input wire [2:0] dw_write_pixel_idx,
    input wire dw_write_pixel_valid, input wire [2:0] dw_write_channel_group,
    input wire [127:0] dw_write_data, input wire [15:0] dw_write_lane_mask,
    input wire dw_commit_valid, output wire dw_commit_ready,
    input wire dw_commit_bank, input wire [EPOCH_WIDTH-1:0] dw_commit_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_commit_block_id,
    input wire pw_acquire_valid, output wire pw_acquire_ready,
    input wire pw_acquire_bank, input wire [EPOCH_WIDTH-1:0] pw_acquire_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_acquire_block_id,
    input wire pw_read_valid, output wire pw_read_ready, input wire pw_read_bank,
    input wire [EPOCH_WIDTH-1:0] pw_read_epoch, input wire [BLOCK_ID_WIDTH-1:0] pw_read_block_id,
    input wire [6:0] pw_read_channel_idx, output wire pw_out_valid, input wire pw_out_ready,
    output wire [EPOCH_WIDTH-1:0] pw_out_epoch, output wire [BLOCK_ID_WIDTH-1:0] pw_out_block_id,
    output wire pw_out_bank, output wire [63:0] pw_out_data, output wire [7:0] pw_out_lane_mask,
    input wire pw_release_valid, output wire pw_release_ready, input wire pw_release_bank,
    input wire [EPOCH_WIDTH-1:0] pw_release_epoch, input wire [BLOCK_ID_WIDTH-1:0] pw_release_block_id,
    output wire dw_commit_pulse, output wire pw_acquire_pulse, output wire pw_release_pulse,
    output wire [1:0] bank0_state, output wire [1:0] bank1_state,
    output wire [EPOCH_WIDTH-1:0] bank0_epoch, output wire [EPOCH_WIDTH-1:0] bank1_epoch,
    output wire [BLOCK_ID_WIDTH-1:0] bank0_block_id, output wire [BLOCK_ID_WIDTH-1:0] bank1_block_id
);
    dw_pw_spatial_block_buffer_lutram #(.EPOCH_WIDTH(EPOCH_WIDTH), .BLOCK_ID_WIDTH(BLOCK_ID_WIDTH)) i (.*);
endmodule
