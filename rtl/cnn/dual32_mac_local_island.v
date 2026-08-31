`timescale 1ns/1ps
`default_nettype none

/*
 * Dual 32-MAC local-island feasibility macro.
 *
 * This is a deliberately narrow physical experiment, rather than a second
 * top-level CNN.  Each island owns 32 int8 multipliers and its accumulator
 * bank.  Only 32-bit source/parameter words cross the boundary.  A completed
 * block is drained as one 32-bit (four int8) commit per cycle; no wide result
 * slot or live bank-state bus is present.
 *
 * mode 0 (PW):   each island is 8 pixels x 4 output channels; the pair is
 *                one 8 pixel x 8 channel block.
 * mode 1 (STEM): each island is 4 pixels x 8 output channels; the pair is
 *                one 4 pixel x 16 channel block.
 * mode 2 (DW):   island 0 is 4 pixels x 8 channels; island 1 is disabled.
 *
 * The source/parameter word mapping is intentionally explicit:
 * PW uses src_word0/1 and param_word0 (island 0)/param_word1 (island 1),
 * STEM uses src_word0 and param_word0..3, and DW uses src_word0 and
 * param_word0/1.  Parameters are loaded one 32-bit record at a time while
 * the macro is idle, so output quantization never observes a live config bus.
 */
module dual32_mac_local_island #(
    parameter integer ISLANDS = 2
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        [1:0]  mode_i,
    input  wire        cfg_valid_i,
    output wire        cfg_ready_o,
    input  wire        cfg_island_i,
    input  wire        [5:0]  cfg_lane_i,
    input  wire signed [31:0] cfg_bias_i,
    input  wire signed [31:0] cfg_multiplier_i,
    input  wire        [5:0]  cfg_shift_i,

    input  wire        valid_in,
    output wire        ready_in,
    input  wire        first_k,
    input  wire        last_k,
    input  wire        [7:0]  k_idx,
    input  wire        [7:0]  block_tag_i,
    input  wire        [7:0]  pixel_base_i,
    input  wire        [8:0]  cout_base_i,
    input  wire        [7:0]  pixel_mask_i,
    input  wire        [15:0] cout_mask_i,
    input  wire signed [31:0] output_zero_point_i,
    input  wire signed [31:0] activation_min_i,
    input  wire signed [31:0] activation_max_i,
    input  wire        [31:0] src_word0_i,
    input  wire        [31:0] src_word1_i,
    input  wire        [31:0] param_word0_i,
    input  wire        [31:0] param_word1_i,
    input  wire        [31:0] param_word2_i,
    input  wire        [31:0] param_word3_i,

    output wire        valid_out,
    input  wire        ready_out,
    output wire        [31:0] out_word,
    output wire        [3:0]  out_word_mask,
    output wire        [7:0]  out_pixel_idx,
    output wire        [8:0]  out_channel_base,
    output wire        [2:0]  out_group_idx,
    output wire        [7:0]  out_block_tag,
    output wire        [1:0]  out_mode,
    output wire        busy_o
);
    localparam [1:0] MODE_PW = 2'd0;
    localparam [1:0] MODE_STEM = 2'd1;
    localparam [1:0] MODE_DW = 2'd2;

    wire i0_cfg_ready, i1_cfg_ready;
    wire i0_valid, i1_valid;
    wire i0_ready, i1_ready;
    wire i0_busy, i1_busy;
    wire [31:0] i0_word, i1_word;
    wire [3:0] i0_mask, i1_mask;
    wire [7:0] i0_pixel, i1_pixel, i0_tag, i1_tag;
    wire [8:0] i0_channel, i1_channel;
    wire [2:0] i0_group, i1_group;
    wire [1:0] i0_mode, i1_mode;

    assign cfg_ready_o = cfg_island_i ? i1_cfg_ready : i0_cfg_ready;

    /* DW intentionally clocks and feeds only one physical island. */
    assign ready_in = rst_n && ((mode_i == MODE_DW) ? i0_ready
                                                    : (i0_ready && i1_ready));

    wire island0_valid_in = valid_in && ((mode_i != MODE_DW) || 1'b1);
    wire island1_valid_in = valid_in && (mode_i != MODE_DW);

    dual32_mac_local_island_lane #(.ISLAND_INDEX(0)) u_island0 (
        .clk(clk), .rst_n(rst_n), .mode_i(mode_i),
        .cfg_valid_i(cfg_valid_i && !cfg_island_i), .cfg_ready_o(i0_cfg_ready),
        .cfg_lane_i(cfg_lane_i), .cfg_bias_i(cfg_bias_i),
        .cfg_multiplier_i(cfg_multiplier_i), .cfg_shift_i(cfg_shift_i),
        .valid_in(island0_valid_in), .ready_in(i0_ready),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .block_tag_i(block_tag_i), .pixel_base_i(pixel_base_i),
        .cout_base_i(cout_base_i), .pixel_mask_i(pixel_mask_i),
        .cout_mask_i(cout_mask_i),
        .output_zero_point_i(output_zero_point_i),
        .activation_min_i(activation_min_i), .activation_max_i(activation_max_i),
        .src_word0_i(src_word0_i), .src_word1_i(src_word1_i),
        .param_word0_i(param_word0_i), .param_word1_i(param_word1_i),
        .param_word2_i(param_word2_i), .param_word3_i(param_word3_i),
        .valid_out(i0_valid), .ready_out(ready_out),
        .out_word(i0_word), .out_word_mask(i0_mask),
        .out_pixel_idx(i0_pixel), .out_channel_base(i0_channel),
        .out_group_idx(i0_group), .out_block_tag(i0_tag), .out_mode(i0_mode),
        .busy_o(i0_busy)
    );

    dual32_mac_local_island_lane #(.ISLAND_INDEX(1)) u_island1 (
        .clk(clk), .rst_n(rst_n), .mode_i(mode_i),
        .cfg_valid_i(cfg_valid_i && cfg_island_i), .cfg_ready_o(i1_cfg_ready),
        .cfg_lane_i(cfg_lane_i), .cfg_bias_i(cfg_bias_i),
        .cfg_multiplier_i(cfg_multiplier_i), .cfg_shift_i(cfg_shift_i),
        .valid_in(island1_valid_in), .ready_in(i1_ready),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .block_tag_i(block_tag_i), .pixel_base_i(pixel_base_i),
        .cout_base_i(cout_base_i), .pixel_mask_i(pixel_mask_i),
        .cout_mask_i(cout_mask_i),
        .output_zero_point_i(output_zero_point_i),
        .activation_min_i(activation_min_i), .activation_max_i(activation_max_i),
        .src_word0_i(src_word0_i), .src_word1_i(src_word1_i),
        .param_word0_i(param_word0_i), .param_word1_i(param_word1_i),
        .param_word2_i(param_word2_i), .param_word3_i(param_word3_i),
        .valid_out(i1_valid), .ready_out(ready_out && !i0_valid),
        .out_word(i1_word), .out_word_mask(i1_mask),
        .out_pixel_idx(i1_pixel), .out_channel_base(i1_channel),
        .out_group_idx(i1_group), .out_block_tag(i1_tag), .out_mode(i1_mode),
        .busy_o(i1_busy)
    );

    /* A narrow priority fence drains island 0 completely before island 1.
     * The lane modules hold all output fields while ready_out is low. */
    wire select_i1 = !i0_valid && i1_valid;
    assign valid_out = i0_valid || i1_valid;
    assign out_word = select_i1 ? i1_word : i0_word;
    assign out_word_mask = select_i1 ? i1_mask : i0_mask;
    assign out_pixel_idx = select_i1 ? i1_pixel : i0_pixel;
    assign out_channel_base = select_i1 ? i1_channel : i0_channel;
    assign out_group_idx = select_i1 ? i1_group : i0_group;
    assign out_block_tag = select_i1 ? i1_tag : i0_tag;
    assign out_mode = select_i1 ? i1_mode : i0_mode;
    assign busy_o = i0_busy || i1_busy;
endmodule

/* One fully local 32-MAC island. */
module dual32_mac_local_island_lane #(
    parameter integer ISLAND_INDEX = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        [1:0] mode_i,
    input  wire        cfg_valid_i,
    output wire        cfg_ready_o,
    input  wire        [5:0] cfg_lane_i,
    input  wire signed [31:0] cfg_bias_i,
    input  wire signed [31:0] cfg_multiplier_i,
    input  wire        [5:0] cfg_shift_i,
    input  wire        valid_in,
    output wire        ready_in,
    input  wire        first_k,
    input  wire        last_k,
    input  wire        [7:0] k_idx,
    input  wire        [7:0] block_tag_i,
    input  wire        [7:0] pixel_base_i,
    input  wire        [8:0] cout_base_i,
    input  wire        [7:0] pixel_mask_i,
    input  wire        [15:0] cout_mask_i,
    input  wire signed [31:0] output_zero_point_i,
    input  wire signed [31:0] activation_min_i,
    input  wire signed [31:0] activation_max_i,
    input  wire [31:0] src_word0_i,
    input  wire [31:0] src_word1_i,
    input  wire [31:0] param_word0_i,
    input  wire [31:0] param_word1_i,
    input  wire [31:0] param_word2_i,
    input  wire [31:0] param_word3_i,
    output wire valid_out,
    input  wire ready_out,
    output wire [31:0] out_word,
    output wire [3:0] out_word_mask,
    output wire [7:0] out_pixel_idx,
    output wire [8:0] out_channel_base,
    output wire [2:0] out_group_idx,
    output wire [7:0] out_block_tag,
    output wire [1:0] out_mode,
    output wire busy_o
);
    localparam [1:0] MODE_PW = 2'd0;
    localparam [1:0] MODE_STEM = 2'd1;
    localparam [1:0] MODE_DW = 2'd2;

    reg signed [31:0] acc [0:31];
    reg signed [31:0] bias_mem [0:31];
    reg signed [31:0] mult_mem [0:31];
    reg [5:0] shift_mem [0:31];

    reg stage_valid, stage_first, stage_last;
    reg [7:0] stage_k_idx;
    reg [1:0] stage_mode;
    reg [31:0] stage_act [0:31];
    reg [31:0] stage_wgt [0:31];
    reg block_active, drain_active;
    reg [2:0] drain_group;
    reg [1:0] saved_mode;
    reg [7:0] saved_tag, saved_pixel_mask;
    reg [15:0] saved_cout_mask;
    reg [7:0] saved_pixel_base;
    reg [8:0] saved_cout_base;
    reg signed [31:0] saved_zp, saved_min, saved_max;

    /* A completed MAC block is committed to this local two-entry FIFO before
     * it enters the requantizer.  The accumulator therefore has no
     * dependency on the output port (or on the other island's ready). */
    reg signed [31:0] result_fifo_acc [0:1][0:31];
    reg [7:0] result_fifo_tag [0:1];
    reg [7:0] result_fifo_pixel_base [0:1];
    reg [8:0] result_fifo_cout_base [0:1];
    reg [7:0] result_fifo_pixel_mask [0:1];
    reg [15:0] result_fifo_cout_mask [0:1];
    reg [1:0] result_fifo_mode [0:1];
    reg signed [31:0] result_fifo_zp [0:1];
    reg signed [31:0] result_fifo_min [0:1];
    reg signed [31:0] result_fifo_max [0:1];
    reg [1:0] result_fifo_count;
    reg result_fifo_wr_ptr, result_fifo_rd_ptr;
    reg signed [31:0] block_zp, block_min, block_max;
    reg [7:0] block_tag, block_pixel_base, block_pixel_mask;
    reg [8:0] block_cout_base;
    reg [15:0] block_cout_mask;
    reg [1:0] block_mode;
    reg signed [31:0] drain_acc [0:31];
    reg signed [31:0] drain_zp, drain_min, drain_max;

    assign cfg_ready_o = rst_n && !block_active && !stage_valid &&
                         !drain_active && (result_fifo_count == 0) &&
                         !q0_valid && !q1_valid && !qf_valid && !q2_valid;
    /* first_k is payload, not flow control.  Looking at it here would make
     * ready depend on a yet-to-be-registered upstream flag and can reject a
     * perfectly legal next token at the stage boundary. */
    /* FIFO space is the only admission limit.  In particular ready_out is
     * deliberately absent: a stalled output may fill the two local slots,
     * but cannot reach back into an already admitted block. */
    assign ready_in = rst_n && (result_fifo_count != 2) &&
                      (!stage_valid || !stage_last);
    wire input_fire = valid_in && ready_in;
    wire stage_fire = stage_valid;
    /* The requant pipeline owns the final output handshake.  These wires are
     * defined by the registered stages below; keeping the drain cursor on
     * the narrow raw-word side avoids a combinational requant path. */
    wire q0_capture;
    wire q0_last_capture;
    wire q2_fire_last;
    wire fifo_pop = !drain_active && (result_fifo_count != 0) &&
                    !q0_valid && !q1_valid && !qf_valid && !q2_valid;

    wire [7:0] src_byte0 [0:3];
    wire [7:0] src_byte1 [0:3];
    wire [7:0] pw_w0 [0:3];
    wire [7:0] pw_w1 [0:3];
    wire [7:0] st_w0 [0:3];
    wire [7:0] st_w1 [0:3];
    assign src_byte0[0] = src_word0_i[7:0];
    assign src_byte0[1] = src_word0_i[15:8];
    assign src_byte0[2] = src_word0_i[23:16];
    assign src_byte0[3] = src_word0_i[31:24];
    assign src_byte1[0] = src_word1_i[7:0];
    assign src_byte1[1] = src_word1_i[15:8];
    assign src_byte1[2] = src_word1_i[23:16];
    assign src_byte1[3] = src_word1_i[31:24];
    assign pw_w0[0] = param_word0_i[7:0];
    assign pw_w0[1] = param_word0_i[15:8];
    assign pw_w0[2] = param_word0_i[23:16];
    assign pw_w0[3] = param_word0_i[31:24];
    assign pw_w1[0] = param_word1_i[7:0];
    assign pw_w1[1] = param_word1_i[15:8];
    assign pw_w1[2] = param_word1_i[23:16];
    assign pw_w1[3] = param_word1_i[31:24];
    assign st_w0[0] = param_word0_i[7:0];
    assign st_w0[1] = param_word0_i[15:8];
    assign st_w0[2] = param_word0_i[23:16];
    assign st_w0[3] = param_word0_i[31:24];
    assign st_w1[0] = param_word1_i[7:0];
    assign st_w1[1] = param_word1_i[15:8];
    assign st_w1[2] = param_word1_i[23:16];
    assign st_w1[3] = param_word1_i[31:24];

    integer li;
    /* Operand decode happens only at the registered island ingress. */
    always @(posedge clk) begin
        if (!rst_n) begin
            stage_valid <= 1'b0;
            stage_first <= 1'b0;
            stage_last <= 1'b0;
            stage_k_idx <= 0;
            stage_mode <= MODE_PW;
            block_active <= 1'b0;
            drain_active <= 1'b0;
            drain_group <= 0;
            saved_mode <= MODE_PW;
            saved_tag <= 0;
            saved_pixel_mask <= 0;
            saved_cout_mask <= 0;
            saved_pixel_base <= 0;
            saved_cout_base <= 0;
            saved_zp <= 0;
            saved_min <= -32'sd128;
            saved_max <= 32'sd127;
            block_zp <= 0;
            block_min <= -32'sd128;
            block_max <= 32'sd127;
            block_tag <= 0;
            block_pixel_base <= 0;
            block_pixel_mask <= 0;
            block_cout_base <= 0;
            block_cout_mask <= 0;
            block_mode <= MODE_PW;
            result_fifo_count <= 0;
            result_fifo_wr_ptr <= 0;
            result_fifo_rd_ptr <= 0;
            drain_zp <= 0;
            drain_min <= -32'sd128;
            drain_max <= 32'sd127;
            for (li = 0; li < 32; li = li + 1) begin
                acc[li] <= 0;
                bias_mem[li] <= 0;
                mult_mem[li] <= 0;
                shift_mem[li] <= 0;
                stage_act[li] <= 0;
                stage_wgt[li] <= 0;
                drain_acc[li] <= 0;
            end
            for (li = 0; li < 2; li = li + 1) begin
                result_fifo_tag[li] <= 0;
                result_fifo_pixel_base[li] <= 0;
                result_fifo_cout_base[li] <= 0;
                result_fifo_pixel_mask[li] <= 0;
                result_fifo_cout_mask[li] <= 0;
                result_fifo_mode[li] <= MODE_PW;
                result_fifo_zp[li] <= 0;
                result_fifo_min[li] <= -32'sd128;
                result_fifo_max[li] <= 32'sd127;
            end
        end else begin
            if (cfg_valid_i && cfg_ready_o && (cfg_lane_i < 32)) begin
                bias_mem[cfg_lane_i] <= cfg_bias_i;
                mult_mem[cfg_lane_i] <= cfg_multiplier_i;
                shift_mem[cfg_lane_i] <= cfg_shift_i;
            end

            if (stage_fire) begin
                for (li = 0; li < 32; li = li + 1)
                    acc[li] <= sum_next[li];
                if (stage_last) begin
                    for (li = 0; li < 32; li = li + 1)
                        result_fifo_acc[result_fifo_wr_ptr][li] <= sum_next[li];
                    result_fifo_tag[result_fifo_wr_ptr] <= block_tag;
                    result_fifo_pixel_base[result_fifo_wr_ptr] <= block_pixel_base;
                    result_fifo_cout_base[result_fifo_wr_ptr] <= block_cout_base;
                    result_fifo_pixel_mask[result_fifo_wr_ptr] <= block_pixel_mask;
                    result_fifo_cout_mask[result_fifo_wr_ptr] <= block_cout_mask;
                    result_fifo_mode[result_fifo_wr_ptr] <= block_mode;
                    result_fifo_zp[result_fifo_wr_ptr] <= block_zp;
                    result_fifo_min[result_fifo_wr_ptr] <= block_min;
                    result_fifo_max[result_fifo_wr_ptr] <= block_max;
                    result_fifo_wr_ptr <= result_fifo_wr_ptr + 1'b1;
                end
            end

            if (fifo_pop) begin
                for (li = 0; li < 32; li = li + 1)
                    drain_acc[li] <= result_fifo_acc[result_fifo_rd_ptr][li];
                saved_mode <= result_fifo_mode[result_fifo_rd_ptr];
                saved_tag <= result_fifo_tag[result_fifo_rd_ptr];
                saved_pixel_mask <= result_fifo_pixel_mask[result_fifo_rd_ptr];
                saved_cout_mask <= result_fifo_cout_mask[result_fifo_rd_ptr];
                saved_pixel_base <= result_fifo_pixel_base[result_fifo_rd_ptr];
                saved_cout_base <= result_fifo_cout_base[result_fifo_rd_ptr];
                drain_zp <= result_fifo_zp[result_fifo_rd_ptr];
                drain_min <= result_fifo_min[result_fifo_rd_ptr];
                drain_max <= result_fifo_max[result_fifo_rd_ptr];
                result_fifo_rd_ptr <= result_fifo_rd_ptr + 1'b1;
                drain_active <= 1'b1;
                drain_group <= 3'd0;
            end

            case ({stage_fire && stage_last, fifo_pop})
                2'b10: result_fifo_count <= result_fifo_count + 1'b1;
                2'b01: result_fifo_count <= result_fifo_count - 1'b1;
                default: result_fifo_count <= result_fifo_count;
            endcase

            if (input_fire) begin
                stage_valid <= 1'b1;
                stage_first <= first_k;
                stage_last <= last_k;
                stage_k_idx <= k_idx;
                stage_mode <= mode_i;
                if (first_k) begin
                    block_active <= 1'b1;
                    block_mode <= mode_i;
                    block_tag <= block_tag_i;
                    block_pixel_mask <= pixel_mask_i;
                    block_cout_mask <= cout_mask_i;
                    block_pixel_base <= pixel_base_i;
                    block_cout_base <= cout_base_i;
                    block_zp <= output_zero_point_i;
                    block_min <= activation_min_i;
                    block_max <= activation_max_i;
                end
                for (li = 0; li < 32; li = li + 1) begin
                    stage_act[li] <= act_for_lane(li);
                    stage_wgt[li] <= weight_for_lane(li);
                end
            end else if (stage_fire) begin
                stage_valid <= 1'b0;
                stage_last <= 1'b0;
            end

            if (q0_capture) begin
                if (drain_group == 3'd7)
                    drain_active <= 1'b0;
                else
                    drain_group <= drain_group + 1'b1;
            end
            if (stage_fire && stage_last && !(input_fire && first_k))
                block_active <= 1'b0;
        end
    end

    function [31:0] act_for_lane;
        input integer lane;
        integer p, c;
        begin
            if (mode_i == MODE_PW) begin
                p = lane / 4;
                if (p < 4) act_for_lane = {24'd0,src_byte0[p]};
                else act_for_lane = {24'd0,src_byte1[p-4]};
            end else begin
                p = lane / 8;
                act_for_lane = (p < 4) ? {24'd0,src_byte0[p]} : 32'd0;
            end
        end
    endfunction

    wire [7:0] q2_next_byte [0:3];
    function [31:0] weight_for_lane;
        input integer lane;
        integer c;
        begin
            if (mode_i == MODE_PW) begin
                c = lane % 4;
                weight_for_lane = {24'd0, (ISLAND_INDEX == 0) ? pw_w0[c] : pw_w1[c]};
            end else begin
                c = lane % 8;
                if (ISLAND_INDEX == 0)
                    weight_for_lane = (c < 4) ? {24'd0,st_w0[c]} :
                                      {24'd0,st_w1[c-4]};
                else
                    weight_for_lane = (c < 4) ? {24'd0,param_word2_i[c*8 +: 8]} :
                                      {24'd0,param_word3_i[(c-4)*8 +: 8]};
            end
        end
    endfunction

    wire signed [31:0] sum_next [0:31];
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : gen_mac
            (* use_dsp = "yes" *) wire signed [15:0] product =
                $signed(stage_act[g][7:0]) * $signed(stage_wgt[g][7:0]);
            wire signed [31:0] product_ext = {{16{product[15]}},product};
            assign sum_next[g] = stage_first ? product_ext :
                                 (acc[g] + product_ext);
        end
    endgenerate

    function lane_valid;
        input integer lane;
        integer p, c, gc;
        begin
            if (saved_mode == MODE_PW) begin
                p = lane / 4; c = lane % 4; gc = c + (ISLAND_INDEX * 4);
            end else begin
                p = lane / 8; c = lane % 8; gc = c + (ISLAND_INDEX * 8);
            end
            if ((saved_mode == MODE_DW) && (ISLAND_INDEX != 0))
                lane_valid = 1'b0;
            else
                lane_valid = saved_pixel_mask[p] && saved_cout_mask[gc];
        end
    endfunction

    function [7:0] requant_lane;
        input signed [31:0] acc_in;
        input signed [31:0] bias_in;
        input signed [31:0] mult_in;
        input [5:0] shift_in;
        reg signed [127:0] aa, mm, pp, fixed;
        reg signed [127:0] shifted, added;
        reg [30:0] low_bits;
        reg neg, low_zero, round_up;
        begin
            aa = acc_in + bias_in;
            mm = mult_in;
            pp = aa * mm;
            low_bits = pp[30:0];
            low_zero = (low_bits == 31'd0);
            neg = pp[127];
            if (!neg) begin
                round_up = (low_bits >= 31'h40000000);
                fixed = (pp >>> 31) + (round_up ? 1 : 0);
            end else begin
                round_up = pp[30] ? (low_zero || (pp[29:0] == 30'd0))
                                  : !low_zero;
                if (low_zero && round_up)
                    fixed = (pp >>> 31) - 1;
                else if (low_zero || round_up)
                    fixed = (pp >>> 31);
                else
                    fixed = (pp >>> 31) + 1;
            end
            shifted = fixed >>> shift_in;
            added = shifted + drain_zp;
            if (added > 127) requant_lane = 8'h7f;
            else if (added < -128) requant_lane = 8'h80;
            else if (added < drain_min) requant_lane = drain_min[7:0];
            else if (added > drain_max) requant_lane = drain_max[7:0];
            else requant_lane = added[7:0];
        end
    endfunction

    /* Three short elastic stages: acc/config mux, 32x32 product, and exact
     * round/shift/clamp.  The old combinational output function put all of
     * these operations on the acc-to-port path (and routed thousands of
     * loads); registering each boundary preserves commit II=1. */
    reg q0_valid, q0_last;
    reg signed [31:0] q0_acc [0:3], q0_bias [0:3], q0_mult [0:3];
    reg [5:0] q0_shift [0:3];
    reg [3:0] q0_mask;
    reg [7:0] q0_pixel, q0_tag;
    reg [8:0] q0_channel;
    reg [1:0] q0_mode;
    reg q1_valid, q1_last;
    reg signed [127:0] q1_prod [0:3];
    reg [5:0] q1_shift [0:3];
    reg [3:0] q1_mask;
    reg [7:0] q1_pixel, q1_tag;
    reg [8:0] q1_channel;
    reg [1:0] q1_mode;
    reg q2_valid, q2_last;
    reg [7:0] q2_bytes [0:3];
    reg [3:0] q2_mask;
    reg [7:0] q2_pixel, q2_tag;
    reg [8:0] q2_channel;
    reg [2:0] q2_group;
    reg [1:0] q2_mode;
    reg qf_valid, qf_last;
    reg signed [127:0] qf_fixed [0:3];
    reg [3:0] qf_mask;
    reg [7:0] qf_pixel, qf_tag;
    reg [8:0] qf_channel;
    reg [1:0] qf_mode;

    wire signed [32:0] q0_sum [0:3];
    genvar qsum_g;
    generate
        for (qsum_g = 0; qsum_g < 4; qsum_g = qsum_g + 1) begin : gen_q0_sum
            assign q0_sum[qsum_g] = {q0_acc[qsum_g][31],q0_acc[qsum_g]} +
                                    {q0_bias[qsum_g][31],q0_bias[qsum_g]};
        end
    endgenerate

    /* This is local output-pipeline elasticity only.  It is intentionally
     * downstream of result_fifo_count/acc admission; ready_out cannot stall
     * the accumulator or cross into the other island's FIFO. */
    wire q2_local_ready = !q2_valid || ready_out;
    wire qf_ready = !qf_valid || q2_local_ready;
    wire q1_ready = !q1_valid || qf_ready;
    wire q0_ready = !q0_valid || q1_ready;
    assign q0_capture = drain_active && q0_ready;
    assign q0_last_capture = q0_capture && (drain_group == 3'd7);
    assign q2_fire_last = q2_valid && ready_out && q2_last;
    assign valid_out = q2_valid;
    assign out_word = {q2_bytes[3],q2_bytes[2],q2_bytes[1],q2_bytes[0]};
    assign out_word_mask = q2_mask;
    assign out_pixel_idx = q2_pixel;
    assign out_channel_base = q2_channel;
    assign out_group_idx = q2_group;
    assign out_block_tag = q2_tag;
    assign out_mode = q2_mode;
    assign busy_o = block_active || stage_valid || drain_active ||
                    (result_fifo_count != 0) ||
                    q0_valid || q1_valid || qf_valid || q2_valid;

    function [7:0] requant_product;
        input signed [127:0] product_in;
        input [5:0] shift_in;
        reg signed [127:0] fixed, shifted, added;
        reg [30:0] low_bits;
        reg neg, low_zero, round_up;
        begin
            low_bits = product_in[30:0];
            low_zero = (low_bits == 31'd0);
            neg = product_in[127];
            if (!neg) begin
                round_up = (low_bits >= 31'h40000000);
                fixed = (product_in >>> 31) + (round_up ? 1 : 0);
            end else begin
                round_up = product_in[30] ? (low_zero || (product_in[29:0] == 30'd0))
                                          : !low_zero;
                if (low_zero && round_up) fixed = (product_in >>> 31) - 1;
                else if (low_zero || round_up) fixed = (product_in >>> 31);
                else fixed = (product_in >>> 31) + 1;
            end
            shifted = fixed >>> shift_in;
            added = shifted + saved_zp;
            if (added > 127) requant_product = 8'h7f;
            else if (added < -128) requant_product = 8'h80;
            else if (added < saved_min) requant_product = saved_min[7:0];
            else if (added > saved_max) requant_product = saved_max[7:0];
            else requant_product = added[7:0];
        end
    endfunction

    function signed [127:0] requant_fixed;
        input signed [127:0] product_in;
        input [5:0] shift_in;
        reg signed [127:0] fixed;
        reg [30:0] low_bits;
        reg neg, low_zero, round_up;
        begin
            low_bits = product_in[30:0]; low_zero = (low_bits == 31'd0);
            neg = product_in[127];
            if (!neg) begin
                round_up = (low_bits >= 31'h40000000);
                fixed = (product_in >>> 31) + (round_up ? 1 : 0);
            end else begin
                round_up = product_in[30] ? (low_zero || (product_in[29:0] == 30'd0))
                                          : !low_zero;
                if (low_zero && round_up) fixed = (product_in >>> 31) - 1;
                else if (low_zero || round_up) fixed = (product_in >>> 31);
                else fixed = (product_in >>> 31) + 1;
            end
            requant_fixed = fixed >>> shift_in;
        end
    endfunction

    function [7:0] requant_clamp;
        input signed [127:0] scaled_in;
        reg signed [127:0] added;
        begin
            added = scaled_in + drain_zp;
            if (added > 127) requant_clamp = 8'h7f;
            else if (added < -128) requant_clamp = 8'h80;
            else if (added < drain_min) requant_clamp = drain_min[7:0];
            else if (added > drain_max) requant_clamp = drain_max[7:0];
            else requant_clamp = added[7:0];
        end
    endfunction

    /* q2_next_byte is now only the final add/clamp cone; the product and
     * rounding/shift operations terminate at qf_fixed registers. */
    genvar qbyte_g2;
    generate
        for (qbyte_g2 = 0; qbyte_g2 < 4; qbyte_g2 = qbyte_g2 + 1) begin : gen_q2_byte
            assign q2_next_byte[qbyte_g2] = qf_mask[qbyte_g2] ?
                requant_clamp(qf_fixed[qbyte_g2]) : 8'd0;
        end
    endgenerate

    integer oi, og, op, oc;
    reg [5:0] capture_idx [0:3];
    reg [3:0] capture_mask;
    reg [7:0] capture_pixel;
    reg [8:0] capture_channel;
    always @* begin
        capture_pixel = saved_pixel_base;
        capture_channel = saved_cout_base;
        if (saved_mode == MODE_PW) begin
            capture_pixel = saved_pixel_base + drain_group;
            capture_channel = saved_cout_base + (ISLAND_INDEX * 4);
        end else begin
            capture_pixel = saved_pixel_base + (drain_group / 2);
            capture_channel = saved_cout_base + (ISLAND_INDEX * 8) +
                              (drain_group[0] ? 4 : 0);
        end
        for (oi = 0; oi < 4; oi = oi + 1) begin
            if (saved_mode == MODE_PW)
                og = drain_group * 4 + oi;
            else
                og = (drain_group / 2) * 8 + (drain_group[0] ? 4 : 0) + oi;
            capture_idx[oi] = og[5:0];
            capture_mask[oi] = (og < 32) && lane_valid(og);
        end
    end

    integer qi;
    always @(posedge clk) begin
        if (!rst_n) begin
            q0_valid <= 0; q1_valid <= 0; qf_valid <= 0; q2_valid <= 0; q2_last <= 0;
            q0_mask <= 0; q1_mask <= 0; q2_mask <= 0;
            q0_pixel <= 0; q1_pixel <= 0; q2_pixel <= 0;
            q0_channel <= 0; q1_channel <= 0; q2_channel <= 0;
            q0_tag <= 0; q1_tag <= 0; q2_tag <= 0;
            q0_mode <= MODE_PW; q1_mode <= MODE_PW; q2_mode <= MODE_PW;
            q2_group <= 0;
            for (qi = 0; qi < 4; qi = qi + 1) begin
                q0_acc[qi] <= 0; q0_bias[qi] <= 0; q0_mult[qi] <= 0;
                q0_shift[qi] <= 0; q1_prod[qi] <= 0; q1_shift[qi] <= 0;
                qf_fixed[qi] <= 0; q2_bytes[qi] <= 0;
            end
        end else begin
            if (q2_local_ready) begin
                q2_valid <= qf_valid;
                if (qf_valid) begin
                    q2_last <= qf_last; q2_mask <= qf_mask;
                    q2_pixel <= qf_pixel; q2_channel <= qf_channel;
                    q2_tag <= qf_tag; q2_mode <= qf_mode;
                    q2_group <= qf_pixel - saved_pixel_base;
                    for (qi = 0; qi < 4; qi = qi + 1)
                        q2_bytes[qi] <= q2_next_byte[qi];
                end
            end
            if (qf_ready) begin
                qf_valid <= q1_valid;
                if (q1_valid) begin
                    qf_last <= q1_last; qf_mask <= q1_mask;
                    qf_pixel <= q1_pixel; qf_channel <= q1_channel;
                    qf_tag <= q1_tag; qf_mode <= q1_mode;
                    for (qi = 0; qi < 4; qi = qi + 1)
                        qf_fixed[qi] <= requant_fixed(q1_prod[qi],q1_shift[qi]);
                end
            end
            if (q1_ready) begin
                q1_valid <= q0_valid;
                if (q0_valid) begin
                    q1_last <= q0_last; q1_mask <= q0_mask;
                    q1_pixel <= q0_pixel; q1_channel <= q0_channel;
                    q1_tag <= q0_tag; q1_mode <= q0_mode;
                    for (qi = 0; qi < 4; qi = qi + 1) begin
                        q1_shift[qi] <= q0_shift[qi];
                        q1_prod[qi] <= $signed({{95{q0_sum[qi][32]}},q0_sum[qi]}) *
                                       $signed({{96{q0_mult[qi][31]}},q0_mult[qi]});
                    end
                end
            end
            if (q0_ready) begin
                q0_valid <= q0_capture;
                if (q0_capture) begin
                    q0_last <= q0_last_capture; q0_mask <= capture_mask;
                    q0_pixel <= capture_pixel; q0_channel <= capture_channel;
                    q0_tag <= saved_tag; q0_mode <= saved_mode;
                    for (qi = 0; qi < 4; qi = qi + 1) begin
                        q0_acc[qi] <= drain_acc[capture_idx[qi]];
                        q0_bias[qi] <= bias_mem[capture_idx[qi]];
                        q0_mult[qi] <= mult_mem[capture_idx[qi]];
                        q0_shift[qi] <= shift_mem[capture_idx[qi]];
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
