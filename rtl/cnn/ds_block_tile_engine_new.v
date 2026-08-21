`timescale 1ns/1ps
`default_nettype none

/*
 * Memory-oriented streaming DSBlock.
 *
 * Configuration is loaded through a scalar indexed write port.  Large input
 * and pointwise-weight payloads live in BRAM-backed buffers instead of packed
 * module ports.  The compute path is:
 *
 * input BRAM -> streaming DW -> BRAM DW tile -> PW 8x8 -> pipelined requant
 */
module ds_block_tile_engine_new #(
    parameter MAX_CIN = 128,
    parameter MAX_COUT = 256,
    parameter MAX_IN_H = 17,
    parameter MAX_IN_W = 17
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               cfg_wr_en,
    output wire               cfg_ready,
    input  wire [3:0]         cfg_target,
    input  wire [15:0]        cfg_index,
    input  wire [31:0]        cfg_data,

    input  wire               start,
    output reg                busy,
    output reg                done,
    output reg                error,

    input  wire [3:0]         out_h,
    input  wire [3:0]         out_w,
    input  wire [7:0]         channels,
    input  wire [15:0]        out_channels,
    input  wire [1:0]         stride,
    input  wire signed [7:0]  input_zero_point,

    input  wire signed [31:0] dw_output_zero_point,
    input  wire signed [31:0] dw_activation_min,
    input  wire signed [31:0] dw_activation_max,
    input  wire signed [31:0] pw_output_zero_point,
    input  wire signed [31:0] pw_activation_min,
    input  wire signed [31:0] pw_activation_max,

    output wire               out_wr_en,
    output wire [5:0]         out_wr_pixel_idx,
    output wire [7:0]         out_wr_channel_idx,
    output wire signed [7:0]  out_wr_data_int8,

    output reg [31:0]         perf_total_cycles,
    output reg [31:0]         perf_dw_cycles,
    output reg [31:0]         perf_pw_cycles,
    output reg [31:0]         perf_pw_issue_cycles
);
    localparam CFG_INPUT      = 4'd0;
    localparam CFG_DW_WEIGHT  = 4'd1;
    localparam CFG_DW_BIAS    = 4'd2;
    localparam CFG_DW_MUL     = 4'd3;
    localparam CFG_DW_SHIFT   = 4'd4;
    localparam CFG_PW_WEIGHT  = 4'd5;
    localparam CFG_PW_BIAS    = 4'd6;
    localparam CFG_PW_MUL     = 4'd7;
    localparam CFG_PW_SHIFT   = 4'd8;

    localparam ST_IDLE            = 5'd0;
    localparam ST_DW_PARAM_LOAD   = 5'd1;
    localparam ST_DW_INPUT_REQ    = 5'd2;
    localparam ST_DW_INPUT_FEED   = 5'd3;
    localparam ST_DW_WAIT         = 5'd4;
    localparam ST_PW_INIT         = 5'd5;
    localparam ST_PW_READ         = 5'd6;
    localparam ST_PW_FEED         = 5'd7;
    localparam ST_PW_WAIT         = 5'd8;
    localparam ST_RQ_ISSUE        = 5'd9;
    localparam ST_RQ_DRAIN        = 5'd10;
    localparam ST_ADVANCE         = 5'd11;
    localparam ST_DONE            = 5'd12;
    localparam ST_ERROR           = 5'd13;

    localparam DW_LANES = 16;
    localparam PW_LANES = 8;
    localparam CHANNEL_TILES = MAX_CIN / DW_LANES;

    reg [4:0] state;

    reg [3:0] out_h_reg;
    reg [3:0] out_w_reg;
    reg [7:0] channels_reg;
    reg [8:0] out_channels_reg;
    reg [1:0] stride_reg;
    reg signed [7:0] input_zero_point_reg;
    reg signed [31:0] dw_output_zero_point_reg;
    reg signed [31:0] dw_activation_min_reg;
    reg signed [31:0] dw_activation_max_reg;
    reg signed [31:0] pw_output_zero_point_reg;
    reg signed [31:0] pw_activation_min_reg;
    reg signed [31:0] pw_activation_max_reg;

    (* ram_style = "distributed" *)
    reg signed [7:0] dw_weight_mem [0:(MAX_CIN*9)-1];
    (* ram_style = "distributed" *)
    reg signed [31:0] dw_bias_mem [0:MAX_CIN-1];
    (* ram_style = "distributed" *)
    reg signed [31:0] dw_multiplier_mem [0:MAX_CIN-1];
    (* ram_style = "distributed" *)
    reg [5:0] dw_shift_mem [0:MAX_CIN-1];
    (* ram_style = "distributed" *)
    reg signed [31:0] pw_bias_mem [0:MAX_COUT-1];
    (* ram_style = "distributed" *)
    reg signed [31:0] pw_multiplier_mem [0:MAX_COUT-1];
    (* ram_style = "distributed" *)
    reg [5:0] pw_shift_mem [0:MAX_COUT-1];

    wire input_buf_wr_en;
    wire input_buf_rd_en;
    wire [8:0] input_buf_rd_pixel;
    wire [$clog2(CHANNEL_TILES)-1:0] input_buf_rd_channel_tile;
    wire input_buf_rd_valid;
    wire signed [(DW_LANES*8)-1:0] input_buf_rd_data;
    wire signed [(DW_LANES*8)-1:0] dw_pixel_vec;

    wire pw_weight_wr_en;
    wire pw_weight_rd_en;
    wire pw_weight_rd_valid;
    wire signed [63:0] pw_weight_rd_data;

    reg [6:0] dw_channel_base;
    reg [3:0] dw_param_lane;
    reg [3:0] dw_param_kernel;
    reg [4:0] stream_x;
    reg [4:0] stream_y;
    wire [4:0] stream_in_h;
    wire [4:0] stream_in_w;
    wire [8:0] stream_pixel_idx;

    reg signed [(DW_LANES*9*8)-1:0] dw_weight_vec;
    reg signed [(DW_LANES*32)-1:0] dw_bias_vec;
    reg signed [(DW_LANES*32)-1:0] dw_multiplier_vec;
    reg        [(DW_LANES*6)-1:0] dw_shift_vec;

    wire dw_valid_in;
    wire dw_ready_in;
    wire dw_valid_out;
    wire [5:0] dw_out_pixel_idx;
    wire [6:0] dw_out_channel_idx;
    wire signed [7:0] dw_out_data_int8;
    wire dw_busy;
    wire dw_done;
    wire dw_output_accept;

    wire dw_buf_wr_en;
    wire dw_buf_rd_en;
    wire dw_buf_rd_valid;
    wire signed [63:0] dw_buf_rd_data;

    reg [5:0] pw_pixel_base;
    reg [8:0] pw_cout_base;
    reg [7:0] pw_read_idx;
    reg [7:0] pw_k_idx;
    wire pw_read_issue;
    wire pw_valid_in;
    wire pw_ready_in;
    wire pw_valid_out;
    wire signed [2047:0] pw_psum_out;
    wire pw_fire;

    reg signed [2047:0] rq_psum_shift;
    reg [6:0] rq_scan_idx;
    reg [7:0] rq_outstanding;
    wire [3:0] rq_pixel_lane;
    wire [3:0] rq_cout_lane;
    wire [6:0] rq_pixel_idx_wide;
    wire [9:0] rq_cout_idx_wide;
    wire rq_lane_active;
    wire rq_valid_in;
    wire rq_ready_in;
    wire rq_valid_out;
    wire signed [7:0] rq_output_int8;
    wire rq_fire;
    reg [2:0] rq_tag_valid;
    reg [5:0] rq_tag_pixel [0:2];
    reg [7:0] rq_tag_cout [0:2];

    wire [7:0] output_pixels;
    wire pw_phase_state;

    integer cfg_addr;
    integer param_channel;
    integer tag_i;
    genvar input_lane_g;

    assign cfg_ready = !busy;
    assign input_buf_wr_en = cfg_wr_en && cfg_ready && (cfg_target == CFG_INPUT);
    assign pw_weight_wr_en = cfg_wr_en && cfg_ready && (cfg_target == CFG_PW_WEIGHT);

    assign stream_in_h = (({1'b0, out_h_reg} - 5'd1) * stride_reg) + 5'd3;
    assign stream_in_w = (({1'b0, out_w_reg} - 5'd1) * stride_reg) + 5'd3;
    assign stream_pixel_idx = (stream_y * MAX_IN_W) + stream_x;
    assign input_buf_rd_en = (state == ST_DW_INPUT_REQ);
    assign input_buf_rd_pixel = stream_pixel_idx;
    assign input_buf_rd_channel_tile = dw_channel_base[6:4];

    generate
        for (input_lane_g = 0; input_lane_g < DW_LANES; input_lane_g = input_lane_g + 1) begin : gen_input_mask
            assign dw_pixel_vec[(input_lane_g*8) +: 8] =
                ((dw_channel_base + input_lane_g) < channels_reg)
                ? input_buf_rd_data[(input_lane_g*8) +: 8]
                : input_zero_point_reg;
        end
    endgenerate

    assign dw_valid_in = (state == ST_DW_INPUT_FEED);
    assign dw_output_accept = dw_valid_out;
    assign dw_buf_wr_en =
        dw_output_accept && ({1'b0, dw_out_channel_idx} < channels_reg);

    assign output_pixels = out_h_reg * out_w_reg;
    // Prime both synchronous BRAMs once, then issue the next K entry in the
    // same cycle that the current entry is accepted by the MAC array.  Keeping
    // the read and feed indices separate removes the former READ/FEED bubble
    // without changing the BRAM's one-cycle read contract.
    assign pw_read_issue =
        (state == ST_PW_READ) ||
        ((state == ST_PW_FEED) && pw_fire &&
         ({1'b0, pw_read_idx} < channels_reg));
    assign dw_buf_rd_en = pw_read_issue;
    assign pw_weight_rd_en = pw_read_issue;
    assign pw_valid_in = (state == ST_PW_FEED) &&
                         dw_buf_rd_valid && pw_weight_rd_valid;
    assign pw_fire = pw_valid_in && pw_ready_in;

    assign rq_pixel_lane = rq_scan_idx[5:3];
    assign rq_cout_lane = rq_scan_idx[2:0];
    assign rq_pixel_idx_wide = pw_pixel_base + rq_pixel_lane;
    assign rq_cout_idx_wide = pw_cout_base + rq_cout_lane;
    assign rq_lane_active =
        (rq_pixel_idx_wide < output_pixels) &&
        (rq_cout_idx_wide < out_channels_reg);
    assign rq_valid_in = (state == ST_RQ_ISSUE) && rq_lane_active;
    assign rq_fire = rq_valid_in && rq_ready_in;

    assign out_wr_en = rq_valid_out && rq_tag_valid[2];
    assign out_wr_pixel_idx = rq_tag_pixel[2];
    assign out_wr_channel_idx = rq_tag_cout[2];
    assign out_wr_data_int8 = rq_output_int8;

    assign pw_phase_state =
        (state == ST_PW_INIT) ||
        (state == ST_PW_READ) ||
        (state == ST_PW_FEED) ||
        (state == ST_PW_WAIT) ||
        (state == ST_RQ_ISSUE) ||
        (state == ST_RQ_DRAIN) ||
        (state == ST_ADVANCE);

    ds_input_tile_buffer_bram #(
        .MAX_CIN(MAX_CIN),
        .MAX_IN_H(MAX_IN_H),
        .MAX_IN_W(MAX_IN_W),
        .LANES(DW_LANES)
    ) u_input_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(input_buf_wr_en),
        .wr_linear_idx(cfg_index),
        .wr_data_int8(cfg_data[7:0]),
        .rd_en(input_buf_rd_en),
        .rd_pixel_idx(input_buf_rd_pixel),
        .rd_channel_tile(input_buf_rd_channel_tile),
        .rd_valid(input_buf_rd_valid),
        .rd_data_vector(input_buf_rd_data)
    );

    pw_weight_buffer_bram #(
        .MAX_CIN(MAX_CIN),
        .MAX_COUT(MAX_COUT),
        .LANES(PW_LANES)
    ) u_pw_weight_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(pw_weight_wr_en),
        .wr_linear_idx(cfg_index[14:0]),
        .wr_data_int8(cfg_data[7:0]),
        .rd_en(pw_weight_rd_en),
        .rd_cout_base(pw_cout_base),
        .rd_channel_idx(pw_read_idx),
        .rd_valid(pw_weight_rd_valid),
        .rd_data_vector(pw_weight_rd_data)
    );

    dw_tile_fusion_engine_new #(
        .DW_LANES(DW_LANES)
    ) u_dw_engine (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(dw_valid_in),
        .ready_in(dw_ready_in),
        .x_idx(stream_x),
        .y_idx(stream_y),
        .pixel_vec_in(dw_pixel_vec),
        .out_h(out_h_reg),
        .out_w(out_w_reg),
        .stride(stride_reg),
        .channel_base(dw_channel_base),
        .weight_vec(dw_weight_vec),
        .bias_vec(dw_bias_vec),
        .multiplier_vec(dw_multiplier_vec),
        .shift_vec(dw_shift_vec),
        .output_zero_point(dw_output_zero_point_reg),
        .activation_min(dw_activation_min_reg),
        .activation_max(dw_activation_max_reg),
        .ready_out(1'b1),
        .valid_out(dw_valid_out),
        .out_pixel_idx(dw_out_pixel_idx),
        .out_channel_idx(dw_out_channel_idx),
        .out_data_int8(dw_out_data_int8),
        .busy(dw_busy),
        .done(dw_done)
    );

    dw_tile_buffer_bram u_dw_tile_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(dw_buf_wr_en),
        .wr_pixel_idx(dw_out_pixel_idx),
        .wr_channel_idx(dw_out_channel_idx),
        .wr_data_int8(dw_out_data_int8),
        .rd_en(dw_buf_rd_en),
        .rd_pixel_base(pw_pixel_base),
        .rd_channel_idx(pw_read_idx[6:0]),
        .rd_valid(dw_buf_rd_valid),
        .rd_data_vector(dw_buf_rd_data)
    );

    pw_systolic_array_8x8 u_pw_array (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(pw_valid_in),
        .ready_in(pw_ready_in),
        .clear_acc(pw_k_idx == 8'd0),
        .k_last((pw_k_idx + 8'd1) >= channels_reg),
        .act_vec(dw_buf_rd_data),
        .wgt_vec(pw_weight_rd_data),
        .ready_out(1'b1),
        .valid_out(pw_valid_out),
        .psum_out(pw_psum_out)
    );

    requant_activation_unit u_pw_requant (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(rq_valid_in),
        .ready_in(rq_ready_in),
        .acc_int32(rq_psum_shift[31:0]),
        .bias_int32(pw_bias_mem[rq_cout_idx_wide[7:0]]),
        .multiplier_int32(pw_multiplier_mem[rq_cout_idx_wide[7:0]]),
        .shift(pw_shift_mem[rq_cout_idx_wide[7:0]]),
        .output_zero_point_int32(pw_output_zero_point_reg),
        .activation_min_int32(pw_activation_min_reg),
        .activation_max_int32(pw_activation_max_reg),
        .ready_out(1'b1),
        .valid_out(rq_valid_out),
        .output_int8(rq_output_int8)
    );

    always @(posedge clk) begin
        if (cfg_wr_en && cfg_ready) begin
            cfg_addr = cfg_index;
            case (cfg_target)
                CFG_DW_WEIGHT: begin
                    if (cfg_addr < (MAX_CIN * 9)) begin
                        dw_weight_mem[cfg_addr] <= cfg_data[7:0];
                    end
                end
                CFG_DW_BIAS: begin
                    if (cfg_addr < MAX_CIN) begin
                        dw_bias_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_DW_MUL: begin
                    if (cfg_addr < MAX_CIN) begin
                        dw_multiplier_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_DW_SHIFT: begin
                    if (cfg_addr < MAX_CIN) begin
                        dw_shift_mem[cfg_addr] <= cfg_data[5:0];
                    end
                end
                CFG_PW_BIAS: begin
                    if (cfg_addr < MAX_COUT) begin
                        pw_bias_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_PW_MUL: begin
                    if (cfg_addr < MAX_COUT) begin
                        pw_multiplier_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_PW_SHIFT: begin
                    if (cfg_addr < MAX_COUT) begin
                        pw_shift_mem[cfg_addr] <= cfg_data[5:0];
                    end
                end
                default: begin
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            out_h_reg <= 4'd0;
            out_w_reg <= 4'd0;
            channels_reg <= 8'd0;
            out_channels_reg <= 9'd0;
            stride_reg <= 2'd1;
            input_zero_point_reg <= 8'sd0;
            dw_output_zero_point_reg <= 32'sd0;
            dw_activation_min_reg <= 32'sd0;
            dw_activation_max_reg <= 32'sd0;
            pw_output_zero_point_reg <= 32'sd0;
            pw_activation_min_reg <= 32'sd0;
            pw_activation_max_reg <= 32'sd0;
            dw_channel_base <= 7'd0;
            dw_param_lane <= 4'd0;
            dw_param_kernel <= 4'd0;
            stream_x <= 5'd0;
            stream_y <= 5'd0;
            dw_weight_vec <= {(DW_LANES*9*8){1'b0}};
            dw_bias_vec <= {(DW_LANES*32){1'b0}};
            dw_multiplier_vec <= {(DW_LANES*32){1'b0}};
            dw_shift_vec <= {(DW_LANES*6){1'b0}};
            pw_pixel_base <= 6'd0;
            pw_cout_base <= 9'd0;
            pw_read_idx <= 8'd0;
            pw_k_idx <= 8'd0;
            rq_psum_shift <= 2048'sd0;
            rq_scan_idx <= 7'd0;
            rq_outstanding <= 8'd0;
            rq_tag_valid <= 3'b000;
            for (tag_i = 0; tag_i < 3; tag_i = tag_i + 1) begin
                rq_tag_pixel[tag_i] <= 6'd0;
                rq_tag_cout[tag_i] <= 8'd0;
            end
            perf_total_cycles <= 32'd0;
            perf_dw_cycles <= 32'd0;
            perf_pw_cycles <= 32'd0;
            perf_pw_issue_cycles <= 32'd0;
        end else begin
            done <= 1'b0;

            rq_tag_valid[0] <= rq_fire;
            rq_tag_valid[1] <= rq_tag_valid[0];
            rq_tag_valid[2] <= rq_tag_valid[1];
            if (rq_fire) begin
                rq_tag_pixel[0] <= rq_pixel_idx_wide[5:0];
                rq_tag_cout[0] <= rq_cout_idx_wide[7:0];
            end
            if (rq_tag_valid[0]) begin
                rq_tag_pixel[1] <= rq_tag_pixel[0];
                rq_tag_cout[1] <= rq_tag_cout[0];
            end
            if (rq_tag_valid[1]) begin
                rq_tag_pixel[2] <= rq_tag_pixel[1];
                rq_tag_cout[2] <= rq_tag_cout[1];
            end

            case ({rq_fire, out_wr_en})
                2'b10: rq_outstanding <= rq_outstanding + 8'd1;
                2'b01: rq_outstanding <= rq_outstanding - 8'd1;
                default: rq_outstanding <= rq_outstanding;
            endcase

            if (busy) begin
                perf_total_cycles <= perf_total_cycles + 32'd1;
                if (pw_phase_state) begin
                    perf_pw_cycles <= perf_pw_cycles + 32'd1;
                end else begin
                    perf_dw_cycles <= perf_dw_cycles + 32'd1;
                end
                if (pw_fire) begin
                    perf_pw_issue_cycles <= perf_pw_issue_cycles + 32'd1;
                end
            end

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        out_h_reg <= out_h;
                        out_w_reg <= out_w;
                        channels_reg <= channels;
                        out_channels_reg <= out_channels[8:0];
                        stride_reg <= stride;
                        input_zero_point_reg <= input_zero_point;
                        dw_output_zero_point_reg <= dw_output_zero_point;
                        dw_activation_min_reg <= dw_activation_min;
                        dw_activation_max_reg <= dw_activation_max;
                        pw_output_zero_point_reg <= pw_output_zero_point;
                        pw_activation_min_reg <= pw_activation_min;
                        pw_activation_max_reg <= pw_activation_max;
                        perf_total_cycles <= 32'd0;
                        perf_dw_cycles <= 32'd0;
                        perf_pw_cycles <= 32'd0;
                        perf_pw_issue_cycles <= 32'd0;
                        error <= 1'b0;
                        if ((out_h == 4'd0) ||
                            (out_w == 4'd0) ||
                            (out_h > 4'd8) ||
                            (out_w > 4'd8) ||
                            (channels == 8'd0) ||
                            (channels > MAX_CIN) ||
                            (out_channels == 16'd0) ||
                            (out_channels > MAX_COUT) ||
                            ((stride != 2'd1) && (stride != 2'd2))) begin
                            busy <= 1'b1;
                            error <= 1'b1;
                            state <= ST_ERROR;
                        end else begin
                            busy <= 1'b1;
                            dw_channel_base <= 7'd0;
                            dw_param_lane <= 4'd0;
                            dw_param_kernel <= 4'd0;
                            dw_weight_vec <= {(DW_LANES*9*8){1'b0}};
                            dw_bias_vec <= {(DW_LANES*32){1'b0}};
                            dw_multiplier_vec <= {(DW_LANES*32){1'b0}};
                            dw_shift_vec <= {(DW_LANES*6){1'b0}};
                            state <= ST_DW_PARAM_LOAD;
                        end
                    end
                end

                ST_DW_PARAM_LOAD: begin
                    param_channel = dw_channel_base + dw_param_lane;
                    if (param_channel < channels_reg) begin
                        dw_weight_vec[
                            ((dw_param_lane*9 + dw_param_kernel)*8) +: 8
                        ] <= dw_weight_mem[(param_channel*9) + dw_param_kernel];
                    end else begin
                        dw_weight_vec[
                            ((dw_param_lane*9 + dw_param_kernel)*8) +: 8
                        ] <= 8'sd0;
                    end

                    if (dw_param_kernel == 4'd8) begin
                        if (param_channel < channels_reg) begin
                            dw_bias_vec[(dw_param_lane*32) +: 32] <=
                                dw_bias_mem[param_channel];
                            dw_multiplier_vec[(dw_param_lane*32) +: 32] <=
                                dw_multiplier_mem[param_channel];
                            dw_shift_vec[(dw_param_lane*6) +: 6] <=
                                dw_shift_mem[param_channel];
                        end else begin
                            dw_bias_vec[(dw_param_lane*32) +: 32] <= 32'sd0;
                            dw_multiplier_vec[(dw_param_lane*32) +: 32] <= 32'sd0;
                            dw_shift_vec[(dw_param_lane*6) +: 6] <= 6'd0;
                        end
                        dw_param_kernel <= 4'd0;
                        if (dw_param_lane == 4'd15) begin
                            dw_param_lane <= 4'd0;
                            stream_x <= 5'd0;
                            stream_y <= 5'd0;
                            state <= ST_DW_INPUT_REQ;
                        end else begin
                            dw_param_lane <= dw_param_lane + 4'd1;
                        end
                    end else begin
                        dw_param_kernel <= dw_param_kernel + 4'd1;
                    end
                end

                ST_DW_INPUT_REQ: begin
                    state <= ST_DW_INPUT_FEED;
                end

                ST_DW_INPUT_FEED: begin
                    if (dw_ready_in) begin
                        if ((stream_x + 5'd1) >= stream_in_w) begin
                            stream_x <= 5'd0;
                            if ((stream_y + 5'd1) >= stream_in_h) begin
                                state <= ST_DW_WAIT;
                            end else begin
                                stream_y <= stream_y + 5'd1;
                                state <= ST_DW_INPUT_REQ;
                            end
                        end else begin
                            stream_x <= stream_x + 5'd1;
                            state <= ST_DW_INPUT_REQ;
                        end
                    end
                end

                ST_DW_WAIT: begin
                    if (dw_done) begin
                        if (({1'b0, dw_channel_base} + DW_LANES) < channels_reg) begin
                            dw_channel_base <= dw_channel_base + DW_LANES;
                            dw_param_lane <= 4'd0;
                            dw_param_kernel <= 4'd0;
                            state <= ST_DW_PARAM_LOAD;
                        end else begin
                            state <= ST_PW_INIT;
                        end
                    end
                end

                ST_PW_INIT: begin
                    pw_pixel_base <= 6'd0;
                    pw_cout_base <= 9'd0;
                    pw_read_idx <= 8'd0;
                    pw_k_idx <= 8'd0;
                    state <= ST_PW_READ;
                end

                ST_PW_READ: begin
                    pw_read_idx <= 8'd1;
                    state <= ST_PW_FEED;
                end

                ST_PW_FEED: begin
                    if (pw_fire) begin
                        if ({1'b0, pw_read_idx} < channels_reg) begin
                            pw_read_idx <= pw_read_idx + 8'd1;
                        end
                        if ((pw_k_idx + 8'd1) >= channels_reg) begin
                            state <= ST_PW_WAIT;
                        end else begin
                            pw_k_idx <= pw_k_idx + 8'd1;
                        end
                    end
                end

                ST_PW_WAIT: begin
                    if (pw_valid_out) begin
                        rq_psum_shift <= pw_psum_out;
                        rq_scan_idx <= 7'd0;
                        state <= ST_RQ_ISSUE;
                    end
                end

                ST_RQ_ISSUE: begin
                    if (!rq_lane_active || rq_ready_in) begin
                        rq_psum_shift <= {32'd0, rq_psum_shift[2047:32]};
                        if (rq_scan_idx == 7'd63) begin
                            state <= ST_RQ_DRAIN;
                        end else begin
                            rq_scan_idx <= rq_scan_idx + 7'd1;
                        end
                    end
                end

                ST_RQ_DRAIN: begin
                    if ((rq_outstanding == 8'd0) &&
                        (rq_tag_valid == 3'b000) &&
                        !rq_valid_out) begin
                        state <= ST_ADVANCE;
                    end
                end

                ST_ADVANCE: begin
                    pw_read_idx <= 8'd0;
                    pw_k_idx <= 8'd0;
                    if ((pw_cout_base + PW_LANES) < out_channels_reg) begin
                        pw_cout_base <= pw_cout_base + PW_LANES;
                        state <= ST_PW_READ;
                    end else if ((pw_pixel_base + PW_LANES) < output_pixels) begin
                        pw_cout_base <= 9'd0;
                        pw_pixel_base <= pw_pixel_base + PW_LANES;
                        state <= ST_PW_READ;
                    end else begin
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    busy <= 1'b0;
                    error <= 1'b1;
                    state <= ST_ERROR;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
