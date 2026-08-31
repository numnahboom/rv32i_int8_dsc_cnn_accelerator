`timescale 1ns/1ps
`default_nettype none

/*
 * Spatial DW producer island.
 *
 * The scheduler presents one narrow, registered token stream to this island.
 * Configuration and tap addressing terminate at the island boundary; the
 * island owns the direct DW pipeline, quantization pipeline, and one elastic
 * registered write-command slot.  No BRAM enable is derived from the remote
 * command payload: the bank island captures this command before asserting its
 * local memory write.
 */
module ds_spatial_dw_producer_island (
    input wire clk, input wire rst_n,
    input wire cfg_valid, output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,
    input wire valid_in, output wire ready_in,
    input wire first_tap, input wire last_tap, input wire [3:0] tap_idx,
    input wire [7:0] pixel_idx, input wire [15:0] lane_mask,
    input wire signed [127:0] act_vec,
    input wire signed [31:0] output_zero_point,
    input wire signed [31:0] activation_min,
    input wire signed [31:0] activation_max,
    input wire [2:0] command_group,
    output wire command_valid, input wire command_ready,
    output wire [2:0] command_pixel_idx, output wire command_pixel_valid,
    output wire [2:0] command_channel_group,
    output wire [127:0] command_data, output wire [15:0] command_lane_mask
);
    wire core_valid_out;
    wire core_ready_out;
    wire [7:0] core_pixel_idx;
    wire [15:0] core_lane_mask;
    wire signed [511:0] core_raw_vec;
    wire signed [511:0] core_bias_vec;
    wire signed [511:0] core_multiplier_vec;
    wire [95:0] core_shift_vec;

    dw_direct_3x3_dsp u_core (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .valid_in(valid_in), .ready_in(ready_in),
        .first_tap(first_tap), .last_tap(last_tap), .tap_idx(tap_idx),
        .pixel_idx(pixel_idx), .lane_mask(lane_mask), .act_vec(act_vec),
        .valid_out(core_valid_out), .ready_out(core_ready_out),
        .out_pixel_idx(core_pixel_idx), .out_lane_mask(core_lane_mask),
        .out_raw_vec(core_raw_vec), .out_bias_vec(core_bias_vec),
        .out_multiplier_vec(core_multiplier_vec), .out_shift_vec(core_shift_vec)
    );

    wire [15:0] rq_valid_lane;
    wire [15:0] rq_ready_lane;
    wire signed [7:0] rq_data [0:15];
    wire rq_advance = !command_valid || command_ready;
    assign core_ready_out = rq_ready_lane[0];

    genvar lane_g;
    generate
        for (lane_g = 0; lane_g < 16; lane_g = lane_g + 1) begin : gen_rq
            wire signed [31:0] lane_acc = core_raw_vec[(lane_g*32) +: 32];
            wire signed [31:0] lane_mul = core_multiplier_vec[(lane_g*32) +: 32];
            wire [5:0] lane_shift = core_shift_vec[(lane_g*6) +: 6];
            requant_activation_unit u_rq (
                .clk(clk), .rst_n(rst_n), .valid_in(core_valid_out),
                .ready_in(rq_ready_lane[lane_g]), .acc_int32(lane_acc),
                .bias_int32(32'sd0), .multiplier_int32(lane_mul),
                .shift(lane_shift), .output_zero_point_int32(output_zero_point),
                .activation_min_int32(activation_min),
                .activation_max_int32(activation_max),
                .ready_out(rq_advance), .valid_out(rq_valid_lane[lane_g]),
                .output_int8(rq_data[lane_g])
            );
        end
    endgenerate

    reg [3:0] pixel_pipe [0:9];
    reg [15:0] mask_pipe [0:9];
    reg [2:0] group_pipe [0:9];
    reg command_valid_reg;
    reg [2:0] command_pixel_reg;
    reg [2:0] command_group_reg;
    reg [127:0] command_data_reg;
    reg [15:0] command_mask_reg;
    integer pi;
    integer li;
    assign command_valid = command_valid_reg;
    assign command_pixel_idx = command_pixel_reg;
    assign command_pixel_valid = command_valid_reg;
    assign command_channel_group = command_group_reg;
    assign command_data = command_data_reg;
    assign command_lane_mask = command_mask_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            command_valid_reg <= 1'b0;
            command_pixel_reg <= 3'd0;
            command_group_reg <= 3'd0;
            command_data_reg <= 128'd0;
            command_mask_reg <= 16'd0;
            for (pi = 0; pi < 10; pi = pi + 1) begin
                pixel_pipe[pi] <= 4'd0;
                mask_pipe[pi] <= 16'd0;
                group_pipe[pi] <= 3'd0;
            end
        end else begin
            if (command_valid_reg && command_ready)
                command_valid_reg <= 1'b0;
            if (rq_advance) begin
                pixel_pipe[0] <= core_valid_out ? core_pixel_idx[3:0] : 4'd0;
                mask_pipe[0] <= core_valid_out ? core_lane_mask : 16'd0;
                group_pipe[0] <= command_group;
                for (pi = 1; pi < 10; pi = pi + 1) begin
                    pixel_pipe[pi] <= pixel_pipe[pi-1];
                    mask_pipe[pi] <= mask_pipe[pi-1];
                    group_pipe[pi] <= group_pipe[pi-1];
                end
            end
            if (rq_valid_lane[0] && rq_advance) begin
                command_valid_reg <= 1'b1;
                command_pixel_reg <= pixel_pipe[9][2:0];
                command_group_reg <= group_pipe[9];
                command_mask_reg <= mask_pipe[9];
                for (li = 0; li < 16; li = li + 1)
                    command_data_reg[(li*8) +: 8] <= rq_data[li];
            end
        end
    end
endmodule

`default_nettype wire
