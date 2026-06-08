`timescale 1ns/1ps
`default_nettype none

module dw_tile_buffer #(
    parameter WRITE_LANES = 16
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire [WRITE_LANES-1:0] wr_en_vec,
    input  wire [5:0]        wr_pixel_idx,
    input  wire [6:0]        wr_channel_base,
    input  wire signed [(WRITE_LANES*8)-1:0] wr_data_vec,

    input  wire              rd_en,
    input  wire [5:0]        rd_pixel_base,
    input  wire [6:0]        rd_channel_idx,
    output reg  signed [63:0] rd_data_vector
);
    localparam BANKS = 16;
    localparam BANK_DEPTH = 512;  // 64 pixels * 8 channel groups.

    reg signed [7:0] bank_mem [0:BANKS-1][0:BANK_DEPTH-1];
    integer i;
    integer wr_lane;
    integer rd_pixel;
    integer wr_channel;
    integer wr_bank;
    integer wr_addr;
    integer rd_bank;
    integer rd_addr;

`ifndef SYNTHESIS
    integer init_bank;
    integer init_addr;
    initial begin
        /* verilator lint_off BLKSEQ */
        for (init_bank = 0; init_bank < BANKS; init_bank = init_bank + 1) begin
            for (init_addr = 0; init_addr < BANK_DEPTH; init_addr = init_addr + 1) begin
                bank_mem[init_bank][init_addr] = 8'sd0;
            end
        end
        /* verilator lint_on BLKSEQ */
    end
`endif

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_data_vector <= 64'sd0;
        end else begin
            /* verilator lint_off BLKSEQ */
            for (wr_lane = 0; wr_lane < WRITE_LANES; wr_lane = wr_lane + 1) begin
                wr_channel = wr_channel_base + wr_lane;
                if (wr_en_vec[wr_lane] && wr_channel < 128) begin
                    wr_bank = wr_channel[3:0];
                    wr_addr = {wr_pixel_idx, wr_channel[6:4]};
                    bank_mem[wr_bank][wr_addr] <= wr_data_vec[(wr_lane*8) +: 8];
                end
            end
            /* verilator lint_on BLKSEQ */
            if (rd_en) begin
                /* verilator lint_off BLKSEQ */
                rd_bank = rd_channel_idx[3:0];
                for (i = 0; i < 8; i = i + 1) begin
                    rd_pixel = rd_pixel_base + i;
                    if (rd_pixel < 64) begin
                        rd_addr = {rd_pixel[5:0], rd_channel_idx[6:4]};
                        rd_data_vector[(i*8) +: 8] <= bank_mem[rd_bank][rd_addr];
                    end else begin
                        rd_data_vector[(i*8) +: 8] <= 8'sd0;
                    end
                end
                /* verilator lint_on BLKSEQ */
            end
        end
    end
endmodule

`default_nettype wire
