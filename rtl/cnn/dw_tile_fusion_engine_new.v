`timescale 1ns/1ps
`default_nettype none

module dw_tile_fusion_engine_new #(
    parameter DW_LANES = 16
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
    output wire                              valid_out,
    output wire [5:0]                        out_pixel_idx,
    output wire [6:0]                        out_channel_idx,
    output wire signed [7:0]                 out_data_int8,
    output wire                              busy,
    output reg                               done
);
    localparam TAG_PIPE_STAGES = 10;
    localparam FIFO_DEPTH = 16;

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
    reg serialize_active;
    reg [3:0] serialize_lane_idx;

    wire req_valid_in;
    wire signed [31:0] req_acc;
    wire signed [31:0] req_bias;
    wire signed [31:0] req_multiplier;
    wire [5:0] req_shift;
    wire req_valid_out;
    wire signed [7:0] req_data_out;

    reg [TAG_PIPE_STAGES-1:0] tag_valid_pipe;
    reg [5:0] tag_pixel_pipe [0:TAG_PIPE_STAGES-1];
    reg [6:0] tag_channel_pipe [0:TAG_PIPE_STAGES-1];

    reg signed [7:0] fifo_data [0:FIFO_DEPTH-1];
    reg [5:0] fifo_pixel [0:FIFO_DEPTH-1];
    reg [6:0] fifo_channel [0:FIFO_DEPTH-1];
    reg [3:0] fifo_write_ptr;
    reg [3:0] fifo_read_ptr;
    reg [4:0] fifo_count;

    wire fifo_push;
    wire fifo_pop;
    wire tag_pipeline_busy;
    wire [7:0] output_pixels_w;
    wire [5:0] last_pixel_idx;
    wire input_fire;

    integer tag_idx;

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
    assign mac_ready_out = !serialize_active;
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

    assign req_valid_in = serialize_active;
    assign req_acc =
        acc_hold[(serialize_lane_idx*32) +: 32];
    assign req_bias =
        bias_vec[(serialize_lane_idx*32) +: 32];
    assign req_multiplier =
        multiplier_vec[(serialize_lane_idx*32) +: 32];
    assign req_shift =
        shift_vec[(serialize_lane_idx*6) +: 6];

    assign fifo_push = req_valid_out && tag_valid_pipe[TAG_PIPE_STAGES-1];
    assign valid_out = (fifo_count != 5'd0);
    assign fifo_pop = valid_out && ready_out;
    assign out_data_int8 = fifo_data[fifo_read_ptr];
    assign out_pixel_idx = fifo_pixel[fifo_read_ptr];
    assign out_channel_idx = fifo_channel[fifo_read_ptr];

    assign tag_pipeline_busy = |tag_valid_pipe;
    assign busy =
        transaction_active ||
        batch_in_progress ||
        mac_busy ||
        mac_valid_out ||
        serialize_active ||
        tag_pipeline_busy ||
        req_valid_out ||
        (fifo_count != 5'd0);

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

    requant_activation_pipeline u_requant_pipeline (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(req_valid_in),
        .acc_int32(req_acc),
        .bias_int32(req_bias),
        .multiplier_int32(req_multiplier),
        .shift(req_shift),
        .output_zero_point_int32(output_zero_point),
        .activation_min_int32(activation_min),
        .activation_max_int32(activation_max),
        .valid_out(req_valid_out),
        .output_int8(req_data_out)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            transaction_active <= 1'b0;
            batch_in_progress <= 1'b0;
            mac_pixel_pending <= 6'd0;
            acc_hold <= {(DW_LANES*32){1'b0}};
            batch_pixel_hold <= 6'd0;
            expected_outputs_remaining <= 5'd0;
            serialize_active <= 1'b0;
            serialize_lane_idx <= 4'd0;
            tag_valid_pipe <= {TAG_PIPE_STAGES{1'b0}};
            fifo_write_ptr <= 4'd0;
            fifo_read_ptr <= 4'd0;
            fifo_count <= 5'd0;
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
            end

            if (mac_output_fire) begin
                acc_hold <= mac_acc_vec;
                batch_pixel_hold <= mac_pixel_pending;
                serialize_lane_idx <= 4'd0;
                serialize_active <= 1'b1;
            end

            if (serialize_active) begin
                if (serialize_lane_idx == (DW_LANES - 1)) begin
                    serialize_active <= 1'b0;
                    serialize_lane_idx <= 4'd0;
                end else begin
                    serialize_lane_idx <= serialize_lane_idx + 4'd1;
                end
            end

            tag_valid_pipe[0] <= req_valid_in;
            if (req_valid_in) begin
                tag_pixel_pipe[0] <= batch_pixel_hold;
                tag_channel_pipe[0] <=
                    channel_base + {{3{1'b0}}, serialize_lane_idx};
            end
            for (tag_idx = 1;
                 tag_idx < TAG_PIPE_STAGES;
                 tag_idx = tag_idx + 1) begin
                tag_valid_pipe[tag_idx] <= tag_valid_pipe[tag_idx-1];
                if (tag_valid_pipe[tag_idx-1]) begin
                    tag_pixel_pipe[tag_idx] <= tag_pixel_pipe[tag_idx-1];
                    tag_channel_pipe[tag_idx] <= tag_channel_pipe[tag_idx-1];
                end
            end

            if (fifo_push) begin
                fifo_data[fifo_write_ptr] <= req_data_out;
                fifo_pixel[fifo_write_ptr] <=
                    tag_pixel_pipe[TAG_PIPE_STAGES-1];
                fifo_channel[fifo_write_ptr] <=
                    tag_channel_pipe[TAG_PIPE_STAGES-1];
                fifo_write_ptr <= fifo_write_ptr + 4'd1;
            end

            if (fifo_pop) begin
                fifo_read_ptr <= fifo_read_ptr + 4'd1;
                if (expected_outputs_remaining != 5'd0) begin
                    expected_outputs_remaining <=
                        expected_outputs_remaining - 5'd1;
                end
                if (expected_outputs_remaining == 5'd1) begin
                    batch_in_progress <= 1'b0;
                    if (out_pixel_idx == last_pixel_idx) begin
                        transaction_active <= 1'b0;
                        done <= 1'b1;
                    end
                end
            end

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + 5'd1;
                2'b01: fifo_count <= fifo_count - 5'd1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end
endmodule

`default_nettype wire
