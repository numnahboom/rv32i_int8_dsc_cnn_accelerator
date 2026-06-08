`timescale 1ns/1ps
`default_nettype none

module pw_systolic_array_8x8 (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 valid_in,
    output wire                 ready_in,
    input  wire                 clear_acc,
    input  wire                 k_last,
    input  wire signed [63:0]   act_vec,
    input  wire signed [63:0]   wgt_vec,

    input  wire                 ready_out,
    output reg                  valid_out,
    output reg  signed [2047:0] psum_out
);
    wire fire;
    reg k_last_d;

    wire signed [31:0] pe_psum [0:7][0:7];
    wire pe_valid [0:7][0:7];
    wire signed [7:0] unused_act [0:7][0:7];
    wire signed [7:0] unused_wgt [0:7][0:7];

    genvar r;
    genvar c;
    generate
        for (r = 0; r < 8; r = r + 1) begin : gen_rows
            for (c = 0; c < 8; c = c + 1) begin : gen_cols
                systolic_pe u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .valid_in(fire),
                    .clear_acc(clear_acc),
                    .act_in(act_vec[(r*8) +: 8]),
                    .wgt_in(wgt_vec[(c*8) +: 8]),
                    .valid_out(pe_valid[r][c]),
                    .act_out(unused_act[r][c]),
                    .wgt_out(unused_wgt[r][c]),
                    .psum_out(pe_psum[r][c])
                );
            end
        end
    endgenerate

    assign ready_in = (!valid_out) || ready_out;
    assign fire = valid_in && ready_in;

    integer i;
    integer j;

    always @(posedge clk) begin
        if (!rst_n) begin
            k_last_d <= 1'b0;
            valid_out <= 1'b0;
            psum_out <= 2048'sd0;
        end else begin
            if (valid_out && ready_out) begin
                valid_out <= 1'b0;
            end

            if (k_last_d && ((!valid_out) || ready_out)) begin
                for (i = 0; i < 8; i = i + 1) begin
                    for (j = 0; j < 8; j = j + 1) begin
                        psum_out[((i*8 + j)*32) +: 32] <= pe_psum[i][j];
                    end
                end
                valid_out <= 1'b1;
            end

            if (ready_in) begin
                k_last_d <= fire && k_last;
            end
        end
    end
endmodule

`default_nettype wire
