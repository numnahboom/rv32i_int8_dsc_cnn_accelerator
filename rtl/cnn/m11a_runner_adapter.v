`timescale 1ns/1ps
`default_nettype none

/*
 * Production runner boundary for the M1.1-A runtime DW16 -> PW64 core.
 *
 * The legacy runner speaks a scalar 32-bit parameter bus and the feature
 * SRAM exposes an aligned 32-bit word read.  M1.1-A consumes a packed config
 * image and one 128-bit source beat, so this module owns the conversion at
 * the compile-time-selected boundary.  It deliberately contains no legacy
 * DS engine; cnn_top selects this adapter for the M1.1-A DS1/DS2 slots when
 * USE_M11A_DS1 is set.
 *
 * Both packed C0 words and the existing one-int8-per-int32 firmware layout
 * are accepted: the former takes one bus read per packed word, while the
 * latter is gathered four scalar reads into one M1.1-A config word.  The
 * config index presented to m11a_runtime_cfg_store is the canonical manifest
 * order for the selected layer.  DS1 uses 308 words and DS2 uses 872 words;
 * the two banks remain independently committed by the runtime core.
 */
module m11a_runner_adapter #(
    parameter integer SRAM_ADDR_WIDTH = 15
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    input  wire [1:0]                   desc_layer,
    input  wire [1023:0]                desc_words,

    output wire                         busy,
    output reg                          done,
    output wire                         error,

    output wire                         mem_req_valid,
    output wire                         mem_req_write,
    output wire [31:0]                  mem_req_addr,
    output wire [31:0]                  mem_req_wdata,
    input  wire                         mem_req_ready,
    input  wire                         mem_resp_valid,
    input  wire [31:0]                  mem_resp_rdata,

    output wire                         sram_input_rd_en,
    output wire [SRAM_ADDR_WIDTH-1:0]  sram_input_rd_addr,
    input  wire                         sram_input_rd_valid,
    input  wire signed [7:0]            sram_input_rd_data,
    output wire                         sram_input_rd_word_en,
    output wire [SRAM_ADDR_WIDTH-1:0]  sram_input_rd_word_addr,
    input  wire                         sram_input_rd_word_valid,
    input  wire [31:0]                  sram_input_rd_word_data,

    output wire                         sram_output_wr_en,
    output wire [SRAM_ADDR_WIDTH-1:0]  sram_output_wr_addr,
    output wire signed [7:0]            sram_output_wr_data,
    output wire                         sram_output_wr4_en,
    output wire [SRAM_ADDR_WIDTH-1:0]  sram_output_wr4_addr,
    output wire [31:0]                  sram_output_wr4_data,
    output wire [3:0]                   sram_output_wr4_be
);
    localparam [31:0] OP_DS_BLOCK = 32'd1;
    localparam integer FLAG_INPUT_FROM_SRAM = 1;
    localparam integer FLAG_OUTPUT_TO_SRAM = 2;
    localparam integer FLAG_PACKED_WEIGHTS = 7;

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_VALIDATE   = 4'd1;
    localparam [3:0] ST_CFG_REQ    = 4'd2;
    localparam [3:0] ST_CFG_WAIT   = 4'd3;
    localparam [3:0] ST_CFG_SEND   = 4'd4;
    localparam [3:0] ST_COMMIT     = 4'd5;
    localparam [3:0] ST_START      = 4'd6;
    localparam [3:0] ST_RUN        = 4'd7;
    localparam [3:0] ST_DONE       = 4'd8;
    localparam [3:0] ST_ERROR      = 4'd9;

    localparam [3:0] CFG_DW_WEIGHT = 4'd0;
    localparam [3:0] CFG_DW_BIAS   = 4'd1;
    localparam [3:0] CFG_DW_MUL    = 4'd2;
    localparam [3:0] CFG_DW_SHIFT  = 4'd3;
    localparam [3:0] CFG_PW_WEIGHT = 4'd4;
    localparam [3:0] CFG_PW_BIAS   = 4'd5;
    localparam [3:0] CFG_PW_MUL    = 4'd6;
    localparam [3:0] CFG_PW_SHIFT  = 4'd7;

    localparam [9:0] DS1_CONFIG_WORDS = 10'd308;
    localparam [9:0] DS2_CONFIG_WORDS = 10'd872;
    localparam [31:0] DS1_OUTPUT_WORDS = 32'd8192;
    localparam [31:0] DS2_OUTPUT_WORDS = 32'd4096;
    localparam [32:0] SRAM_CAPACITY_BYTES = (33'd1 << SRAM_ADDR_WIDTH);

    reg [3:0] state;
    reg error_r;
    reg [1:0] layer_r;
    reg [31:0] input_base_r;
    reg [31:0] sink_base_r;
    reg [31:0] dw_weight_base_r, dw_bias_base_r;
    reg [31:0] dw_mul_base_r, dw_shift_base_r;
    reg [31:0] pw_weight_base_r, pw_bias_base_r;
    reg [31:0] pw_mul_base_r, pw_shift_base_r;
    reg [15:0] in_h_r, in_w_r, in_c_r, out_c_r;
    reg [7:0] stride_r, pad_r;
    reg [7:0] input_zp_r;
    reg [31:0] dw_zp_r, pw_zp_r;
    reg signed [31:0] dw_min_r, dw_max_r;
    reg signed [31:0] pw_min_r, pw_max_r;
    reg [31:0] flags_r;
    reg packed_weights_r;
    reg [31:0] row_stride_r;

    reg [3:0] cfg_phase_r;
    reg [9:0] cfg_word_r;
    reg [1:0] cfg_byte_lane_r;
    reg [31:0] cfg_word_data_r;

    reg [31:0] out_word_count_r;
    reg [31:0] config_read_count_r;
    reg done_seen_r;

    wire [31:0] desc_word0  = desc_words[(0*32) +: 32];
    wire [31:0] desc_word1  = desc_words[(1*32) +: 32];
    wire [31:0] desc_word2  = desc_words[(2*32) +: 32];
    wire [31:0] desc_word3  = desc_words[(3*32) +: 32];
    wire [31:0] desc_word4  = desc_words[(4*32) +: 32];
    wire [31:0] desc_word5  = desc_words[(5*32) +: 32];
    wire [31:0] desc_word6  = desc_words[(6*32) +: 32];
    wire [31:0] desc_word7  = desc_words[(7*32) +: 32];
    wire [31:0] desc_word8  = desc_words[(8*32) +: 32];
    wire [31:0] desc_word9  = desc_words[(9*32) +: 32];
    wire [31:0] desc_word10 = desc_words[(10*32) +: 32];
    wire [31:0] desc_word11 = desc_words[(11*32) +: 32];
    wire [31:0] desc_word12 = desc_words[(12*32) +: 32];
    wire [31:0] desc_word13 = desc_words[(13*32) +: 32];
    wire [31:0] desc_word14 = desc_words[(14*32) +: 32];
    wire [31:0] desc_word15 = desc_words[(15*32) +: 32];
    wire [31:0] desc_word16 = desc_words[(16*32) +: 32];
    wire [31:0] desc_word17 = desc_words[(17*32) +: 32];
    wire [31:0] desc_word18 = desc_words[(18*32) +: 32];

    wire cfg_phase_is_weight = (cfg_phase_r == CFG_DW_WEIGHT) ||
                               (cfg_phase_r == CFG_PW_WEIGHT);
    wire [9:0] cfg_phase_limit_ds1 =
        (cfg_phase_r == CFG_DW_WEIGHT) ? 10'd36 :
        (cfg_phase_r == CFG_DW_BIAS)   ? 10'd16 :
        (cfg_phase_r == CFG_DW_MUL)    ? 10'd16 :
        (cfg_phase_r == CFG_DW_SHIFT)  ? 10'd16 :
        (cfg_phase_r == CFG_PW_WEIGHT) ? 10'd128 :
        (cfg_phase_r == CFG_PW_BIAS)   ? 10'd32 :
        (cfg_phase_r == CFG_PW_MUL)    ? 10'd32 :
                                          10'd32;
    wire [9:0] cfg_phase_limit_ds2 =
        (cfg_phase_r == CFG_DW_WEIGHT) ? 10'd72 :
        (cfg_phase_r == CFG_DW_BIAS)   ? 10'd32 :
        (cfg_phase_r == CFG_DW_MUL)    ? 10'd32 :
        (cfg_phase_r == CFG_DW_SHIFT)  ? 10'd32 :
        (cfg_phase_r == CFG_PW_WEIGHT) ? 10'd512 :
        (cfg_phase_r == CFG_PW_BIAS)   ? 10'd64 :
        (cfg_phase_r == CFG_PW_MUL)    ? 10'd64 :
                                          10'd64;
    wire [9:0] cfg_phase_limit = (layer_r == 2'd2) ?
                                  cfg_phase_limit_ds2 : cfg_phase_limit_ds1;
    wire [9:0] cfg_phase_cfg_base_ds1 =
        (cfg_phase_r == CFG_DW_WEIGHT) ? 10'd0 :
        (cfg_phase_r == CFG_DW_BIAS)   ? 10'd36 :
        (cfg_phase_r == CFG_DW_MUL)    ? 10'd52 :
        (cfg_phase_r == CFG_DW_SHIFT)  ? 10'd68 :
        (cfg_phase_r == CFG_PW_WEIGHT) ? 10'd84 :
        (cfg_phase_r == CFG_PW_BIAS)   ? 10'd212 :
        (cfg_phase_r == CFG_PW_MUL)    ? 10'd244 :
                                          10'd276;
    wire [9:0] cfg_phase_cfg_base_ds2 =
        (cfg_phase_r == CFG_DW_WEIGHT) ? 10'd0 :
        (cfg_phase_r == CFG_DW_BIAS)   ? 10'd72 :
        (cfg_phase_r == CFG_DW_MUL)    ? 10'd104 :
        (cfg_phase_r == CFG_DW_SHIFT)  ? 10'd136 :
        (cfg_phase_r == CFG_PW_WEIGHT) ? 10'd168 :
        (cfg_phase_r == CFG_PW_BIAS)   ? 10'd680 :
        (cfg_phase_r == CFG_PW_MUL)    ? 10'd744 :
                                          10'd808;
    wire [9:0] cfg_phase_cfg_base = (layer_r == 2'd2) ?
                                    cfg_phase_cfg_base_ds2 :
                                    cfg_phase_cfg_base_ds1;
    wire [31:0] cfg_phase_base_addr =
        (cfg_phase_r == CFG_DW_WEIGHT) ? dw_weight_base_r :
        (cfg_phase_r == CFG_DW_BIAS)   ? dw_bias_base_r :
        (cfg_phase_r == CFG_DW_MUL)    ? dw_mul_base_r :
        (cfg_phase_r == CFG_DW_SHIFT)  ? dw_shift_base_r :
        (cfg_phase_r == CFG_PW_WEIGHT) ? pw_weight_base_r :
        (cfg_phase_r == CFG_PW_BIAS)   ? pw_bias_base_r :
        (cfg_phase_r == CFG_PW_MUL)    ? pw_mul_base_r :
                                          pw_shift_base_r;
    wire [31:0] cfg_scalar_element =
        ({22'd0, cfg_word_r} << 2) + {30'd0, cfg_byte_lane_r};
    wire [31:0] cfg_external_addr = cfg_phase_base_addr +
        ((cfg_phase_is_weight && !packed_weights_r) ?
         (cfg_scalar_element << 2) : ({22'd0, cfg_word_r} << 2));
    wire [9:0] cfg_core_index = cfg_phase_cfg_base + cfg_word_r;

    /* M1.1-A core-side configuration and descriptor boundary. */
    wire core_cfg_valid = (state == ST_CFG_SEND);
    wire core_cfg_ready;
    wire [1:0] core_cfg_layer = layer_r;
    wire [9:0] core_cfg_index = cfg_core_index;
    wire [31:0] core_cfg_data = cfg_word_data_r;
    wire core_cfg_commit_valid = (state == ST_COMMIT);
    wire core_cfg_commit_ready;
    wire [1:0] core_cfg_commit_layer = layer_r;
    wire core_start_valid = (state == ST_START);
    wire core_start_ready;

    wire core_mem_req_valid;
    wire core_mem_req_ready;
    wire [31:0] core_mem_req_addr;
    wire core_mem_resp_valid;
    reg [127:0] core_mem_resp_data_r;

    wire core_out_valid;
    wire core_out_ready = (state == ST_RUN);
    wire [31:0] core_out_addr;
    wire [31:0] core_out_data;
    wire [3:0] core_out_be;
    wire [1:0] core_out_context;
    wire core_out_owner;
    wire [31:0] core_out_epoch;
    wire core_out_last;
    wire core_busy;
    wire core_done;
    wire core_error;
    wire [7:0] core_error_code;
    wire [31:0] core_dw_mac_count;
    wire [31:0] core_dw_vector_count;
    wire [31:0] core_padding_tap_count;
    wire [31:0] core_input_read_count;
    wire [31:0] core_pw_token_count;
    wire [31:0] core_pw_mac_count;
    wire [31:0] core_out_word_count;

    m11a_runtime_dw_pw_core u_m11a_core (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(core_cfg_valid), .cfg_ready(core_cfg_ready),
        .cfg_layer(core_cfg_layer), .cfg_index(core_cfg_index),
        .cfg_data(core_cfg_data), .cfg_commit_valid(core_cfg_commit_valid),
        .cfg_commit_ready(core_cfg_commit_ready),
        .cfg_commit_layer(core_cfg_commit_layer),
        .start_valid(core_start_valid), .start_ready(core_start_ready),
        .desc_layer(layer_r), .desc_in_h(in_h_r[5:0]), .desc_in_w(in_w_r[5:0]),
        .desc_cin(in_c_r[5:0]), .desc_cout(out_c_r[6:0]),
        .desc_stride(stride_r[1:0]), .desc_input_base(input_base_r),
        .desc_input_row_stride(row_stride_r),
        .desc_input_zero_point(input_zp_r),
        .desc_dw_output_zero_point(dw_zp_r),
        .desc_pw_output_zero_point(pw_zp_r),
        .desc_activation_min({{24{dw_min_r[7]}}, dw_min_r[7:0]}),
        .desc_activation_max({{24{dw_max_r[7]}}, dw_max_r[7:0]}),
        .desc_sink_base(sink_base_r),
        .mem_req_valid(core_mem_req_valid), .mem_req_ready(core_mem_req_ready),
        .mem_req_addr(core_mem_req_addr), .mem_resp_valid(core_mem_resp_valid),
        .mem_resp_data(core_mem_resp_data_r),
        .out_valid(core_out_valid), .out_ready(core_out_ready),
        .out_addr(core_out_addr), .out_data(core_out_data),
        .out_be(core_out_be), .out_context(core_out_context),
        .out_owner(core_out_owner), .out_epoch(core_out_epoch),
        .out_last(core_out_last), .busy(core_busy), .done(core_done),
        .error(core_error), .error_code(core_error_code),
        .dw_mac_count(core_dw_mac_count), .dw_vector_count(core_dw_vector_count),
        .padding_tap_count(core_padding_tap_count),
        .input_read_count(core_input_read_count),
        .pw_token_count(core_pw_token_count), .pw_mac_count(core_pw_mac_count),
        .out_word_count(core_out_word_count)
    );

    /* Four consecutive 32-bit feature-SRAM words form one M1.1-A beat. */
    localparam [1:0] AGG_IDLE = 2'd0;
    localparam [1:0] AGG_REQ  = 2'd1;
    localparam [1:0] AGG_WAIT = 2'd2;
    localparam [1:0] AGG_RESP = 2'd3;
    reg [1:0] agg_state;
    reg [31:0] agg_base_addr_r;
    reg [1:0] agg_lane_r;
    reg [31:0] agg_word0_r, agg_word1_r, agg_word2_r;
    wire [31:0] agg_word_addr = agg_base_addr_r +
                                ({30'd0, agg_lane_r} << 2);

    assign core_mem_req_ready = (state == ST_RUN) && (agg_state == AGG_IDLE);
    assign core_mem_resp_valid = (state == ST_RUN) && (agg_state == AGG_RESP);

    assign sram_input_rd_en = 1'b0;
    assign sram_input_rd_addr = {SRAM_ADDR_WIDTH{1'b0}};
    /* The SRAM word port is synchronous and has no ready signal.  Keep its
     * enable high for exactly one cycle per address; AGG_WAIT consumes the
     * corresponding registered response before issuing the next request. */
    assign sram_input_rd_word_en = (state == ST_RUN) &&
                                   (agg_state == AGG_REQ);
    assign sram_input_rd_word_addr = agg_word_addr[SRAM_ADDR_WIDTH-1:0];

    assign sram_output_wr_en = 1'b0;
    assign sram_output_wr_addr = {SRAM_ADDR_WIDTH{1'b0}};
    assign sram_output_wr_data = 8'sd0;
    assign sram_output_wr4_en = (state == ST_RUN) && core_out_valid &&
                                (core_out_ready);
    assign sram_output_wr4_addr = core_out_addr[SRAM_ADDR_WIDTH-1:0];
    assign sram_output_wr4_data = core_out_data;
    assign sram_output_wr4_be = core_out_be;

    /* Parameter traffic is the only use of the runner's 32-bit external bus
     * in the M1.1-A variant.  Source traffic is routed to the feature SRAM
     * aggregator above. */
    assign mem_req_valid = (state == ST_CFG_REQ);
    assign mem_req_write = 1'b0;
    assign mem_req_addr = cfg_external_addr;
    assign mem_req_wdata = 32'd0;

    assign busy = (state != ST_IDLE) && (state != ST_DONE) &&
                  (state != ST_ERROR);
    assign error = error_r | core_error;

    wire [31:0] output_word_limit = (layer_r == 2'd2) ?
                                    DS2_OUTPUT_WORDS : DS1_OUTPUT_WORDS;
    wire output_address_valid =
        (core_out_addr >= sink_base_r) &&
        (({33'd0, core_out_addr} - {33'd0, sink_base_r}) <
         SRAM_CAPACITY_BYTES);
    wire input_address_valid =
        (core_mem_req_addr[1:0] == 2'b00) &&
        ({33'd0, core_mem_req_addr} < SRAM_CAPACITY_BYTES);

    wire [31:0] expected_context_ordinal_r =
        (layer_r == 2'd2) ? (out_word_count_r >> 7) :
                             (out_word_count_r >> 6);

    integer reset_i;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            error_r <= 1'b0;
            layer_r <= 2'd0;
            done <= 1'b0;
            input_base_r <= 32'd0;
            sink_base_r <= 32'd0;
            dw_weight_base_r <= 32'd0;
            dw_bias_base_r <= 32'd0;
            dw_mul_base_r <= 32'd0;
            dw_shift_base_r <= 32'd0;
            pw_weight_base_r <= 32'd0;
            pw_bias_base_r <= 32'd0;
            pw_mul_base_r <= 32'd0;
            pw_shift_base_r <= 32'd0;
            in_h_r <= 16'd0;
            in_w_r <= 16'd0;
            in_c_r <= 16'd0;
            out_c_r <= 16'd0;
            stride_r <= 8'd0;
            pad_r <= 8'd0;
            input_zp_r <= 8'd0;
            dw_zp_r <= 32'd0;
            pw_zp_r <= 32'd0;
            dw_min_r <= -32'sd128;
            dw_max_r <= 32'sd127;
            pw_min_r <= -32'sd128;
            pw_max_r <= 32'sd127;
            flags_r <= 32'd0;
            packed_weights_r <= 1'b0;
            row_stride_r <= 32'd0;
            cfg_phase_r <= CFG_DW_WEIGHT;
            cfg_word_r <= 10'd0;
            cfg_byte_lane_r <= 2'd0;
            cfg_word_data_r <= 32'd0;
            out_word_count_r <= 32'd0;
            config_read_count_r <= 32'd0;
            done_seen_r <= 1'b0;
            core_mem_resp_data_r <= 128'd0;
            agg_state <= AGG_IDLE;
            agg_base_addr_r <= 32'd0;
            agg_lane_r <= 2'd0;
            agg_word0_r <= 32'd0;
            agg_word1_r <= 32'd0;
            agg_word2_r <= 32'd0;
        end else begin
            done <= 1'b0;

            if (state == ST_IDLE) begin
                agg_state <= AGG_IDLE;
                if (start) begin
                    error_r <= 1'b0;
                    layer_r <= desc_layer;
                    done_seen_r <= 1'b0;
                    out_word_count_r <= 32'd0;
                    config_read_count_r <= 32'd0;
                    input_base_r <= desc_word1;
                    sink_base_r <= desc_word2;
                    dw_weight_base_r <= desc_word3;
                    dw_bias_base_r <= desc_word4;
                    dw_mul_base_r <= desc_word5;
                    dw_shift_base_r <= desc_word6;
                    pw_weight_base_r <= desc_word7;
                    pw_bias_base_r <= desc_word8;
                    pw_mul_base_r <= desc_word9;
                    pw_shift_base_r <= desc_word10;
                    in_h_r <= desc_word11[15:0];
                    in_w_r <= desc_word11[31:16];
                    in_c_r <= desc_word12[15:0];
                    out_c_r <= desc_word12[31:16];
                    stride_r <= desc_word13[7:0];
                    pad_r <= desc_word13[15:8];
                    input_zp_r <= desc_word14[7:0];
                    dw_zp_r <= desc_word15;
                    pw_zp_r <= desc_word16;
                    dw_min_r <= $signed({{24{desc_word17[7]}}, desc_word17[7:0]});
                    dw_max_r <= $signed({{24{desc_word17[15]}}, desc_word17[15:8]});
                    pw_min_r <= $signed({{24{desc_word17[23]}}, desc_word17[23:16]});
                    pw_max_r <= $signed({{24{desc_word17[31]}}, desc_word17[31:24]});
                    flags_r <= desc_word18;
                    packed_weights_r <= desc_word18[FLAG_PACKED_WEIGHTS];
                    row_stride_r <= {16'd0, desc_word11[31:16]} *
                                    {16'd0, desc_word12[15:0]};
                    state <= ST_VALIDATE;
                end
            end else if (state == ST_VALIDATE) begin
                /* Both C0 DS shapes use SAME padding and SRAM on both sides.
                 * Keep the shape check explicit so a descriptor cannot route
                 * an unsupported layer into the shared M1.1-A banks. */
                if ((desc_word0 != OP_DS_BLOCK) ||
                    !(((layer_r == 2'd1) &&
                       (in_h_r == 16'd32) && (in_w_r == 16'd32) &&
                       (in_c_r == 16'd16) && (out_c_r == 16'd32) &&
                       (stride_r == 8'd1) && (pad_r == 8'd1) &&
                       (row_stride_r == 32'd512)) ||
                      ((layer_r == 2'd2) &&
                       (in_h_r == 16'd32) && (in_w_r == 16'd32) &&
                       (in_c_r == 16'd32) && (out_c_r == 16'd64) &&
                       (stride_r == 8'd2) && (pad_r == 8'd1) &&
                       (row_stride_r == 32'd1024))) ||
                    !flags_r[FLAG_INPUT_FROM_SRAM] ||
                    !flags_r[FLAG_OUTPUT_TO_SRAM] ||
                    ((layer_r != 2'd1) && (layer_r != 2'd2)) ||
                    (dw_weight_base_r[1:0] != 2'b00) ||
                    (dw_bias_base_r[1:0] != 2'b00) ||
                    (dw_mul_base_r[1:0] != 2'b00) ||
                    (dw_shift_base_r[1:0] != 2'b00) ||
                    (pw_weight_base_r[1:0] != 2'b00) ||
                    (pw_bias_base_r[1:0] != 2'b00) ||
                    (pw_mul_base_r[1:0] != 2'b00) ||
                    (pw_shift_base_r[1:0] != 2'b00)) begin
                    error_r <= 1'b1;
                    done <= 1'b1;
                    state <= ST_ERROR;
                end else begin
                    cfg_phase_r <= CFG_DW_WEIGHT;
                    cfg_word_r <= 10'd0;
                    cfg_byte_lane_r <= 2'd0;
                    cfg_word_data_r <= 32'd0;
                    state <= ST_CFG_REQ;
                end
            end else if (state == ST_CFG_REQ) begin
                if (mem_req_valid && mem_req_ready) begin
                    config_read_count_r <= config_read_count_r + 1'b1;
                    state <= ST_CFG_WAIT;
                end
            end else if (state == ST_CFG_WAIT) begin
                if (mem_resp_valid) begin
                    if (cfg_phase_is_weight && !packed_weights_r) begin
                        cfg_word_data_r[(cfg_byte_lane_r*8) +: 8] <=
                            mem_resp_rdata[7:0];
                        if (cfg_byte_lane_r == 2'd3) begin
                            cfg_byte_lane_r <= 2'd0;
                            state <= ST_CFG_SEND;
                        end else begin
                            cfg_byte_lane_r <= cfg_byte_lane_r + 1'b1;
                            state <= ST_CFG_REQ;
                        end
                    end else begin
                        cfg_word_data_r <= mem_resp_rdata;
                        state <= ST_CFG_SEND;
                    end
                end
            end else if (state == ST_CFG_SEND) begin
                if (core_cfg_valid && core_cfg_ready) begin
                    cfg_word_data_r <= 32'd0;
                    cfg_byte_lane_r <= 2'd0;
                    if ((cfg_word_r + 1'b1) >= cfg_phase_limit) begin
                        cfg_word_r <= 10'd0;
                        if (cfg_phase_r == CFG_PW_SHIFT) begin
                            state <= ST_COMMIT;
                        end else begin
                            cfg_phase_r <= cfg_phase_r + 1'b1;
                            state <= ST_CFG_REQ;
                        end
                    end else begin
                        cfg_word_r <= cfg_word_r + 1'b1;
                        state <= ST_CFG_REQ;
                    end
                end
            end else if (state == ST_COMMIT) begin
                if (core_cfg_commit_valid && core_cfg_commit_ready) begin
                    state <= ST_START;
                end
            end else if (state == ST_START) begin
                if (core_error) begin
                    error_r <= 1'b1;
                    done <= 1'b1;
                    state <= ST_ERROR;
                end else if (core_start_valid && core_start_ready) begin
                    out_word_count_r <= 32'd0;
                    agg_state <= AGG_IDLE;
                    state <= ST_RUN;
                end
            end else if (state == ST_RUN) begin
                if (core_error) begin
                    error_r <= 1'b1;
                end

                if (core_mem_req_valid && core_mem_req_ready) begin
                    if (!input_address_valid) begin
                        error_r <= 1'b1;
                    end
                    agg_base_addr_r <= core_mem_req_addr;
                    agg_lane_r <= 2'd0;
                    agg_state <= AGG_REQ;
                end

                if (core_out_valid && core_out_ready) begin
                    if (!output_address_valid || (core_out_be != 4'hf) ||
                        (core_out_addr != (sink_base_r +
                                           (out_word_count_r << 2))) ||
                        (core_out_context !=
                         expected_context_ordinal_r[1:0]) ||
                        (core_out_owner !=
                         expected_context_ordinal_r[0]) ||
                        (core_out_epoch !=
                         (expected_context_ordinal_r >> 1)) ||
                         (core_out_last !=
                         (out_word_count_r == output_word_limit - 1'b1))) begin
                        error_r <= 1'b1;
                    end
                    if (out_word_count_r >= output_word_limit) begin
                        error_r <= 1'b1;
                    end else begin
                        out_word_count_r <= out_word_count_r + 1'b1;
                    end
                    if (core_out_last) begin
                        done_seen_r <= 1'b1;
                        done <= 1'b1;
                        state <= ST_DONE;
                    end
                end

                if (core_done && !done_seen_r) begin
                    /* The external completion boundary is the last accepted
                     * output, not an internal PW state transition. */
                    error_r <= 1'b1;
                    done <= 1'b1;
                    state <= ST_ERROR;
                end
            end else if (state == ST_DONE) begin
                /* done is a one-cycle layer pulse.  The core itself returns
                 * to TOP_IDLE after its done state, allowing the next top
                 * controller descriptor to start a fresh DS transaction. */
                state <= ST_IDLE;
            end else begin
                state <= ST_IDLE;
            end

            /* Source response aggregation has its own one-outstanding-word
             * contract.  The feature SRAM returns a word one cycle after the
             * corresponding read enable, while the M1.1-A core waits for the
             * assembled 128-bit response.  Separate request and wait states
             * are required because holding a synchronous SRAM enable high
             * repeats the same address request every cycle. */
            if ((state == ST_RUN) && (agg_state == AGG_REQ)) begin
                agg_state <= AGG_WAIT;
            end else if ((state == ST_RUN) && (agg_state == AGG_WAIT) &&
                         sram_input_rd_word_valid) begin
                if (agg_lane_r == 2'd0)
                    agg_word0_r <= sram_input_rd_word_data;
                else if (agg_lane_r == 2'd1)
                    agg_word1_r <= sram_input_rd_word_data;
                else if (agg_lane_r == 2'd2)
                    agg_word2_r <= sram_input_rd_word_data;
                else begin
                    core_mem_resp_data_r <= {
                        sram_input_rd_word_data, agg_word2_r,
                        agg_word1_r, agg_word0_r
                    };
                    agg_state <= AGG_RESP;
                end
                if (agg_lane_r != 2'd3) begin
                    agg_lane_r <= agg_lane_r + 1'b1;
                    agg_state <= AGG_REQ;
                end else begin
                    agg_lane_r <= 2'd0;
                end
            end else if ((state == ST_RUN) && (agg_state == AGG_RESP)) begin
                /* core_mem_resp_valid is high during this state and is
                 * consumed by m11a_dw16_shared_line at this clock edge. */
                if (core_mem_resp_valid)
                    agg_state <= AGG_IDLE;
            end
        end
    end
endmodule

`default_nettype wire
