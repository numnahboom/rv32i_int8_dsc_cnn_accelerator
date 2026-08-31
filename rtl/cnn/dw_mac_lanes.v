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
    /* The original implementation performed three 8x8 products, two adds,
     * and the 32-bit accumulator add in one cycle.  That is functionally
     * compact but creates a long carry/routing cone on every lane.  Keep the
     * single-outstanding interface and reuse the same arithmetic operators,
     * but explicitly separate product, row-sum, and accumulate phases. */
    reg [1:0] cycle_idx;
    reg [1:0] mac_phase;
    reg [LANES-1:0] lane_active_r;
    /* Each lane keeps the current 3-tap row and the two future rows in
     * dedicated registers.  This makes the product stage fixed-lane/fixed-
     * tap; cycle_idx only selects the next row at the already registered
     * accumulate boundary instead of driving a wide arithmetic input mux. */
    reg signed [7:0] pixel_cur0 [0:LANES-1];
    reg signed [7:0] pixel_cur1 [0:LANES-1];
    reg signed [7:0] pixel_cur2 [0:LANES-1];
    reg signed [7:0] weight_cur0 [0:LANES-1];
    reg signed [7:0] weight_cur1 [0:LANES-1];
    reg signed [7:0] weight_cur2 [0:LANES-1];
    reg signed [7:0] pixel_row1_0 [0:LANES-1];
    reg signed [7:0] pixel_row1_1 [0:LANES-1];
    reg signed [7:0] pixel_row1_2 [0:LANES-1];
    reg signed [7:0] weight_row1_0 [0:LANES-1];
    reg signed [7:0] weight_row1_1 [0:LANES-1];
    reg signed [7:0] weight_row1_2 [0:LANES-1];
    reg signed [7:0] pixel_row2_0 [0:LANES-1];
    reg signed [7:0] pixel_row2_1 [0:LANES-1];
    reg signed [7:0] pixel_row2_2 [0:LANES-1];
    reg signed [7:0] weight_row2_0 [0:LANES-1];
    reg signed [7:0] weight_row2_1 [0:LANES-1];
    reg signed [7:0] weight_row2_2 [0:LANES-1];
    reg signed [31:0] acc [0:LANES-1];
    reg signed [15:0] product0 [0:LANES-1];
    reg signed [15:0] product1 [0:LANES-1];
    reg signed [15:0] product2 [0:LANES-1];
    reg signed [31:0] row_sum_reg [0:LANES-1];

    integer lane;
    integer init_lane;

    wire input_fire;
    wire output_fire;

    assign ready_in = !busy && (!valid_out || ready_out);
    assign input_fire = valid_in && ready_in;
    assign output_fire = valid_out && ready_out;

    function signed [15:0] mul8;
        input signed [7:0] a;
        input signed [7:0] b;
        reg signed [15:0] a_wide;
        reg signed [15:0] b_wide;
        begin
            a_wide = a;
            b_wide = b;
            mul8 = a_wide * b_wide;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            valid_out <= 1'b0;
            cycle_idx <= 2'd0;
            mac_phase <= 2'd0;
            lane_active_r <= {LANES{1'b0}};
            acc_vec <= {(LANES*32){1'b0}};
            for (init_lane = 0; init_lane < LANES; init_lane = init_lane + 1) begin
                acc[init_lane] <= 32'sd0;
                pixel_cur0[init_lane] <= 8'sd0;
                pixel_cur1[init_lane] <= 8'sd0;
                pixel_cur2[init_lane] <= 8'sd0;
                weight_cur0[init_lane] <= 8'sd0;
                weight_cur1[init_lane] <= 8'sd0;
                weight_cur2[init_lane] <= 8'sd0;
                pixel_row1_0[init_lane] <= 8'sd0;
                pixel_row1_1[init_lane] <= 8'sd0;
                pixel_row1_2[init_lane] <= 8'sd0;
                weight_row1_0[init_lane] <= 8'sd0;
                weight_row1_1[init_lane] <= 8'sd0;
                weight_row1_2[init_lane] <= 8'sd0;
                pixel_row2_0[init_lane] <= 8'sd0;
                pixel_row2_1[init_lane] <= 8'sd0;
                pixel_row2_2[init_lane] <= 8'sd0;
                weight_row2_0[init_lane] <= 8'sd0;
                weight_row2_1[init_lane] <= 8'sd0;
                weight_row2_2[init_lane] <= 8'sd0;
                product0[init_lane] <= 16'sd0;
                product1[init_lane] <= 16'sd0;
                product2[init_lane] <= 16'sd0;
                row_sum_reg[init_lane] <= 32'sd0;
            end
        end else begin
            if (output_fire) begin
                valid_out <= 1'b0;
            end

            if (input_fire) begin
                busy <= 1'b1;
                cycle_idx <= 2'd0;
                mac_phase <= 2'd0;
                lane_active_r <= lane_active;
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    acc[lane] <= 32'sd0;
                    pixel_cur0[lane] <= window_vec[((lane*9 + 0)*8) +: 8];
                    pixel_cur1[lane] <= window_vec[((lane*9 + 1)*8) +: 8];
                    pixel_cur2[lane] <= window_vec[((lane*9 + 2)*8) +: 8];
                    weight_cur0[lane] <= weight_vec[((lane*9 + 0)*8) +: 8];
                    weight_cur1[lane] <= weight_vec[((lane*9 + 1)*8) +: 8];
                    weight_cur2[lane] <= weight_vec[((lane*9 + 2)*8) +: 8];
                    pixel_row1_0[lane] <= window_vec[((lane*9 + 3)*8) +: 8];
                    pixel_row1_1[lane] <= window_vec[((lane*9 + 4)*8) +: 8];
                    pixel_row1_2[lane] <= window_vec[((lane*9 + 5)*8) +: 8];
                    weight_row1_0[lane] <= weight_vec[((lane*9 + 3)*8) +: 8];
                    weight_row1_1[lane] <= weight_vec[((lane*9 + 4)*8) +: 8];
                    weight_row1_2[lane] <= weight_vec[((lane*9 + 5)*8) +: 8];
                    pixel_row2_0[lane] <= window_vec[((lane*9 + 6)*8) +: 8];
                    pixel_row2_1[lane] <= window_vec[((lane*9 + 7)*8) +: 8];
                    pixel_row2_2[lane] <= window_vec[((lane*9 + 8)*8) +: 8];
                    weight_row2_0[lane] <= weight_vec[((lane*9 + 6)*8) +: 8];
                    weight_row2_1[lane] <= weight_vec[((lane*9 + 7)*8) +: 8];
                    weight_row2_2[lane] <= weight_vec[((lane*9 + 8)*8) +: 8];
                end
            end else if (busy) begin
                if (mac_phase == 2'd0) begin
                    /* Registered DSP inputs/outputs: three products per lane
                     * are isolated from both the row adder and accumulator. */
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        if (lane_active_r[lane]) begin
                            product0[lane] <= mul8(
                                pixel_cur0[lane], weight_cur0[lane]);
                            product1[lane] <= mul8(
                                pixel_cur1[lane], weight_cur1[lane]);
                            product2[lane] <= mul8(
                                pixel_cur2[lane], weight_cur2[lane]);
                        end
                    end
                    mac_phase <= 2'd1;
                end else if (mac_phase == 2'd1) begin
                    /* The row sum is a separate registered stage. */
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        if (lane_active_r[lane]) begin
                            row_sum_reg[lane] <=
                                {{16{product0[lane][15]}}, product0[lane]} +
                                {{16{product1[lane][15]}}, product1[lane]} +
                                {{16{product2[lane][15]}}, product2[lane]};
                        end
                    end
                    mac_phase <= 2'd2;
                end else begin
                    /* Only the accumulator carry chain remains in this stage. */
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        if (lane_active_r[lane]) begin
                            acc[lane] <= acc[lane] + row_sum_reg[lane];
                            if (cycle_idx == 2'd2)
                                acc_vec[(lane*32) +: 32] <=
                                    acc[lane] + row_sum_reg[lane];
                        end else if (cycle_idx == 2'd2) begin
                            acc_vec[(lane*32) +: 32] <= 32'sd0;
                        end
                        if (cycle_idx == 2'd0) begin
                            pixel_cur0[lane] <= pixel_row1_0[lane];
                            pixel_cur1[lane] <= pixel_row1_1[lane];
                            pixel_cur2[lane] <= pixel_row1_2[lane];
                            weight_cur0[lane] <= weight_row1_0[lane];
                            weight_cur1[lane] <= weight_row1_1[lane];
                            weight_cur2[lane] <= weight_row1_2[lane];
                        end else if (cycle_idx == 2'd1) begin
                            pixel_cur0[lane] <= pixel_row2_0[lane];
                            pixel_cur1[lane] <= pixel_row2_1[lane];
                            pixel_cur2[lane] <= pixel_row2_2[lane];
                            weight_cur0[lane] <= weight_row2_0[lane];
                            weight_cur1[lane] <= weight_row2_1[lane];
                            weight_cur2[lane] <= weight_row2_2[lane];
                        end
                    end

                    if (cycle_idx == 2'd2) begin
                        busy <= 1'b0;
                        valid_out <= 1'b1;
                        cycle_idx <= 2'd0;
                    end else begin
                        cycle_idx <= cycle_idx + 2'd1;
                        mac_phase <= 2'd0;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
