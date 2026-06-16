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
    localparam BANK_COUNT = 128;  // 16 channel banks x 8 pixel-lane banks.
    localparam BANK_DEPTH = 64;   // 8 pixel groups x 8 channel groups.

    reg  [BANK_COUNT-1:0]        bank_wr_en;
    reg  [(BANK_COUNT*6)-1:0]    bank_wr_addr;
    reg  signed [(BANK_COUNT*8)-1:0] bank_wr_data;
    reg  [(BANK_COUNT*6)-1:0]    bank_rd_addr;
    wire signed [(BANK_COUNT*8)-1:0] bank_rd_data;

    integer wr_lane;
    integer wr_channel;
    integer wr_bank_idx;
    integer wr_addr;
    integer lane;
    integer rd_pixel;
    integer rd_bank_idx;
    integer rd_addr;

    genvar bank_g;
    generate
        for (bank_g = 0; bank_g < BANK_COUNT; bank_g = bank_g + 1) begin : gen_banks
            dw_tile_buffer_bank #(
                .BANK_DEPTH(BANK_DEPTH)
            ) u_bank (
                .clk(clk),
                .wr_en(bank_wr_en[bank_g]),
                .wr_addr(bank_wr_addr[(bank_g*6) +: 6]),
                .wr_data(bank_wr_data[(bank_g*8) +: 8]),
                .rd_addr(bank_rd_addr[(bank_g*6) +: 6]),
                .rd_data(bank_rd_data[(bank_g*8) +: 8])
            );
        end
    endgenerate

    always @(*) begin
        bank_wr_en = {BANK_COUNT{1'b0}};
        bank_wr_addr = {(BANK_COUNT*6){1'b0}};
        bank_wr_data = {(BANK_COUNT*8){1'b0}};

        /* verilator lint_off BLKSEQ */
        for (wr_lane = 0; wr_lane < WRITE_LANES; wr_lane = wr_lane + 1) begin
            wr_channel = wr_channel_base + wr_lane;
            if (wr_en_vec[wr_lane] && wr_channel < 128) begin
                wr_bank_idx = {wr_channel[3:0], wr_pixel_idx[2:0]};
                wr_addr = {wr_pixel_idx[5:3], wr_channel[6:4]};
                bank_wr_en[wr_bank_idx] = 1'b1;
                bank_wr_addr[(wr_bank_idx*6) +: 6] = wr_addr[5:0];
                bank_wr_data[(wr_bank_idx*8) +: 8] = wr_data_vec[(wr_lane*8) +: 8];
            end
        end

        bank_rd_addr = {(BANK_COUNT*6){1'b0}};
        for (lane = 0; lane < 8; lane = lane + 1) begin
            rd_pixel = rd_pixel_base + lane;
            if (rd_pixel < 64) begin
                rd_bank_idx = {rd_channel_idx[3:0], rd_pixel[2:0]};
                rd_addr = {rd_pixel[5:3], rd_channel_idx[6:4]};
                bank_rd_addr[(rd_bank_idx*6) +: 6] = rd_addr[5:0];
            end
        end
        /* verilator lint_on BLKSEQ */
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_data_vector <= 64'sd0;
        end else if (rd_en) begin
            /* verilator lint_off BLKSEQ */
            for (lane = 0; lane < 8; lane = lane + 1) begin
                rd_pixel = rd_pixel_base + lane;
                if (rd_pixel < 64) begin
                    rd_bank_idx = {rd_channel_idx[3:0], rd_pixel[2:0]};
                    rd_data_vector[(lane*8) +: 8] <= bank_rd_data[(rd_bank_idx*8) +: 8];
                end else begin
                    rd_data_vector[(lane*8) +: 8] <= 8'sd0;
                end
            end
            /* verilator lint_on BLKSEQ */
        end
    end
endmodule

module dw_tile_buffer_bank #(
    parameter BANK_DEPTH = 64
) (
    input  wire             clk,
    input  wire             wr_en,
    input  wire [5:0]       wr_addr,
    input  wire signed [7:0] wr_data,
    input  wire [5:0]       rd_addr,
    output wire signed [7:0] rd_data
);
    reg signed [7:0] mem [0:BANK_DEPTH-1];

`ifndef SYNTHESIS
    integer init_addr;
    initial begin
        /* verilator lint_off BLKSEQ */
        for (init_addr = 0; init_addr < BANK_DEPTH; init_addr = init_addr + 1) begin
            mem[init_addr] = 8'sd0;
        end
        /* verilator lint_on BLKSEQ */
    end
`endif

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    assign rd_data = mem[rd_addr];
endmodule

`default_nettype wire
