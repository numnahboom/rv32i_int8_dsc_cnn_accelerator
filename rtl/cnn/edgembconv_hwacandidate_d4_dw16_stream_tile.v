`timescale 1ns/1ps
`default_nettype none

/*
 * Independent D4 depthwise primitive.
 *
 * This block is deliberately a small physical/data-plane primitive rather
 * than a copy of the D4 block shell.  One transaction computes one output
 * tile for one group of sixteen depthwise channels.  The source ABI is a
 * worded, synchronous memory ABI: src_req_addr is a word address and the
 * owner returns one 128-bit word (sixteen signed INT8 values) on the
 * decoupled src_resp channel.  There is never an asynchronous read of a
 * large activation array in this module.
 *
 * The request/response feeder can issue the next in-bounds word in the same
 * cycle in which the previous response is accepted.  The sixteen MAC cells
 * have a registered product stage and consume one tap per clock (II=1 after
 * a source word is available).  SAME halo taps are generated locally as a
 * zero word.  A product is accumulated once, with folded INT32 bias and
 * per-channel nearest-away-from-zero requantization at the final tap.
 *
 * Only the sixteen depthwise products are marked for DSP inference.  The
 * requant products are explicitly marked use_dsp=no so this primitive does
 * not silently duplicate the PW DSP array.  Outputs, metadata, and request
 * sidebands are registered/held by ready/valid rules.
 */
module edgembconv_hwacandidate_d4_dw16_stream_tile #(
    parameter integer MAX_IN_W = 32,
    parameter integer MAX_IN_H = 32,
    parameter integer MAX_TILE_W = 8,
    parameter integer MAX_TILE_H = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,

    /* Small weight/parameter loader.  cfg_addr is a byte/channel slot:
     * weight slots 0..143 are channel*9+tap; parameter slots are 0..15. */
    input  wire                         cfg_valid,
    output wire                         cfg_ready,
    input  wire [1:0]                   cfg_kind,
    input  wire [7:0]                   cfg_addr,
    input  wire [31:0]                  cfg_data,

    input  wire                         start_valid,
    output wire                         start_ready,
    input  wire [7:0]                   start_in_w,
    input  wire [7:0]                   start_in_h,
    input  wire [7:0]                   start_out_w,
    input  wire [7:0]                   start_out_h,
    input  wire [1:0]                   start_stride,
    input  wire [7:0]                   start_tile_x,
    input  wire [7:0]                   start_tile_y,
    input  wire [3:0]                   start_tile_w,
    input  wire [3:0]                   start_tile_h,
    input  wire [7:0]                   start_channel_base,
    input  wire [15:0]                  start_channel_mask,
    input  wire signed [7:0]             start_padding_value,
    input  wire signed [31:0]            start_output_zero_point,
    input  wire signed [31:0]            start_activation_min,
    input  wire signed [31:0]            start_activation_max,
    input  wire [3:0]                    start_epoch,
    input  wire [31:0]                   start_metadata,

    /* Worded synchronous source memory interface. */
    output wire                         src_req_valid,
    input  wire                         src_req_ready,
    output wire [31:0]                  src_req_addr,
    output wire [7:0]                   src_req_pixel_idx,
    output wire [3:0]                   src_req_tap_idx,
    output wire                         src_req_first_tap,
    output wire                         src_req_last_tap,
    output wire [31:0]                  src_req_metadata,
    input  wire                         src_resp_valid,
    output wire                         src_resp_ready,
    input  wire [127:0]                 src_resp_data,

    input  wire                         out_ready,
    output reg                          out_valid,
    output reg [127:0]                  out_data_vec,
    output reg [511:0]                  out_raw_psum_vec,
    output reg [7:0]                    out_pixel_idx,
    output reg [7:0]                    out_channel_base,
    output reg [15:0]                   out_lane_mask,
    output reg                          out_first,
    output reg                          out_last,
    output reg [31:0]                   out_metadata,

    output reg                          done_valid,
    input wire                          done_ready,
    output reg [3:0]                    done_epoch,

    output wire                         busy,
    output reg [31:0]                   cycle_count,
    output reg [31:0]                   tap_count,
    output reg [31:0]                   source_word_count,
    output reg [31:0]                   source_stall_count,
    output reg [31:0]                   output_stall_count,
    output reg [31:0]                   protocol_errors
);
    localparam [1:0] CFG_WEIGHT = 2'd0;
    localparam [1:0] CFG_BIAS = 2'd1;
    localparam [1:0] CFG_MULTIPLIER = 2'd2;
    localparam [1:0] CFG_SHIFT = 2'd3;

    (* ram_style = "distributed" *) reg signed [7:0] weight_mem [0:143];
    reg signed [31:0] bias_mem [0:15];
    reg signed [31:0] multiplier_mem [0:15];
    reg [5:0] shift_mem [0:15];

    reg active;
    reg req_pending;
    reg product_valid;
    reg product_last;
    reg drain_pending;
    reg [3:0] tap_idx;
    reg [7:0] pixel_x, pixel_y;
    reg [7:0] in_w, in_h, out_w, out_h;
    reg [1:0] stride;
    reg [7:0] tile_x, tile_y;
    reg [3:0] tile_w, tile_h;
    reg [7:0] channel_base;
    reg [15:0] channel_mask;
    reg signed [7:0] padding_value;
    reg signed [31:0] output_zero_point;
    reg signed [31:0] activation_min;
    reg signed [31:0] activation_max;
    reg [3:0] epoch;
    reg [31:0] transaction_metadata;

    reg signed [15:0] product_reg [0:15];
    reg signed [31:0] acc [0:15];
    /* The final accumulator is registered before the (LUT-oriented)
     * requantization cone.  This is both a physical timing boundary and a
     * precise separation between the 16 DW DSP products and output scaling. */
    reg final_pending;
    reg q_product_valid;
    reg signed [31:0] final_sum_reg [0:15];

    integer tap_row_i, tap_col_i;
    integer output_x_i, output_y_i;
    integer input_x_i, input_y_i;
    integer request_addr_i;
    integer pixel_idx_i;
    integer tile_pixels_i;
    integer i;

    wire start_fire = start_valid && start_ready;
    wire cfg_fire = cfg_valid && cfg_ready;
    wire response_fire = src_resp_valid && src_resp_ready;

    /* Tap coordinates are intentionally explicit case logic: this keeps the
     * synthesis cone small and avoids a variable divide/modulo implementation
     * in the request address path. */
    always @* begin
        case (tap_idx)
            4'd0: begin tap_row_i = 0; tap_col_i = 0; end
            4'd1: begin tap_row_i = 0; tap_col_i = 1; end
            4'd2: begin tap_row_i = 0; tap_col_i = 2; end
            4'd3: begin tap_row_i = 1; tap_col_i = 0; end
            4'd4: begin tap_row_i = 1; tap_col_i = 1; end
            4'd5: begin tap_row_i = 1; tap_col_i = 2; end
            4'd6: begin tap_row_i = 2; tap_col_i = 0; end
            4'd7: begin tap_row_i = 2; tap_col_i = 1; end
            4'd8: begin tap_row_i = 2; tap_col_i = 2; end
            default: begin tap_row_i = 0; tap_col_i = 0; end
        endcase
        output_x_i = tile_x + pixel_x;
        output_y_i = tile_y + pixel_y;
        input_x_i = (output_x_i * stride) + tap_col_i - 1;
        input_y_i = (output_y_i * stride) + tap_row_i - 1;
        request_addr_i = (input_y_i * in_w) + input_x_i;
        pixel_idx_i = (pixel_y * tile_w) + pixel_x;
        tile_pixels_i = tile_w * tile_h;
    end

    wire tap_in_bounds = (input_x_i >= 0) && (input_x_i < in_w) &&
                         (input_y_i >= 0) && (input_y_i < in_h);
    wire current_last_tap = (tap_idx == 4'd8);
    wire halo_fire = active && !out_valid && !drain_pending &&
                     !req_pending && !tap_in_bounds;
    wire next_after_response = response_fire && !current_last_tap;
    /* A response and the next request may cross at the same clock edge.  The
     * request address then uses the following tap, while the product stage
     * still uses the current tap. */
    integer request_tap_i;
    integer request_row_i, request_col_i, request_x_i, request_y_i;
    integer request_output_x_i, request_output_y_i;
    always @* begin
        request_tap_i = tap_idx;
        if (next_after_response)
            request_tap_i = tap_idx + 1;
        case (request_tap_i)
            0: begin request_row_i = 0; request_col_i = 0; end
            1: begin request_row_i = 0; request_col_i = 1; end
            2: begin request_row_i = 0; request_col_i = 2; end
            3: begin request_row_i = 1; request_col_i = 0; end
            4: begin request_row_i = 1; request_col_i = 1; end
            5: begin request_row_i = 1; request_col_i = 2; end
            6: begin request_row_i = 2; request_col_i = 0; end
            7: begin request_row_i = 2; request_col_i = 1; end
            8: begin request_row_i = 2; request_col_i = 2; end
            default: begin request_row_i = 0; request_col_i = 0; end
        endcase
        request_output_x_i = tile_x + pixel_x;
        request_output_y_i = tile_y + pixel_y;
        request_x_i = request_output_x_i * stride + request_col_i - 1;
        request_y_i = request_output_y_i * stride + request_row_i - 1;
    end
    wire request_tap_in_bounds = (request_x_i >= 0) &&
                                  (request_x_i < in_w) &&
                                  (request_y_i >= 0) &&
                                  (request_y_i < in_h);
    wire request_is_allowed = active && !out_valid && !drain_pending &&
                              request_tap_in_bounds;
    assign src_req_valid = request_is_allowed && (!req_pending || next_after_response);
    assign src_req_addr = request_is_allowed
                        ? (request_y_i * in_w + request_x_i) : 32'd0;
    assign src_req_pixel_idx = pixel_idx_i[7:0];
    assign src_req_tap_idx = request_tap_i[3:0];
    assign src_req_first_tap = (request_tap_i == 0);
    assign src_req_last_tap = (request_tap_i == 8);
    assign src_req_metadata = transaction_metadata;

    /* The one outstanding-request invariant makes the source response order
     * explicit.  The response may be held by the owner when this ready is
     * low; no request or output state depends on an unaccepted response. */
    assign src_resp_ready = active && req_pending && !out_valid &&
                            !drain_pending;
    wire request_fire = src_req_valid && src_req_ready;
    wire tap_fire = response_fire || halo_fire;
    wire signed [7:0] pad_byte = padding_value;
    wire [127:0] tap_word = response_fire ? src_resp_data :
                             {16{pad_byte}};

    /* One explicit signed DSP product per channel.  Requantization below is
     * a separate LUT multiplier (use_dsp=no) and cannot duplicate this DSP
     * bank. */
    wire signed [15:0] tap_product [0:15];
    genvar lane_g;
    generate
        for (lane_g = 0; lane_g < 16; lane_g = lane_g + 1) begin : gen_dw_product
            wire signed [7:0] act_lane = channel_mask[lane_g]
                ? $signed(tap_word[(lane_g*8) +: 8]) : 8'sd0;
            wire signed [7:0] weight_lane = weight_mem[(lane_g*9) + tap_idx];
            (* use_dsp = "yes" *) wire signed [15:0] dsp_product =
                act_lane * weight_lane;
            assign tap_product[lane_g] = dsp_product;
        end
    endgenerate

    function signed [7:0] requant_from_product;
        input signed [63:0] product_value;
        input [5:0] shift_value;
        input signed [31:0] zero_point_value;
        input signed [31:0] min_value;
        input signed [31:0] max_value;
        reg signed [63:0] magnitude_value;
        reg signed [63:0] rounded_value;
        reg signed [63:0] scaled_value;
        begin
            if (shift_value == 0) begin
                scaled_value = product_value;
            end else if (product_value < 0) begin
                magnitude_value = -product_value;
                rounded_value = (magnitude_value + (64'sd1 <<< (shift_value - 1))) >>> shift_value;
                scaled_value = -rounded_value;
            end else begin
                rounded_value = (product_value + (64'sd1 <<< (shift_value - 1))) >>> shift_value;
                scaled_value = rounded_value;
            end
            scaled_value = scaled_value + zero_point_value;
            if (scaled_value < min_value)
                requant_from_product = min_value[7:0];
            else if (scaled_value > max_value)
                requant_from_product = max_value[7:0];
            else
                requant_from_product = scaled_value[7:0];
        end
    endfunction

    /* Balanced, multiplier-operator-free requant products.  The upper
     * multiplier bit is the signed two's-complement term; the remaining bits
     * are positive shift/add terms. */
    wire signed [63:0] q_product_comb [0:15];
    wire signed [63:0] q_product_reg [0:15];
    genvar qg;
    generate
        for (qg = 0; qg < 16; qg = qg + 1) begin : gen_lut_requant_multiplier
            wire signed [63:0] q_a = {{32{final_sum_reg[qg][31]}}, final_sum_reg[qg]};
            wire signed [63:0] pp0 = multiplier_mem[qg][0] ? q_a : 64'sd0;
            wire signed [63:0] pp1 = multiplier_mem[qg][1] ? (q_a <<< 1) : 64'sd0;
            wire signed [63:0] pp2 = multiplier_mem[qg][2] ? (q_a <<< 2) : 64'sd0;
            wire signed [63:0] pp3 = multiplier_mem[qg][3] ? (q_a <<< 3) : 64'sd0;
            wire signed [63:0] pp4 = multiplier_mem[qg][4] ? (q_a <<< 4) : 64'sd0;
            wire signed [63:0] pp5 = multiplier_mem[qg][5] ? (q_a <<< 5) : 64'sd0;
            wire signed [63:0] pp6 = multiplier_mem[qg][6] ? (q_a <<< 6) : 64'sd0;
            wire signed [63:0] pp7 = multiplier_mem[qg][7] ? (q_a <<< 7) : 64'sd0;
            wire signed [63:0] pp8 = multiplier_mem[qg][8] ? (q_a <<< 8) : 64'sd0;
            wire signed [63:0] pp9 = multiplier_mem[qg][9] ? (q_a <<< 9) : 64'sd0;
            wire signed [63:0] pp10 = multiplier_mem[qg][10] ? (q_a <<< 10) : 64'sd0;
            wire signed [63:0] pp11 = multiplier_mem[qg][11] ? (q_a <<< 11) : 64'sd0;
            wire signed [63:0] pp12 = multiplier_mem[qg][12] ? (q_a <<< 12) : 64'sd0;
            wire signed [63:0] pp13 = multiplier_mem[qg][13] ? (q_a <<< 13) : 64'sd0;
            wire signed [63:0] pp14 = multiplier_mem[qg][14] ? (q_a <<< 14) : 64'sd0;
            wire signed [63:0] pp15 = multiplier_mem[qg][15] ? (q_a <<< 15) : 64'sd0;
            wire signed [63:0] pp16 = multiplier_mem[qg][16] ? (q_a <<< 16) : 64'sd0;
            wire signed [63:0] pp17 = multiplier_mem[qg][17] ? (q_a <<< 17) : 64'sd0;
            wire signed [63:0] pp18 = multiplier_mem[qg][18] ? (q_a <<< 18) : 64'sd0;
            wire signed [63:0] pp19 = multiplier_mem[qg][19] ? (q_a <<< 19) : 64'sd0;
            wire signed [63:0] pp20 = multiplier_mem[qg][20] ? (q_a <<< 20) : 64'sd0;
            wire signed [63:0] pp21 = multiplier_mem[qg][21] ? (q_a <<< 21) : 64'sd0;
            wire signed [63:0] pp22 = multiplier_mem[qg][22] ? (q_a <<< 22) : 64'sd0;
            wire signed [63:0] pp23 = multiplier_mem[qg][23] ? (q_a <<< 23) : 64'sd0;
            wire signed [63:0] pp24 = multiplier_mem[qg][24] ? (q_a <<< 24) : 64'sd0;
            wire signed [63:0] pp25 = multiplier_mem[qg][25] ? (q_a <<< 25) : 64'sd0;
            wire signed [63:0] pp26 = multiplier_mem[qg][26] ? (q_a <<< 26) : 64'sd0;
            wire signed [63:0] pp27 = multiplier_mem[qg][27] ? (q_a <<< 27) : 64'sd0;
            wire signed [63:0] pp28 = multiplier_mem[qg][28] ? (q_a <<< 28) : 64'sd0;
            wire signed [63:0] pp29 = multiplier_mem[qg][29] ? (q_a <<< 29) : 64'sd0;
            wire signed [63:0] pp30 = multiplier_mem[qg][30] ? (q_a <<< 30) : 64'sd0;
            wire signed [63:0] pp31 = multiplier_mem[qg][31] ? -(q_a <<< 31) : 64'sd0;
            wire signed [63:0] s10 = pp0 + pp1, s11 = pp2 + pp3;
            wire signed [63:0] s12 = pp4 + pp5, s13 = pp6 + pp7;
            wire signed [63:0] s14 = pp8 + pp9, s15 = pp10 + pp11;
            wire signed [63:0] s16 = pp12 + pp13, s17 = pp14 + pp15;
            wire signed [63:0] s18 = pp16 + pp17, s19 = pp18 + pp19;
            wire signed [63:0] s1a = pp20 + pp21, s1b = pp22 + pp23;
            wire signed [63:0] s1c = pp24 + pp25, s1d = pp26 + pp27;
            wire signed [63:0] s1e = pp28 + pp29, s1f = pp30 + pp31;
            wire signed [63:0] s20 = s10 + s11, s21 = s12 + s13;
            wire signed [63:0] s22 = s14 + s15, s23 = s16 + s17;
            wire signed [63:0] s24 = s18 + s19, s25 = s1a + s1b;
            wire signed [63:0] s26 = s1c + s1d, s27 = s1e + s1f;
            wire signed [63:0] s30 = s20 + s21, s31 = s22 + s23;
            wire signed [63:0] s32 = s24 + s25, s33 = s26 + s27;
            wire signed [63:0] s40 = s30 + s31, s41 = s32 + s33;
            assign q_product_comb[qg] = s40 + s41;
        end
    endgenerate

    genvar qreg_g;
    generate
        for (qreg_g = 0; qreg_g < 16; qreg_g = qreg_g + 1) begin : gen_q_product_reg
            reg signed [63:0] qreg;
            assign q_product_reg[qreg_g] = qreg;
            always @(posedge clk) begin
                if (!rst_n)
                    qreg <= 64'sd0;
                else if (final_pending)
                    qreg <= q_product_comb[qreg_g];
            end
        end
    endgenerate

    reg [127:0] requant_vec_comb;
    integer q_i;
    always @* begin
        requant_vec_comb = 128'd0;
        for (q_i = 0; q_i < 16; q_i = q_i + 1) begin
            if (channel_mask[q_i])
                requant_vec_comb[(q_i*8) +: 8] = requant_from_product(
                    q_product_reg[q_i], shift_mem[q_i], output_zero_point,
                    activation_min, activation_max);
            else
                requant_vec_comb[(q_i*8) +: 8] = 8'sd0;
        end
    end

    assign cfg_ready = rst_n && !active && !out_valid && !done_valid;
    assign start_ready = rst_n && !active && !out_valid && !done_valid;
    assign busy = active || out_valid || done_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0;
            req_pending <= 1'b0;
            product_valid <= 1'b0;
            product_last <= 1'b0;
            final_pending <= 1'b0;
            q_product_valid <= 1'b0;
            drain_pending <= 1'b0;
            tap_idx <= 4'd0;
            pixel_x <= 8'd0;
            pixel_y <= 8'd0;
            in_w <= 8'd0; in_h <= 8'd0; out_w <= 8'd0; out_h <= 8'd0;
            stride <= 2'd1;
            tile_x <= 8'd0; tile_y <= 8'd0;
            tile_w <= 4'd0; tile_h <= 4'd0;
            channel_base <= 8'd0;
            channel_mask <= 16'd0;
            padding_value <= 8'sd0;
            output_zero_point <= 32'sd0;
            activation_min <= -32'sd128;
            activation_max <= 32'sd127;
            epoch <= 4'd0;
            transaction_metadata <= 32'd0;
            out_valid <= 1'b0;
            out_data_vec <= 128'd0;
            out_raw_psum_vec <= 512'd0;
            out_pixel_idx <= 8'd0;
            out_channel_base <= 8'd0;
            out_lane_mask <= 16'd0;
            out_first <= 1'b0;
            out_last <= 1'b0;
            out_metadata <= 32'd0;
            done_valid <= 1'b0;
            done_epoch <= 4'd0;
            cycle_count <= 32'd0;
            tap_count <= 32'd0;
            source_word_count <= 32'd0;
            source_stall_count <= 32'd0;
            output_stall_count <= 32'd0;
            protocol_errors <= 32'd0;
            for (i = 0; i < 16; i = i + 1) begin
                product_reg[i] <= 16'sd0;
                acc[i] <= 32'sd0;
                final_sum_reg[i] <= 32'sd0;
            end
        end else begin
            if (done_valid && done_ready)
                done_valid <= 1'b0;

            if (active || out_valid)
                cycle_count <= cycle_count + 1'b1;
            if (src_req_valid && !src_req_ready)
                source_stall_count <= source_stall_count + 1'b1;
            if (out_valid && !out_ready)
                output_stall_count <= output_stall_count + 1'b1;

            if (cfg_fire) begin
                case (cfg_kind)
                    CFG_WEIGHT: begin
                        if (cfg_addr < 8'd144)
                            weight_mem[cfg_addr] <= cfg_data[7:0];
                        else
                            protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_BIAS: begin
                        if (cfg_addr < 8'd16)
                            bias_mem[cfg_addr] <= cfg_data;
                        else
                            protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_MULTIPLIER: begin
                        if (cfg_addr < 8'd16)
                            multiplier_mem[cfg_addr] <= cfg_data;
                        else
                            protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_SHIFT: begin
                        if (cfg_addr < 8'd16)
                            shift_mem[cfg_addr] <= cfg_data[5:0];
                        else
                            protocol_errors <= protocol_errors + 1'b1;
                    end
                    default: protocol_errors <= protocol_errors + 1'b1;
                endcase
            end

            if (start_fire) begin
                if ((start_stride != 2'd1 && start_stride != 2'd2) ||
                    start_in_w == 0 || start_in_h == 0 ||
                    start_out_w == 0 || start_out_h == 0 ||
                    start_tile_w == 0 || start_tile_h == 0 ||
                    start_tile_w > MAX_TILE_W || start_tile_h > MAX_TILE_H)
                    protocol_errors <= protocol_errors + 1'b1;
                active <= 1'b1;
                req_pending <= 1'b0;
                product_valid <= 1'b0;
                product_last <= 1'b0;
                final_pending <= 1'b0;
                q_product_valid <= 1'b0;
                drain_pending <= 1'b0;
                tap_idx <= 4'd0;
                pixel_x <= 8'd0;
                pixel_y <= 8'd0;
                in_w <= start_in_w; in_h <= start_in_h;
                out_w <= start_out_w; out_h <= start_out_h;
                stride <= start_stride;
                tile_x <= start_tile_x; tile_y <= start_tile_y;
                tile_w <= start_tile_w; tile_h <= start_tile_h;
                channel_base <= start_channel_base;
                channel_mask <= start_channel_mask;
                padding_value <= start_padding_value;
                output_zero_point <= start_output_zero_point;
                activation_min <= start_activation_min;
                activation_max <= start_activation_max;
                epoch <= start_epoch;
                transaction_metadata <= start_metadata;
                cycle_count <= 32'd0;
                tap_count <= 32'd0;
                source_word_count <= 32'd0;
                source_stall_count <= 32'd0;
                output_stall_count <= 32'd0;
                for (i = 0; i < 16; i = i + 1)
                    acc[i] <= 32'sd0;
            end

            if (request_fire)
                source_word_count <= source_word_count + 1'b1;
            if (response_fire)
                req_pending <= request_fire;
            else if (request_fire)
                req_pending <= 1'b1;

            /* Registered DSP product/M stage.  The old product is consumed
             * while a new tap is captured, which is the II=1 boundary. */
            product_valid <= tap_fire;
            if (tap_fire) begin
                tap_count <= tap_count + 1'b1;
                for (i = 0; i < 16; i = i + 1)
                    product_reg[i] <= tap_product[i];
                product_last <= current_last_tap;
                if (!current_last_tap)
                    tap_idx <= tap_idx + 1'b1;
                else
                    drain_pending <= 1'b1;
            end

            if (product_valid) begin
                for (i = 0; i < 16; i = i + 1) begin
                    acc[i] <= acc[i] + {{16{product_reg[i][15]}}, product_reg[i]};
                    if (product_last) begin
                        if (channel_mask[i]) begin
                            out_raw_psum_vec[(i*32) +: 32] <=
                                acc[i] + {{16{product_reg[i][15]}}, product_reg[i]} + bias_mem[i];
                            final_sum_reg[i] <=
                                acc[i] + {{16{product_reg[i][15]}}, product_reg[i]} + bias_mem[i];
                        end else begin
                            out_raw_psum_vec[(i*32) +: 32] <= 32'sd0;
                            final_sum_reg[i] <= 32'sd0;
                        end
                    end
                end
                if (product_last) begin
                    final_pending <= 1'b1;
                    out_pixel_idx <= pixel_idx_i[7:0];
                    out_channel_base <= channel_base;
                    out_lane_mask <= channel_mask;
                    out_first <= (pixel_idx_i == 0);
                    out_last <= (pixel_idx_i == tile_pixels_i - 1);
                    out_metadata <= transaction_metadata;
                    /* Keep the pixel fenced while q_product_valid drains;
                     * the next tap may only begin after out_ready accepts
                     * this completed vector. */
                end
            end

            /* Requantization is intentionally one registered stage after the
             * final raw psum.  The output remains invalid until all sixteen
             * lane values are formed, so ready/valid stability is unchanged. */
            q_product_valid <= final_pending;
            if (q_product_valid) begin
                out_data_vec <= requant_vec_comb;
                out_valid <= 1'b1;
            end
            if (final_pending)
                final_pending <= 1'b0;

            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
                if (pixel_idx_i == tile_pixels_i - 1) begin
                    active <= 1'b0;
                    req_pending <= 1'b0;
                    done_valid <= 1'b1;
                    done_epoch <= epoch;
                    tap_idx <= 4'd0;
                    drain_pending <= 1'b0;
                end else begin
                    if (pixel_x == tile_w - 1) begin
                        pixel_x <= 8'd0;
                        pixel_y <= pixel_y + 1'b1;
                    end else begin
                        pixel_x <= pixel_x + 1'b1;
                    end
                    tap_idx <= 4'd0;
                    drain_pending <= 1'b0;
                    req_pending <= 1'b0;
                    for (i = 0; i < 16; i = i + 1)
                        acc[i] <= 32'sd0;
                end
            end
        end
    end
endmodule

`default_nettype wire
