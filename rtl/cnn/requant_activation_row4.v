`timescale 1ns/1ps
`default_nettype none

/*
 * Four-lane row drain for the non-production PW row-bank prototype.
 *
 * Four result bytes are presented as one packed transaction, but the exact
 * existing requant unit is time-multiplexed across the four lanes.  This is
 * intentional: requant_activation_unit maps its exact 32x32 Q31 operation
 * to four DSP48E1s, so one shared instance holds the row sink to four DSPs
 * total.  A beat takes four scalar issue cycles internally; the registered
 * packed sink keeps that serialization private and presents one stable
 * 32-bit word under arbitrary output backpressure.
 */
module requant_activation_row4 (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire signed [127:0] acc_vec,
    input wire signed [127:0] bias_vec,
    input wire signed [127:0] multiplier_vec,
    input wire [23:0] shift_vec,
    input wire [2:0] row_idx,
    input wire beat_idx,
    input wire [5:0] pixel_base,
    input wire [8:0] cout_base,
    input wire [3:0] lane_mask,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out,
    output wire valid_out,
    output wire [2:0] out_row_idx,
    output wire out_beat_idx,
    output wire [5:0] out_pixel_idx,
    output wire [8:0] out_channel_base,
    output wire [3:0] out_lane_mask,
    output wire signed [31:0] out_data,
    output wire busy
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_ISSUE = 2'd1;
    localparam [1:0] ST_COLLECT = 2'd2;
    localparam [1:0] ST_OUTPUT = 2'd3;

    reg [1:0] state;
    reg [2:0] issue_lane;
    reg [2:0] collect_lane;
    reg signed [31:0] acc_hold [0:3];
    reg signed [31:0] bias_hold [0:3];
    reg signed [31:0] multiplier_hold [0:3];
    reg [5:0] shift_hold [0:3];
    reg [3:0] mask_hold;
    reg [2:0] row_hold;
    reg beat_hold;
    reg [5:0] pixel_hold;
    reg [8:0] cout_hold;
    reg signed [31:0] zp_hold, min_hold, max_hold;
    reg signed [31:0] packed_data;

    wire core_ready_in;
    wire core_valid_in = (state == ST_ISSUE);
    wire core_valid_out;
    wire signed [7:0] core_data;
    /* Keep the exact unit's elastic pipeline flowing during scalar issue and
     * collection.  The final byte is accepted before entering ST_OUTPUT. */
    wire core_ready_out = (state == ST_ISSUE) || (state == ST_COLLECT);
    wire core_input_fire = core_valid_in && core_ready_in;
    wire core_output_fire = core_valid_out && core_ready_out;

    requant_activation_unit u_core (
        .clk(clk), .rst_n(rst_n), .valid_in(core_valid_in),
        .ready_in(core_ready_in), .acc_int32(acc_hold[issue_lane]),
        .bias_int32(bias_hold[issue_lane]),
        .multiplier_int32(multiplier_hold[issue_lane]),
        .shift(shift_hold[issue_lane]),
        .output_zero_point_int32(zp_hold),
        .activation_min_int32(min_hold),
        .activation_max_int32(max_hold),
        .ready_out(core_ready_out), .valid_out(core_valid_out),
        .output_int8(core_data)
    );

    assign ready_in = rst_n && (state == ST_IDLE);
    assign valid_out = (state == ST_OUTPUT);
    assign out_row_idx = row_hold;
    assign out_beat_idx = beat_hold;
    assign out_pixel_idx = pixel_hold + row_hold;
    assign out_channel_base = cout_hold + (beat_hold ? 9'd4 : 9'd0);
    assign out_lane_mask = mask_hold;
    assign out_data = packed_data;
    assign busy = (state != ST_IDLE);

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            issue_lane <= 3'd0;
            collect_lane <= 3'd0;
            mask_hold <= 4'd0; row_hold <= 3'd0; beat_hold <= 1'b0;
            pixel_hold <= 6'd0; cout_hold <= 9'd0; packed_data <= 32'sd0;
            zp_hold <= 32'sd0; min_hold <= 32'sd0; max_hold <= 32'sd0;
            for (i = 0; i < 4; i = i + 1) begin
                acc_hold[i] <= 32'sd0; bias_hold[i] <= 32'sd0;
                multiplier_hold[i] <= 32'sd0; shift_hold[i] <= 6'd0;
            end
        end else begin
            if ((state == ST_IDLE) && valid_in) begin
                for (i = 0; i < 4; i = i + 1) begin
                    acc_hold[i] <= acc_vec[(i*32) +: 32];
                    bias_hold[i] <= bias_vec[(i*32) +: 32];
                    multiplier_hold[i] <= multiplier_vec[(i*32) +: 32];
                    shift_hold[i] <= shift_vec[(i*6) +: 6];
                end
                mask_hold <= lane_mask;
                row_hold <= row_idx; beat_hold <= beat_idx;
                pixel_hold <= pixel_base; cout_hold <= cout_base;
                zp_hold <= output_zero_point_int32;
                min_hold <= activation_min_int32;
                max_hold <= activation_max_int32;
                issue_lane <= 3'd0;
                collect_lane <= 3'd0;
                state <= ST_ISSUE;
            end

            if (core_input_fire) begin
                if (issue_lane == 3'd3) begin
                    collect_lane <= 3'd0;
                    state <= ST_COLLECT;
                end else begin
                    issue_lane <= issue_lane + 3'd1;
                end
            end

            if (core_output_fire) begin
                packed_data[(collect_lane*8) +: 8] <= core_data;
                if (collect_lane == 3'd3) begin
                    state <= ST_OUTPUT;
                end else begin
                    collect_lane <= collect_lane + 3'd1;
                end
            end

            if ((state == ST_OUTPUT) && ready_out)
                state <= ST_IDLE;
        end
    end
endmodule

`default_nettype wire
