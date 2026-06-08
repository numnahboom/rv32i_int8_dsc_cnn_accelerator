`timescale 1ns/1ps
`default_nettype none

module dw_tile_buffer (
    input  wire              clk,
    input  wire              rst_n,

    input  wire              wr_en,
    input  wire [5:0]        wr_pixel_idx,
    input  wire [6:0]        wr_channel_idx,
    input  wire signed [7:0] wr_data_int8,

    input  wire              rd_en,
    input  wire [5:0]        rd_pixel_base,
    input  wire [6:0]        rd_channel_idx,
    output reg  signed [63:0] rd_data_vector
);
    reg signed [7:0] mem [0:8191];
    integer i;
    integer init_i;
    integer rd_pixel;

    wire [12:0] wr_addr;
    assign wr_addr = {wr_pixel_idx, 7'b0} + {6'b0, wr_channel_idx};

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_data_vector <= 64'sd0;
            /* verilator lint_off BLKSEQ */
            for (init_i = 0; init_i < 8192; init_i = init_i + 1) begin
                mem[init_i] = 8'sd0;
            end
            /* verilator lint_on BLKSEQ */
        end else begin
            if (wr_en) begin
                mem[wr_addr] <= wr_data_int8;
            end
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
