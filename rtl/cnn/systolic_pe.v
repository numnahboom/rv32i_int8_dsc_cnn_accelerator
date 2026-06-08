`timescale 1ns/1ps
`default_nettype none

module systolic_pe (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire               clear_acc,
    input  wire signed [7:0]  act_in,
    input  wire signed [7:0]  wgt_in,
    output reg                valid_out,
    output reg  signed [7:0]  act_out,
    output reg  signed [7:0]  wgt_out,
    output reg  signed [31:0] psum_out
);
    wire signed [15:0] product;
    wire signed [31:0] product_ext;

    assign product = act_in * wgt_in;
    assign product_ext = {{16{product[15]}}, product};

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            act_out <= 8'sd0;
            wgt_out <= 8'sd0;
            psum_out <= 32'sd0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                act_out <= act_in;
                wgt_out <= wgt_in;
                if (clear_acc) begin
                    psum_out <= product_ext;
                end else begin
                    psum_out <= psum_out + product_ext;
                end
            end
        end
    end
endmodule

`default_nettype wire
