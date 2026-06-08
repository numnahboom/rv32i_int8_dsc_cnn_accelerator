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
    reg signed [7:0] mem [0:8191];
    integer i;
    integer init_i;
    integer wr_lane;
    integer rd_pixel;
    integer wr_channel;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_data_vector <= 64'sd0;
            /* verilator lint_off BLKSEQ */
            for (init_i = 0; init_i < 8192; init_i = init_i + 1) begin
                mem[init_i] = 8'sd0;
            end
            /* verilator lint_on BLKSEQ */
        end else begin
            /* verilator lint_off BLKSEQ */
            for (wr_lane = 0; wr_lane < WRITE_LANES; wr_lane = wr_lane + 1) begin
                wr_channel = wr_channel_base + wr_lane;
                if (wr_en_vec[wr_lane] && wr_channel < 128) begin
                    mem[{wr_pixel_idx, 7'b0} + wr_channel[6:0]] <=
                        wr_data_vec[(wr_lane*8) +: 8];
                end
            end
            /* verilator lint_on BLKSEQ */
            if (rd_en) begin
                /* verilator lint_off BLKSEQ */
                for (i = 0; i < 8; i = i + 1) begin
                    rd_pixel = rd_pixel_base + i;
                    if (rd_pixel < 64) begin
                        rd_data_vector[(i*8) +: 8] <= mem[{rd_pixel[5:0], 7'b0} + {6'b0, rd_channel_idx}];
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
