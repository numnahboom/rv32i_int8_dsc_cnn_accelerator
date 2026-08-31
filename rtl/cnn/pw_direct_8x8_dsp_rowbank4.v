`timescale 1ns/1ps
`default_nettype none

/*
 * Non-production output-stationary PW prototype with a four-lane row sink.
 *
 * This is the row-bank design's narrow successor: two local 8x8x32 result
 * banks overlap accumulation and drain, while each eight-value row drains in
 * two four-lane beats.  The arithmetic is unchanged; only the final
 * requant/writeback width is doubled.  Bank ownership is the fence:
 * FREE -> ACCUM -> READY -> DRAIN -> FREE.
 */
module pw_direct_8x8_dsp_rowbank4 (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire first_k, input wire last_k, input wire [7:0] k_idx,
    input wire [7:0] pixel_mask, input wire [7:0] cout_mask,
    input wire signed [63:0] act_vec, input wire signed [63:0] wgt_vec,
    input wire [5:0] pixel_base, input wire [8:0] cout_base,
    input wire [7:0] output_pixels, input wire [8:0] output_channels,
    input wire signed [255:0] bias_vec,
    input wire signed [255:0] multiplier_vec,
    input wire [47:0] shift_vec,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out,
    output wire valid_out,
    output wire [2:0] out_row_idx,
    output wire out_beat_idx,
    output wire [5:0] out_pixel_idx,
    output wire [8:0] out_channel_base,
    output wire [3:0] out_lane_mask,
    output wire signed [31:0] out_data,
    output wire busy
);
    localparam [1:0] ST_FREE  = 2'd0;
    localparam [1:0] ST_ACCUM = 2'd1;
    localparam [1:0] ST_READY = 2'd2;
    localparam [1:0] ST_DRAIN = 2'd3;

    reg [1:0] bank_state [0:1];
    reg current_active, current_bank, alloc_bank_reg;
    reg drain_active, drain_bank;
    reg [4:0] issue_idx;

    reg [63:0] bank_mask [0:1];
    reg [5:0] bank_pixel_base [0:1];
    reg [8:0] bank_cout_base [0:1];
    reg signed [255:0] bank_bias [0:1];
    reg signed [255:0] bank_multiplier [0:1];
    reg [47:0] bank_shift [0:1];
    reg signed [31:0] bank_zp [0:1], bank_min [0:1], bank_max [0:1];

    wire free0 = (bank_state[0] == ST_FREE);
    wire free1 = (bank_state[1] == ST_FREE);
    /* Never trust a stale round-robin bit when a bank is READY/DRAIN.  The
     * previous row2 prototype only tested whether either bank was free, which
     * allowed a slower drain to be overwritten when the selected bit lagged
     * ownership.  Fall back to the other bank before accepting a new block. */
    wire alloc_bank = free0 ? (free1 ? alloc_bank_reg : 1'b0) :
                             (free1 ? 1'b1 : alloc_bank_reg);
    wire alloc_available = current_active ||
                           (alloc_bank ? free1 : free0);
    wire input_fire = valid_in && ready_in;

    /* One-entry input stage keeps ownership decode out of the DSP inputs and
     * prevents a final token from aliasing the next reduction's bank. */
    reg in_stage_valid, in_stage_first, in_stage_last, in_stage_bank;
    reg signed [7:0] in_stage_act_row [0:7];
    reg signed [7:0] in_stage_wgt_col [0:7];
    assign ready_in = rst_n && alloc_available &&
                      !(in_stage_valid && in_stage_last);

    wire [63:0] input_lane_mask;
    genvar gm;
    generate for (gm = 0; gm < 64; gm = gm + 1) begin : gen_input_mask
        assign input_lane_mask[gm] = pixel_mask[gm/8] && cout_mask[gm%8];
    end endgenerate

    wire signed [31:0] cell_sum_next [0:63];
    wire cell_last_pending [0:63];
    wire cell_last_pending_any = cell_last_pending[0];
    wire mac_fire = in_stage_valid;
    genvar gi;
    generate for (gi = 0; gi < 64; gi = gi + 1) begin : gen_mac
        pw_rowbank4_mac_cell u_mac (
            .clk(clk), .rst_n(rst_n), .en(mac_fire),
            .clear_acc(in_stage_first), .last_in(in_stage_last),
            .act_in(in_stage_act_row[gi/8]),
            .wgt_in(in_stage_wgt_col[gi%8]),
            .sum_next(cell_sum_next[gi]),
            .last_pending(cell_last_pending[gi])
        );
    end endgenerate

    reg signed [2047:0] bank_psum0, bank_psum1;
    wire signed [2047:0] cell_sum_pack;
    generate for (gi = 0; gi < 64; gi = gi + 1) begin : gen_pack
        assign cell_sum_pack[(gi*32) +: 32] = cell_sum_next[gi];
    end endgenerate
    wire signed [2047:0] drain_psum = drain_bank ? bank_psum1 : bank_psum0;
    wire [63:0] drain_mask = drain_bank ? bank_mask[1] : bank_mask[0];

    reg signed [255:0] row_psum, row_bias, row_multiplier;
    reg [47:0] row_shift;
    reg [7:0] row_mask;
    reg [5:0] row_pixel_base;
    reg [8:0] row_cout_base;
    reg signed [31:0] row_zp, row_min, row_max;
    reg rq_stage_valid;
    reg signed [127:0] stage_acc, stage_bias, stage_multiplier;
    reg [23:0] stage_shift;
    reg [2:0] stage_row;
    reg stage_beat;
    reg [5:0] stage_pixel_base;
    reg [8:0] stage_cout_base;
    reg [3:0] stage_mask;

    wire rq_ready, rq_busy, rq_valid;
    wire [2:0] rq_row;
    wire rq_beat;
    wire [5:0] rq_pixel;
    wire [8:0] rq_cout;
    wire [3:0] rq_mask;
    wire signed [31:0] rq_data;
    reg rq_idle_d;
    requant_activation_row4 u_row_rq (
        .clk(clk), .rst_n(rst_n), .valid_in(rq_stage_valid),
        .ready_in(rq_ready), .acc_vec(stage_acc), .bias_vec(stage_bias),
        .multiplier_vec(stage_multiplier), .shift_vec(stage_shift),
        .row_idx(stage_row), .beat_idx(stage_beat),
        .pixel_base(stage_pixel_base), .cout_base(stage_cout_base),
        .lane_mask(stage_mask),
        .output_zero_point_int32(row_zp),
        .activation_min_int32(row_min), .activation_max_int32(row_max),
        .ready_out(ready_out), .valid_out(rq_valid),
        .out_row_idx(rq_row), .out_beat_idx(rq_beat),
        .out_pixel_idx(rq_pixel), .out_channel_base(rq_cout),
        .out_lane_mask(rq_mask), .out_data(rq_data), .busy(rq_busy)
    );
    assign valid_out = rq_valid;
    assign out_row_idx = rq_row;
    assign out_beat_idx = rq_beat;
    assign out_pixel_idx = rq_pixel;
    assign out_channel_base = rq_cout;
    assign out_lane_mask = rq_mask;
    assign out_data = rq_data;
    assign busy = current_active || drain_active || in_stage_valid ||
                  rq_stage_valid || rq_busy ||
                  (bank_state[0] != ST_FREE) || (bank_state[1] != ST_FREE);

    wire output_fire = rq_valid && ready_out;
    wire start_bank = (bank_state[0] == ST_READY) ? 1'b0 : 1'b1;
    wire drain_start = !drain_active && !in_stage_valid &&
                        !cell_last_pending_any && !rq_stage_valid && rq_idle_d &&
                        ((bank_state[0] == ST_READY) ||
                         (bank_state[1] == ST_READY)) &&
                        (bank_state[0] != ST_DRAIN) &&
                        (bank_state[1] != ST_DRAIN) &&
                        (!current_active || (start_bank != current_bank));
    wire stage_fire = rq_stage_valid && rq_ready;
    wire stage_load = drain_active && (!rq_stage_valid || rq_ready);
    wire [2:0] issue_row = issue_idx[4:1];
    wire issue_beat = issue_idx[0];
    /* The linear drain index names a four-lane beat, hence each increment
     * advances 128 bits in the packed 64-entry bank.  Both beats of a row
     * must select different halves of that row. */
    wire [11:0] issue_psum_bit = {issue_idx, 7'd0};
    wire [5:0] issue_shift_bit = issue_beat * 6'd24;
    wire [4:0] issue_mask_bit = issue_beat * 5'd4;

    integer n;
    always @(posedge clk) begin
        if (!rst_n) begin
            bank_state[0] <= ST_FREE; bank_state[1] <= ST_FREE;
            current_active <= 1'b0; current_bank <= 1'b0;
            alloc_bank_reg <= 1'b0;
            in_stage_valid <= 1'b0; in_stage_first <= 1'b0;
            in_stage_last <= 1'b0; in_stage_bank <= 1'b0;
            for (n = 0; n < 8; n = n + 1) begin
                in_stage_act_row[n] <= 0; in_stage_wgt_col[n] <= 0;
            end
            drain_active <= 1'b0; drain_bank <= 1'b0; issue_idx <= 0;
            row_psum <= 0; row_bias <= 0; row_multiplier <= 0;
            row_shift <= 0; row_mask <= 0; row_pixel_base <= 0;
            row_cout_base <= 0; row_zp <= 0; row_min <= 0; row_max <= 0;
            rq_stage_valid <= 1'b0; stage_acc <= 0; stage_bias <= 0;
            stage_multiplier <= 0; stage_shift <= 0; stage_row <= 0;
            stage_beat <= 0; stage_pixel_base <= 0; stage_cout_base <= 0;
            stage_mask <= 0; rq_idle_d <= 1'b1;
            bank_psum0 <= 0; bank_psum1 <= 0;
            for (n = 0; n < 2; n = n + 1) begin
                bank_mask[n] <= 0; bank_pixel_base[n] <= 0;
                bank_cout_base[n] <= 0; bank_bias[n] <= 0;
                bank_multiplier[n] <= 0; bank_shift[n] <= 0;
                bank_zp[n] <= 0; bank_min[n] <= 0; bank_max[n] <= 0;
            end
        end else begin
            rq_idle_d <= !rq_busy;

            if (input_fire) begin
                in_stage_valid <= 1'b1;
                in_stage_first <= first_k; in_stage_last <= last_k;
                in_stage_bank <= current_active ? current_bank : alloc_bank;
                for (n = 0; n < 8; n = n + 1) begin
                    in_stage_act_row[n] <= act_vec[(n*8) +: 8];
                    in_stage_wgt_col[n] <= wgt_vec[(n*8) +: 8];
                end
            end else begin
                in_stage_valid <= 1'b0;
                in_stage_first <= 1'b0; in_stage_last <= 1'b0;
            end

            if (cell_last_pending_any) begin
                if (in_stage_bank) bank_psum1 <= cell_sum_pack;
                else bank_psum0 <= cell_sum_pack;
            end

            if (output_fire && (rq_row == 3'd7) && rq_beat) begin
                bank_state[drain_bank] <= ST_FREE;
                alloc_bank_reg <= drain_bank;
            end

            if (input_fire) begin
                if (!current_active) begin
                    current_bank <= alloc_bank;
                    current_active <= !last_k;
                    bank_state[alloc_bank] <= last_k ? ST_READY : ST_ACCUM;
                    if (last_k) alloc_bank_reg <= ~alloc_bank;
                    if (first_k) begin
                        bank_mask[alloc_bank] <= input_lane_mask;
                        bank_pixel_base[alloc_bank] <= pixel_base;
                        bank_cout_base[alloc_bank] <= cout_base;
                        bank_bias[alloc_bank] <= bias_vec;
                        bank_multiplier[alloc_bank] <= multiplier_vec;
                        bank_shift[alloc_bank] <= shift_vec;
                        bank_zp[alloc_bank] <= output_zero_point_int32;
                        bank_min[alloc_bank] <= activation_min_int32;
                        bank_max[alloc_bank] <= activation_max_int32;
                    end
                end else if (last_k) begin
                    current_active <= 1'b0;
                    bank_state[current_bank] <= ST_READY;
                    alloc_bank_reg <= ~current_bank;
                end
            end

            if (drain_start) begin
                drain_active <= 1'b1; drain_bank <= start_bank; issue_idx <= 0;
                bank_state[start_bank] <= ST_DRAIN;
                row_psum <= start_bank ? bank_psum1[255:0] : bank_psum0[255:0];
                row_bias <= bank_bias[start_bank];
                row_multiplier <= bank_multiplier[start_bank];
                row_shift <= bank_shift[start_bank];
                row_mask <= start_bank ? bank_mask[1][7:0] : bank_mask[0][7:0];
                row_pixel_base <= bank_pixel_base[start_bank];
                row_cout_base <= bank_cout_base[start_bank];
                row_zp <= bank_zp[start_bank]; row_min <= bank_min[start_bank];
                row_max <= bank_max[start_bank];
            end else if (stage_load) begin
                rq_stage_valid <= 1'b1;
                stage_acc <= row_psum[issue_psum_bit +: 128];
                stage_bias <= row_bias[issue_psum_bit +: 128];
                stage_multiplier <= row_multiplier[issue_psum_bit +: 128];
                stage_shift <= row_shift[issue_shift_bit +: 24];
                stage_row <= issue_row; stage_beat <= issue_beat;
                stage_pixel_base <= row_pixel_base;
                stage_cout_base <= row_cout_base;
                stage_mask <= row_mask[issue_mask_bit +: 4];
                if (issue_idx == 5'd15) begin
                    drain_active <= 1'b0;
                end else begin
                    issue_idx <= issue_idx + 1'b1;
                    if (issue_idx[0]) begin
                        row_psum <= drain_psum[((issue_row + 1'b1)*256) +: 256];
                        row_mask <= drain_mask[((issue_row + 1'b1)*8) +: 8];
                    end
                end
            end else if (stage_fire) begin
                rq_stage_valid <= 1'b0;
            end
        end
    end
endmodule

module pw_rowbank4_mac_cell (
    input wire clk, input wire rst_n, input wire en,
    input wire clear_acc, input wire last_in,
    input wire signed [7:0] act_in, input wire signed [7:0] wgt_in,
    output wire signed [31:0] sum_next, output wire last_pending
);
    reg signed [7:0] act_reg, wgt_reg;
    reg clear_reg, last_reg, valid_reg;
    (* use_dsp = "yes" *) wire signed [15:0] product = act_reg * wgt_reg;
    wire signed [31:0] product_ext = {{16{product[15]}}, product};
    reg signed [31:0] acc_reg;
    assign sum_next = clear_reg ? product_ext : acc_reg + product_ext;
    assign last_pending = last_reg;
    always @(posedge clk) begin
        if (!rst_n) begin
            acc_reg <= 0; act_reg <= 0; wgt_reg <= 0;
            clear_reg <= 0; last_reg <= 0; valid_reg <= 0;
        end else begin
            if (en) begin
                act_reg <= act_in; wgt_reg <= wgt_in;
                clear_reg <= clear_acc; last_reg <= last_in; valid_reg <= 1'b1;
            end else begin
                last_reg <= 1'b0; valid_reg <= 1'b0;
            end
            if (valid_reg) acc_reg <= sum_next;
        end
    end
endmodule

`default_nettype wire
