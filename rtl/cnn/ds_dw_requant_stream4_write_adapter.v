`timescale 1ns/1ps
`default_nettype none

/* Converts one registered sixteen-lane DW result into four four-lane stream
 * beats.  The stream's own elastic pipe retains the pixel/chunk identity;
 * this adapter only retains one raw result while its four beats are issued. */
module ds_dw_requant_stream4_write_adapter (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire [5:0] pixel_idx_in,
    input wire [15:0] lane_mask_in,
    input wire signed [511:0] raw_vec_in,
    input wire signed [511:0] multiplier_vec_in,
    input wire [95:0] shift_vec_in,
    input wire signed [31:0] output_zero_point,
    input wire signed [31:0] activation_min,
    input wire signed [31:0] activation_max,
    output wire valid_out, input wire ready_out,
    output wire [5:0] pixel_idx_out,
    output wire [1:0] lane_base_out,
    output wire [31:0] data_out,
    output wire [3:0] lane_mask_out,
    output wire busy
);
    reg active;
    reg [2:0] issue_idx;
    reg [5:0] pixel_reg;
    reg [15:0] mask_reg;
    reg signed [511:0] raw_reg;
    reg signed [511:0] multiplier_reg;
    reg [95:0] shift_reg;
    wire stream_ready;
    wire stream_valid;
    wire [5:0] stream_pixel;
    wire [6:0] stream_channel;
    wire [3:0] stream_mask;
    wire signed [31:0] stream_data;
    wire stream_busy;
    wire issue_valid = active && (issue_idx < 3'd4);

    requant_activation_stream4_masked u_stream (
        .clk(clk), .rst_n(rst_n), .valid_in(issue_valid), .ready_in(stream_ready),
        .acc_vec(raw_reg[(issue_idx*128) +: 128]),
        .bias_vec(128'sd0),
        .multiplier_vec(multiplier_reg[(issue_idx*128) +: 128]),
        .shift_vec(shift_reg[(issue_idx*24) +: 24]),
        .pixel_idx(pixel_reg), .channel_idx({2'b0, issue_idx, 2'b0}),
        .lane_mask(mask_reg[(issue_idx*4) +: 4]),
        .output_zero_point_int32(output_zero_point),
        .activation_min_int32(activation_min),
        .activation_max_int32(activation_max), .ready_out(ready_out),
        .valid_out(stream_valid), .out_pixel_idx(stream_pixel),
        .out_channel_idx(stream_channel), .out_lane_mask(stream_mask),
        .out_data_int8(stream_data), .busy(stream_busy)
    );
    assign ready_in = rst_n && !active;
    assign valid_out = stream_valid;
    assign pixel_idx_out = stream_pixel;
    assign lane_base_out = stream_channel[3:2];
    assign data_out = stream_data;
    assign lane_mask_out = stream_mask;
    assign busy = active | stream_busy;

    wire input_fire = valid_in && ready_in;
    wire issue_fire = issue_valid && stream_ready;
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0; issue_idx <= 0; pixel_reg <= 0;
            mask_reg <= 0; raw_reg <= 0; multiplier_reg <= 0; shift_reg <= 0;
        end else begin
            if (input_fire) begin
                active <= 1'b1; issue_idx <= 0; pixel_reg <= pixel_idx_in;
                mask_reg <= lane_mask_in; raw_reg <= raw_vec_in;
                multiplier_reg <= multiplier_vec_in; shift_reg <= shift_vec_in;
            end else if (issue_fire) begin
                if (issue_idx == 3) active <= 1'b0;
                else issue_idx <= issue_idx + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
