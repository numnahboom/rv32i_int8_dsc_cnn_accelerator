`timescale 1ns/1ps
`default_nettype none

/*
 * Dual 32-MAC accumulator islands followed by one shared four-lane
 * requantizer.  This is a physical experiment and deliberately has a new
 * name/ABI: the retained dual32_mac_local_island is not changed.
 *
 * The islands only commit 32-bit sums and their captured block description.
 * A narrow arbiter copies one complete block (eight 4-lane words) into a
 * 16-entry raw FIFO.  The FIFO carries four sums, four biases, four
 * multipliers and four shifts per entry; no 2048-bit result mux exists on
 * the island-to-RQ boundary.  A single elastic stream4 RQ drains one entry
 * per cycle.  Each island owns two completed-block slots, so output stalls
 * cannot reach an already admitted accumulator block until those slots are
 * genuinely full.
 */
module dual32_shared_stream4_rq #(
    parameter integer RAW_DEPTH = 16
) (
    input wire clk, input wire rst_n,
    input wire [1:0] mode_i,
    input wire cfg_valid_i, output wire cfg_ready_o, input wire cfg_island_i,
    input wire [5:0] cfg_lane_i,
    input wire signed [31:0] cfg_bias_i,
    input wire signed [31:0] cfg_multiplier_i,
    input wire [5:0] cfg_shift_i,
    input wire valid_in, output wire ready_in,
    input wire first_k, input wire last_k, input wire [7:0] k_idx,
    input wire [7:0] block_tag_i, input wire [7:0] pixel_base_i,
    input wire [8:0] cout_base_i, input wire [7:0] pixel_mask_i,
    input wire [15:0] cout_mask_i,
    input wire signed [31:0] output_zero_point_i,
    input wire signed [31:0] activation_min_i,
    input wire signed [31:0] activation_max_i,
    input wire [31:0] src_word0_i, input wire [31:0] src_word1_i,
    input wire [31:0] param_word0_i, input wire [31:0] param_word1_i,
    input wire [31:0] param_word2_i, input wire [31:0] param_word3_i,
    output wire valid_out, input wire ready_out,
    output wire [31:0] out_word, output wire [3:0] out_word_mask,
    output wire [7:0] out_pixel_idx, output wire [8:0] out_channel_base,
    output wire [2:0] out_group_idx, output wire [7:0] out_block_tag,
    output wire [1:0] out_mode, output wire busy_o
);
    localparam [1:0] MODE_PW = 2'd0;
    localparam [1:0] MODE_STEM = 2'd1;
    localparam [1:0] MODE_DW = 2'd2;
    localparam integer RAW_AW = (RAW_DEPTH <= 2) ? 1 : $clog2(RAW_DEPTH);

    wire i0_cfg_ready, i1_cfg_ready;
    wire i0_ready, i1_ready, i0_busy, i1_busy;
    wire i0_block_valid, i1_block_valid;
    reg i0_block_pop, i1_block_pop;
    wire [1023:0] i0_acc, i1_acc, i0_bias, i1_bias, i0_mult, i1_mult;
    wire [191:0] i0_shift, i1_shift;
    wire [7:0] i0_tag, i1_tag, i0_pixel_base, i1_pixel_base;
    wire [8:0] i0_cout_base, i1_cout_base;
    wire [7:0] i0_pixel_mask, i1_pixel_mask;
    wire [15:0] i0_cout_mask, i1_cout_mask;
    wire [1:0] i0_mode, i1_mode;
    wire signed [31:0] i0_zp, i1_zp, i0_min, i1_min, i0_max, i1_max;

    assign cfg_ready_o = cfg_island_i ? i1_cfg_ready : i0_cfg_ready;
    assign ready_in = rst_n && ((mode_i == MODE_DW) ? i0_ready
                                                    : (i0_ready && i1_ready));

    dual32_shared_stream4_rq_raw_island #(.ISLAND_INDEX(0)) u_island0 (
        .clk(clk), .rst_n(rst_n), .mode_i(mode_i),
        .cfg_valid_i(cfg_valid_i && !cfg_island_i), .cfg_ready_o(i0_cfg_ready),
        .cfg_lane_i(cfg_lane_i), .cfg_bias_i(cfg_bias_i),
        .cfg_multiplier_i(cfg_multiplier_i), .cfg_shift_i(cfg_shift_i),
        .valid_in(valid_in), .ready_in(i0_ready), .first_k(first_k),
        .last_k(last_k), .k_idx(k_idx), .block_tag_i(block_tag_i),
        .pixel_base_i(pixel_base_i), .cout_base_i(cout_base_i),
        .pixel_mask_i(pixel_mask_i), .cout_mask_i(cout_mask_i),
        .output_zero_point_i(output_zero_point_i),
        .activation_min_i(activation_min_i), .activation_max_i(activation_max_i),
        .src_word0_i(src_word0_i), .src_word1_i(src_word1_i),
        .param_word0_i(param_word0_i), .param_word1_i(param_word1_i),
        .param_word2_i(param_word2_i), .param_word3_i(param_word3_i),
        .block_valid_o(i0_block_valid), .block_pop_i(i0_block_pop),
        .block_acc_o(i0_acc), .block_bias_o(i0_bias), .block_mult_o(i0_mult),
        .block_shift_o(i0_shift), .block_tag_o(i0_tag),
        .block_pixel_base_o(i0_pixel_base), .block_cout_base_o(i0_cout_base),
        .block_pixel_mask_o(i0_pixel_mask), .block_cout_mask_o(i0_cout_mask),
        .block_mode_o(i0_mode), .block_zp_o(i0_zp), .block_min_o(i0_min),
        .block_max_o(i0_max), .busy_o(i0_busy));

    dual32_shared_stream4_rq_raw_island #(.ISLAND_INDEX(1)) u_island1 (
        .clk(clk), .rst_n(rst_n), .mode_i(mode_i),
        .cfg_valid_i(cfg_valid_i && cfg_island_i), .cfg_ready_o(i1_cfg_ready),
        .cfg_lane_i(cfg_lane_i), .cfg_bias_i(cfg_bias_i),
        .cfg_multiplier_i(cfg_multiplier_i), .cfg_shift_i(cfg_shift_i),
        .valid_in(valid_in && (mode_i != MODE_DW)), .ready_in(i1_ready),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .block_tag_i(block_tag_i), .pixel_base_i(pixel_base_i),
        .cout_base_i(cout_base_i), .pixel_mask_i(pixel_mask_i),
        .cout_mask_i(cout_mask_i), .output_zero_point_i(output_zero_point_i),
        .activation_min_i(activation_min_i), .activation_max_i(activation_max_i),
        .src_word0_i(src_word0_i), .src_word1_i(src_word1_i),
        .param_word0_i(param_word0_i), .param_word1_i(param_word1_i),
        .param_word2_i(param_word2_i), .param_word3_i(param_word3_i),
        .block_valid_o(i1_block_valid), .block_pop_i(i1_block_pop),
        .block_acc_o(i1_acc), .block_bias_o(i1_bias), .block_mult_o(i1_mult),
        .block_shift_o(i1_shift), .block_tag_o(i1_tag),
        .block_pixel_base_o(i1_pixel_base), .block_cout_base_o(i1_cout_base),
        .block_pixel_mask_o(i1_pixel_mask), .block_cout_mask_o(i1_cout_mask),
        .block_mode_o(i1_mode), .block_zp_o(i1_zp), .block_min_o(i1_min),
        .block_max_o(i1_max), .busy_o(i1_busy));

    /* The raw FIFO is intentionally decomposed into 128-bit vectors. */
    reg [127:0] raw_acc_fifo [0:RAW_DEPTH-1];
    reg [127:0] raw_bias_fifo [0:RAW_DEPTH-1];
    reg [127:0] raw_mult_fifo [0:RAW_DEPTH-1];
    reg [23:0] raw_shift_fifo [0:RAW_DEPTH-1];
    reg [7:0] raw_pixel_fifo [0:RAW_DEPTH-1];
    reg [8:0] raw_channel_fifo [0:RAW_DEPTH-1];
    reg [2:0] raw_group_fifo [0:RAW_DEPTH-1];
    reg [7:0] raw_tag_fifo [0:RAW_DEPTH-1];
    reg [1:0] raw_mode_fifo [0:RAW_DEPTH-1];
    reg [3:0] raw_mask_fifo [0:RAW_DEPTH-1];
    reg signed [31:0] raw_zp_fifo [0:RAW_DEPTH-1];
    reg signed [31:0] raw_min_fifo [0:RAW_DEPTH-1];
    reg signed [31:0] raw_max_fifo [0:RAW_DEPTH-1];
    reg [RAW_AW-1:0] raw_wr_ptr, raw_rd_ptr;
    reg [RAW_AW:0] raw_count;
    reg copy_active, copy_island;
    reg [2:0] copy_group;

    wire selected_valid = copy_island ? i1_block_valid : i0_block_valid;
    /* block_pop is a one-cycle pulse registered at the copy boundary.  Do
     * not select that just-finished head again during the pulse; the island
     * consumes the pop on the following clock edge. */
    wire arb_i0_valid = i0_block_valid && !i0_block_pop;
    wire arb_i1_valid = i1_block_valid && !i1_block_pop;
    wire [1023:0] selected_acc = copy_island ? i1_acc : i0_acc;
    wire [1023:0] selected_bias = copy_island ? i1_bias : i0_bias;
    wire [1023:0] selected_mult = copy_island ? i1_mult : i0_mult;
    wire [191:0] selected_shift = copy_island ? i1_shift : i0_shift;
    wire [7:0] selected_tag = copy_island ? i1_tag : i0_tag;
    wire [7:0] selected_pixel_base = copy_island ? i1_pixel_base : i0_pixel_base;
    wire [8:0] selected_cout_base = copy_island ? i1_cout_base : i0_cout_base;
    wire [7:0] selected_pixel_mask = copy_island ? i1_pixel_mask : i0_pixel_mask;
    wire [15:0] selected_cout_mask = copy_island ? i1_cout_mask : i0_cout_mask;
    wire [1:0] selected_mode = copy_island ? i1_mode : i0_mode;
    wire signed [31:0] selected_zp = copy_island ? i1_zp : i0_zp;
    wire signed [31:0] selected_min = copy_island ? i1_min : i0_min;
    wire signed [31:0] selected_max = copy_island ? i1_max : i0_max;

    wire [7:0] copy_pixel = (selected_mode == MODE_PW) ?
        (selected_pixel_base + copy_group) :
        (selected_pixel_base + (copy_group >> 1));
    wire [8:0] copy_channel = (selected_mode == MODE_PW) ?
        (selected_cout_base + (copy_island ? 9'd4 : 9'd0)) :
        ((selected_mode == MODE_DW) ?
         (selected_cout_base + ((copy_group[0]) ? 9'd4 : 9'd0)) :
         (selected_cout_base + (copy_island ? 9'd8 : 9'd0) +
          (copy_group[0] ? 9'd4 : 9'd0)));
    wire [2:0] copy_out_group = (selected_mode == MODE_PW) ?
        copy_group : (copy_group >> 1);
    wire [3:0] copy_lane_mask =
        (selected_mode == MODE_PW) ?
            ({4{selected_pixel_mask[copy_group]}} &
             selected_cout_mask[(copy_island ? 4 : 0) +: 4]) :
        (selected_mode == MODE_DW) ?
            ({4{selected_pixel_mask[copy_group >> 1]}} &
             selected_cout_mask[(copy_group[0] ? 4 : 0) +: 4]) :
            ({4{selected_pixel_mask[copy_group >> 1]}} &
             selected_cout_mask[(copy_island ? 8 : 0) +
                                (copy_group[0] ? 4 : 0) +: 4]);

    wire raw_write = copy_active && selected_valid && (raw_count < RAW_DEPTH);
    wire rq_valid_in = (raw_count != 0);
    wire rq_ready_in;
    wire rq_fire = rq_valid_in && rq_ready_in;
    wire rq_busy;
    wire [31:0] rq_out_word;
    wire [3:0] rq_out_mask;
    wire [7:0] rq_out_pixel, rq_out_tag;
    wire [8:0] rq_out_channel;
    wire [2:0] rq_out_group;
    wire [1:0] rq_out_mode;

    dual32_shared_stream4_rq_tagged u_rq (
        .clk(clk), .rst_n(rst_n), .valid_in(rq_valid_in),
        .ready_in(rq_ready_in), .acc_vec(raw_acc_fifo[raw_rd_ptr]),
        .bias_vec(raw_bias_fifo[raw_rd_ptr]),
        .multiplier_vec(raw_mult_fifo[raw_rd_ptr]),
        .shift_vec(raw_shift_fifo[raw_rd_ptr]),
        .pixel_idx(raw_pixel_fifo[raw_rd_ptr]),
        .channel_idx(raw_channel_fifo[raw_rd_ptr]),
        .lane_mask(raw_mask_fifo[raw_rd_ptr]),
        .block_tag(raw_tag_fifo[raw_rd_ptr]),
        .group_idx(raw_group_fifo[raw_rd_ptr]),
        .mode_idx(raw_mode_fifo[raw_rd_ptr]),
        .output_zero_point(raw_zp_fifo[raw_rd_ptr]),
        .activation_min(raw_min_fifo[raw_rd_ptr]),
        .activation_max(raw_max_fifo[raw_rd_ptr]),
        .ready_out(ready_out), .valid_out(valid_out),
        .out_word(rq_out_word), .out_word_mask(rq_out_mask),
        .out_pixel_idx(rq_out_pixel), .out_channel_base(rq_out_channel),
        .out_group_idx(rq_out_group), .out_block_tag(rq_out_tag),
        .out_mode(rq_out_mode), .busy(rq_busy));

    assign out_word = rq_out_word;
    assign out_word_mask = rq_out_mask;
    assign out_pixel_idx = rq_out_pixel;
    assign out_channel_base = rq_out_channel;
    assign out_group_idx = rq_out_group;
    assign out_block_tag = rq_out_tag;
    assign out_mode = rq_out_mode;
    assign busy_o = i0_busy || i1_busy || copy_active || (raw_count != 0) || rq_busy;

    integer ri;
    always @(posedge clk) begin
        if (!rst_n) begin
            raw_wr_ptr <= 0; raw_rd_ptr <= 0; raw_count <= 0;
            copy_active <= 0; copy_island <= 0; copy_group <= 0;
            i0_block_pop <= 0; i1_block_pop <= 0;
            for (ri = 0; ri < RAW_DEPTH; ri = ri + 1) begin
                raw_acc_fifo[ri] <= 0; raw_bias_fifo[ri] <= 0;
                raw_mult_fifo[ri] <= 0; raw_shift_fifo[ri] <= 0;
                raw_pixel_fifo[ri] <= 0; raw_channel_fifo[ri] <= 0;
                raw_group_fifo[ri] <= 0; raw_tag_fifo[ri] <= 0;
                raw_mode_fifo[ri] <= 0; raw_mask_fifo[ri] <= 0;
                raw_zp_fifo[ri] <= 0; raw_min_fifo[ri] <= -128; raw_max_fifo[ri] <= 127;
            end
        end else begin
            i0_block_pop <= 1'b0;
            i1_block_pop <= 1'b0;

            /* Reserve eight entries before taking ownership of a block. */
            if (!copy_active && (raw_count <= RAW_DEPTH-8) &&
                (arb_i0_valid || arb_i1_valid)) begin
                copy_active <= 1'b1;
                copy_island <= arb_i0_valid ? 1'b0 : 1'b1;
                copy_group <= 3'd0;
            end

            if (raw_write) begin
                raw_acc_fifo[raw_wr_ptr] <= selected_acc[(copy_group*128) +: 128];
                raw_bias_fifo[raw_wr_ptr] <= selected_bias[(copy_group*128) +: 128];
                raw_mult_fifo[raw_wr_ptr] <= selected_mult[(copy_group*128) +: 128];
                raw_shift_fifo[raw_wr_ptr] <= selected_shift[(copy_group*24) +: 24];
                raw_pixel_fifo[raw_wr_ptr] <= copy_pixel;
                raw_channel_fifo[raw_wr_ptr] <= copy_channel;
                raw_group_fifo[raw_wr_ptr] <= copy_out_group;
                raw_tag_fifo[raw_wr_ptr] <= selected_tag;
                raw_mode_fifo[raw_wr_ptr] <= selected_mode;
                raw_mask_fifo[raw_wr_ptr] <= copy_lane_mask;
                raw_zp_fifo[raw_wr_ptr] <= selected_zp;
                raw_min_fifo[raw_wr_ptr] <= selected_min;
                raw_max_fifo[raw_wr_ptr] <= selected_max;
                raw_wr_ptr <= raw_wr_ptr + 1'b1;
                if (copy_group == 3'd7) begin
                    copy_active <= 1'b0;
                    if (copy_island) i1_block_pop <= 1'b1;
                    else i0_block_pop <= 1'b1;
                end else begin
                    copy_group <= copy_group + 1'b1;
                end
            end
            if (rq_fire)
                raw_rd_ptr <= raw_rd_ptr + 1'b1;
            case ({raw_write, rq_fire})
                2'b10: raw_count <= raw_count + 1'b1;
                2'b01: raw_count <= raw_count - 1'b1;
                default: raw_count <= raw_count;
            endcase
        end
    end
endmodule

/* Raw accumulator island.  It is intentionally free of requant arithmetic. */
module dual32_shared_stream4_rq_raw_island #(
    parameter integer ISLAND_INDEX = 0
) (
    input wire clk, input wire rst_n, input wire [1:0] mode_i,
    input wire cfg_valid_i, output wire cfg_ready_o, input wire [5:0] cfg_lane_i,
    input wire signed [31:0] cfg_bias_i, input wire signed [31:0] cfg_multiplier_i,
    input wire [5:0] cfg_shift_i, input wire valid_in, output wire ready_in,
    input wire first_k, input wire last_k, input wire [7:0] k_idx,
    input wire [7:0] block_tag_i, input wire [7:0] pixel_base_i,
    input wire [8:0] cout_base_i, input wire [7:0] pixel_mask_i,
    input wire [15:0] cout_mask_i,
    input wire signed [31:0] output_zero_point_i,
    input wire signed [31:0] activation_min_i,
    input wire signed [31:0] activation_max_i,
    input wire [31:0] src_word0_i, input wire [31:0] src_word1_i,
    input wire [31:0] param_word0_i, input wire [31:0] param_word1_i,
    input wire [31:0] param_word2_i, input wire [31:0] param_word3_i,
    output wire block_valid_o, input wire block_pop_i,
    output wire [1023:0] block_acc_o, output wire [1023:0] block_bias_o,
    output wire [1023:0] block_mult_o, output wire [191:0] block_shift_o,
    output wire [7:0] block_tag_o, output wire [7:0] block_pixel_base_o,
    output wire [8:0] block_cout_base_o, output wire [7:0] block_pixel_mask_o,
    output wire [15:0] block_cout_mask_o, output wire [1:0] block_mode_o,
    output wire signed [31:0] block_zp_o, output wire signed [31:0] block_min_o,
    output wire signed [31:0] block_max_o, output wire busy_o
);
    localparam [1:0] MODE_PW = 2'd0;
    localparam [1:0] MODE_STEM = 2'd1;
    localparam [1:0] MODE_DW = 2'd2;
    reg signed [31:0] acc [0:31];
    reg signed [31:0] bias_mem [0:31], mult_mem [0:31];
    reg [5:0] shift_mem [0:31];
    reg stage_valid, stage_first, stage_last;
    reg [7:0] stage_k_idx;
    reg [31:0] stage_act [0:31], stage_wgt [0:31];
    reg block_active;
    reg [1:0] block_mode;
    reg [7:0] block_tag, block_pixel_base, block_pixel_mask;
    reg [8:0] block_cout_base;
    reg [15:0] block_cout_mask;
    reg signed [31:0] block_zp, block_min, block_max;
    reg [1023:0] result_acc [0:1], result_bias [0:1], result_mult [0:1];
    reg [191:0] result_shift [0:1];
    reg [7:0] result_tag [0:1], result_pixel_base [0:1], result_pixel_mask [0:1];
    reg [8:0] result_cout_base [0:1];
    reg [15:0] result_cout_mask [0:1];
    reg [1:0] result_mode [0:1];
    reg signed [31:0] result_zp [0:1], result_min [0:1], result_max [0:1];
    reg result_wr_ptr, result_rd_ptr;
    reg [1:0] result_count;
    wire stage_fire = stage_valid;
    wire input_fire = valid_in && ready_in;
    wire commit_fire = stage_fire && stage_last;
    assign block_valid_o = (result_count != 0);
    assign cfg_ready_o = rst_n && !block_active && !stage_valid &&
                         (result_count == 0);
    /* The only admission fence is the local two-entry completed-block FIFO. */
    assign ready_in = rst_n && (result_count != 2) &&
                      (!stage_valid || !stage_last);

    wire [7:0] src_b0 [0:3], src_b1 [0:3];
    wire [7:0] pw_b0 [0:3], pw_b1 [0:3];
    wire [7:0] pw_b2 [0:3], pw_b3 [0:3];
    assign src_b0[0]=src_word0_i[7:0]; assign src_b0[1]=src_word0_i[15:8];
    assign src_b0[2]=src_word0_i[23:16]; assign src_b0[3]=src_word0_i[31:24];
    assign src_b1[0]=src_word1_i[7:0]; assign src_b1[1]=src_word1_i[15:8];
    assign src_b1[2]=src_word1_i[23:16]; assign src_b1[3]=src_word1_i[31:24];
    assign pw_b0[0]=param_word0_i[7:0]; assign pw_b0[1]=param_word0_i[15:8];
    assign pw_b0[2]=param_word0_i[23:16]; assign pw_b0[3]=param_word0_i[31:24];
    assign pw_b1[0]=param_word1_i[7:0]; assign pw_b1[1]=param_word1_i[15:8];
    assign pw_b1[2]=param_word1_i[23:16]; assign pw_b1[3]=param_word1_i[31:24];
    assign pw_b2[0]=param_word2_i[7:0]; assign pw_b2[1]=param_word2_i[15:8];
    assign pw_b2[2]=param_word2_i[23:16]; assign pw_b2[3]=param_word2_i[31:24];
    assign pw_b3[0]=param_word3_i[7:0]; assign pw_b3[1]=param_word3_i[15:8];
    assign pw_b3[2]=param_word3_i[23:16]; assign pw_b3[3]=param_word3_i[31:24];

    function [31:0] act_for_lane;
        input integer lane; integer p;
        begin
            if (mode_i == MODE_PW) begin
                p = lane / 4;
                act_for_lane = (p < 4) ? {24'd0,src_b0[p]} : {24'd0,src_b1[p-4]};
            end else begin
                p = lane / 8;
                act_for_lane = (p < 4) ? {24'd0,src_b0[p]} : 32'd0;
            end
        end
    endfunction
    function [31:0] weight_for_lane;
        input integer lane; integer c;
        begin
            if (mode_i == MODE_PW) begin
                c = lane % 4;
                weight_for_lane = (ISLAND_INDEX == 0) ? {24'd0,pw_b0[c]} :
                                  {24'd0,pw_b1[c]};
            end else begin
                c = lane % 8;
                if (ISLAND_INDEX == 0)
                    weight_for_lane = (c < 4) ? {24'd0,pw_b0[c]} : {24'd0,pw_b1[c-4]};
                else
                    weight_for_lane = (c < 4) ? {24'd0,pw_b2[c]} : {24'd0,pw_b3[c-4]};
            end
        end
    endfunction
    wire signed [31:0] sum_next [0:31];
    genvar g;
    generate for (g=0; g<32; g=g+1) begin : gen_raw_mac
        (* use_dsp = "yes" *) wire signed [15:0] product =
            $signed(stage_act[g][7:0]) * $signed(stage_wgt[g][7:0]);
        wire signed [31:0] product_ext = {{16{product[15]}},product};
        assign sum_next[g] = stage_first ? product_ext : (acc[g] + product_ext);
    end endgenerate

    integer li;
    always @(posedge clk) begin
        if (!rst_n) begin
            stage_valid<=0; stage_first<=0; stage_last<=0; stage_k_idx<=0;
            block_active<=0; block_mode<=MODE_PW; block_tag<=0;
            block_pixel_base<=0; block_cout_base<=0; block_pixel_mask<=0;
            block_cout_mask<=0; block_zp<=0; block_min<=-128; block_max<=127;
            result_wr_ptr<=0; result_rd_ptr<=0; result_count<=0;
            for (li=0; li<32; li=li+1) begin
                acc[li]<=0; bias_mem[li]<=0; mult_mem[li]<=0; shift_mem[li]<=0;
                stage_act[li]<=0; stage_wgt[li]<=0;
            end
            for (li=0; li<2; li=li+1) begin
                result_acc[li]<=0; result_bias[li]<=0; result_mult[li]<=0;
                result_shift[li]<=0; result_tag[li]<=0; result_pixel_base[li]<=0;
                result_pixel_mask[li]<=0; result_cout_base[li]<=0;
                result_cout_mask[li]<=0; result_mode[li]<=MODE_PW;
                result_zp[li]<=0; result_min[li]<=-128; result_max[li]<=127;
            end
        end else begin
            if (cfg_valid_i && cfg_ready_o && (cfg_lane_i < 32)) begin
                bias_mem[cfg_lane_i] <= cfg_bias_i;
                mult_mem[cfg_lane_i] <= cfg_multiplier_i;
                shift_mem[cfg_lane_i] <= cfg_shift_i;
            end
            if (stage_fire) begin
                for (li=0; li<32; li=li+1) acc[li] <= sum_next[li];
                if (stage_last) begin
                    for (li=0; li<32; li=li+1) begin
                        result_acc[result_wr_ptr][li*32 +: 32] <= sum_next[li];
                        result_bias[result_wr_ptr][li*32 +: 32] <= bias_mem[li];
                        result_mult[result_wr_ptr][li*32 +: 32] <= mult_mem[li];
                        result_shift[result_wr_ptr][li*6 +: 6] <= shift_mem[li];
                    end
                    result_tag[result_wr_ptr] <= block_tag;
                    result_pixel_base[result_wr_ptr] <= block_pixel_base;
                    result_cout_base[result_wr_ptr] <= block_cout_base;
                    result_pixel_mask[result_wr_ptr] <= block_pixel_mask;
                    result_cout_mask[result_wr_ptr] <= block_cout_mask;
                    result_mode[result_wr_ptr] <= block_mode;
                    result_zp[result_wr_ptr] <= block_zp;
                    result_min[result_wr_ptr] <= block_min;
                    result_max[result_wr_ptr] <= block_max;
                    result_wr_ptr <= result_wr_ptr + 1'b1;
                end
            end
            if (block_pop_i) result_rd_ptr <= result_rd_ptr + 1'b1;
            case ({commit_fire,block_pop_i})
                2'b10: result_count <= result_count + 1'b1;
                2'b01: result_count <= result_count - 1'b1;
                default: result_count <= result_count;
            endcase
            if (input_fire) begin
                stage_valid<=1'b1; stage_first<=first_k; stage_last<=last_k;
                stage_k_idx<=k_idx;
                if (first_k) begin
                    block_active<=1'b1; block_mode<=mode_i; block_tag<=block_tag_i;
                    block_pixel_base<=pixel_base_i; block_cout_base<=cout_base_i;
                    block_pixel_mask<=pixel_mask_i; block_cout_mask<=cout_mask_i;
                    block_zp<=output_zero_point_i; block_min<=activation_min_i;
                    block_max<=activation_max_i;
                end
                for (li=0; li<32; li=li+1) begin
                    stage_act[li]<=act_for_lane(li); stage_wgt[li]<=weight_for_lane(li);
                end
            end else if (stage_fire) begin
                stage_valid<=1'b0; stage_last<=1'b0;
            end
            if (commit_fire && !(input_fire && first_k)) block_active<=1'b0;
        end
    end

    genvar bo;
    generate for (bo=0; bo<32; bo=bo+1) begin : gen_block_out
        assign block_acc_o[bo*32 +: 32] = result_acc[result_rd_ptr][bo*32 +: 32];
        assign block_bias_o[bo*32 +: 32] = result_bias[result_rd_ptr][bo*32 +: 32];
        assign block_mult_o[bo*32 +: 32] = result_mult[result_rd_ptr][bo*32 +: 32];
    end endgenerate
    assign block_shift_o = result_shift[result_rd_ptr];
    assign block_tag_o = result_tag[result_rd_ptr];
    assign block_pixel_base_o = result_pixel_base[result_rd_ptr];
    assign block_cout_base_o = result_cout_base[result_rd_ptr];
    assign block_pixel_mask_o = result_pixel_mask[result_rd_ptr];
    assign block_cout_mask_o = result_cout_mask[result_rd_ptr];
    assign block_mode_o = result_mode[result_rd_ptr];
    assign block_zp_o = result_zp[result_rd_ptr];
    assign block_min_o = result_min[result_rd_ptr];
    assign block_max_o = result_max[result_rd_ptr];
    assign busy_o = block_active || stage_valid || (result_count != 0);
endmodule

/* New sideband-compatible wrapper around the retained arithmetic stream4. */
module dual32_shared_stream4_rq_tagged (
    input wire clk, input wire rst_n, input wire valid_in, output wire ready_in,
    input wire signed [127:0] acc_vec, input wire signed [127:0] bias_vec,
    input wire signed [127:0] multiplier_vec, input wire [23:0] shift_vec,
    input wire [7:0] pixel_idx, input wire [8:0] channel_idx,
    input wire [3:0] lane_mask, input wire [7:0] block_tag,
    input wire [2:0] group_idx, input wire [1:0] mode_idx,
    input wire signed [31:0] output_zero_point,
    input wire signed [31:0] activation_min, input wire signed [31:0] activation_max,
    input wire ready_out, output wire valid_out, output wire [31:0] out_word,
    output wire [3:0] out_word_mask, output wire [7:0] out_pixel_idx,
    output wire [8:0] out_channel_base, output wire [2:0] out_group_idx,
    output wire [7:0] out_block_tag, output wire [1:0] out_mode,
    output wire busy
);
    wire inner_ready, inner_valid;
    wire [5:0] inner_pixel;
    wire [6:0] inner_channel;
    wire signed [31:0] inner_data;
    wire inner_busy;
    reg [9:0] meta_valid;
    reg [7:0] pixel_pipe [0:9], tag_pipe [0:9];
    reg [8:0] channel_pipe [0:9];
    reg [2:0] group_pipe [0:9];
    reg [1:0] mode_pipe [0:9];
    reg [3:0] mask_pipe [0:9];
    integer mi;

    requant_activation_stream4 u_stream (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(inner_ready),
        .acc_vec(acc_vec), .bias_vec(bias_vec), .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec), .pixel_idx(pixel_idx[5:0]),
        .channel_idx(channel_idx[6:0]),
        .output_zero_point_int32(output_zero_point),
        .activation_min_int32(activation_min), .activation_max_int32(activation_max),
        .ready_out(ready_out), .valid_out(inner_valid),
        .out_pixel_idx(inner_pixel), .out_channel_idx(inner_channel),
        .out_data_int8(inner_data), .busy(inner_busy));
    assign ready_in = rst_n && inner_ready;
    assign valid_out = inner_valid;
    assign out_word = inner_data;
    assign out_word_mask = mask_pipe[9];
    assign out_pixel_idx = pixel_pipe[9];
    assign out_channel_base = channel_pipe[9];
    assign out_group_idx = group_pipe[9];
    assign out_block_tag = tag_pipe[9];
    assign out_mode = mode_pipe[9];
    assign busy = inner_busy | (|meta_valid);
    always @(posedge clk) begin
        if (!rst_n) begin
            meta_valid <= 0;
            for (mi=0; mi<10; mi=mi+1) begin
                pixel_pipe[mi]<=0; tag_pipe[mi]<=0; channel_pipe[mi]<=0;
                group_pipe[mi]<=0; mode_pipe[mi]<=0; mask_pipe[mi]<=0;
            end
        end else if (inner_ready) begin
            meta_valid[0] <= valid_in;
            if (valid_in) begin
                pixel_pipe[0] <= pixel_idx; channel_pipe[0] <= channel_idx;
                group_pipe[0] <= group_idx; tag_pipe[0] <= block_tag;
                mode_pipe[0] <= mode_idx; mask_pipe[0] <= lane_mask;
            end
            for (mi=1; mi<10; mi=mi+1) begin
                meta_valid[mi] <= meta_valid[mi-1];
                if (meta_valid[mi-1]) begin
                    pixel_pipe[mi] <= pixel_pipe[mi-1];
                    channel_pipe[mi] <= channel_pipe[mi-1];
                    group_pipe[mi] <= group_pipe[mi-1];
                    tag_pipe[mi] <= tag_pipe[mi-1];
                    mode_pipe[mi] <= mode_pipe[mi-1];
                    mask_pipe[mi] <= mask_pipe[mi-1];
                end
            end
        end
    end
endmodule

`default_nettype wire
