`timescale 1ns/1ps
`default_nettype none

module tile_scheduler #(
    parameter TILE_H = 8,
    parameter TILE_W = 8
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire       next,
    input  wire [7:0] out_h,
    input  wire [7:0] out_w,
    input  wire [1:0] stride,
    output reg        valid,
    output reg [7:0]  tile_h_start,
    output reg [7:0]  tile_w_start,
    output reg [7:0]  tile_h_size,
    output reg [7:0]  tile_w_size,
    output reg [7:0]  input_tile_h,
    output reg [7:0]  input_tile_w,
    output reg        is_last_tile
);
    reg [7:0] cur_h;
    reg [7:0] cur_w;

    function [7:0] min_tile;
        input [7:0] start_pos;
        input [7:0] limit;
        input [7:0] tile_size;
        reg [8:0] remaining;
        begin
            if (start_pos >= limit) begin
                min_tile = 8'd0;
            end else begin
                remaining = {1'b0, limit} - {1'b0, start_pos};
                if (remaining > {1'b0, tile_size}) begin
                    min_tile = tile_size;
                end else begin
                    min_tile = remaining[7:0];
                end
            end
        end
    endfunction

    always @(*) begin
        tile_h_start = cur_h;
        tile_w_start = cur_w;
        tile_h_size = min_tile(cur_h, out_h, TILE_H[7:0]);
        tile_w_size = min_tile(cur_w, out_w, TILE_W[7:0]);
        if (stride == 2'd2) begin
            input_tile_h = ((tile_h_size - 8'd1) << 1) + 8'd3;
            input_tile_w = ((tile_w_size - 8'd1) << 1) + 8'd3;
        end else begin
            input_tile_h = tile_h_size + 8'd2;
            input_tile_w = tile_w_size + 8'd2;
        end
        is_last_tile = ((cur_h + tile_h_size) >= out_h) && ((cur_w + tile_w_size) >= out_w);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            valid <= 1'b0;
            cur_h <= 8'd0;
            cur_w <= 8'd0;
        end else begin
            if (start) begin
                valid <= 1'b1;
                cur_h <= 8'd0;
                cur_w <= 8'd0;
            end else if (next && valid) begin
                if (is_last_tile) begin
                    valid <= 1'b0;
                end else if ((cur_w + TILE_W[7:0]) >= out_w) begin
                    cur_w <= 8'd0;
                    cur_h <= cur_h + TILE_H[7:0];
                end else begin
                    cur_w <= cur_w + TILE_W[7:0];
                end
            end
        end
    end
endmodule

`default_nettype wire
