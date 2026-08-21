`timescale 1ns/1ps
`default_nettype none

module cnn_layer_runner #(
    parameter MAX_CIN = 128,
    parameter MAX_COUT = 256,
    parameter MAX_DS_IN_H = 17,
    parameter MAX_DS_IN_W = 17,
    parameter SRAM_ADDR_WIDTH = 15
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [1023:0] desc_words,

    output reg         busy,
    output reg         done,
    output reg         error,

    output reg         mem_req_valid,
    output reg         mem_req_write,
    output reg  [31:0] mem_req_addr,
    output reg  [31:0] mem_req_wdata,
    input  wire        mem_req_ready,
    input  wire        mem_resp_valid,
    input  wire [31:0] mem_resp_rdata,

    output reg                         sram_input_rd_en,
    output reg  [SRAM_ADDR_WIDTH-1:0]  sram_input_rd_addr,
    input  wire                        sram_input_rd_valid,
    input  wire signed [7:0]           sram_input_rd_data,
    output reg                         sram_output_wr_en,
    output reg  [SRAM_ADDR_WIDTH-1:0]  sram_output_wr_addr,
    output reg  signed [7:0]           sram_output_wr_data
);
    localparam OP_CONV3X3_STEM = 32'd0;
    localparam OP_DS_BLOCK     = 32'd1;
    localparam OP_GAP          = 32'd2;
    localparam OP_FC           = 32'd3;

    localparam FLAG_SKIP_EXEC       = 0;
    localparam FLAG_INPUT_FROM_SRAM = 1;
    localparam FLAG_OUTPUT_TO_SRAM  = 2;
    localparam FLAG_TILED_DS_BLOCK  = 5;
    localparam FLAG_TILED_STEM      = FLAG_TILED_DS_BLOCK;

    localparam PH_INPUT     = 4'd0;
    localparam PH_DW_WEIGHT = 4'd1;
    localparam PH_DW_BIAS   = 4'd2;
    localparam PH_DW_MUL    = 4'd3;
    localparam PH_DW_SHIFT  = 4'd4;
    localparam PH_PW_WEIGHT = 4'd5;
    localparam PH_PW_BIAS   = 4'd6;
    localparam PH_PW_MUL    = 4'd7;
    localparam PH_PW_SHIFT  = 4'd8;

    localparam DS_CFG_INPUT      = 4'd0;
    localparam DS_CFG_DW_WEIGHT  = 4'd1;
    localparam DS_CFG_DW_BIAS    = 4'd2;
    localparam DS_CFG_DW_MUL     = 4'd3;
    localparam DS_CFG_DW_SHIFT   = 4'd4;
    localparam DS_CFG_PW_WEIGHT  = 4'd5;
    localparam DS_CFG_PW_BIAS    = 4'd6;
    localparam DS_CFG_PW_MUL     = 4'd7;
    localparam DS_CFG_PW_SHIFT   = 4'd8;

    localparam ST_IDLE                = 5'd0;
    localparam ST_VALIDATE            = 5'd1;
    localparam ST_LOAD_SETUP          = 5'd2;
    localparam ST_READ_REQ            = 5'd3;
    localparam ST_READ_RESP           = 5'd4;
    localparam ST_ENGINE_START        = 5'd5;
    localparam ST_ENGINE_WAIT         = 5'd6;
    localparam ST_STORE_SETUP         = 5'd7;
    localparam ST_WRITE_REQ           = 5'd8;
    localparam ST_DONE                = 5'd9;
    localparam ST_ERROR               = 5'd10;
    localparam ST_TILED_INIT          = 5'd11;
    localparam ST_TILED_LOAD_SETUP    = 5'd12;
    localparam ST_TILED_LOAD_REQ      = 5'd13;
    localparam ST_TILED_LOAD_RESP     = 5'd14;
    localparam ST_TILED_ENGINE_START  = 5'd15;
    localparam ST_TILED_ENGINE_WAIT   = 5'd16;
    localparam ST_TILED_STORE_SETUP   = 5'd17;
    localparam ST_TILED_WRITE_REQ     = 5'd18;
    localparam ST_TILED_ADVANCE       = 5'd19;
    localparam ST_TILED_NEXT_WAIT     = 5'd20;
    localparam ST_TILED_START_WAIT    = 5'd21;
    localparam ST_STORE_PREFETCH      = 5'd22;
    localparam ST_TILED_STORE_PREFETCH = 5'd23;
    localparam integer OUT_BUFFER_DEPTH = 64 * MAX_COUT;
    localparam integer OUT_BUFFER_ADDR_WIDTH =
        (OUT_BUFFER_DEPTH <= 2) ? 1 : $clog2(OUT_BUFFER_DEPTH);
    localparam [32:0] SRAM_CAPACITY_BYTES = (33'd1 << SRAM_ADDR_WIDTH);

    reg [4:0] state;
    reg [31:0] op_type_reg;
    reg [31:0] input_addr_reg;
    reg [31:0] output_addr_reg;
    reg [31:0] dw_weight_addr_reg;
    reg [31:0] dw_bias_addr_reg;
    reg [31:0] dw_mul_addr_reg;
    reg [31:0] dw_shift_addr_reg;
    reg [31:0] pw_weight_addr_reg;
    reg [31:0] pw_bias_addr_reg;
    reg [31:0] pw_mul_addr_reg;
    reg [31:0] pw_shift_addr_reg;
    reg [15:0] in_h_reg;
    reg [15:0] in_w_reg;
    reg [15:0] in_c_reg;
    reg [15:0] out_c_reg;
    reg [7:0] stride_reg;
    reg [7:0] pad_reg;
    reg signed [31:0] input_zero_point_reg;
    reg signed [31:0] dw_output_zero_point_reg;
    reg signed [31:0] pw_output_zero_point_reg;
    reg signed [31:0] dw_activation_min_reg;
    reg signed [31:0] dw_activation_max_reg;
    reg signed [31:0] pw_activation_min_reg;
    reg signed [31:0] pw_activation_max_reg;
    reg [31:0] flags_reg;

    reg [3:0] phase_idx;
    reg [31:0] phase_count;
    reg [31:0] phase_base_addr;
    reg [31:0] load_idx;
    reg [15:0] compact_load_y;
    reg [15:0] compact_load_x;
    reg [15:0] compact_load_channel;
    reg [15:0] pw_load_cout;
    reg [15:0] pw_load_cin;
    reg [31:0] store_idx;
    reg [31:0] store_count;
    reg [31:0] tiled_load_idx;
    reg [31:0] tiled_load_count;
    reg [7:0] tiled_load_y;
    reg [7:0] tiled_load_x;
    reg [15:0] tiled_load_channel;
    reg [7:0] tiled_store_y;
    reg [7:0] tiled_store_x;

    wire out_buffer_wr_en;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] out_buffer_wr_addr;
    wire signed [7:0] out_buffer_wr_data;
    wire out_buffer_rd_en;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] out_buffer_rd_addr;
    wire signed [7:0] out_buffer_rd_data;
    reg  [OUT_BUFFER_ADDR_WIDTH-1:0] store_outbuf_addr;
    reg  [15:0] store_channel_pos;
    wire [15:0] store_active_channels;
    wire [OUT_BUFFER_ADDR_WIDTH-1:0] store_outbuf_next_addr;

    reg stem_start;
    wire stem_busy;
    wire stem_done;
    wire stem_error;
    wire stem_cfg_ready;
    wire stem_out_wr_en;
    wire [5:0] stem_out_wr_pixel_idx;
    wire [3:0] stem_out_wr_channel_idx;
    wire signed [7:0] stem_out_wr_data_int8;

    reg ds_start;
    wire ds_busy;
    wire ds_done;
    wire ds_out_wr_en;
    wire [5:0] ds_out_wr_pixel_idx;
    wire [7:0] ds_out_wr_channel_idx;
    wire signed [7:0] ds_out_wr_data_int8;
    reg ds_cfg_wr_en;
    reg [3:0] ds_cfg_target;
    reg [15:0] ds_cfg_index;
    reg [31:0] ds_cfg_data;
    wire ds_cfg_ready;
    wire ds_error;
    wire [31:0] ds_perf_total_cycles;
    wire [31:0] ds_perf_dw_cycles;
    wire [31:0] ds_perf_pw_cycles;
    wire [31:0] ds_perf_pw_issue_cycles;

    reg gap_start;
    wire gap_busy;
    wire gap_done;
    wire gap_cfg_ready;
    wire signed [7:0] gap_out_rd_data;

    reg fc_start;
    wire fc_busy;
    wire fc_done;
    wire fc_error;
    wire fc_cfg_ready;
    wire signed [7:0] fc_out_rd_data;

    reg aux_cfg_wr_en;
    reg [3:0] aux_cfg_target;
    reg [15:0] aux_cfg_index;
    reg [31:0] aux_cfg_data;

    reg tile_sched_start;
    reg tile_sched_next;
    wire tile_sched_valid;
    wire [7:0] sched_tile_h_start;
    wire [7:0] sched_tile_w_start;
    wire [7:0] sched_tile_h_size;
    wire [7:0] sched_tile_w_size;
    wire [7:0] sched_input_tile_h;
    wire [7:0] sched_input_tile_w;
    wire sched_is_last_tile;
    reg [7:0] tile_h_start_reg;
    reg [7:0] tile_w_start_reg;
    reg [7:0] tile_h_size_reg;
    reg [7:0] tile_w_size_reg;
    reg [7:0] tile_input_h_reg;
    reg [7:0] tile_input_w_reg;
    reg tile_is_last_reg;

    wire [31:0] desc_word0;
    wire [31:0] desc_word1;
    wire [31:0] desc_word2;
    wire [31:0] desc_word3;
    wire [31:0] desc_word4;
    wire [31:0] desc_word5;
    wire [31:0] desc_word6;
    wire [31:0] desc_word7;
    wire [31:0] desc_word8;
    wire [31:0] desc_word9;
    wire [31:0] desc_word10;
    wire [31:0] desc_word11;
    wire [31:0] desc_word12;
    wire [31:0] desc_word13;
    wire [31:0] desc_word14;
    wire [31:0] desc_word15;
    wire [31:0] desc_word16;
    wire [31:0] desc_word17;
    wire [31:0] desc_word18;

    wire [7:0] effective_stride;
    wire [3:0] conv_out_h;
    wire [3:0] conv_out_w;
    wire [13:0] conv_out_pixels;
    wire [7:0] store_byte_current;
    wire tiled_stem_mode;
    wire tiled_ds_mode;
    wire tiled_spatial_mode;
    wire [7:0] tiled_out_h;
    wire [7:0] tiled_out_w;
    wire [3:0] stem_engine_out_h;
    wire [3:0] stem_engine_out_w;
    wire [3:0] ds_engine_out_h;
    wire [3:0] ds_engine_out_w;
    wire tiled_load_channel_wrap;
    wire tiled_load_x_wrap;
    wire [7:0] tiled_load_y_next;
    wire [7:0] tiled_load_x_next;
    wire [15:0] tiled_load_channel_next;

    assign desc_word0  = desc_words[(0*32) +: 32];
    assign desc_word1  = desc_words[(1*32) +: 32];
    assign desc_word2  = desc_words[(2*32) +: 32];
    assign desc_word3  = desc_words[(3*32) +: 32];
    assign desc_word4  = desc_words[(4*32) +: 32];
    assign desc_word5  = desc_words[(5*32) +: 32];
    assign desc_word6  = desc_words[(6*32) +: 32];
    assign desc_word7  = desc_words[(7*32) +: 32];
    assign desc_word8  = desc_words[(8*32) +: 32];
    assign desc_word9  = desc_words[(9*32) +: 32];
    assign desc_word10 = desc_words[(10*32) +: 32];
    assign desc_word11 = desc_words[(11*32) +: 32];
    assign desc_word12 = desc_words[(12*32) +: 32];
    assign desc_word13 = desc_words[(13*32) +: 32];
    assign desc_word14 = desc_words[(14*32) +: 32];
    assign desc_word15 = desc_words[(15*32) +: 32];
    assign desc_word16 = desc_words[(16*32) +: 32];
    assign desc_word17 = desc_words[(17*32) +: 32];
    assign desc_word18 = desc_words[(18*32) +: 32];

    assign effective_stride = (stride_reg == 8'd0) ? 8'd1 : stride_reg;
    assign conv_out_h = calc_out_dim(in_h_reg, effective_stride);
    assign conv_out_w = calc_out_dim(in_w_reg, effective_stride);
    assign conv_out_pixels = conv_out_h * conv_out_w;
    assign store_byte_current =
        ((op_type_reg == OP_CONV3X3_STEM) ||
         (op_type_reg == OP_DS_BLOCK))
        ? out_buffer_rd_data
        : ((op_type_reg == OP_GAP)
           ? gap_out_rd_data
           : ((op_type_reg == OP_FC)
              ? fc_out_rd_data
              : 8'd0));
    assign tiled_stem_mode = (op_type_reg == OP_CONV3X3_STEM) && flags_reg[FLAG_TILED_STEM];
    assign tiled_ds_mode = (op_type_reg == OP_DS_BLOCK) && flags_reg[FLAG_TILED_DS_BLOCK];
    assign tiled_spatial_mode = tiled_stem_mode || tiled_ds_mode;
    assign tiled_out_h = same_out_dim(in_h_reg, effective_stride);
    assign tiled_out_w = same_out_dim(in_w_reg, effective_stride);
    assign tiled_load_channel_wrap =
        (tiled_load_channel + 16'd1) >= in_c_reg;
    assign tiled_load_x_wrap =
        (tiled_load_x + 8'd1) >= tile_input_w_reg;
    assign tiled_load_channel_next = tiled_load_channel_wrap ?
                                     16'd0 :
                                     (tiled_load_channel + 16'd1);
    assign tiled_load_x_next = tiled_load_channel_wrap ?
                               (tiled_load_x_wrap ? 8'd0 :
                                (tiled_load_x + 8'd1)) :
                               tiled_load_x;
    assign tiled_load_y_next =
        (tiled_load_channel_wrap && tiled_load_x_wrap) ?
        (tiled_load_y + 8'd1) : tiled_load_y;
    assign stem_engine_out_h = tiled_stem_mode ? tile_h_size_reg[3:0] : conv_out_h;
    assign stem_engine_out_w = tiled_stem_mode ? tile_w_size_reg[3:0] : conv_out_w;
    assign ds_engine_out_h = tiled_ds_mode ? tile_h_size_reg[3:0] : conv_out_h;
    assign ds_engine_out_w = tiled_ds_mode ? tile_w_size_reg[3:0] : conv_out_w;

    conv3x3_stem_engine_new u_stem_engine (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_wr_en(aux_cfg_wr_en && (op_type_reg == OP_CONV3X3_STEM)),
        .cfg_ready(stem_cfg_ready),
        .cfg_target(aux_cfg_target),
        .cfg_index(aux_cfg_index),
        .cfg_data(aux_cfg_data),
        .start(stem_start),
        .busy(stem_busy),
        .done(stem_done),
        .error(stem_error),
        .out_h(stem_engine_out_h),
        .out_w(stem_engine_out_w),
        .output_zero_point(dw_output_zero_point_reg),
        .activation_min(dw_activation_min_reg),
        .activation_max(dw_activation_max_reg),
        .out_wr_en(stem_out_wr_en),
        .out_wr_pixel_idx(stem_out_wr_pixel_idx),
        .out_wr_channel_idx(stem_out_wr_channel_idx),
        .out_wr_data_int8(stem_out_wr_data_int8)
    );

    ds_block_tile_engine_new #(
        .MAX_CIN(MAX_CIN),
        .MAX_COUT(MAX_COUT),
        .MAX_IN_H(MAX_DS_IN_H),
        .MAX_IN_W(MAX_DS_IN_W)
    ) u_ds_block_engine (
        .clk(clk),
        .rst_n(rst_n),
        .start(ds_start),
        .busy(ds_busy),
        .done(ds_done),
        .error(ds_error),
        .cfg_wr_en(ds_cfg_wr_en),
        .cfg_ready(ds_cfg_ready),
        .cfg_target(ds_cfg_target),
        .cfg_index(ds_cfg_index),
        .cfg_data(ds_cfg_data),
        .out_h(ds_engine_out_h),
        .out_w(ds_engine_out_w),
        .channels(in_c_reg[7:0]),
        .out_channels(out_c_reg),
        .stride(effective_stride[1:0]),
        .input_zero_point(input_zero_point_reg[7:0]),
        .dw_output_zero_point(dw_output_zero_point_reg),
        .dw_activation_min(dw_activation_min_reg),
        .dw_activation_max(dw_activation_max_reg),
        .pw_output_zero_point(pw_output_zero_point_reg),
        .pw_activation_min(pw_activation_min_reg),
        .pw_activation_max(pw_activation_max_reg),
        .out_wr_en(ds_out_wr_en),
        .out_wr_pixel_idx(ds_out_wr_pixel_idx),
        .out_wr_channel_idx(ds_out_wr_channel_idx),
        .out_wr_data_int8(ds_out_wr_data_int8),
        .perf_total_cycles(ds_perf_total_cycles),
        .perf_dw_cycles(ds_perf_dw_cycles),
        .perf_pw_cycles(ds_perf_pw_cycles),
        .perf_pw_issue_cycles(ds_perf_pw_issue_cycles)
    );

    tile_scheduler #(
        .TILE_H(8),
        .TILE_W(8)
    ) u_tile_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start(tile_sched_start),
        .next(tile_sched_next),
        .out_h(tiled_out_h),
        .out_w(tiled_out_w),
        .stride(effective_stride[1:0]),
        .valid(tile_sched_valid),
        .tile_h_start(sched_tile_h_start),
        .tile_w_start(sched_tile_w_start),
        .tile_h_size(sched_tile_h_size),
        .tile_w_size(sched_tile_w_size),
        .input_tile_h(sched_input_tile_h),
        .input_tile_w(sched_input_tile_w),
        .is_last_tile(sched_is_last_tile)
    );

    gap_unit_new u_gap_unit (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_wr_en(aux_cfg_wr_en && (op_type_reg == OP_GAP) &&
                   (aux_cfg_target == PH_INPUT)),
        .cfg_ready(gap_cfg_ready),
        .cfg_index(aux_cfg_index),
        .cfg_data_int8(aux_cfg_data[7:0]),
        .start(gap_start),
        .busy(gap_busy),
        .done(gap_done),
        .out_rd_index(store_idx[7:0]),
        .out_rd_data(gap_out_rd_data)
    );

    fc_unit_new u_fc_unit (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_wr_en(aux_cfg_wr_en && (op_type_reg == OP_FC)),
        .cfg_ready(fc_cfg_ready),
        .cfg_target(aux_cfg_target),
        .cfg_index(aux_cfg_index),
        .cfg_data(aux_cfg_data),
        .start(fc_start),
        .busy(fc_busy),
        .done(fc_done),
        .error(fc_error),
        .output_zero_point(pw_output_zero_point_reg),
        .activation_min(pw_activation_min_reg),
        .activation_max(pw_activation_max_reg),
        .out_rd_index(store_idx[3:0]),
        .out_rd_data(fc_out_rd_data)
    );

    cnn_out_buffer #(
        .DEPTH(OUT_BUFFER_DEPTH),
        .ADDR_WIDTH(OUT_BUFFER_ADDR_WIDTH)
    ) u_out_buffer (
        .clk(clk),
        .wr_en(out_buffer_wr_en),
        .wr_addr(out_buffer_wr_addr),
        .wr_data(out_buffer_wr_data),
        .rd_en(out_buffer_rd_en),
        .rd_addr(out_buffer_rd_addr),
        .rd_data(out_buffer_rd_data)
    );

    assign out_buffer_wr_en = stem_out_wr_en || ds_out_wr_en;
    assign out_buffer_wr_addr = stem_out_wr_en ?
        ((stem_out_wr_pixel_idx * MAX_COUT) + stem_out_wr_channel_idx) :
        ((ds_out_wr_pixel_idx * MAX_COUT) + ds_out_wr_channel_idx);
    assign out_buffer_wr_data = stem_out_wr_en ? stem_out_wr_data_int8 : ds_out_wr_data_int8;
    assign store_active_channels = (op_type_reg == OP_CONV3X3_STEM) ?
                                   16'd16 : out_c_reg;
    assign store_outbuf_next_addr =
        ((store_channel_pos + 16'd1) >= store_active_channels) ?
        (store_outbuf_addr + MAX_COUT - store_active_channels + 16'd1) :
        (store_outbuf_addr + 1'b1);
    assign out_buffer_rd_addr =
        (((state == ST_WRITE_REQ) || (state == ST_TILED_WRITE_REQ)) &&
         ((store_idx + 32'd1) < store_count)) ?
        store_outbuf_next_addr : store_outbuf_addr;
    assign out_buffer_rd_en =
        ((op_type_reg == OP_CONV3X3_STEM) || (op_type_reg == OP_DS_BLOCK)) &&
        ((state == ST_STORE_PREFETCH) ||
         (state == ST_WRITE_REQ) ||
         (state == ST_TILED_STORE_PREFETCH) ||
         (state == ST_TILED_WRITE_REQ));

    function [3:0] calc_out_dim;
        input [15:0] in_dim;
        input [7:0] stride_value;
        reg [15:0] out_value;
        begin
            if (in_dim < 16'd3) begin
                calc_out_dim = 4'd0;
            end else if ((stride_value == 8'd0) || (stride_value == 8'd1)) begin
                calc_out_dim = (in_dim - 16'd2);
            end else if (stride_value == 8'd2) begin
                out_value = ((in_dim - 16'd3) >> 1) + 16'd1;
                calc_out_dim = out_value[3:0];
            end else begin
                calc_out_dim = 4'd0;
            end
        end
    endfunction

    function [7:0] same_out_dim;
        input [15:0] in_dim;
        input [7:0] stride_value;
        begin
            if (in_dim == 16'd0) begin
                same_out_dim = 8'd0;
            end else if ((stride_value == 8'd0) || (stride_value == 8'd1)) begin
                same_out_dim = in_dim[7:0];
            end else if (stride_value == 8'd2) begin
                same_out_dim = ((in_dim + 16'd1) >> 1);
            end else begin
                same_out_dim = 8'd0;
            end
        end
    endfunction

    function [31:0] conv_input_count;
        begin
            conv_input_count = {16'd0, in_h_reg} * {16'd0, in_w_reg} * {16'd0, in_c_reg};
        end
    endfunction

    function [31:0] phase_count_for;
        input [31:0] op_type;
        input [3:0] phase;
        begin
            phase_count_for = 32'd0;
            case (op_type)
                OP_CONV3X3_STEM: begin
                    case (phase)
                        PH_INPUT:     phase_count_for = {16'd0, in_h_reg} * {16'd0, in_w_reg} * 32'd3;
                        PH_DW_WEIGHT: phase_count_for = 32'd16 * 32'd27;
                        PH_DW_BIAS:   phase_count_for = 32'd16;
                        PH_DW_MUL:    phase_count_for = 32'd16;
                        PH_DW_SHIFT:  phase_count_for = 32'd16;
                        default:      phase_count_for = 32'd0;
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     phase_count_for = conv_input_count();
                        PH_DW_WEIGHT: phase_count_for = {16'd0, in_c_reg} * 32'd9;
                        PH_DW_BIAS:   phase_count_for = {16'd0, in_c_reg};
                        PH_DW_MUL:    phase_count_for = {16'd0, in_c_reg};
                        PH_DW_SHIFT:  phase_count_for = {16'd0, in_c_reg};
                        PH_PW_WEIGHT: phase_count_for = {16'd0, out_c_reg} * {16'd0, in_c_reg};
                        PH_PW_BIAS:   phase_count_for = {16'd0, out_c_reg};
                        PH_PW_MUL:    phase_count_for = {16'd0, out_c_reg};
                        PH_PW_SHIFT:  phase_count_for = {16'd0, out_c_reg};
                        default:      phase_count_for = 32'd0;
                    endcase
                end
                OP_GAP: begin
                    phase_count_for = (phase == PH_INPUT) ? 32'd4096 : 32'd0;
                end
                OP_FC: begin
                    case (phase)
                        PH_INPUT:     phase_count_for = 32'd256;
                        PH_PW_WEIGHT: phase_count_for = 32'd2560;
                        PH_PW_BIAS:   phase_count_for = 32'd10;
                        PH_PW_MUL:    phase_count_for = 32'd10;
                        PH_PW_SHIFT:  phase_count_for = 32'd10;
                        default:      phase_count_for = 32'd0;
                    endcase
                end
                default: begin
                    phase_count_for = 32'd0;
                end
            endcase
        end
    endfunction

    function [31:0] phase_addr_for;
        input [31:0] op_type;
        input [3:0] phase;
        begin
            phase_addr_for = 32'd0;
            case (op_type)
                OP_CONV3X3_STEM: begin
                    case (phase)
                        PH_INPUT:     phase_addr_for = input_addr_reg;
                        PH_DW_WEIGHT: phase_addr_for = dw_weight_addr_reg;
                        PH_DW_BIAS:   phase_addr_for = dw_bias_addr_reg;
                        PH_DW_MUL:    phase_addr_for = dw_mul_addr_reg;
                        PH_DW_SHIFT:  phase_addr_for = dw_shift_addr_reg;
                        default:      phase_addr_for = 32'd0;
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     phase_addr_for = input_addr_reg;
                        PH_DW_WEIGHT: phase_addr_for = dw_weight_addr_reg;
                        PH_DW_BIAS:   phase_addr_for = dw_bias_addr_reg;
                        PH_DW_MUL:    phase_addr_for = dw_mul_addr_reg;
                        PH_DW_SHIFT:  phase_addr_for = dw_shift_addr_reg;
                        PH_PW_WEIGHT: phase_addr_for = pw_weight_addr_reg;
                        PH_PW_BIAS:   phase_addr_for = pw_bias_addr_reg;
                        PH_PW_MUL:    phase_addr_for = pw_mul_addr_reg;
                        PH_PW_SHIFT:  phase_addr_for = pw_shift_addr_reg;
                        default:      phase_addr_for = 32'd0;
                    endcase
                end
                OP_GAP: begin
                    phase_addr_for = (phase == PH_INPUT) ? input_addr_reg : 32'd0;
                end
                OP_FC: begin
                    case (phase)
                        PH_INPUT:     phase_addr_for = input_addr_reg;
                        PH_PW_WEIGHT: phase_addr_for = pw_weight_addr_reg;
                        PH_PW_BIAS:   phase_addr_for = pw_bias_addr_reg;
                        PH_PW_MUL:    phase_addr_for = pw_mul_addr_reg;
                        PH_PW_SHIFT:  phase_addr_for = pw_shift_addr_reg;
                        default:      phase_addr_for = 32'd0;
                    endcase
                end
                default: begin
                    phase_addr_for = 32'd0;
                end
            endcase
        end
    endfunction

    function [3:0] last_phase_for;
        input [31:0] op_type;
        begin
            case (op_type)
                OP_CONV3X3_STEM: last_phase_for = PH_DW_SHIFT;
                OP_DS_BLOCK:     last_phase_for = PH_PW_SHIFT;
                OP_GAP:          last_phase_for = PH_INPUT;
                OP_FC:           last_phase_for = PH_PW_SHIFT;
                default:         last_phase_for = PH_INPUT;
            endcase
        end
    endfunction

    function [31:0] output_count_for;
        input [31:0] op_type;
        begin
            case (op_type)
                OP_CONV3X3_STEM: output_count_for = {18'd0, conv_out_pixels} * 32'd16;
                OP_DS_BLOCK:     output_count_for = {18'd0, conv_out_pixels} * {16'd0, out_c_reg};
                OP_GAP:          output_count_for = 32'd256;
                OP_FC:           output_count_for = 32'd10;
                default:         output_count_for = 32'd0;
            endcase
        end
    endfunction

    function [31:0] sram_output_count_for;
        input [31:0] op_type;
        begin
            if (tiled_spatial_mode) begin
                sram_output_count_for =
                    {24'd0, tiled_out_h} *
                    {24'd0, tiled_out_w} *
                    {16'd0, out_c_reg};
            end else begin
                sram_output_count_for = output_count_for(op_type);
            end
        end
    endfunction

    function sram_span_valid;
        input [31:0] base_addr;
        input [31:0] element_count;
        reg [32:0] span_end_exclusive;
        begin
            span_end_exclusive =
                {1'b0, base_addr} + {1'b0, element_count};
            sram_span_valid =
                ({1'b0, base_addr} < SRAM_CAPACITY_BYTES) &&
                (span_end_exclusive <= SRAM_CAPACITY_BYTES);
        end
    endfunction

    function [SRAM_ADDR_WIDTH-1:0] sram_addr_for_index;
        input [31:0] base_addr;
        input [31:0] idx;
        begin
            sram_addr_for_index = base_addr + idx;
        end
    endfunction

    /* verilator lint_off BLKSEQ */
    function [31:0] tiled_input_index_current;
        integer src_y;
        integer src_x;
        begin
            src_y = (tile_h_start_reg * effective_stride) + tiled_load_y - 1;
            src_x = (tile_w_start_reg * effective_stride) + tiled_load_x - 1;
            tiled_input_index_current =
                (((src_y * in_w_reg) + src_x) * in_c_reg) +
                tiled_load_channel;
        end
    endfunction

    function tiled_input_current_is_padding;
        integer src_y;
        integer src_x;
        begin
            src_y = (tile_h_start_reg * effective_stride) + tiled_load_y - 1;
            src_x = (tile_w_start_reg * effective_stride) + tiled_load_x - 1;
            tiled_input_current_is_padding =
                (src_y < 0) || (src_x < 0) ||
                (src_y >= in_h_reg) || (src_x >= in_w_reg);
        end
    endfunction

    function [31:0] tiled_input_index_next;
        integer src_y;
        integer src_x;
        begin
            src_y = (tile_h_start_reg * effective_stride) +
                    tiled_load_y_next - 1;
            src_x = (tile_w_start_reg * effective_stride) +
                    tiled_load_x_next - 1;
            tiled_input_index_next =
                (((src_y * in_w_reg) + src_x) * in_c_reg) +
                tiled_load_channel_next;
        end
    endfunction

    function tiled_input_next_is_padding;
        integer src_y;
        integer src_x;
        begin
            src_y = (tile_h_start_reg * effective_stride) +
                    tiled_load_y_next - 1;
            src_x = (tile_w_start_reg * effective_stride) +
                    tiled_load_x_next - 1;
            tiled_input_next_is_padding =
                (src_y < 0) || (src_x < 0) ||
                (src_y >= in_h_reg) || (src_x >= in_w_reg);
        end
    endfunction

    function [31:0] tiled_store_global_index_current;
        integer global_y;
        integer global_x;
        begin
            global_y = tile_h_start_reg + tiled_store_y;
            global_x = tile_w_start_reg + tiled_store_x;
            tiled_store_global_index_current =
                (((global_y * tiled_out_w) + global_x) * out_c_reg) +
                store_channel_pos;
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    function valid_config;
        begin
            valid_config = 1'b0;
            case (op_type_reg)
                OP_CONV3X3_STEM: begin
                    if (tiled_stem_mode) begin
                        valid_config = (in_h_reg >= 16'd1) && (in_h_reg <= 16'd32) &&
                                       (in_w_reg >= 16'd1) && (in_w_reg <= 16'd32) &&
                                       (in_c_reg == 16'd3) &&
                                       (out_c_reg == 16'd16) &&
                                       (effective_stride == 8'd1) &&
                                       (pad_reg == 8'd1) &&
                                       (tiled_out_h != 8'd0) && (tiled_out_w != 8'd0);
                    end else begin
                        valid_config = (in_h_reg >= 16'd3) && (in_h_reg <= 16'd10) &&
                                       (in_w_reg >= 16'd3) && (in_w_reg <= 16'd10) &&
                                       (in_c_reg == 16'd3) &&
                                       (out_c_reg == 16'd16) &&
                                       (effective_stride == 8'd1) &&
                                       (pad_reg == 8'd1) &&
                                       (conv_out_pixels <= 14'd64);
                    end
                end
                OP_DS_BLOCK: begin
                    if (tiled_ds_mode) begin
                        valid_config = (in_h_reg >= 16'd1) && (in_h_reg <= 16'd32) &&
                                       (in_w_reg >= 16'd1) && (in_w_reg <= 16'd32) &&
                                       (in_c_reg >= 16'd1) && (in_c_reg <= MAX_CIN) &&
                                       (out_c_reg >= 16'd1) && (out_c_reg <= MAX_COUT) &&
                                       ((effective_stride == 8'd1) || (effective_stride == 8'd2)) &&
                                       (pad_reg == 8'd1) &&
                                       (tiled_out_h != 8'd0) && (tiled_out_w != 8'd0);
                    end else begin
                        valid_config = (in_h_reg >= 16'd3) && (in_h_reg <= MAX_DS_IN_H) &&
                                       (in_w_reg >= 16'd3) && (in_w_reg <= MAX_DS_IN_W) &&
                                       (in_c_reg >= 16'd1) && (in_c_reg <= MAX_CIN) &&
                                       (out_c_reg >= 16'd1) && (out_c_reg <= MAX_COUT) &&
                                       ((effective_stride == 8'd1) || (effective_stride == 8'd2)) &&
                                       (pad_reg == 8'd1) &&
                                       (conv_out_pixels <= 14'd64);
                    end
                end
                OP_GAP: begin
                    valid_config = (in_h_reg == 16'd4) &&
                                   (in_w_reg == 16'd4) &&
                                   (in_c_reg == 16'd256) &&
                                   (out_c_reg == 16'd256) &&
                                   (effective_stride == 8'd1) &&
                                   (pad_reg == 8'd0);
                end
                OP_FC: begin
                    valid_config = (in_h_reg == 16'd1) &&
                                   (in_w_reg == 16'd1) &&
                                   (in_c_reg == 16'd256) &&
                                   (out_c_reg == 16'd10) &&
                                   (effective_stride == 8'd1) &&
                                   (pad_reg == 8'd0);
                end
                default: begin
                    valid_config = 1'b0;
                end
            endcase
        end
    endfunction

    /* verilator lint_off BLKSEQ */
    task store_stem_input;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (compact_load_y * 10 * 3) +
                (compact_load_x * 3) +
                compact_load_channel;
            aux_cfg_wr_en <= 1'b1;
            aux_cfg_target <= PH_INPUT;
            aux_cfg_index <= cfg_linear_index[15:0];
            aux_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task store_stem_tiled_input;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (tiled_load_y * 10 * 3) +
                (tiled_load_x * 3) +
                tiled_load_channel;
            aux_cfg_wr_en <= 1'b1;
            aux_cfg_target <= PH_INPUT;
            aux_cfg_index <= cfg_linear_index[15:0];
            aux_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task store_ds_input;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (compact_load_y * MAX_DS_IN_W * MAX_CIN) +
                (compact_load_x * MAX_CIN) +
                compact_load_channel;
            ds_cfg_wr_en <= 1'b1;
            ds_cfg_target <= DS_CFG_INPUT;
            ds_cfg_index <= cfg_linear_index[15:0];
            ds_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task store_ds_tiled_input;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index =
                (tiled_load_y * MAX_DS_IN_W * MAX_CIN) +
                (tiled_load_x * MAX_CIN) +
                tiled_load_channel;
            ds_cfg_wr_en <= 1'b1;
            ds_cfg_target <= DS_CFG_INPUT;
            ds_cfg_index <= cfg_linear_index[15:0];
            ds_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task advance_tiled_load_position;
        begin
            if ((tiled_load_channel + 16'd1) >= in_c_reg) begin
                tiled_load_channel <= 16'd0;
                if ((tiled_load_x + 8'd1) >= tile_input_w_reg) begin
                    tiled_load_x <= 8'd0;
                    tiled_load_y <= tiled_load_y + 8'd1;
                end else begin
                    tiled_load_x <= tiled_load_x + 8'd1;
                end
            end else begin
                tiled_load_channel <= tiled_load_channel + 16'd1;
            end
        end
    endtask

    task advance_tiled_store_position;
        begin
            if ((store_channel_pos + 16'd1) >= store_active_channels) begin
                store_channel_pos <= 16'd0;
                if ((tiled_store_x + 8'd1) >= tile_w_size_reg) begin
                    tiled_store_x <= 8'd0;
                    tiled_store_y <= tiled_store_y + 8'd1;
                end else begin
                    tiled_store_x <= tiled_store_x + 8'd1;
                end
            end else begin
                store_channel_pos <= store_channel_pos + 16'd1;
            end
        end
    endtask

    task store_pw_weight;
        input [7:0] value;
        integer cfg_linear_index;
        begin
            cfg_linear_index = (pw_load_cout * MAX_CIN) + pw_load_cin;
            ds_cfg_wr_en <= 1'b1;
            ds_cfg_target <= DS_CFG_PW_WEIGHT;
            ds_cfg_index <= cfg_linear_index[15:0];
            ds_cfg_data <= {{24{value[7]}}, value};
        end
    endtask

    task advance_compact_load_position;
        input [3:0] phase;
        begin
            if ((phase == PH_INPUT) &&
                ((op_type_reg == OP_CONV3X3_STEM) ||
                 (op_type_reg == OP_DS_BLOCK))) begin
                if ((compact_load_channel + 16'd1) >= in_c_reg) begin
                    compact_load_channel <= 16'd0;
                    if ((compact_load_x + 16'd1) >= in_w_reg) begin
                        compact_load_x <= 16'd0;
                        compact_load_y <= compact_load_y + 16'd1;
                    end else begin
                        compact_load_x <= compact_load_x + 16'd1;
                    end
                end else begin
                    compact_load_channel <= compact_load_channel + 16'd1;
                end
            end else if ((phase == PH_PW_WEIGHT) &&
                         (op_type_reg == OP_DS_BLOCK)) begin
                if ((pw_load_cin + 16'd1) >= in_c_reg) begin
                    pw_load_cin <= 16'd0;
                    pw_load_cout <= pw_load_cout + 16'd1;
                end else begin
                    pw_load_cin <= pw_load_cin + 16'd1;
                end
            end
        end
    endtask

    task store_response_word;
        input [3:0] phase;
        input [31:0] idx;
        input [31:0] data;
        begin
            case (op_type_reg)
                OP_CONV3X3_STEM: begin
                    case (phase)
                        PH_INPUT:     store_stem_input(data[7:0]);
                        PH_DW_WEIGHT,
                        PH_DW_BIAS,
                        PH_DW_MUL,
                        PH_DW_SHIFT: begin
                            aux_cfg_wr_en <= 1'b1;
                            aux_cfg_target <= phase;
                            aux_cfg_index <= idx[15:0];
                            aux_cfg_data <= data;
                        end
                        default: begin end
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     store_ds_input(data[7:0]);
                        PH_DW_WEIGHT: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_DW_WEIGHT;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_DW_BIAS: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_DW_BIAS;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_DW_MUL: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_DW_MUL;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_DW_SHIFT: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_DW_SHIFT;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_PW_WEIGHT: store_pw_weight(data[7:0]);
                        PH_PW_BIAS: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_PW_BIAS;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_PW_MUL: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_PW_MUL;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        PH_PW_SHIFT: begin
                            ds_cfg_wr_en <= 1'b1;
                            ds_cfg_target <= DS_CFG_PW_SHIFT;
                            ds_cfg_index <= idx[15:0];
                            ds_cfg_data <= data;
                        end
                        default: begin end
                    endcase
                end
                OP_GAP: begin
                    if (phase == PH_INPUT) begin
                        aux_cfg_wr_en <= 1'b1;
                        aux_cfg_target <= PH_INPUT;
                        aux_cfg_index <= idx[15:0];
                        aux_cfg_data <= data;
                    end
                end
                OP_FC: begin
                    case (phase)
                        PH_INPUT,
                        PH_PW_WEIGHT,
                        PH_PW_BIAS,
                        PH_PW_MUL,
                        PH_PW_SHIFT: begin
                            aux_cfg_wr_en <= 1'b1;
                            aux_cfg_target <= phase;
                            aux_cfg_index <= idx[15:0];
                            aux_cfg_data <= data;
                        end
                        default: begin end
                    endcase
                end
                default: begin end
            endcase
        end
    endtask
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            mem_req_valid <= 1'b0;
            mem_req_write <= 1'b0;
            mem_req_addr <= 32'd0;
            mem_req_wdata <= 32'd0;
            sram_input_rd_en <= 1'b0;
            sram_input_rd_addr <= {SRAM_ADDR_WIDTH{1'b0}};
            sram_output_wr_en <= 1'b0;
            sram_output_wr_addr <= {SRAM_ADDR_WIDTH{1'b0}};
            sram_output_wr_data <= 8'sd0;
            stem_start <= 1'b0;
            ds_start <= 1'b0;
            ds_cfg_wr_en <= 1'b0;
            ds_cfg_target <= 4'd0;
            ds_cfg_index <= 16'd0;
            ds_cfg_data <= 32'd0;
            aux_cfg_wr_en <= 1'b0;
            aux_cfg_target <= 4'd0;
            aux_cfg_index <= 16'd0;
            aux_cfg_data <= 32'd0;
            gap_start <= 1'b0;
            fc_start <= 1'b0;
            tile_sched_start <= 1'b0;
            tile_sched_next <= 1'b0;
            tile_h_start_reg <= 8'd0;
            tile_w_start_reg <= 8'd0;
            tile_h_size_reg <= 8'd0;
            tile_w_size_reg <= 8'd0;
            tile_input_h_reg <= 8'd0;
            tile_input_w_reg <= 8'd0;
            tile_is_last_reg <= 1'b0;
            phase_idx <= 4'd0;
            phase_count <= 32'd0;
            phase_base_addr <= 32'd0;
            load_idx <= 32'd0;
            compact_load_y <= 16'd0;
            compact_load_x <= 16'd0;
            compact_load_channel <= 16'd0;
            pw_load_cout <= 16'd0;
            pw_load_cin <= 16'd0;
            store_idx <= 32'd0;
            store_count <= 32'd0;
            store_outbuf_addr <= {OUT_BUFFER_ADDR_WIDTH{1'b0}};
            store_channel_pos <= 16'd0;
            tiled_load_idx <= 32'd0;
            tiled_load_count <= 32'd0;
            tiled_load_y <= 8'd0;
            tiled_load_x <= 8'd0;
            tiled_load_channel <= 16'd0;
            tiled_store_y <= 8'd0;
            tiled_store_x <= 8'd0;
            op_type_reg <= 32'd0;
            input_addr_reg <= 32'd0;
            output_addr_reg <= 32'd0;
            dw_weight_addr_reg <= 32'd0;
            dw_bias_addr_reg <= 32'd0;
            dw_mul_addr_reg <= 32'd0;
            dw_shift_addr_reg <= 32'd0;
            pw_weight_addr_reg <= 32'd0;
            pw_bias_addr_reg <= 32'd0;
            pw_mul_addr_reg <= 32'd0;
            pw_shift_addr_reg <= 32'd0;
            in_h_reg <= 16'd0;
            in_w_reg <= 16'd0;
            in_c_reg <= 16'd0;
            out_c_reg <= 16'd0;
            stride_reg <= 8'd1;
            pad_reg <= 8'd0;
            input_zero_point_reg <= 32'sd0;
            dw_output_zero_point_reg <= 32'sd0;
            pw_output_zero_point_reg <= 32'sd0;
            dw_activation_min_reg <= -32'sd128;
            dw_activation_max_reg <= 32'sd127;
            pw_activation_min_reg <= -32'sd128;
            pw_activation_max_reg <= 32'sd127;
            flags_reg <= 32'd0;
        end else begin
            done <= 1'b0;
            stem_start <= 1'b0;
            ds_start <= 1'b0;
            ds_cfg_wr_en <= 1'b0;
            aux_cfg_wr_en <= 1'b0;
            gap_start <= 1'b0;
            fc_start <= 1'b0;
            sram_input_rd_en <= 1'b0;
            sram_output_wr_en <= 1'b0;
            tile_sched_start <= 1'b0;
            tile_sched_next <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        error <= 1'b0;
                        op_type_reg <= desc_word0;
                        input_addr_reg <= desc_word1;
                        output_addr_reg <= desc_word2;
                        dw_weight_addr_reg <= desc_word3;
                        dw_bias_addr_reg <= desc_word4;
                        dw_mul_addr_reg <= desc_word5;
                        dw_shift_addr_reg <= desc_word6;
                        pw_weight_addr_reg <= desc_word7;
                        pw_bias_addr_reg <= desc_word8;
                        pw_mul_addr_reg <= desc_word9;
                        pw_shift_addr_reg <= desc_word10;
                        in_h_reg <= desc_word11[15:0];
                        in_w_reg <= desc_word11[31:16];
                        in_c_reg <= desc_word12[15:0];
                        out_c_reg <= desc_word12[31:16];
                        stride_reg <= desc_word13[7:0];
                        pad_reg <= desc_word13[15:8];
                        input_zero_point_reg <= desc_word14;
                        dw_output_zero_point_reg <= desc_word15;
                        pw_output_zero_point_reg <= desc_word16;
                        dw_activation_min_reg <= {{24{desc_word17[7]}}, desc_word17[7:0]};
                        dw_activation_max_reg <= {{24{desc_word17[15]}}, desc_word17[15:8]};
                        pw_activation_min_reg <= {{24{desc_word17[23]}}, desc_word17[23:16]};
                        pw_activation_max_reg <= {{24{desc_word17[31]}}, desc_word17[31:24]};
                        flags_reg <= desc_word18;
                        state <= ST_VALIDATE;
                    end
                end

                ST_VALIDATE: begin
                    if (flags_reg[FLAG_SKIP_EXEC]) begin
                        state <= ST_DONE;
                    end else if (!valid_config()) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else if (
                        (flags_reg[FLAG_INPUT_FROM_SRAM] &&
                         !sram_span_valid(
                             input_addr_reg,
                             phase_count_for(op_type_reg, PH_INPUT)
                         )) ||
                        (flags_reg[FLAG_OUTPUT_TO_SRAM] &&
                         !sram_span_valid(
                             output_addr_reg,
                             sram_output_count_for(op_type_reg)
                         ))
                    ) begin
                        // SRAM ports intentionally expose only
                        // SRAM_ADDR_WIDTH address bits.  Reject a descriptor
                        // whose logical tensor would otherwise alias through
                        // silent high-bit truncation or end-of-bank wraparound.
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else begin
                        phase_idx <= (tiled_spatial_mode ? PH_DW_WEIGHT : PH_INPUT);
                        state <= ST_LOAD_SETUP;
                    end
                end

                ST_LOAD_SETUP: begin
                    phase_count <= phase_count_for(op_type_reg, phase_idx);
                    phase_base_addr <= phase_addr_for(op_type_reg, phase_idx);
                    load_idx <= 32'd0;
                    if (phase_idx == PH_INPUT) begin
                        compact_load_y <= 16'd0;
                        compact_load_x <= 16'd0;
                        compact_load_channel <= 16'd0;
                    end
                    if (phase_idx == PH_PW_WEIGHT) begin
                        pw_load_cout <= 16'd0;
                        pw_load_cin <= 16'd0;
                    end
                    if (phase_count_for(op_type_reg, phase_idx) == 32'd0) begin
                        if (phase_idx == last_phase_for(op_type_reg)) begin
                            state <= (tiled_spatial_mode ? ST_TILED_INIT : ST_ENGINE_START);
                        end else begin
                            phase_idx <= phase_idx + 4'd1;
                        end
                    end else begin
                        state <= ST_READ_REQ;
                    end
                end

                ST_READ_REQ: begin
                    if ((phase_idx == PH_INPUT) && flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        sram_input_rd_en <= 1'b1;
                        sram_input_rd_addr <= sram_addr_for_index(phase_base_addr, load_idx);
                        state <= ST_READ_RESP;
                    end else begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b0;
                        mem_req_addr <= phase_base_addr + (load_idx << 2);
                        mem_req_wdata <= 32'd0;
                        if (mem_req_valid && mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            state <= ST_READ_RESP;
                        end
                    end
                end

                ST_READ_RESP: begin
                    if ((phase_idx == PH_INPUT) && flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        if (sram_input_rd_valid) begin
                            store_response_word(
                                phase_idx,
                                load_idx,
                                {{24{sram_input_rd_data[7]}}, sram_input_rd_data}
                            );
                            if ((load_idx + 32'd1) >= phase_count) begin
                                if (phase_idx == last_phase_for(op_type_reg)) begin
                                    state <= (tiled_spatial_mode ? ST_TILED_INIT : ST_ENGINE_START);
                                end else begin
                                    phase_idx <= phase_idx + 4'd1;
                                    state <= ST_LOAD_SETUP;
                                end
                            end else begin
                                load_idx <= load_idx + 32'd1;
                                advance_compact_load_position(phase_idx);
                                // The feature SRAM has a fixed one-cycle
                                // synchronous read contract.  Launch the next
                                // read directly while consuming this response;
                                // no additional request-setup state is needed.
                                sram_input_rd_en <= 1'b1;
                                sram_input_rd_addr <= sram_addr_for_index(
                                    phase_base_addr,
                                    load_idx + 32'd1
                                );
                                state <= ST_READ_RESP;
                            end
                        end
                    end else if (mem_resp_valid) begin
                        store_response_word(phase_idx, load_idx, mem_resp_rdata);
                        if ((load_idx + 32'd1) >= phase_count) begin
                            if (phase_idx == last_phase_for(op_type_reg)) begin
                                state <= (tiled_spatial_mode ? ST_TILED_INIT : ST_ENGINE_START);
                            end else begin
                                phase_idx <= phase_idx + 4'd1;
                                state <= ST_LOAD_SETUP;
                            end
                        end else begin
                            load_idx <= load_idx + 32'd1;
                            advance_compact_load_position(phase_idx);
                            // Pre-arm the next single-outstanding request while
                            // consuming this response.  ST_READ_REQ then sees
                            // valid already asserted and can handshake in one
                            // cycle when ready, instead of spending an extra
                            // cycle merely raising mem_req_valid.
                            mem_req_valid <= 1'b1;
                            mem_req_write <= 1'b0;
                            mem_req_addr <= phase_base_addr +
                                            ((load_idx + 32'd1) << 2);
                            mem_req_wdata <= 32'd0;
                            state <= ST_READ_REQ;
                        end
                    end
                end

                ST_ENGINE_START: begin
                    case (op_type_reg)
                        OP_CONV3X3_STEM: stem_start <= 1'b1;
                        OP_DS_BLOCK:     ds_start <= 1'b1;
                        OP_GAP:          gap_start <= 1'b1;
                        OP_FC:           fc_start <= 1'b1;
                        default: begin
                            error <= 1'b1;
                            state <= ST_ERROR;
                        end
                    endcase
                    if ((op_type_reg == OP_CONV3X3_STEM) ||
                        (op_type_reg == OP_DS_BLOCK) ||
                        (op_type_reg == OP_GAP) ||
                        (op_type_reg == OP_FC)) begin
                        state <= ST_ENGINE_WAIT;
                    end
                end

                ST_ENGINE_WAIT: begin
                    if (((op_type_reg == OP_CONV3X3_STEM) &&
                         stem_done && stem_error) ||
                        ((op_type_reg == OP_DS_BLOCK) &&
                         ds_done && ds_error) ||
                        ((op_type_reg == OP_FC) &&
                         fc_done && fc_error)) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else if (((op_type_reg == OP_CONV3X3_STEM) && stem_done) ||
                        ((op_type_reg == OP_DS_BLOCK) && ds_done) ||
                        ((op_type_reg == OP_GAP) && gap_done) ||
                        ((op_type_reg == OP_FC) && fc_done)) begin
                        state <= ST_STORE_SETUP;
                    end
                end

                ST_STORE_SETUP: begin
                    store_count <= output_count_for(op_type_reg);
                    store_idx <= 32'd0;
                    store_outbuf_addr <= {OUT_BUFFER_ADDR_WIDTH{1'b0}};
                    store_channel_pos <= 16'd0;
                    if (output_count_for(op_type_reg) == 32'd0) begin
                        state <= ST_DONE;
                    end else if ((op_type_reg == OP_CONV3X3_STEM) ||
                                 (op_type_reg == OP_DS_BLOCK)) begin
                        state <= ST_STORE_PREFETCH;
                    end else begin
                        state <= ST_WRITE_REQ;
                    end
                end

                ST_STORE_PREFETCH: begin
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    state <= ST_WRITE_REQ;
                end

                ST_WRITE_REQ: begin
                    if (flags_reg[FLAG_OUTPUT_TO_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        sram_output_wr_en <= 1'b1;
                        sram_output_wr_addr <= sram_addr_for_index(output_addr_reg, store_idx);
                        sram_output_wr_data <= store_byte_current;
                        if ((store_idx + 32'd1) >= store_count) begin
                            state <= ST_DONE;
                        end else begin
                            store_idx <= store_idx + 32'd1;
                            store_outbuf_addr <= store_outbuf_next_addr;
                            if ((store_channel_pos + 16'd1) >= store_active_channels) begin
                                store_channel_pos <= 16'd0;
                            end else begin
                                store_channel_pos <= store_channel_pos + 16'd1;
                            end
                        end
                    end else begin
                        if (!mem_req_valid) begin
                            mem_req_valid <= 1'b1;
                            mem_req_write <= 1'b1;
                            mem_req_addr <= output_addr_reg + (store_idx << 2);
                            mem_req_wdata <= {{24{store_byte_current[7]}}, store_byte_current};
                        end else if (mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            mem_req_write <= 1'b0;
                            if ((store_idx + 32'd1) >= store_count) begin
                                state <= ST_DONE;
                            end else begin
                                store_idx <= store_idx + 32'd1;
                                store_outbuf_addr <= store_outbuf_next_addr;
                                if ((store_channel_pos + 16'd1) >= store_active_channels) begin
                                    store_channel_pos <= 16'd0;
                                end else begin
                                    store_channel_pos <= store_channel_pos + 16'd1;
                                end
                            end
                        end
                    end
                end

                ST_TILED_INIT: begin
                    tile_sched_start <= 1'b1;
                    tiled_load_idx <= 32'd0;
                    tiled_load_count <= 32'd0;
                    tiled_load_y <= 8'd0;
                    tiled_load_x <= 8'd0;
                    tiled_load_channel <= 16'd0;
                    state <= ST_TILED_START_WAIT;
                end

                ST_TILED_START_WAIT: begin
                    state <= ST_TILED_LOAD_SETUP;
                end

                ST_TILED_LOAD_SETUP: begin
                    if (tile_sched_valid) begin
                        tile_h_start_reg <= sched_tile_h_start;
                        tile_w_start_reg <= sched_tile_w_start;
                        tile_h_size_reg <= sched_tile_h_size;
                        tile_w_size_reg <= sched_tile_w_size;
                        tile_input_h_reg <= sched_input_tile_h;
                        tile_input_w_reg <= sched_input_tile_w;
                        tile_is_last_reg <= sched_is_last_tile;
                        tiled_load_idx <= 32'd0;
                        tiled_load_y <= 8'd0;
                        tiled_load_x <= 8'd0;
                        tiled_load_channel <= 16'd0;
                        tiled_load_count <= {24'd0, sched_input_tile_h} *
                                            {24'd0, sched_input_tile_w} *
                                            {16'd0, in_c_reg};
                        if (({24'd0, sched_input_tile_h} *
                             {24'd0, sched_input_tile_w} *
                             {16'd0, in_c_reg}) == 32'd0) begin
                            state <= ST_TILED_ENGINE_START;
                        end else begin
                            state <= ST_TILED_LOAD_REQ;
                        end
                    end else begin
                        state <= ST_TILED_LOAD_SETUP;
                    end
                end

                ST_TILED_LOAD_REQ: begin
                    if (tiled_input_current_is_padding()) begin
                        if (tiled_stem_mode) begin
                            store_stem_tiled_input(input_zero_point_reg[7:0]);
                        end else begin
                            store_ds_tiled_input(input_zero_point_reg[7:0]);
                        end
                        if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                            state <= ST_TILED_ENGINE_START;
                        end else begin
                            tiled_load_idx <= tiled_load_idx + 32'd1;
                            advance_tiled_load_position();
                            // Look through the padding run boundary.  A real
                            // next element can be pre-armed immediately; a
                            // padded next element remains local to this state
                            // and must not create a memory transaction.
                            if (!tiled_input_next_is_padding()) begin
                                if (flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                                    sram_input_rd_en <= 1'b1;
                                    sram_input_rd_addr <= sram_addr_for_index(
                                        input_addr_reg,
                                        tiled_input_index_next()
                                    );
                                    state <= ST_TILED_LOAD_RESP;
                                end else begin
                                    mem_req_valid <= 1'b1;
                                    mem_req_write <= 1'b0;
                                    mem_req_addr <= input_addr_reg +
                                                    (tiled_input_index_next() << 2);
                                    mem_req_wdata <= 32'd0;
                                end
                            end
                        end
                    end else if (flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        sram_input_rd_en <= 1'b1;
                        sram_input_rd_addr <= sram_addr_for_index(
                            input_addr_reg,
                            tiled_input_index_current()
                        );
                        state <= ST_TILED_LOAD_RESP;
                    end else begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b0;
                        mem_req_addr <= input_addr_reg +
                                        (tiled_input_index_current() << 2);
                        mem_req_wdata <= 32'd0;
                        if (mem_req_valid && mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            state <= ST_TILED_LOAD_RESP;
                        end
                    end
                end

                ST_TILED_LOAD_RESP: begin
                    if (flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        if (sram_input_rd_valid) begin
                            if (tiled_stem_mode) begin
                                store_stem_tiled_input(sram_input_rd_data[7:0]);
                            end else begin
                                store_ds_tiled_input(sram_input_rd_data[7:0]);
                            end
                            if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                                state <= ST_TILED_ENGINE_START;
                            end else begin
                                tiled_load_idx <= tiled_load_idx + 32'd1;
                                advance_tiled_load_position();
                                if (tiled_input_next_is_padding()) begin
                                    state <= ST_TILED_LOAD_REQ;
                                end else begin
                                    sram_input_rd_en <= 1'b1;
                                    sram_input_rd_addr <= sram_addr_for_index(
                                        input_addr_reg,
                                        tiled_input_index_next()
                                    );
                                    state <= ST_TILED_LOAD_RESP;
                                end
                            end
                        end
                    end else if (mem_resp_valid) begin
                        if (tiled_stem_mode) begin
                            store_stem_tiled_input(mem_resp_rdata[7:0]);
                        end else begin
                            store_ds_tiled_input(mem_resp_rdata[7:0]);
                        end
                        if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                            state <= ST_TILED_ENGINE_START;
                        end else begin
                            tiled_load_idx <= tiled_load_idx + 32'd1;
                            advance_tiled_load_position();
                            if (!tiled_input_next_is_padding()) begin
                                mem_req_valid <= 1'b1;
                                mem_req_write <= 1'b0;
                                mem_req_addr <= input_addr_reg +
                                                (tiled_input_index_next() << 2);
                                mem_req_wdata <= 32'd0;
                            end
                            state <= ST_TILED_LOAD_REQ;
                        end
                    end
                end

                ST_TILED_ENGINE_START: begin
                    if (tiled_stem_mode) begin
                        stem_start <= 1'b1;
                    end else begin
                        ds_start <= 1'b1;
                    end
                    state <= ST_TILED_ENGINE_WAIT;
                end

                ST_TILED_ENGINE_WAIT: begin
                    if ((tiled_stem_mode && stem_done && stem_error) ||
                        (tiled_ds_mode && ds_done && ds_error)) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else if ((tiled_stem_mode && stem_done) ||
                                 (tiled_ds_mode && ds_done)) begin
                        state <= ST_TILED_STORE_SETUP;
                    end
                end

                ST_TILED_STORE_SETUP: begin
                    store_count <= {24'd0, tile_h_size_reg} *
                                   {24'd0, tile_w_size_reg} *
                                   {16'd0, out_c_reg};
                    store_idx <= 32'd0;
                    store_outbuf_addr <= {OUT_BUFFER_ADDR_WIDTH{1'b0}};
                    store_channel_pos <= 16'd0;
                    tiled_store_y <= 8'd0;
                    tiled_store_x <= 8'd0;
                    if (({24'd0, tile_h_size_reg} *
                         {24'd0, tile_w_size_reg} *
                         {16'd0, out_c_reg}) == 32'd0) begin
                        state <= ST_TILED_ADVANCE;
                    end else begin
                        state <= ST_TILED_STORE_PREFETCH;
                    end
                end

                ST_TILED_STORE_PREFETCH: begin
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    state <= ST_TILED_WRITE_REQ;
                end

                ST_TILED_WRITE_REQ: begin
                    if (flags_reg[FLAG_OUTPUT_TO_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        sram_output_wr_en <= 1'b1;
                        sram_output_wr_addr <= sram_addr_for_index(
                            output_addr_reg,
                            tiled_store_global_index_current()
                        );
                        sram_output_wr_data <= store_byte_current;
                        if ((store_idx + 32'd1) >= store_count) begin
                            state <= ST_TILED_ADVANCE;
                        end else begin
                            store_idx <= store_idx + 32'd1;
                            store_outbuf_addr <= store_outbuf_next_addr;
                            advance_tiled_store_position();
                        end
                    end else begin
                        if (!mem_req_valid) begin
                            mem_req_valid <= 1'b1;
                            mem_req_write <= 1'b1;
                            mem_req_addr <= output_addr_reg +
                                            (tiled_store_global_index_current() << 2);
                            mem_req_wdata <= {{24{store_byte_current[7]}}, store_byte_current};
                        end else if (mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            mem_req_write <= 1'b0;
                            if ((store_idx + 32'd1) >= store_count) begin
                                state <= ST_TILED_ADVANCE;
                            end else begin
                                store_idx <= store_idx + 32'd1;
                                store_outbuf_addr <= store_outbuf_next_addr;
                                advance_tiled_store_position();
                            end
                        end
                    end
                end

                ST_TILED_ADVANCE: begin
                    if (tile_is_last_reg) begin
                        state <= ST_DONE;
                    end else begin
                        tile_sched_next <= 1'b1;
                        state <= ST_TILED_NEXT_WAIT;
                    end
                end

                ST_TILED_NEXT_WAIT: begin
                    state <= ST_TILED_LOAD_SETUP;
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    sram_input_rd_en <= 1'b0;
                    sram_output_wr_en <= 1'b0;
                    tile_sched_start <= 1'b0;
                    tile_sched_next <= 1'b0;
                    state <= ST_IDLE;
                end

                ST_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    mem_req_valid <= 1'b0;
                    mem_req_write <= 1'b0;
                    sram_input_rd_en <= 1'b0;
                    sram_output_wr_en <= 1'b0;
                    tile_sched_start <= 1'b0;
                    tile_sched_next <= 1'b0;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

module cnn_out_buffer #(
    parameter DEPTH = 16384,
    parameter ADDR_WIDTH = 14
) (
    input  wire                      clk,
    input  wire                      wr_en,
    input  wire [ADDR_WIDTH-1:0]     wr_addr,
    input  wire signed [7:0]         wr_data,
    input  wire                      rd_en,
    input  wire [ADDR_WIDTH-1:0]     rd_addr,
    output wire signed [7:0]         rd_data
);
`ifdef SYNTHESIS
    wire [7:0] rd_data_unsigned;

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(DEPTH * 8),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(8),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(8),
        .WRITE_MODE_B("read_first")
    ) u_output_memory (
        .clka(clk),
        .ena(wr_en),
        .wea(wr_en),
        .addra(wr_addr),
        .dina(wr_data),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .clkb(clk),
        .rstb(1'b0),
        .enb(rd_en),
        .regceb(1'b1),
        .addrb(rd_addr),
        .doutb(rd_data_unsigned),
        .sbiterrb(),
        .dbiterrb(),
        .sleep(1'b0)
    );

    assign rd_data = rd_data_unsigned;
`else
    reg signed [7:0] mem [0:DEPTH-1];
    reg signed [7:0] rd_data_reg;

    integer init_i;
    initial begin
        /* verilator lint_off BLKSEQ */
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
            mem[init_i] = 8'sd0;
        end
        rd_data_reg = 8'sd0;
        /* verilator lint_on BLKSEQ */
    end

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        if (rd_en) begin
            rd_data_reg <= mem[rd_addr];
        end
    end

    assign rd_data = rd_data_reg;
`endif
endmodule

`default_nettype wire
