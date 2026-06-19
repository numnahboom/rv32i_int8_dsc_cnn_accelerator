`timescale 1ns/1ps
`default_nettype none

module dw_line_buffer (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         valid_in,
    input  wire         ready_out,
    input  wire [4:0]   x_idx,
    input  wire [4:0]   y_idx,
    input  wire [127:0] pixel_vec_in,
    output wire         ready_in,
    output reg          window_valid,
    output reg  [127:0] row0_col0,
    output reg  [127:0] row0_col1,
    output reg  [127:0] row0_col2,
    output reg  [127:0] row1_col0,
    output reg  [127:0] row1_col1,
    output reg  [127:0] row1_col2,
    output reg  [127:0] row2_col0,
    output reg  [127:0] row2_col1,
    output reg  [127:0] row2_col2
);
    (* ram_style = "distributed" *) reg [127:0] row0 [0:31];
    (* ram_style = "distributed" *) reg [127:0] row1 [0:31];

    assign ready_in = !window_valid || ready_out;

    always @(posedge clk) begin
        if (!rst_n) begin
            window_valid <= 0;

            row0_col0 <= 0;
            row0_col1 <= 0;
            row0_col2 <= 0;
            row1_col0 <= 0;
            row1_col1 <= 0;
            row1_col2 <= 0;
            row2_col0 <= 0;
            row2_col1 <= 0;
            row2_col2 <= 0;
        end else begin
            if (ready_in) begin
                if (valid_in) begin
                    row0[x_idx] <= row1[x_idx];
                    row1[x_idx] <= pixel_vec_in;

                    row0_col0 <= row0_col1;
                    row0_col1 <= row0_col2;
                    row0_col2 <= row0[x_idx];
                    row1_col0 <= row1_col1;
                    row1_col1 <= row1_col2;
                    row1_col2 <= row1[x_idx];
                    row2_col0 <= row2_col1;
                    row2_col1 <= row2_col2;
                    row2_col2 <= pixel_vec_in;

                    window_valid <= (y_idx >= 2) && (x_idx >= 2);
                end else begin
                    window_valid <= 1'b0;
                end
            end
        end
    end
endmodule

`default_nettype wire
