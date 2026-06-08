`timescale 1ns/1ps
`default_nettype none

module feature_sram_bank #(
    parameter ADDR_WIDTH = 15,
    parameter DATA_WIDTH = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         wr_en,
    input  wire [ADDR_WIDTH-1:0]        wr_addr,
    input  wire signed [DATA_WIDTH-1:0] wr_data,

    input  wire                         rd_en,
    input  wire [ADDR_WIDTH-1:0]        rd_addr,
    output reg                          rd_valid,
    output reg  signed [DATA_WIDTH-1:0] rd_data
);
    localparam DEPTH = (1 << ADDR_WIDTH);

    reg signed [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
            rd_data <= {DATA_WIDTH{1'b0}};
        end else begin
            rd_valid <= rd_en;
            if (wr_en) begin
                mem[wr_addr] <= wr_data;
            end
            if (rd_en) begin
                if (wr_en && (wr_addr == rd_addr)) begin
                    rd_data <= wr_data;
                end else begin
                    rd_data <= mem[rd_addr];
                end
            end
        end
    end
endmodule

`default_nettype wire
