`timescale 1ns/1ps
`default_nettype none

module gap_unit (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    output reg                          busy,
    output reg                          done,
    input  wire signed [(4*4*256*8)-1:0] feature_in,
    output reg  signed [(256*8)-1:0]    gap_out
);
    localparam ST_IDLE = 2'd0;
    localparam ST_RUN = 2'd1;
    localparam ST_DONE = 2'd2;

    reg [1:0] state;
    reg [8:0] channel_idx;

    /* verilator lint_off BLKSEQ */
    function signed [7:0] gap_avg;
        input integer channel;
        integer y;
        integer x;
        integer bit_base;
        reg signed [7:0] value;
        reg signed [31:0] sum;
        reg signed [31:0] avg;
        begin
            sum = 32'sd0;
            for (y = 0; y < 4; y = y + 1) begin
                for (x = 0; x < 4; x = x + 1) begin
                    bit_base = (((y * 4 * 256) + (x * 256) + channel) * 8);
                    value = feature_in[bit_base +: 8];
                    sum = sum + {{24{value[7]}}, value};
                end
            end
            avg = sum >>> 4;
            if (avg > 32'sd127) begin
                gap_avg = 8'sd127;
            end else if (avg < -32'sd128) begin
                gap_avg = -8'sd128;
            end else begin
                gap_avg = avg[7:0];
            end
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            channel_idx <= 9'd0;
            gap_out <= 2048'sd0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        channel_idx <= 9'd0;
                        state <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    gap_out[(channel_idx*8) +: 8] <= gap_avg(channel_idx);
                    if (channel_idx == 9'd255) begin
                        state <= ST_DONE;
                    end else begin
                        channel_idx <= channel_idx + 9'd1;
                    end
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
