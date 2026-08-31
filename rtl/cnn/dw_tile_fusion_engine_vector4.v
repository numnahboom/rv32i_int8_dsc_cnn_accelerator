`timescale 1ns/1ps
`default_nettype none

module dw_tile_fusion_engine_vector4 #(
    parameter DW_LANES = 16,
    parameter VECTOR4_OUTPUT = 1'b1
) (
    input  wire                              clk,
    input  wire                              rst_n,

    input  wire                              valid_in,
    output wire                              ready_in,
    input  wire [4:0]                        x_idx,
    input  wire [4:0]                        y_idx,
    input  wire signed [(DW_LANES*8)-1:0]    pixel_vec_in,

    input  wire [3:0]                        out_h,
    input  wire [3:0]                        out_w,
    input  wire [1:0]                        stride,
    input  wire [6:0]                        channel_base,
    input  wire signed [(DW_LANES*9*8)-1:0]  weight_vec,
    input  wire signed [(DW_LANES*32)-1:0]   bias_vec,
    input  wire signed [(DW_LANES*32)-1:0]   multiplier_vec,
    input  wire        [(DW_LANES*6)-1:0]    shift_vec,
    input  wire signed [31:0]                output_zero_point,
    input  wire signed [31:0]                activation_min,
    input  wire signed [31:0]                activation_max,

    input  wire                              ready_out,
    // Vector output is used by the memory-oriented DS engine.  The legacy
    // scalar stream remains available for existing unit benches.
    input  wire                              ready_out_vec4,
    output wire                              valid_out,
    output wire [5:0]                        out_pixel_idx,
    output wire [6:0]                        out_channel_idx,
    output wire signed [7:0]                 out_data_int8,
    output wire                              valid_out_vec4,
    output wire [5:0]                        out_pixel_idx_vec4,
    output wire [6:0]                        out_channel_idx_vec4,
    output wire signed [31:0]                out_data_int8_vec4,
    output wire                              busy,
    output reg                               done
);
    wire lb_ready_out;
    wire lb_window_valid;
    wire [4:0] lb_window_x_idx;
    wire [4:0] lb_window_y_idx;
    wire [127:0] row0_col0;
    wire [127:0] row0_col1;
    wire [127:0] row0_col2;
    wire [127:0] row1_col0;
    wire [127:0] row1_col1;
    wire [127:0] row1_col2;
    wire [127:0] row2_col0;
    wire [127:0] row2_col1;
    wire [127:0] row2_col2;

    wire [4:0] window_origin_x;
    wire [4:0] window_origin_y;
    wire [4:0] selected_ow;
    wire [4:0] selected_oh;
    wire [9:0] selected_pixel_w;
    wire stride_supported;
    wire stride_phase_match;
    wire window_inside_output;
    wire window_selected;

    wire signed [(DW_LANES*9*8)-1:0] mac_window_vec;
    wire mac_valid_in;
    wire mac_ready_in;
    wire mac_ready_out;
    wire mac_busy;
    wire mac_valid_out;
    wire signed [(DW_LANES*32)-1:0] mac_acc_vec;
    wire mac_input_fire;
    wire mac_output_fire;

    reg transaction_active;
    reg batch_in_progress;
    reg [5:0] mac_pixel_pending;
    reg signed [(DW_LANES*32)-1:0] acc_hold;
    reg [5:0] batch_pixel_hold;
    reg [4:0] expected_outputs_remaining;
    reg batch_requant_active;
    reg [1:0] requant_group_idx;
    reg final_output_seen;
    wire rq_ready_in;
    wire rq_valid_out;
    wire rq_ready_out;
    wire [5:0] rq_pixel_out;
    wire [6:0] rq_channel_out;
    wire signed [31:0] rq_data_out;
    wire rq_busy;
    wire rq_capture_fire;
    wire vector_output_fire;
    wire scalar_output_fire;
    wire [7:0] output_pixels_w;
    wire [5:0] last_pixel_idx;
    wire input_fire;

    genvar rq_group_g;

    assign input_fire = valid_in && ready_in;
    assign window_origin_x = lb_window_x_idx - 5'd2;
    assign window_origin_y = lb_window_y_idx - 5'd2;
    assign stride_supported = (stride == 2'd1) || (stride == 2'd2);
    assign stride_phase_match =
        (stride == 2'd1) ||
        ((stride == 2'd2) &&
         (window_origin_x[0] == 1'b0) &&
         (window_origin_y[0] == 1'b0));
    assign selected_ow = (stride == 2'd2)
                       ? (window_origin_x >> 1)
                       : window_origin_x;
    assign selected_oh = (stride == 2'd2)
                       ? (window_origin_y >> 1)
                       : window_origin_y;
    assign window_inside_output =
        (selected_ow < {1'b0, out_w}) &&
        (selected_oh < {1'b0, out_h});
    assign window_selected =
        lb_window_valid &&
        stride_supported &&
        stride_phase_match &&
        window_inside_output;
    assign selected_pixel_w = (selected_oh * out_w) + selected_ow;

    assign mac_valid_in =
        lb_window_valid &&
        window_selected &&
        !batch_in_progress;
    assign mac_ready_out = !batch_requant_active;
    assign mac_input_fire = mac_valid_in && mac_ready_in;
    assign mac_output_fire = mac_valid_out && mac_ready_out;

    /*
     * Non-selected windows are discarded immediately. A selected window holds
     * the line buffer until the MAC accepts it. Only one MAC/requant batch is
     * allowed in flight, which bounds downstream storage to 16 outputs.
     */
    assign lb_ready_out = !lb_window_valid
                        ? 1'b1
                        : (!window_selected
                           ? 1'b1
                           : (!batch_in_progress && mac_ready_in));

    assign rq_capture_fire = batch_requant_active && rq_ready_in;
    assign valid_out_vec4 = VECTOR4_OUTPUT && rq_valid_out;
    assign valid_out = (!VECTOR4_OUTPUT) && rq_valid_out;
    assign out_pixel_idx_vec4 = rq_pixel_out;
    assign out_channel_idx_vec4 = rq_channel_out;
    assign out_data_int8_vec4 = rq_data_out;
    assign out_pixel_idx = rq_pixel_out;
    assign out_channel_idx = rq_channel_out;
    assign out_data_int8 = rq_data_out[7:0];
    assign vector_output_fire = valid_out_vec4 && ready_out_vec4;
    assign scalar_output_fire = valid_out && ready_out;
    assign busy =
        transaction_active ||
        batch_in_progress ||
        mac_busy ||
        mac_valid_out ||
        batch_requant_active ||
        rq_busy || rq_valid_out;

    assign output_pixels_w = out_h * out_w;
    assign last_pixel_idx =
        (output_pixels_w == 8'd0)
        ? 6'd0
        : output_pixels_w[5:0] - 6'd1;
    dw_line_buffer u_dw_line_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .ready_out(lb_ready_out),
        .x_idx(x_idx),
        .y_idx(y_idx),
        .pixel_vec_in(pixel_vec_in),
        .ready_in(ready_in),
        .window_valid(lb_window_valid),
        .window_x_idx(lb_window_x_idx),
        .window_y_idx(lb_window_y_idx),
        .row0_col0(row0_col0),
        .row0_col1(row0_col1),
        .row0_col2(row0_col2),
        .row1_col0(row1_col0),
        .row1_col1(row1_col1),
        .row1_col2(row1_col2),
        .row2_col0(row2_col0),
        .row2_col1(row2_col1),
        .row2_col2(row2_col2)
    );

    genvar lane_g;
    generate
        for (lane_g = 0; lane_g < DW_LANES; lane_g = lane_g + 1) begin : gen_window_transpose
            assign mac_window_vec[((lane_g*9 + 0)*8) +: 8] =
                row0_col0[(lane_g*8) +: 8];
            assign mac_window_vec[((lane_g*9 + 1)*8) +: 8] =
                row0_col1[(lane_g*8) +: 8];
            assign mac_window_vec[((lane_g*9 + 2)*8) +: 8] =
                row0_col2[(lane_g*8) +: 8];
            assign mac_window_vec[((lane_g*9 + 3)*8) +: 8] =
                row1_col0[(lane_g*8) +: 8];
            assign mac_window_vec[((lane_g*9 + 4)*8) +: 8] =
                row1_col1[(lane_g*8) +: 8];
            assign mac_window_vec[((lane_g*9 + 5)*8) +: 8] =
                row1_col2[(lane_g*8) +: 8];
            assign mac_window_vec[((lane_g*9 + 6)*8) +: 8] =
                row2_col0[(lane_g*8) +: 8];
            assign mac_window_vec[((lane_g*9 + 7)*8) +: 8] =
                row2_col1[(lane_g*8) +: 8];
            assign mac_window_vec[((lane_g*9 + 8)*8) +: 8] =
                row2_col2[(lane_g*8) +: 8];
        end
    endgenerate

    dw_mac_lanes #(
        .LANES(DW_LANES)
    ) u_dw_mac_lanes (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(mac_valid_in),
        .ready_in(mac_ready_in),
        .lane_active({DW_LANES{1'b1}}),
        .window_vec(mac_window_vec),
        .weight_vec(weight_vec),
        .ready_out(mac_ready_out),
        .busy(mac_busy),
        .valid_out(mac_valid_out),
        .acc_vec(mac_acc_vec)
    );

    assign rq_ready_out = VECTOR4_OUTPUT ? ready_out_vec4 : ready_out;
    wire [127:0] rq_acc_group = acc_hold[(requant_group_idx*128) +: 128];
    wire [127:0] rq_bias_group = bias_vec[(requant_group_idx*128) +: 128];
    wire [127:0] rq_mul_group = multiplier_vec[(requant_group_idx*128) +: 128];
    wire [23:0] rq_shift_group = shift_vec[(requant_group_idx*24) +: 24];
    requant_activation_stream4 u_requant_stream4 (
        .clk(clk), .rst_n(rst_n), .valid_in(batch_requant_active),
        .ready_in(rq_ready_in), .acc_vec(rq_acc_group),
        .bias_vec(rq_bias_group), .multiplier_vec(rq_mul_group),
        .shift_vec(rq_shift_group), .pixel_idx(batch_pixel_hold),
        .channel_idx(channel_base + {requant_group_idx,2'b00}),
        .output_zero_point_int32(output_zero_point),
        .activation_min_int32(activation_min),
        .activation_max_int32(activation_max), .ready_out(rq_ready_out),
        .valid_out(rq_valid_out), .out_pixel_idx(rq_pixel_out),
        .out_channel_idx(rq_channel_out), .out_data_int8(rq_data_out),
        .busy(rq_busy)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            transaction_active <= 1'b0;
            batch_in_progress <= 1'b0;
            mac_pixel_pending <= 6'd0;
            acc_hold <= {(DW_LANES*32){1'b0}};
            batch_pixel_hold <= 6'd0;
            expected_outputs_remaining <= 5'd0;
            batch_requant_active <= 1'b0;
            requant_group_idx <= 2'd0;
            final_output_seen <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            if (input_fire) begin
                transaction_active <= 1'b1;
            end

            if (mac_input_fire) begin
                batch_in_progress <= 1'b1;
                mac_pixel_pending <= selected_pixel_w[5:0];
                expected_outputs_remaining <= 5'd16;
                final_output_seen <= 1'b0;
            end

            if (mac_output_fire) begin
                acc_hold <= mac_acc_vec;
                batch_pixel_hold <= mac_pixel_pending;
                batch_requant_active <= 1'b1;
                requant_group_idx <= 2'd0;
            end

            if (rq_capture_fire) begin
                if (requant_group_idx == 2'd3)
                    batch_requant_active <= 1'b0;
                else
                    requant_group_idx <= requant_group_idx + 2'd1;
            end

            if (vector_output_fire || scalar_output_fire) begin
                if (expected_outputs_remaining <=
                    (vector_output_fire ? 3'd4 : 3'd1)) begin
                    expected_outputs_remaining <= 5'd0;
                    final_output_seen <= 1'b1;
                end else begin
                    expected_outputs_remaining <= expected_outputs_remaining -
                        (vector_output_fire ? 3'd4 : 3'd1);
                end
            end

            /* Do not launch another MAC batch until every lane FIFO has
             * observed the final pop.  This matters in scalar compatibility
             * mode where the four lane FIFOs are drained one at a time. */
            if (final_output_seen && (rq_valid_out == 16'd0)) begin
                batch_in_progress <= 1'b0;
                final_output_seen <= 1'b0;
                if (batch_pixel_hold == last_pixel_idx) begin
                    transaction_active <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
