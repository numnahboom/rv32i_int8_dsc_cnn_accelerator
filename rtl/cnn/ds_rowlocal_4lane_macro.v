`timescale 1ns/1ps
`default_nettype none

/*
 * Row-local two-island DS/PW compute macro.
 *
 * The arithmetic boundary is deliberately narrow.  Each of the two islands
 * contains eight independent four-lane rows (32 MACs).  A token contains
 * eight pixels and eight weights; island zero consumes weight lanes 0..3 and
 * island one consumes lanes 4..7.  At the end of a K block each row writes a
 * single four-lane record into its own two-entry FIFO.  The FIFOs are drained
 * in row order into one stream4 requantizer.
 *
 * There is no block-wide result bus or global result-valid.  Product and
 * accumulation are separated by product registers: DSP multiplication ends
 * at prod_*_reg, and the following cycle is the registered completed-sum
 * boundary before a row FIFO write.  Quantization parameters are copied into
 * the row record at commit time, so a later configuration cannot change an
 * in-flight result.
 */
module ds_rowlocal_4lane_macro #(
    parameter integer ROW_FIFO_DEPTH = 2,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer SESSION_WIDTH = 4
) (
    input wire clk, input wire rst_n,

    input wire cfg_valid, output wire cfg_ready,
    input wire cfg_island, input wire [5:0] cfg_lane,
    input wire signed [31:0] cfg_bias,
    input wire signed [31:0] cfg_multiplier,
    input wire [5:0] cfg_shift,

    input wire token_valid, output wire token_ready,
    input wire token_first, input wire token_last, input wire [7:0] token_k,
    input wire [9:0] token_pixel_base, input wire [8:0] token_cout_base,
    input wire [7:0] token_pixel_mask, input wire [7:0] token_cout_mask,
    input wire [63:0] token_act_vec, input wire [63:0] token_wgt_vec,
    input wire [7:0] token_tag,
    input wire [EPOCH_WIDTH-1:0] token_epoch,
    input wire [SESSION_WIDTH-1:0] token_session,
    input wire [1:0] token_mode,
    input wire signed [31:0] token_output_zero_point,
    input wire signed [31:0] token_activation_min,
    input wire signed [31:0] token_activation_max,

    output wire out_valid, input wire out_ready,
    output wire [31:0] out_word, output wire [3:0] out_word_mask,
    output wire [9:0] out_pixel_base, output wire [8:0] out_channel_base,
    output wire [2:0] out_group, output wire [7:0] out_tag,
    output wire [EPOCH_WIDTH-1:0] out_epoch,
    output wire [SESSION_WIDTH-1:0] out_session,
    output wire [1:0] out_mode,
    output wire busy,
    output wire [4:0] row_occupancy
);
    localparam integer ROWS = 16;
    localparam integer PTR_W = (ROW_FIFO_DEPTH <= 2) ? 1 : $clog2(ROW_FIFO_DEPTH);
    localparam integer COUNT_W = $clog2(ROW_FIFO_DEPTH+1);

    /* Configuration is local to an island/lane. */
    reg signed [31:0] bias_mem [0:1][0:31];
    reg signed [31:0] mult_mem [0:1][0:31];
    reg [5:0] shift_mem [0:1][0:31];

    /* Token ingress and a registered product stage. */
    reg tok_valid;
    reg tok_first, tok_last;
    reg [7:0] tok_k;
    reg [63:0] tok_act, tok_wgt;
    reg [9:0] tok_pixel_base;
    reg [8:0] tok_cout_base;
    reg [7:0] tok_pixel_mask, tok_cout_mask, tok_tag;
    reg [EPOCH_WIDTH-1:0] tok_epoch;
    reg [SESSION_WIDTH-1:0] tok_session;
    reg [1:0] tok_mode;
    reg signed [31:0] tok_zp, tok_min, tok_max;

    reg prod_valid;
    reg prod_first, prod_last;
    reg [7:0] prod_k;
    reg signed [15:0] prod_reg [0:1][0:7][0:3];

    /* Block metadata is captured only at first-token acceptance. */
    reg [9:0] block_pixel_base;
    reg [8:0] block_cout_base;
    reg [7:0] block_pixel_mask, block_cout_mask, block_tag;
    reg [EPOCH_WIDTH-1:0] block_epoch;
    reg [SESSION_WIDTH-1:0] block_session;
    reg [1:0] block_mode;
    reg signed [31:0] block_zp, block_min, block_max;
    reg block_active;

    /* Per-row, two-entry narrow completed-sum FIFOs. */
    reg signed [31:0] row_sum_mem [0:15][0:ROW_FIFO_DEPTH-1][0:3];
    reg signed [31:0] row_bias_mem [0:15][0:ROW_FIFO_DEPTH-1][0:3];
    reg signed [31:0] row_mult_mem [0:15][0:ROW_FIFO_DEPTH-1][0:3];
    reg [5:0] row_shift_mem [0:15][0:ROW_FIFO_DEPTH-1][0:3];
    reg [9:0] row_pixel_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg [8:0] row_channel_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg [2:0] row_group_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg [3:0] row_mask_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg [7:0] row_tag_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg [EPOCH_WIDTH-1:0] row_epoch_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg [SESSION_WIDTH-1:0] row_session_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg [1:0] row_mode_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg signed [31:0] row_zp_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg signed [31:0] row_min_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg signed [31:0] row_max_mem [0:15][0:ROW_FIFO_DEPTH-1];
    reg [PTR_W-1:0] row_wr_ptr [0:15], row_rd_ptr [0:15];
    reg [COUNT_W-1:0] row_count [0:15];

    reg [3:0] issue_row;

    wire row_all_space;
    wire issue_has_data = (row_count[issue_row] != 0);
    wire rq_ready_in;
    wire rq_valid_in = issue_has_data;
    wire rq_fire = rq_valid_in && rq_ready_in;

    /* A row pop can make a full row writable on this same edge. */
    wire commit_space = row_all_space;
    wire prod_advance = prod_valid && (!prod_last || commit_space);
    /* Product stage may accept a token whenever it is empty, or when its
     * current item advances into accumulation on this edge. */
    wire prod_ready = !prod_valid || (!prod_last || commit_space);
    wire tok_advance = !tok_valid || prod_ready;
    assign token_ready = rst_n && tok_advance;
    wire token_fire = token_valid && token_ready;

    /* Configuration cannot change while any payload or row record exists. */
    wire rows_empty = (row_occupancy == 0);
    assign cfg_ready = rst_n && !tok_valid && !prod_valid && !block_active &&
                       rows_empty;

    /* Explicit reductions avoid a self-sensitive variable accumulation in
     * simulation and synthesize to small local count comparators. */
    wire row_space0  = (row_count[0]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd0));
    wire row_space1  = (row_count[1]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd1));
    wire row_space2  = (row_count[2]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd2));
    wire row_space3  = (row_count[3]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd3));
    wire row_space4  = (row_count[4]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd4));
    wire row_space5  = (row_count[5]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd5));
    wire row_space6  = (row_count[6]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd6));
    wire row_space7  = (row_count[7]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd7));
    wire row_space8  = (row_count[8]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd8));
    wire row_space9  = (row_count[9]  < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd9));
    wire row_space10 = (row_count[10] < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd10));
    wire row_space11 = (row_count[11] < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd11));
    wire row_space12 = (row_count[12] < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd12));
    wire row_space13 = (row_count[13] < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd13));
    wire row_space14 = (row_count[14] < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd14));
    wire row_space15 = (row_count[15] < ROW_FIFO_DEPTH) || (rq_fire && (issue_row == 4'd15));
    assign row_all_space = row_space0 & row_space1 & row_space2 & row_space3 &
                           row_space4 & row_space5 & row_space6 & row_space7 &
                           row_space8 & row_space9 & row_space10 & row_space11 &
                           row_space12 & row_space13 & row_space14 & row_space15;

    /* Four-lane source vectors for the selected row.  Dynamic row indexing
     * is only four lanes wide; it never fans a block-wide result bus. */
    wire signed [127:0] rq_acc_vec = {
        row_sum_mem[issue_row][row_rd_ptr[issue_row]][3],
        row_sum_mem[issue_row][row_rd_ptr[issue_row]][2],
        row_sum_mem[issue_row][row_rd_ptr[issue_row]][1],
        row_sum_mem[issue_row][row_rd_ptr[issue_row]][0]};
    wire signed [127:0] rq_bias_vec = {
        row_bias_mem[issue_row][row_rd_ptr[issue_row]][3],
        row_bias_mem[issue_row][row_rd_ptr[issue_row]][2],
        row_bias_mem[issue_row][row_rd_ptr[issue_row]][1],
        row_bias_mem[issue_row][row_rd_ptr[issue_row]][0]};
    wire signed [127:0] rq_mult_vec = {
        row_mult_mem[issue_row][row_rd_ptr[issue_row]][3],
        row_mult_mem[issue_row][row_rd_ptr[issue_row]][2],
        row_mult_mem[issue_row][row_rd_ptr[issue_row]][1],
        row_mult_mem[issue_row][row_rd_ptr[issue_row]][0]};
    wire [23:0] rq_shift_vec = {
        row_shift_mem[issue_row][row_rd_ptr[issue_row]][3],
        row_shift_mem[issue_row][row_rd_ptr[issue_row]][2],
        row_shift_mem[issue_row][row_rd_ptr[issue_row]][1],
        row_shift_mem[issue_row][row_rd_ptr[issue_row]][0]};
    wire [9:0] rq_pixel = row_pixel_mem[issue_row][row_rd_ptr[issue_row]];
    wire [8:0] rq_channel = row_channel_mem[issue_row][row_rd_ptr[issue_row]];
    wire [2:0] rq_group = row_group_mem[issue_row][row_rd_ptr[issue_row]];
    wire [3:0] rq_mask = row_mask_mem[issue_row][row_rd_ptr[issue_row]];
    wire [7:0] rq_tag = row_tag_mem[issue_row][row_rd_ptr[issue_row]];
    wire [EPOCH_WIDTH-1:0] rq_epoch = row_epoch_mem[issue_row][row_rd_ptr[issue_row]];
    wire [SESSION_WIDTH-1:0] rq_session = row_session_mem[issue_row][row_rd_ptr[issue_row]];
    wire [1:0] rq_mode = row_mode_mem[issue_row][row_rd_ptr[issue_row]];
    wire signed [31:0] rq_zp = row_zp_mem[issue_row][row_rd_ptr[issue_row]];
    wire signed [31:0] rq_min = row_min_mem[issue_row][row_rd_ptr[issue_row]];
    wire signed [31:0] rq_max = row_max_mem[issue_row][row_rd_ptr[issue_row]];

    wire rq_valid_out;
    wire signed [31:0] rq_data_unused;
    wire [5:0] rq_pixel_unused;
    wire [6:0] rq_channel_unused;
    wire rq_busy;
    requant_activation_stream4 u_shared_rq (
        .clk(clk), .rst_n(rst_n), .valid_in(rq_valid_in), .ready_in(rq_ready_in),
        .acc_vec(rq_acc_vec), .bias_vec(rq_bias_vec), .multiplier_vec(rq_mult_vec),
        .shift_vec(rq_shift_vec), .pixel_idx(rq_pixel[5:0]),
        .channel_idx(rq_channel[6:0]), .output_zero_point_int32(rq_zp),
        .activation_min_int32(rq_min), .activation_max_int32(rq_max),
        .ready_out(out_ready), .valid_out(rq_valid_out),
        .out_pixel_idx(rq_pixel_unused), .out_channel_idx(rq_channel_unused),
        .out_data_int8(rq_data_unused), .busy(rq_busy));

    /* stream4 has a ten-step elastic arithmetic pipeline.  Its sideband is
     * advanced by the same ready signal, not by output ready, so metadata is
     * stable through arbitrary output backpressure. */
    reg [9:0] side_valid;
    reg [9:0] side_pixel [0:9];
    reg [8:0] side_channel [0:9];
    reg [2:0] side_group [0:9];
    reg [3:0] side_mask [0:9];
    reg [7:0] side_tag [0:9];
    reg [EPOCH_WIDTH-1:0] side_epoch [0:9];
    reg [SESSION_WIDTH-1:0] side_session [0:9];
    reg [1:0] side_mode [0:9];
    integer si;
    always @(posedge clk) begin
        if (!rst_n) begin
            side_valid <= 0;
            for (si = 0; si < 10; si = si + 1) begin
                side_pixel[si] <= 0; side_channel[si] <= 0; side_group[si] <= 0;
                side_mask[si] <= 0; side_tag[si] <= 0; side_epoch[si] <= 0;
                side_session[si] <= 0; side_mode[si] <= 0;
            end
        end else if (rq_ready_in) begin
            side_valid[0] <= rq_valid_in;
            if (rq_valid_in) begin
                side_pixel[0] <= rq_pixel;
                side_channel[0] <= rq_channel;
                side_group[0] <= rq_group;
                side_mask[0] <= rq_mask;
                side_tag[0] <= rq_tag;
                side_epoch[0] <= rq_epoch;
                side_session[0] <= rq_session;
                side_mode[0] <= rq_mode;
            end
            for (si = 1; si < 10; si = si + 1) begin
                side_valid[si] <= side_valid[si-1];
                if (side_valid[si-1]) begin
                    side_pixel[si] <= side_pixel[si-1];
                    side_channel[si] <= side_channel[si-1];
                    side_group[si] <= side_group[si-1];
                    side_mask[si] <= side_mask[si-1];
                    side_tag[si] <= side_tag[si-1];
                    side_epoch[si] <= side_epoch[si-1];
                    side_session[si] <= side_session[si-1];
                    side_mode[si] <= side_mode[si-1];
                end
            end
        end
    end

    assign out_valid = rq_valid_out;
    assign out_word = rq_data_unused;
    assign out_word_mask = side_mask[9];
    assign out_pixel_base = side_pixel[9];
    assign out_channel_base = side_channel[9];
    assign out_group = side_group[9];
    assign out_tag = side_tag[9];
    assign out_epoch = side_epoch[9];
    assign out_session = side_session[9];
    assign out_mode = side_mode[9];
    assign busy = tok_valid || prod_valid || block_active || rq_busy ||
                  (row_occupancy != 0) || (|side_valid);

    assign row_occupancy = row_count[0] + row_count[1] + row_count[2] + row_count[3] +
                           row_count[4] + row_count[5] + row_count[6] + row_count[7] +
                           row_count[8] + row_count[9] + row_count[10] + row_count[11] +
                           row_count[12] + row_count[13] + row_count[14] + row_count[15];

    /* Product wires use fixed byte positions.  The generate constants keep
     * the island/row/lane source cone local and avoid a variable-wide mux. */
    wire signed [15:0] product_wire [0:1][0:7][0:3];
    genvar gi, gj, gk;
    generate
        for (gi = 0; gi < 2; gi = gi + 1)
            for (gj = 0; gj < 8; gj = gj + 1)
                for (gk = 0; gk < 4; gk = gk + 1) begin : gen_products
                    assign product_wire[gi][gj][gk] =
                        $signed(tok_act[(gj*8) +: 8]) *
                        $signed(tok_wgt[((gi*4+gk)*8) +: 8]);
                end
    endgenerate

    /* The second stage performs only registered-product accumulation and
     * row-record writes.  No multiplier and accumulator carry chain share a
     * cycle. */
    integer ii, jj, kk, slot, row_idx;
    reg signed [31:0] sum_value;
    always @(posedge clk) begin
        if (!rst_n) begin
            tok_valid <= 0; tok_first <= 0; tok_last <= 0; tok_k <= 0;
            tok_act <= 0; tok_wgt <= 0; tok_pixel_base <= 0; tok_cout_base <= 0;
            tok_pixel_mask <= 0; tok_cout_mask <= 0; tok_tag <= 0;
            tok_epoch <= 0; tok_session <= 0; tok_mode <= 0;
            tok_zp <= 0; tok_min <= -128; tok_max <= 127;
            prod_valid <= 0; prod_first <= 0; prod_last <= 0; prod_k <= 0;
            block_active <= 0; block_pixel_base <= 0; block_cout_base <= 0;
            block_pixel_mask <= 0; block_cout_mask <= 0; block_tag <= 0;
            block_epoch <= 0; block_session <= 0; block_mode <= 0;
            block_zp <= 0; block_min <= -128; block_max <= 127;
            issue_row <= 0;
            for (ii = 0; ii < 2; ii = ii + 1)
                for (jj = 0; jj < 32; jj = jj + 1) begin
                    bias_mem[ii][jj] <= 0; mult_mem[ii][jj] <= 0; shift_mem[ii][jj] <= 0;
                end
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                row_wr_ptr[row_idx] <= 0; row_rd_ptr[row_idx] <= 0; row_count[row_idx] <= 0;
            end
            for (ii = 0; ii < 2; ii = ii + 1)
                for (jj = 0; jj < 8; jj = jj + 1)
                    for (kk = 0; kk < 4; kk = kk + 1)
                        prod_reg[ii][jj][kk] <= 0;
        end else begin
            if (cfg_valid && cfg_ready && (cfg_lane < 32)) begin
                bias_mem[cfg_island][cfg_lane] <= cfg_bias;
                mult_mem[cfg_island][cfg_lane] <= cfg_multiplier;
                shift_mem[cfg_island][cfg_lane] <= cfg_shift;
            end

            /* Consume a row only when stream4 accepted its narrow beat. */
            if (rq_fire) begin
                if (row_rd_ptr[issue_row] == ROW_FIFO_DEPTH-1)
                    row_rd_ptr[issue_row] <= 0;
                else row_rd_ptr[issue_row] <= row_rd_ptr[issue_row] + 1'b1;
                if (issue_row == ROWS-1) issue_row <= 0;
                else issue_row <= issue_row + 1'b1;
            end

            /* Move token to the multiplier boundary. */
            if (tok_advance) begin
                prod_valid <= tok_valid;
                if (tok_valid) begin
                    prod_first <= tok_first; prod_last <= tok_last; prod_k <= tok_k;
                    for (ii = 0; ii < 2; ii = ii + 1)
                        for (jj = 0; jj < 8; jj = jj + 1)
                            for (kk = 0; kk < 4; kk = kk + 1)
                                prod_reg[ii][jj][kk] <= product_wire[ii][jj][kk];
                end
            end
            if (token_fire) begin
                tok_valid <= 1'b1; tok_first <= token_first; tok_last <= token_last;
                tok_k <= token_k; tok_act <= token_act_vec; tok_wgt <= token_wgt_vec;
                tok_pixel_base <= token_pixel_base; tok_cout_base <= token_cout_base;
                tok_pixel_mask <= token_pixel_mask; tok_cout_mask <= token_cout_mask;
                tok_tag <= token_tag; tok_epoch <= token_epoch; tok_session <= token_session;
                tok_mode <= token_mode; tok_zp <= token_output_zero_point;
                tok_min <= token_activation_min; tok_max <= token_activation_max;
                if (token_first) begin
                    block_active <= 1'b1;
                    block_pixel_base <= token_pixel_base;
                    block_cout_base <= token_cout_base;
                    block_pixel_mask <= token_pixel_mask;
                    block_cout_mask <= token_cout_mask;
                    block_tag <= token_tag; block_epoch <= token_epoch;
                    block_session <= token_session; block_mode <= token_mode;
                    block_zp <= token_output_zero_point;
                    block_min <= token_activation_min; block_max <= token_activation_max;
                end
            end else if (tok_advance)
                tok_valid <= 1'b0;

            /* Commit all rows from a final registered product. */
            if (prod_advance) begin
                for (ii = 0; ii < 2; ii = ii + 1)
                    for (jj = 0; jj < 8; jj = jj + 1) begin
                        row_idx = ii*8 + jj;
                        slot = row_wr_ptr[row_idx];
                        for (kk = 0; kk < 4; kk = kk + 1) begin
                            sum_value = prod_first ?
                                {{16{prod_reg[ii][jj][kk][15]}},prod_reg[ii][jj][kk]} :
                                /* The accumulator is held in the row FIFO
                                 * only between K blocks; active sums live in
                                 * these local row accumulators below. */ 32'sd0;
                            if (!prod_first)
                                sum_value = acc_mem[ii][jj][kk] +
                                    {{16{prod_reg[ii][jj][kk][15]}},prod_reg[ii][jj][kk]};
                            if (prod_last) begin
                                row_sum_mem[row_idx][slot][kk] <= sum_value;
                                row_bias_mem[row_idx][slot][kk] <= bias_mem[ii][jj*4+kk];
                                row_mult_mem[row_idx][slot][kk] <= mult_mem[ii][jj*4+kk];
                                row_shift_mem[row_idx][slot][kk] <= shift_mem[ii][jj*4+kk];
                            end
                            acc_mem[ii][jj][kk] <= sum_value;
                        end
                        if (prod_last) begin
                            row_pixel_mem[row_idx][slot] <= block_pixel_base + jj;
                            row_channel_mem[row_idx][slot] <= block_cout_base + ii*4;
                            row_group_mem[row_idx][slot] <= jj[2:0];
                            row_mask_mem[row_idx][slot] <=
                                ({4{block_pixel_mask[jj]}} & block_cout_mask[(ii*4) +: 4]);
                            row_tag_mem[row_idx][slot] <= block_tag;
                            row_epoch_mem[row_idx][slot] <= block_epoch;
                            row_session_mem[row_idx][slot] <= block_session;
                            row_mode_mem[row_idx][slot] <= block_mode;
                            row_zp_mem[row_idx][slot] <= block_zp;
                            row_min_mem[row_idx][slot] <= block_min;
                            row_max_mem[row_idx][slot] <= block_max;
                            if (row_wr_ptr[row_idx] == ROW_FIFO_DEPTH-1)
                                row_wr_ptr[row_idx] <= 0;
                            else row_wr_ptr[row_idx] <= row_wr_ptr[row_idx] + 1'b1;
                        end
                    end
                if (prod_last) block_active <= 1'b0;
            end

            /* Count updates are intentionally local to each row. */
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                if (prod_advance && prod_last && rq_fire && (issue_row == row_idx))
                    row_count[row_idx] <= row_count[row_idx];
                else if (prod_advance && prod_last)
                    row_count[row_idx] <= row_count[row_idx] + 1'b1;
                else if (rq_fire && (issue_row == row_idx))
                    row_count[row_idx] <= row_count[row_idx] - 1'b1;
            end
        end
    end

    /* Active sums are local to each 4-lane row and are not output-bus state. */
    reg signed [31:0] acc_mem [0:1][0:7][0:3];
endmodule

/* Feed-integrated wrapper.  The persistent feed ABI is instantiated exactly
 * as published; only a narrow token/config adapter is added around it. */
module ds_rowlocal_4lane_feed_macro #(
    parameter integer MAX_SOURCE_WORDS = 4096,
    parameter integer MAX_PARAM_ROWS = 4096,
    parameter integer MAX_CIN = 128,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer SESSION_WIDTH = 4
) (
    input wire clk, input wire rst_n,
    input wire cfg_valid, output wire cfg_ready,
    input wire [2:0] cfg_layer_id, input wire cfg_mode,
    input wire [EPOCH_WIDTH-1:0] cfg_epoch, input wire [SESSION_WIDTH-1:0] cfg_session,
    output wire [15:0] cfg_output_pixels, output wire [7:0] cfg_cin,
    output wire [8:0] cfg_cout, output wire [15:0] cfg_source_pixels,
    output wire [15:0] cfg_source_words, output wire [15:0] cfg_param_words,
    input wire load_start_valid, output wire load_start_ready,
    input wire [31:0] load_source_base_addr, input wire [31:0] load_param_base_addr,
    output wire source_req_valid, input wire source_req_ready, output wire [31:0] source_req_addr,
    input wire source_resp_valid, output wire source_resp_ready, input wire [31:0] source_resp_data,
    output wire param_req_valid, input wire param_req_ready, output wire [31:0] param_req_addr,
    input wire param_resp_valid, output wire param_resp_ready, input wire [31:0] param_resp_data,
    output wire load_active, output wire load_done,
    output wire [15:0] source_external_word_count, output wire [15:0] param_external_word_count,
    output wire [15:0] source_request_stall_count, output wire [15:0] param_request_stall_count,
    input wire commit_valid, output wire commit_ready, output wire commit_reject,
    output wire committed_valid, output wire [EPOCH_WIDTH-1:0] committed_epoch,
    output wire [SESSION_WIDTH-1:0] committed_session,
    input wire job_valid, output wire job_ready,
    input wire [EPOCH_WIDTH-1:0] job_epoch, input wire [SESSION_WIDTH-1:0] job_session,
    input wire [9:0] job_pixel_base, input wire [4:0] job_cout_tile,
    input wire [7:0] job_pixel_mask, input wire [7:0] job_cout_mask,
    output wire job_reject_stale, output wire job_done,
    input wire cfgq_valid, output wire cfgq_ready, input wire cfgq_island,
    input wire [5:0] cfgq_lane, input wire signed [31:0] cfgq_bias,
    input wire signed [31:0] cfgq_multiplier, input wire [5:0] cfgq_shift,
    input wire signed [31:0] output_zero_point, input wire signed [31:0] activation_min,
    input wire signed [31:0] activation_max,
    output wire out_valid, input wire out_ready, output wire [31:0] out_word,
    output wire [3:0] out_word_mask, output wire [9:0] out_pixel_base,
    output wire [8:0] out_channel_base, output wire [2:0] out_group, output wire [7:0] out_tag,
    output wire [EPOCH_WIDTH-1:0] out_epoch, output wire [SESSION_WIDTH-1:0] out_session,
    output wire [1:0] out_mode, output wire busy
);
    wire feed_token_valid, feed_token_ready;
    wire feed_first, feed_last; wire [7:0] feed_k;
    wire [9:0] feed_pixel; wire [8:0] feed_channel;
    wire [7:0] feed_pmask, feed_cmask; wire [63:0] feed_act, feed_wgt;
    wire feed_busy;
    wire feed_cfg_ready;
    reg cfg_mode_reg;
    reg [7:0] job_tag_reg;

    ds_persistent_feed_contract #(
        .MAX_SOURCE_WORDS(MAX_SOURCE_WORDS), .MAX_PARAM_ROWS(MAX_PARAM_ROWS),
        .MAX_CIN(MAX_CIN), .EPOCH_WIDTH(EPOCH_WIDTH), .SESSION_WIDTH(SESSION_WIDTH)
    ) u_feed (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(feed_cfg_ready),
        .cfg_layer_id(cfg_layer_id), .cfg_mode(cfg_mode), .cfg_epoch(cfg_epoch), .cfg_session(cfg_session),
        .cfg_output_pixels(cfg_output_pixels), .cfg_cin(cfg_cin), .cfg_cout(cfg_cout),
        .cfg_source_pixels(cfg_source_pixels), .cfg_source_words(cfg_source_words), .cfg_param_words(cfg_param_words),
        .load_start_valid(load_start_valid), .load_start_ready(load_start_ready),
        .load_source_base_addr(load_source_base_addr), .load_param_base_addr(load_param_base_addr),
        .source_req_valid(source_req_valid), .source_req_ready(source_req_ready), .source_req_addr(source_req_addr),
        .source_resp_valid(source_resp_valid), .source_resp_ready(source_resp_ready), .source_resp_data(source_resp_data),
        .param_req_valid(param_req_valid), .param_req_ready(param_req_ready), .param_req_addr(param_req_addr),
        .param_resp_valid(param_resp_valid), .param_resp_ready(param_resp_ready), .param_resp_data(param_resp_data),
        .load_active(load_active), .load_done(load_done), .source_external_word_count(source_external_word_count),
        .param_external_word_count(param_external_word_count), .source_request_stall_count(source_request_stall_count),
        .param_request_stall_count(param_request_stall_count), .commit_valid(commit_valid), .commit_ready(commit_ready),
        .commit_reject(commit_reject), .committed_valid(committed_valid), .committed_epoch(committed_epoch),
        .committed_session(committed_session), .job_valid(job_valid), .job_ready(job_ready), .job_epoch(job_epoch),
        .job_session(job_session), .job_pixel_base(job_pixel_base), .job_cout_tile(job_cout_tile),
        .job_pixel_mask(job_pixel_mask), .job_cout_mask(job_cout_mask), .job_reject_stale(job_reject_stale),
        .token_valid(feed_token_valid), .token_ready(feed_token_ready), .token_first(feed_first), .token_last(feed_last),
        .token_k_idx(feed_k), .token_pixel_base(feed_pixel), .token_cout_base(feed_channel),
        .token_pixel_mask(feed_pmask), .token_cout_mask(feed_cmask), .token_act_vec(feed_act), .token_wgt_vec(feed_wgt),
        .job_done(job_done), .busy(feed_busy), .local_source_word_read_count(), .local_param_row_read_count(),
        .token_count(), .window_reuse_count()
    );
    assign cfg_ready = feed_cfg_ready;
    always @(posedge clk) begin
        if (!rst_n) begin cfg_mode_reg <= 0; job_tag_reg <= 0; end
        else begin
            if (cfg_valid && feed_cfg_ready) cfg_mode_reg <= cfg_mode;
            if (job_valid && job_ready) job_tag_reg <= {3'b000,job_cout_tile};
        end
    end

    ds_rowlocal_4lane_macro #(.EPOCH_WIDTH(EPOCH_WIDTH), .SESSION_WIDTH(SESSION_WIDTH)) u_compute (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfgq_valid), .cfg_ready(cfgq_ready), .cfg_island(cfgq_island),
        .cfg_lane(cfgq_lane), .cfg_bias(cfgq_bias), .cfg_multiplier(cfgq_multiplier), .cfg_shift(cfgq_shift),
        .token_valid(feed_token_valid), .token_ready(feed_token_ready), .token_first(feed_first), .token_last(feed_last),
        .token_k(feed_k), .token_pixel_base(feed_pixel), .token_cout_base(feed_channel),
        .token_pixel_mask(feed_pmask), .token_cout_mask(feed_cmask), .token_act_vec(feed_act), .token_wgt_vec(feed_wgt),
        .token_tag(job_tag_reg), .token_epoch(committed_epoch), .token_session(committed_session),
        .token_mode({1'b0,cfg_mode_reg}), .token_output_zero_point(output_zero_point),
        .token_activation_min(activation_min), .token_activation_max(activation_max),
        .out_valid(out_valid), .out_ready(out_ready), .out_word(out_word), .out_word_mask(out_word_mask),
        .out_pixel_base(out_pixel_base), .out_channel_base(out_channel_base), .out_group(out_group), .out_tag(out_tag),
        .out_epoch(out_epoch), .out_session(out_session), .out_mode(out_mode), .busy(), .row_occupancy()
    );
    assign busy = feed_busy;
endmodule

`default_nettype wire
