`timescale 1ns/1ps
`default_nettype none

module status_counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,
    input  wire        enable,
    input  wire        layer_start,
    input  wire [7:0]  layer_idx,
    output reg  [31:0] total_cycles,
    output reg  [31:0] layer_cycles,
    output reg  [7:0]  active_layer
);
    always @(posedge clk) begin
        if (!rst_n) begin
            total_cycles <= 32'd0;
            layer_cycles <= 32'd0;
            active_layer <= 8'd0;
        end else if (clear) begin
            total_cycles <= 32'd0;
            layer_cycles <= 32'd0;
            active_layer <= layer_idx;
        end else begin
            if (layer_start) begin
                layer_cycles <= 32'd0;
                active_layer <= layer_idx;
            end else if (enable) begin
                layer_cycles <= layer_cycles + 32'd1;
            end

            if (enable) begin
                total_cycles <= total_cycles + 32'd1;
            end
        end
    end
endmodule

`default_nettype wire
