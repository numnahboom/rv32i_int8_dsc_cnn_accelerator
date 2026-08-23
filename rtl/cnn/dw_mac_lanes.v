`timescale 1ns/1ps
`default_nettype none

module dw_mac_lanes #(
    parameter LANES = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         valid_in,
    output wire                         ready_in,
    input  wire [LANES-1:0]             lane_active,
    input  wire signed [(LANES*9*8)-1:0] window_vec,
    input  wire signed [(LANES*9*8)-1:0] weight_vec,
    input  wire                         ready_out,
    output reg                          busy,
    output reg                          valid_out,
    output reg  signed [(LANES*32)-1:0] acc_vec
);
    reg [1:0] cycle_idx;
    reg [LANES-1:0] lane_active_r;
    reg signed [(LANES*9*8)-1:0] window_r;
    reg signed [(LANES*9*8)-1:0] weight_r;
    reg signed [31:0] acc [0:LANES-1];

    integer lane;
    integer init_lane;

    wire input_fire;
    wire output_fire;

    assign ready_in = !busy && (!valid_out || ready_out);
    assign input_fire = valid_in && ready_in;
    assign output_fire = valid_out && ready_out;

    function signed [31:0] row_sum;
        input integer lane_idx;
        input [1:0] row_idx;
        reg signed [7:0] a0;
        reg signed [7:0] a1;
        reg signed [7:0] a2;
        reg signed [7:0] w0;
        reg signed [7:0] w1;
        reg signed [7:0] w2;
        reg signed [15:0] p0;
        reg signed [15:0] p1;
        reg signed [15:0] p2;
        integer base;
        begin
            base = (lane_idx * 9 + row_idx * 3) * 8;
            a0 = window_r[base +: 8];
            a1 = window_r[(base + 8) +: 8];
            a2 = window_r[(base + 16) +: 8];
            w0 = weight_r[base +: 8];
            w1 = weight_r[(base + 8) +: 8];
            w2 = weight_r[(base + 16) +: 8];
            p0 = a0 * w0;
            p1 = a1 * w1;
            p2 = a2 * w2;
            row_sum = {{16{p0[15]}}, p0} + {{16{p1[15]}}, p1} + {{16{p2[15]}}, p2};
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            valid_out <= 1'b0;
            cycle_idx <= 2'd0;
            lane_active_r <= {LANES{1'b0}};
            window_r <= {(LANES*9*8){1'b0}};
            weight_r <= {(LANES*9*8){1'b0}};
            acc_vec <= {(LANES*32){1'b0}};
            for (init_lane = 0; init_lane < LANES; init_lane = init_lane + 1) begin
                acc[init_lane] <= 32'sd0;
            end
        end else begin
            if (output_fire) begin
                valid_out <= 1'b0;
            end

            if (input_fire) begin
                busy <= 1'b1;
                cycle_idx <= 2'd0;
                lane_active_r <= lane_active;
                window_r <= window_vec;
                weight_r <= weight_vec;
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    acc[lane] <= 32'sd0;
                end
            end else if (busy) begin
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    if (lane_active_r[lane]) begin
                        acc[lane] <= acc[lane] + row_sum(lane, cycle_idx);
                        if (cycle_idx == 2'd2) begin
                            acc_vec[(lane*32) +: 32] <= acc[lane] + row_sum(lane, cycle_idx);
                        end
                    end else if (cycle_idx == 2'd2) begin
                        acc_vec[(lane*32) +: 32] <= 32'sd0;
                    end
                end

                if (cycle_idx == 2'd2) begin
                    busy <= 1'b0;
                    valid_out <= 1'b1;
                    cycle_idx <= 2'd0;
                end else begin
                    cycle_idx <= cycle_idx + 2'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire
