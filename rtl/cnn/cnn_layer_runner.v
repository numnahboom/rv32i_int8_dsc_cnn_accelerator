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
    reg [31:0] store_idx;
    reg [31:0] store_count;
    reg [31:0] tiled_load_idx;
    reg [31:0] tiled_load_count;

    reg signed [(10*10*3*8)-1:0] stem_input_tile;
    reg signed [(16*27*8)-1:0] stem_weight;
    reg signed [(16*32)-1:0] stem_bias;
    reg signed [(16*32)-1:0] stem_multiplier;
    reg [(16*8)-1:0] stem_shift;

    reg signed [(MAX_DS_IN_H*MAX_DS_IN_W*MAX_CIN*8)-1:0] ds_input_tile;
    reg signed [(MAX_CIN*9*8)-1:0] dw_weight;
    reg signed [(MAX_CIN*32)-1:0] dw_bias;
    reg signed [(MAX_CIN*32)-1:0] dw_multiplier;
    reg [(MAX_CIN*8)-1:0] dw_shift;
    reg signed [(MAX_COUT*MAX_CIN*8)-1:0] pw_weight;
    reg signed [(MAX_COUT*32)-1:0] pw_bias;
    reg signed [(MAX_COUT*32)-1:0] pw_multiplier;
    reg [(MAX_COUT*8)-1:0] pw_shift;

    reg signed [(4*4*256*8)-1:0] gap_feature_in;
    wire signed [(256*8)-1:0] gap_out;

    reg signed [(256*8)-1:0] fc_input_vec;
    reg signed [(10*256*8)-1:0] fc_weight;
    reg signed [(10*32)-1:0] fc_bias;
    reg signed [(10*32)-1:0] fc_multiplier;
    reg [(10*8)-1:0] fc_shift;
    wire signed [(10*8)-1:0] fc_logits;

    reg signed [7:0] out_buffer [0:(64*MAX_COUT)-1];

    reg stem_start;
    wire stem_busy;
    wire stem_done;
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

    reg gap_start;
    wire gap_busy;
    wire gap_done;

    reg fc_start;
    wire fc_busy;
    wire fc_done;

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

    integer clear_i;

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
    assign store_byte_current = output_byte_for(op_type_reg, store_idx);
    assign tiled_stem_mode = (op_type_reg == OP_CONV3X3_STEM) && flags_reg[FLAG_TILED_STEM];
    assign tiled_ds_mode = (op_type_reg == OP_DS_BLOCK) && flags_reg[FLAG_TILED_DS_BLOCK];
    assign tiled_spatial_mode = tiled_stem_mode || tiled_ds_mode;
    assign tiled_out_h = same_out_dim(in_h_reg, effective_stride);
    assign tiled_out_w = same_out_dim(in_w_reg, effective_stride);
    assign stem_engine_out_h = tiled_stem_mode ? tile_h_size_reg[3:0] : conv_out_h;
    assign stem_engine_out_w = tiled_stem_mode ? tile_w_size_reg[3:0] : conv_out_w;
    assign ds_engine_out_h = tiled_ds_mode ? tile_h_size_reg[3:0] : conv_out_h;
    assign ds_engine_out_w = tiled_ds_mode ? tile_w_size_reg[3:0] : conv_out_w;

    conv3x3_stem_engine u_stem_engine (
        .clk(clk),
        .rst_n(rst_n),
        .start(stem_start),
        .busy(stem_busy),
        .done(stem_done),
        .out_h(stem_engine_out_h),
        .out_w(stem_engine_out_w),
        .input_zero_point(input_zero_point_reg[7:0]),
        .input_tile(stem_input_tile),
        .stem_weight(stem_weight),
        .stem_bias(stem_bias),
        .stem_multiplier(stem_multiplier),
        .stem_shift(stem_shift),
        .output_zero_point(dw_output_zero_point_reg),
        .activation_min(dw_activation_min_reg),
        .activation_max(dw_activation_max_reg),
        .out_wr_en(stem_out_wr_en),
        .out_wr_pixel_idx(stem_out_wr_pixel_idx),
        .out_wr_channel_idx(stem_out_wr_channel_idx),
        .out_wr_data_int8(stem_out_wr_data_int8)
    );

    ds_block_tile_engine #(
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
        .out_h(ds_engine_out_h),
        .out_w(ds_engine_out_w),
        .channels(in_c_reg[7:0]),
        .out_channels(out_c_reg),
        .stride(effective_stride[1:0]),
        .input_zero_point(input_zero_point_reg[7:0]),
        .input_tile(ds_input_tile),
        .dw_weight(dw_weight),
        .dw_bias(dw_bias),
        .dw_multiplier(dw_multiplier),
        .dw_shift(dw_shift),
        .dw_output_zero_point(dw_output_zero_point_reg),
        .dw_activation_min(dw_activation_min_reg),
        .dw_activation_max(dw_activation_max_reg),
        .pw_weight(pw_weight),
        .pw_bias(pw_bias),
        .pw_multiplier(pw_multiplier),
        .pw_shift(pw_shift),
        .pw_output_zero_point(pw_output_zero_point_reg),
        .pw_activation_min(pw_activation_min_reg),
        .pw_activation_max(pw_activation_max_reg),
        .out_wr_en(ds_out_wr_en),
        .out_wr_pixel_idx(ds_out_wr_pixel_idx),
        .out_wr_channel_idx(ds_out_wr_channel_idx),
        .out_wr_data_int8(ds_out_wr_data_int8)
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

    gap_unit u_gap_unit (
        .clk(clk),
        .rst_n(rst_n),
        .start(gap_start),
        .busy(gap_busy),
        .done(gap_done),
        .feature_in(gap_feature_in),
        .gap_out(gap_out)
    );

    fc_unit u_fc_unit (
        .clk(clk),
        .rst_n(rst_n),
        .start(fc_start),
        .busy(fc_busy),
        .done(fc_done),
        .input_vec(fc_input_vec),
        .fc_weight(fc_weight),
        .fc_bias(fc_bias),
        .fc_multiplier(fc_multiplier),
        .fc_shift(fc_shift),
        .output_zero_point(pw_output_zero_point_reg),
        .activation_min(pw_activation_min_reg),
        .activation_max(pw_activation_max_reg),
        .logits(fc_logits)
    );

    function [3:0] calc_out_dim;
        input [15:0] in_dim;
        input [7:0] stride_value;
        reg [15:0] stride_safe;
        reg [15:0] out_value;
        begin
            stride_safe = (stride_value == 8'd0) ? 16'd1 : {8'd0, stride_value};
            if (in_dim < 16'd3) begin
                calc_out_dim = 4'd0;
            end else begin
                out_value = ((in_dim - 16'd3) / stride_safe) + 16'd1;
                calc_out_dim = out_value[3:0];
            end
        end
    endfunction

    function [7:0] same_out_dim;
        input [15:0] in_dim;
        input [7:0] stride_value;
        reg [15:0] stride_safe;
        reg [15:0] out_value;
        begin
            stride_safe = (stride_value == 8'd0) ? 16'd1 : {8'd0, stride_value};
            if (in_dim == 16'd0) begin
                same_out_dim = 8'd0;
            end else begin
                out_value = ((in_dim - 16'd1) / stride_safe) + 16'd1;
                same_out_dim = out_value[7:0];
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

    function integer buffer_index_from_linear;
        input [31:0] idx;
        input [15:0] channel_count;
        integer p;
        integer c;
        begin
            p = 0;
            c = 0;
            if (channel_count != 16'd0) begin
                p = idx / channel_count;
                c = idx % channel_count;
            end
            buffer_index_from_linear = (p * MAX_COUT) + c;
        end
    endfunction

    function [7:0] output_byte_for;
        input [31:0] op_type;
        input [31:0] idx;
        integer buf_idx;
        begin
            output_byte_for = 8'd0;
            case (op_type)
                OP_CONV3X3_STEM: begin
                    buf_idx = buffer_index_from_linear(idx, 16'd16);
                    output_byte_for = out_buffer[buf_idx];
                end
                OP_DS_BLOCK: begin
                    buf_idx = buffer_index_from_linear(idx, out_c_reg);
                    output_byte_for = out_buffer[buf_idx];
                end
                OP_GAP: begin
                    output_byte_for = gap_out[(idx*8) +: 8];
                end
                OP_FC: begin
                    output_byte_for = fc_logits[(idx*8) +: 8];
                end
                default: begin
                    output_byte_for = 8'd0;
                end
            endcase
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
    function [31:0] tiled_input_index_for;
        input [31:0] idx;
        integer local_y;
        integer local_x;
        integer channel;
        integer src_y;
        integer src_x;
        begin
            local_y = 0;
            local_x = 0;
            channel = 0;
            src_y = 0;
            src_x = 0;
            if (tile_input_w_reg != 8'd0 && in_c_reg != 16'd0) begin
                local_y = idx / (tile_input_w_reg * in_c_reg);
                local_x = (idx / in_c_reg) % tile_input_w_reg;
                channel = idx % in_c_reg;
            end
            src_y = (tile_h_start_reg * effective_stride) + local_y - 1;
            src_x = (tile_w_start_reg * effective_stride) + local_x - 1;
            tiled_input_index_for = (((src_y * in_w_reg) + src_x) * in_c_reg) + channel;
        end
    endfunction

    function tiled_input_is_padding;
        input [31:0] idx;
        integer local_y;
        integer local_x;
        integer src_y;
        integer src_x;
        begin
            local_y = 0;
            local_x = 0;
            src_y = 0;
            src_x = 0;
            if (tile_input_w_reg != 8'd0 && in_c_reg != 16'd0) begin
                local_y = idx / (tile_input_w_reg * in_c_reg);
                local_x = (idx / in_c_reg) % tile_input_w_reg;
            end
            src_y = (tile_h_start_reg * effective_stride) + local_y - 1;
            src_x = (tile_w_start_reg * effective_stride) + local_x - 1;
            tiled_input_is_padding = (src_y < 0) || (src_x < 0) ||
                                     (src_y >= in_h_reg) || (src_x >= in_w_reg);
        end
    endfunction

    function [31:0] tiled_store_global_index_for;
        input [31:0] idx;
        integer local_pixel;
        integer local_y;
        integer local_x;
        integer channel;
        integer global_y;
        integer global_x;
        begin
            local_pixel = 0;
            local_y = 0;
            local_x = 0;
            channel = 0;
            global_y = 0;
            global_x = 0;
            if (out_c_reg != 16'd0) begin
                local_pixel = idx / out_c_reg;
                channel = idx % out_c_reg;
            end
            if (tile_w_size_reg != 8'd0) begin
                local_y = local_pixel / tile_w_size_reg;
                local_x = local_pixel % tile_w_size_reg;
            end
            global_y = tile_h_start_reg + local_y;
            global_x = tile_w_start_reg + local_x;
            tiled_store_global_index_for = (((global_y * tiled_out_w) + global_x) * out_c_reg) + channel;
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
                                       (conv_out_pixels <= 14'd64);
                    end
                end
                OP_GAP: begin
                    valid_config = 1'b1;
                end
                OP_FC: begin
                    valid_config = 1'b1;
                end
                default: begin
                    valid_config = 1'b0;
                end
            endcase
        end
    endfunction

    /* verilator lint_off BLKSEQ */
    task store_stem_input;
        input [31:0] idx;
        input [7:0] value;
        integer y;
        integer x;
        integer c;
        integer bit_base;
        begin
            y = idx / (in_w_reg * 3);
            x = (idx / 3) % in_w_reg;
            c = idx % 3;
            bit_base = (((y * 10 * 3) + (x * 3) + c) * 8);
            stem_input_tile[bit_base +: 8] <= value;
        end
    endtask

    task store_stem_tiled_input;
        input [31:0] idx;
        input [7:0] value;
        integer y;
        integer x;
        integer c;
        integer bit_base;
        begin
            y = 0;
            x = 0;
            c = 0;
            if (tile_input_w_reg != 8'd0 && in_c_reg != 16'd0) begin
                y = idx / (tile_input_w_reg * in_c_reg);
                x = (idx / in_c_reg) % tile_input_w_reg;
                c = idx % in_c_reg;
            end
            bit_base = (((y * 10 * 3) + (x * 3) + c) * 8);
            stem_input_tile[bit_base +: 8] <= value;
        end
    endtask

    task store_ds_input;
        input [31:0] idx;
        input [7:0] value;
        integer y;
        integer x;
        integer c;
        integer bit_base;
        begin
            y = idx / (in_w_reg * in_c_reg);
            x = (idx / in_c_reg) % in_w_reg;
            c = idx % in_c_reg;
            bit_base = (((y * MAX_DS_IN_W * MAX_CIN) + (x * MAX_CIN) + c) * 8);
            ds_input_tile[bit_base +: 8] <= value;
        end
    endtask

    task store_ds_tiled_input;
        input [31:0] idx;
        input [7:0] value;
        integer y;
        integer x;
        integer c;
        integer bit_base;
        begin
            y = 0;
            x = 0;
            c = 0;
            if (tile_input_w_reg != 8'd0 && in_c_reg != 16'd0) begin
                y = idx / (tile_input_w_reg * in_c_reg);
                x = (idx / in_c_reg) % tile_input_w_reg;
                c = idx % in_c_reg;
            end
            bit_base = (((y * MAX_DS_IN_W * MAX_CIN) + (x * MAX_CIN) + c) * 8);
            ds_input_tile[bit_base +: 8] <= value;
        end
    endtask

    task store_pw_weight;
        input [31:0] idx;
        input [7:0] value;
        integer co;
        integer ci;
        integer bit_base;
        begin
            co = idx / in_c_reg;
            ci = idx % in_c_reg;
            bit_base = (((co * MAX_CIN) + ci) * 8);
            pw_weight[bit_base +: 8] <= value;
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
                        PH_INPUT:     store_stem_input(idx, data[7:0]);
                        PH_DW_WEIGHT: stem_weight[(idx*8) +: 8] <= data[7:0];
                        PH_DW_BIAS:   stem_bias[(idx*32) +: 32] <= data;
                        PH_DW_MUL:    stem_multiplier[(idx*32) +: 32] <= data;
                        PH_DW_SHIFT:  stem_shift[(idx*8) +: 8] <= data[7:0];
                        default: begin end
                    endcase
                end
                OP_DS_BLOCK: begin
                    case (phase)
                        PH_INPUT:     store_ds_input(idx, data[7:0]);
                        PH_DW_WEIGHT: dw_weight[(idx*8) +: 8] <= data[7:0];
                        PH_DW_BIAS:   dw_bias[(idx*32) +: 32] <= data;
                        PH_DW_MUL:    dw_multiplier[(idx*32) +: 32] <= data;
                        PH_DW_SHIFT:  dw_shift[(idx*8) +: 8] <= data[7:0];
                        PH_PW_WEIGHT: store_pw_weight(idx, data[7:0]);
                        PH_PW_BIAS:   pw_bias[(idx*32) +: 32] <= data;
                        PH_PW_MUL:    pw_multiplier[(idx*32) +: 32] <= data;
                        PH_PW_SHIFT:  pw_shift[(idx*8) +: 8] <= data[7:0];
                        default: begin end
                    endcase
                end
                OP_GAP: begin
                    if (phase == PH_INPUT) begin
                        gap_feature_in[(idx*8) +: 8] <= data[7:0];
                    end
                end
                OP_FC: begin
                    case (phase)
                        PH_INPUT:     fc_input_vec[(idx*8) +: 8] <= data[7:0];
                        PH_PW_WEIGHT: fc_weight[(idx*8) +: 8] <= data[7:0];
                        PH_PW_BIAS:   fc_bias[(idx*32) +: 32] <= data;
                        PH_PW_MUL:    fc_multiplier[(idx*32) +: 32] <= data;
                        PH_PW_SHIFT:  fc_shift[(idx*8) +: 8] <= data[7:0];
                        default: begin end
                    endcase
                end
                default: begin end
            endcase
        end
    endtask
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (stem_out_wr_en) begin
            out_buffer[(stem_out_wr_pixel_idx * MAX_COUT) + stem_out_wr_channel_idx] <= stem_out_wr_data_int8;
        end
        if (ds_out_wr_en) begin
            out_buffer[(ds_out_wr_pixel_idx * MAX_COUT) + ds_out_wr_channel_idx] <= ds_out_wr_data_int8;
        end
    end

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
            store_idx <= 32'd0;
            store_count <= 32'd0;
            tiled_load_idx <= 32'd0;
            tiled_load_count <= 32'd0;
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
            stem_input_tile <= 2400'sd0;
            stem_weight <= 3456'sd0;
            stem_bias <= 512'sd0;
            stem_multiplier <= 512'sd0;
            stem_shift <= 128'd0;
            ds_input_tile <= 0;
            dw_weight <= 0;
            dw_bias <= 0;
            dw_multiplier <= 0;
            dw_shift <= 0;
            pw_weight <= 0;
            pw_bias <= 0;
            pw_multiplier <= 0;
            pw_shift <= 0;
            gap_feature_in <= 32768'sd0;
            fc_input_vec <= 2048'sd0;
            fc_weight <= 20480'sd0;
            fc_bias <= 320'sd0;
            fc_multiplier <= 320'sd0;
            fc_shift <= 80'd0;
        end else begin
            done <= 1'b0;
            stem_start <= 1'b0;
            ds_start <= 1'b0;
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
                    stem_input_tile <= 2400'sd0;
                    stem_weight <= 3456'sd0;
                    stem_bias <= 512'sd0;
                    stem_multiplier <= 512'sd0;
                    stem_shift <= 128'd0;
                    ds_input_tile <= 0;
                    dw_weight <= 0;
                    dw_bias <= 0;
                    dw_multiplier <= 0;
                    dw_shift <= 0;
                    pw_weight <= 0;
                    pw_bias <= 0;
                    pw_multiplier <= 0;
                    pw_shift <= 0;
                    gap_feature_in <= 32768'sd0;
                    fc_input_vec <= 2048'sd0;
                    fc_weight <= 20480'sd0;
                    fc_bias <= 320'sd0;
                    fc_multiplier <= 320'sd0;
                    fc_shift <= 80'd0;
                    /* verilator lint_off BLKSEQ */
                    for (clear_i = 0; clear_i < (64*MAX_COUT); clear_i = clear_i + 1) begin
                        out_buffer[clear_i] = 8'sd0;
                    end
                    /* verilator lint_on BLKSEQ */

                    if (flags_reg[FLAG_SKIP_EXEC]) begin
                        state <= ST_DONE;
                    end else if (!valid_config()) begin
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
                                state <= ST_READ_REQ;
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
                    if (((op_type_reg == OP_CONV3X3_STEM) && stem_done) ||
                        ((op_type_reg == OP_DS_BLOCK) && ds_done) ||
                        ((op_type_reg == OP_GAP) && gap_done) ||
                        ((op_type_reg == OP_FC) && fc_done)) begin
                        state <= ST_STORE_SETUP;
                    end
                end

                ST_STORE_SETUP: begin
                    store_count <= output_count_for(op_type_reg);
                    store_idx <= 32'd0;
                    if (output_count_for(op_type_reg) == 32'd0) begin
                        state <= ST_DONE;
                    end else begin
                        state <= ST_WRITE_REQ;
                    end
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
                        end
                    end else begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b1;
                        mem_req_addr <= output_addr_reg + (store_idx << 2);
                        mem_req_wdata <= {{24{store_byte_current[7]}}, store_byte_current};
                        if (mem_req_valid && mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            mem_req_write <= 1'b0;
                            if ((store_idx + 32'd1) >= store_count) begin
                                state <= ST_DONE;
                            end else begin
                                store_idx <= store_idx + 32'd1;
                            end
                        end
                    end
                end

                ST_TILED_INIT: begin
                    tile_sched_start <= 1'b1;
                    tiled_load_idx <= 32'd0;
                    tiled_load_count <= 32'd0;
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
                        tiled_load_count <= {24'd0, sched_input_tile_h} *
                                            {24'd0, sched_input_tile_w} *
                                            {16'd0, in_c_reg};
                        ds_input_tile <= 0;
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
                    if (tiled_input_is_padding(tiled_load_idx)) begin
                        if (tiled_stem_mode) begin
                            store_stem_tiled_input(tiled_load_idx, input_zero_point_reg[7:0]);
                        end else begin
                            store_ds_tiled_input(tiled_load_idx, input_zero_point_reg[7:0]);
                        end
                        if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                            state <= ST_TILED_ENGINE_START;
                        end else begin
                            tiled_load_idx <= tiled_load_idx + 32'd1;
                        end
                    end else if (flags_reg[FLAG_INPUT_FROM_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        sram_input_rd_en <= 1'b1;
                        sram_input_rd_addr <= sram_addr_for_index(
                            input_addr_reg,
                            tiled_input_index_for(tiled_load_idx)
                        );
                        state <= ST_TILED_LOAD_RESP;
                    end else begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b0;
                        mem_req_addr <= input_addr_reg + (tiled_input_index_for(tiled_load_idx) << 2);
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
                                store_stem_tiled_input(tiled_load_idx, sram_input_rd_data[7:0]);
                            end else begin
                                store_ds_tiled_input(tiled_load_idx, sram_input_rd_data[7:0]);
                            end
                            if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                                state <= ST_TILED_ENGINE_START;
                            end else begin
                                tiled_load_idx <= tiled_load_idx + 32'd1;
                                state <= ST_TILED_LOAD_REQ;
                            end
                        end
                    end else if (mem_resp_valid) begin
                        if (tiled_stem_mode) begin
                            store_stem_tiled_input(tiled_load_idx, mem_resp_rdata[7:0]);
                        end else begin
                            store_ds_tiled_input(tiled_load_idx, mem_resp_rdata[7:0]);
                        end
                        if ((tiled_load_idx + 32'd1) >= tiled_load_count) begin
                            state <= ST_TILED_ENGINE_START;
                        end else begin
                            tiled_load_idx <= tiled_load_idx + 32'd1;
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
                    if ((tiled_stem_mode && stem_done) || (tiled_ds_mode && ds_done)) begin
                        state <= ST_TILED_STORE_SETUP;
                    end
                end

                ST_TILED_STORE_SETUP: begin
                    store_count <= {24'd0, tile_h_size_reg} *
                                   {24'd0, tile_w_size_reg} *
                                   {16'd0, out_c_reg};
                    store_idx <= 32'd0;
                    if (({24'd0, tile_h_size_reg} *
                         {24'd0, tile_w_size_reg} *
                         {16'd0, out_c_reg}) == 32'd0) begin
                        state <= ST_TILED_ADVANCE;
                    end else begin
                        state <= ST_TILED_WRITE_REQ;
                    end
                end

                ST_TILED_WRITE_REQ: begin
                    if (flags_reg[FLAG_OUTPUT_TO_SRAM]) begin
                        mem_req_valid <= 1'b0;
                        mem_req_write <= 1'b0;
                        sram_output_wr_en <= 1'b1;
                        sram_output_wr_addr <= sram_addr_for_index(
                            output_addr_reg,
                            tiled_store_global_index_for(store_idx)
                        );
                        sram_output_wr_data <= store_byte_current;
                        if ((store_idx + 32'd1) >= store_count) begin
                            state <= ST_TILED_ADVANCE;
                        end else begin
                            store_idx <= store_idx + 32'd1;
                        end
                    end else begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b1;
                        mem_req_addr <= output_addr_reg + (tiled_store_global_index_for(store_idx) << 2);
                        mem_req_wdata <= {{24{store_byte_current[7]}}, store_byte_current};
                        if (mem_req_valid && mem_req_ready) begin
                            mem_req_valid <= 1'b0;
                            mem_req_write <= 1'b0;
                            if ((store_idx + 32'd1) >= store_count) begin
                                state <= ST_TILED_ADVANCE;
                            end else begin
                                store_idx <= store_idx + 32'd1;
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

`default_nettype wire
