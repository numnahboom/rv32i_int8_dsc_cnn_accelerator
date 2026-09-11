`timescale 1ns/1ps
`default_nettype none

/*
 * One 64-lane arithmetic island shared by the unified Stem and unified DS
 * engines.  The two producers are mutually exclusive at the layer runner
 * (a layer is either Stem or DS), but this block deliberately selects the
 * layout per transaction rather than relying on synthesis to discover that
 * fact.  Consequently a full top contains one MAC bank and one four-lane
 * requant bank, while the source/window and DW-feed memories remain in their
 * respective front ends.
 *
 * mode_stem == 0: 8 pixels x 8 output channels (DS PW)
 * mode_stem == 1: 4 pixels x 16 output channels (Stem)
 *
 * Both layouts contain exactly 64 signed 8x8 products and drain sixteen
 * four-byte beats.  The 2048-bit accumulator bank is therefore shared; only
 * the small row/beat address decode changes with the captured mode.  No
 * computation or precision is removed by this multiplexing.
 */
module unified64_shared_compute_array #(
    parameter integer EPOCH_WIDTH = 4
) (
    input wire clk,
    input wire rst_n,
    input wire mode_stem,
    input wire valid_in,
    output wire ready_in,
    input wire first_k,
    input wire last_k,
    input wire [7:0] k_idx,
    input wire signed [63:0] act_vec,
    input wire signed [127:0] wgt_vec16,
    input wire [7:0] pixel_mask,
    input wire [15:0] cout_mask,
    input wire [10:0] pixel_base,
    /* Optional producer metadata.  The arithmetic island carries this
     * opaque tag with the completed block so downstream control does not
     * have to reconstruct row/column geometry from the linear pixel index. */
    input wire [8:0] spatial_tag,
    input wire [8:0] cout_base,
    input wire signed [511:0] bias_vec,
    input wire signed [511:0] multiplier_vec,
    input wire [95:0] shift_vec,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out,
    output wire valid_out,
    output wire [10:0] out_pixel_idx,
    output wire [8:0] out_channel_base,
    output wire [3:0] out_lane_mask,
    output wire signed [31:0] out_data,
    output wire [8:0] out_spatial_tag,
    output wire [2:0] out_inner_pixel,
    output wire busy,
    output wire [31:0] metric_token_count,
    output wire [31:0] metric_masked_mac_count,
    output wire [31:0] metric_commit_count
);
    reg bank_live0, bank_live1, bank_ready0, bank_ready1;
    reg current_active, current_bank, alloc_bank_reg;
    reg drain_active, drain_bank;
    reg [5:0] issue_idx;

    reg in_stage_valid, in_stage_first, in_stage_last, in_stage_mode;
    reg in_stage_bank;
    (* keep = "true" *) reg signed [7:0] in_stage_act [0:63];
    (* keep = "true" *) reg signed [7:0] in_stage_wgt [0:63];
    reg [7:0] in_stage_pixel_mask;
    reg [15:0] in_stage_cout_mask;
    reg [10:0] in_stage_pixel_base;
    reg [8:0] in_stage_cout_base;
    reg signed [511:0] in_stage_bias, in_stage_multiplier;
    reg [95:0] in_stage_shift;
    reg signed [31:0] in_stage_zp, in_stage_min, in_stage_max;

    wire bank_free_any = !bank_live0 || !bank_live1;
    assign ready_in = rst_n && (current_active || bank_free_any) &&
                      (!in_stage_valid || !in_stage_last);
    wire input_fire = valid_in && ready_in;

    wire cell_last_pending [0:63];
    wire [31:0] cell_sum [0:63];
    wire [7:0] mac_en_row;
    wire [7:0] mac_rst_row;
    genvar g;
    generate for (g=0; g<8; g=g+1) begin : gen_local_controls
`ifdef SYNTHESIS
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_en_buf
            (.I0(in_stage_valid), .O(mac_en_row[g]));
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rst_buf
            (.I0(rst_n), .O(mac_rst_row[g]));
`else
        assign mac_en_row[g] = in_stage_valid;
        assign mac_rst_row[g] = rst_n;
`endif
    end endgenerate
    generate for (g=0; g<64; g=g+1) begin : gen_shared_mac
        pw_rowbank_mac_cell u_mac (
            .clk(clk), .rst_n(mac_rst_row[g/8]), .en(mac_en_row[g/8]),
            .clear_acc(in_stage_first), .last_in(in_stage_last),
            .act_in(in_stage_act[g]), .wgt_in(in_stage_wgt[g]),
            .sum_next(cell_sum[g]), .last_pending(cell_last_pending[g])
        );
    end endgenerate
    wire mac_last_pending = cell_last_pending[0];

    reg signed [2047:0] bank_psum0, bank_psum1;
    reg bank_mode0, bank_mode1;
    reg [7:0] bank_pixel_mask0, bank_pixel_mask1;
    reg [15:0] bank_cout_mask0, bank_cout_mask1;
    reg [10:0] bank_pixel_base0, bank_pixel_base1;
    reg [8:0] bank_spatial_tag0, bank_spatial_tag1;
    reg [8:0] bank_cout_base0, bank_cout_base1;
    reg signed [511:0] bank_bias0, bank_bias1;
    reg signed [511:0] bank_multiplier0, bank_multiplier1;
    reg [95:0] bank_shift0, bank_shift1;
    reg signed [31:0] bank_zp0, bank_zp1, bank_min0, bank_min1;
    reg signed [31:0] bank_max0, bank_max1;

    /* A new block reserves its physical bank immediately, but its wide
     * sideband is committed one clock later from this registered bundle.  In
     * particular, the 512-bit parameter writes no longer use the producer's
     * valid/current-bank/address cone as their write-enable.  The pending
     * entry is single-depth because reservation is only possible when the
     * previous first-token stage has drained; a simultaneous commit and new
     * reservation is handled by retaining the newly captured pending entry. */
    reg meta_pending_valid, meta_pending_bank;
    reg meta_pending_mode;
    reg [7:0] meta_pending_pixel_mask;
    reg [15:0] meta_pending_cout_mask;
    reg [10:0] meta_pending_pixel_base;
    reg [8:0] meta_pending_spatial_tag;
    reg [8:0] meta_pending_cout_base;
    reg signed [511:0] meta_pending_bias, meta_pending_multiplier;
    reg [95:0] meta_pending_shift;
    reg signed [31:0] meta_pending_zp, meta_pending_min, meta_pending_max;
    reg bank_meta_valid0, bank_meta_valid1;

    wire signed [2047:0] cell_sum_pack;
    generate for (g=0; g<64; g=g+1) begin : gen_sum_pack
        assign cell_sum_pack[(g*32) +: 32] = cell_sum[g];
    end endgenerate

    reg signed [2047:0] drain_psum;
    reg drain_mode;
    reg [7:0] drain_pixel_mask;
    reg [15:0] drain_cout_mask;
    reg [10:0] drain_pixel_base_reg;
    reg [8:0] drain_spatial_tag_reg;
    reg [8:0] drain_cout_base_reg;
    reg signed [511:0] drain_bias, drain_multiplier;
    reg [95:0] drain_shift;
    reg signed [31:0] drain_zp, drain_min, drain_max;
    reg rq_stage_valid;
    reg signed [127:0] rq_acc, rq_bias, rq_multiplier;
    reg [23:0] rq_shift;
    reg [3:0] rq_row;
    reg rq_beat;
    reg [10:0] rq_pixel_base;
    reg [8:0] rq_cout_base;
    reg [3:0] rq_mask;
    wire rq_ready, rq_valid, rq_busy;
    wire [3:0] rq_out_row, rq_out_beat;
    wire rq_out_beat_bit;
    wire [10:0] rq_out_pixel;
    wire [8:0] rq_out_cout;
    wire [3:0] rq_out_mask;
    wire signed [31:0] rq_out_data;

    shared_requant4_wide u_shared_rq (
        .clk(clk), .rst_n(rst_n), .valid_in(rq_stage_valid), .ready_in(rq_ready),
        .acc_vec(rq_acc), .bias_vec(rq_bias), .multiplier_vec(rq_multiplier),
        .shift_vec(rq_shift), .row_idx(rq_row), .beat_idx(rq_beat),
        .pixel_base(rq_pixel_base), .cout_base(rq_cout_base), .lane_mask(rq_mask),
        .output_zero_point_int32(drain_zp), .activation_min_int32(drain_min),
        .activation_max_int32(drain_max), .ready_out(ready_out),
        .valid_out(rq_valid), .out_row_idx(rq_out_row), .out_beat_idx(rq_out_beat_bit),
        .out_pixel_idx(rq_out_pixel), .out_channel_base(rq_out_cout),
        .out_lane_mask(rq_out_mask), .out_data(rq_out_data), .busy(rq_busy)
    );
    assign valid_out = rq_valid;
    assign out_pixel_idx = rq_out_pixel;
    assign out_channel_base = rq_out_cout;
    assign out_lane_mask = rq_out_mask;
    assign out_data = rq_out_data;
    /* All sixteen beats drained from one completed bank share the same
     * spatial tag.  The inner pixel index comes from the existing row tag
     * and is therefore already aligned with the requant output pipeline. */
    assign out_spatial_tag = drain_spatial_tag_reg;
    assign out_inner_pixel = rq_out_row[2:0];
    wire output_fire = rq_valid && ready_out;

    wire drain_ready0 = bank_ready0 && bank_meta_valid0;
    wire drain_ready1 = bank_ready1 && bank_meta_valid1;
    wire drain_start = !drain_active && !in_stage_valid && !mac_last_pending &&
                        !rq_stage_valid && !rq_busy &&
                        (drain_ready0 || drain_ready1);
    wire stage_load = drain_active && (!rq_stage_valid || rq_ready);
    wire stage_fire = rq_stage_valid && rq_ready;
    wire drain_final_fire = output_fire &&
        (rq_out_row == (drain_mode ? 4'd3 : 4'd7)) &&
        (rq_out_beat_bit == (drain_mode ? 1'b1 : 1'b1)) &&
        (drain_mode ? (rq_out_cout == drain_cout_base_reg + 9'd12) :
                      (rq_out_cout == drain_cout_base_reg + 9'd4));
    assign busy = current_active || drain_active || in_stage_valid ||
                  rq_stage_valid || rq_busy || bank_live0 || bank_live1;

    /* The counters are intentionally narrow in hardware; they are status
     * only and are not part of the arithmetic/control timing cone. */
    reg [19:0] token_count_reg;
    reg [21:0] masked_mac_count_reg;
    reg [15:0] commit_count_reg;
`ifndef SYNTHESIS
    // Mode-separated integration counters.  These are simulation evidence
    // only and are deliberately absent from the synthesized datapath.
    reg [31:0] stem_token_count_reg, ds_token_count_reg;
    reg [31:0] stem_commit_count_reg, ds_commit_count_reg;
`endif
`ifdef SYNTHESIS
    assign metric_token_count=0; assign metric_masked_mac_count=0;
    assign metric_commit_count=0;
`else
    assign metric_token_count={{12{1'b0}},token_count_reg};
    assign metric_masked_mac_count={{10{1'b0}},masked_mac_count_reg};
    assign metric_commit_count={{16{1'b0}},commit_count_reg};
`endif

    integer i;
    wire [2:0] issue_pixel_index = drain_mode ?
        {1'b0,issue_idx[3:2]} : issue_idx[3:1];
    wire [3:0] issue_group_index = drain_mode ?
        {2'b0,issue_idx[1:0]} : {3'b0,issue_idx[0]};
    wire [10:0] issue_acc_offset = drain_mode ?
        ({issue_pixel_index,9'd0} + {issue_group_index,7'd0}) :
        ({issue_pixel_index,8'd0} + {issue_group_index,7'd0});
    wire [8:0] issue_param_offset = {issue_group_index,7'd0};
    wire [6:0] issue_shift_offset =
        ({issue_group_index,3'd0} << 1) + {issue_group_index,3'd0};
    wire [4:0] issue_cout_mask_offset = {issue_group_index,2'd0};
    wire reserve_fire = input_fire && !current_active;
    /* These enables are sourced only by the registered pending bundle.  Keep
     * them separate so Vivado can replicate the one-bit commit control near
     * each bank rather than rebuilding the producer geometry cone. */
    wire meta_commit0 = meta_pending_valid && !meta_pending_bank;
    wire meta_commit1 = meta_pending_valid && meta_pending_bank;
    always @(posedge clk) begin
        if (!rst_n) begin
            bank_live0<=0; bank_live1<=0; bank_ready0<=0; bank_ready1<=0;
            current_active<=0; current_bank<=0; alloc_bank_reg<=0;
            drain_active<=0; drain_bank<=0; issue_idx<=0;
            in_stage_valid<=0; in_stage_first<=0; in_stage_last<=0;
            in_stage_mode<=0; in_stage_bank<=0;
            rq_stage_valid<=0;
            bank_psum0<=0; bank_psum1<=0;
            bank_spatial_tag0<=0; bank_spatial_tag1<=0;
            drain_spatial_tag_reg<=0;
            meta_pending_valid<=0; meta_pending_bank<=0;
            bank_meta_valid0<=0; bank_meta_valid1<=0;
            token_count_reg<=0; masked_mac_count_reg<=0; commit_count_reg<=0;
`ifndef SYNTHESIS
            stem_token_count_reg<=0; ds_token_count_reg<=0;
            stem_commit_count_reg<=0; ds_commit_count_reg<=0;
`endif
        end else begin
            if (input_fire) begin
                in_stage_valid<=1'b1;
                in_stage_first<=first_k; in_stage_last<=last_k;
                in_stage_mode<=mode_stem;
                in_stage_bank<=current_active ? current_bank : alloc_bank_reg;
                in_stage_pixel_mask<=pixel_mask; in_stage_cout_mask<=cout_mask;
                in_stage_pixel_base<=pixel_base; in_stage_cout_base<=cout_base;
                in_stage_bias<=bias_vec; in_stage_multiplier<=multiplier_vec;
                in_stage_shift<=shift_vec; in_stage_zp<=output_zero_point_int32;
                in_stage_min<=activation_min_int32; in_stage_max<=activation_max_int32;
                for (i=0;i<64;i=i+1) begin
                    if (mode_stem) begin
                        /* Stem cells are laid out as four pixel rows of
                         * sixteen output channels.  Every channel in a row
                         * sees the same pixel operand. */
                        in_stage_act[i] <= act_vec[((i/16)*8) +: 8];
                        in_stage_wgt[i] <= wgt_vec16[((i%16)*8) +: 8];
                    end else begin
                        in_stage_act[i] <= act_vec[((i/8)*8)+:8];
                        in_stage_wgt[i] <= wgt_vec16[(i%8)*8 +: 8];
                    end
                end
                token_count_reg<=token_count_reg+1'b1;
`ifndef SYNTHESIS
                if (mode_stem) stem_token_count_reg<=stem_token_count_reg+1'b1;
                else ds_token_count_reg<=ds_token_count_reg+1'b1;
`endif
                /* The common arithmetic island executes all 64 products;
                 * invalid lanes are masked only at commit.  The metric is
                 * retained as an ABI but deliberately omitted from the
                 * synthesis datapath. */
            end else begin
                in_stage_valid<=1'b0; in_stage_first<=1'b0; in_stage_last<=1'b0;
            end
            /* Commit the complete sideband bundle from a registered pending
             * entry.  Reservation below deliberately comes afterwards: if a
             * commit and a new reservation coincide, the new reservation
             * replaces the pending entry for the following clock while the
             * old entry is still written to its bank here. */
            if (meta_commit0) begin
                bank_mode0<=meta_pending_mode;
                bank_pixel_mask0<=meta_pending_pixel_mask;
                bank_cout_mask0<=meta_pending_cout_mask;
                bank_pixel_base0<=meta_pending_pixel_base;
                bank_spatial_tag0<=meta_pending_spatial_tag;
                bank_cout_base0<=meta_pending_cout_base;
                bank_bias0<=meta_pending_bias;
                bank_multiplier0<=meta_pending_multiplier;
                bank_shift0<=meta_pending_shift;
                bank_zp0<=meta_pending_zp;
                bank_min0<=meta_pending_min;
                bank_max0<=meta_pending_max;
                bank_meta_valid0<=1'b1;
            end
            if (meta_commit1) begin
                bank_mode1<=meta_pending_mode;
                bank_pixel_mask1<=meta_pending_pixel_mask;
                bank_cout_mask1<=meta_pending_cout_mask;
                bank_pixel_base1<=meta_pending_pixel_base;
                bank_spatial_tag1<=meta_pending_spatial_tag;
                bank_cout_base1<=meta_pending_cout_base;
                bank_bias1<=meta_pending_bias;
                bank_multiplier1<=meta_pending_multiplier;
                bank_shift1<=meta_pending_shift;
                bank_zp1<=meta_pending_zp;
                bank_min1<=meta_pending_min;
                bank_max1<=meta_pending_max;
                bank_meta_valid1<=1'b1;
            end
            if (meta_pending_valid && !reserve_fire)
                meta_pending_valid<=1'b0;

            if (reserve_fire) begin
                current_bank<=alloc_bank_reg; current_active<=!last_k;
                if (!alloc_bank_reg) begin
                    bank_live0<=1; bank_ready0<=last_k;
                    bank_meta_valid0<=0;
                    meta_pending_bank<=1'b0;
                end else begin
                    bank_live1<=1; bank_ready1<=last_k;
                    bank_meta_valid1<=0;
                    meta_pending_bank<=1'b1;
                end
                meta_pending_valid<=1'b1;
                meta_pending_mode<=mode_stem;
                meta_pending_pixel_mask<=pixel_mask;
                meta_pending_cout_mask<=cout_mask;
                meta_pending_pixel_base<=pixel_base;
                meta_pending_spatial_tag<=spatial_tag;
                meta_pending_cout_base<=cout_base;
                meta_pending_bias<=bias_vec;
                meta_pending_multiplier<=multiplier_vec;
                meta_pending_shift<=shift_vec;
                meta_pending_zp<=output_zero_point_int32;
                meta_pending_min<=activation_min_int32;
                meta_pending_max<=activation_max_int32;
            end
            if (mac_last_pending) begin
                if (in_stage_bank) begin
                    bank_psum1<=cell_sum_pack; bank_ready1<=1;
                    current_active<=0;
                    alloc_bank_reg<=0;
                end else begin
                    bank_psum0<=cell_sum_pack; bank_ready0<=1;
                    current_active<=0;
                    alloc_bank_reg<=1;
                end
            end
            if (drain_start) begin
                drain_active<=1; drain_bank<=drain_ready0 ? 0 : 1; issue_idx<=0;
                if (drain_ready0) begin
                    drain_psum<=bank_psum0; drain_mode<=bank_mode0;
                    drain_pixel_mask<=bank_pixel_mask0; drain_cout_mask<=bank_cout_mask0;
                    drain_pixel_base_reg<=bank_pixel_base0; drain_cout_base_reg<=bank_cout_base0;
                    drain_spatial_tag_reg<=bank_spatial_tag0;
                    drain_bias<=bank_bias0; drain_multiplier<=bank_multiplier0;
                    drain_shift<=bank_shift0; drain_zp<=bank_zp0;
                    drain_min<=bank_min0; drain_max<=bank_max0; bank_ready0<=0;
                end else begin
                    drain_psum<=bank_psum1; drain_mode<=bank_mode1;
                    drain_pixel_mask<=bank_pixel_mask1; drain_cout_mask<=bank_cout_mask1;
                    drain_pixel_base_reg<=bank_pixel_base1; drain_cout_base_reg<=bank_cout_base1;
                    drain_spatial_tag_reg<=bank_spatial_tag1;
                    drain_bias<=bank_bias1; drain_multiplier<=bank_multiplier1;
                    drain_shift<=bank_shift1; drain_zp<=bank_zp1;
                    drain_min<=bank_min1; drain_max<=bank_max1; bank_ready1<=0;
                end
            end else if (stage_load) begin
                rq_stage_valid<=1;
                rq_row <= {1'b0,issue_pixel_index};
                rq_beat <= drain_mode ? issue_idx[1] : issue_idx[0];
                rq_pixel_base<=drain_pixel_base_reg +
                    {8'd0,issue_pixel_index};
                rq_cout_base<=drain_cout_base_reg +
                    {6'd0,issue_group_index,2'd0};
                if (drain_mode) begin
                    rq_acc <= drain_psum[issue_acc_offset +: 128];
                    rq_bias <= drain_bias[issue_param_offset +: 128];
                    rq_multiplier <= drain_multiplier[issue_param_offset +: 128];
                    rq_shift <= drain_shift[issue_shift_offset +: 24];
                    rq_mask <= ({4{drain_pixel_mask[issue_pixel_index]}} &
                                drain_cout_mask[issue_cout_mask_offset +: 4]);
                end else begin
                    rq_acc <= drain_psum[issue_acc_offset +: 128];
                    rq_bias <= drain_bias[issue_param_offset +: 128];
                    rq_multiplier <= drain_multiplier[issue_param_offset +: 128];
                    rq_shift <= drain_shift[issue_shift_offset +: 24];
                    rq_mask <= ({4{drain_pixel_mask[issue_pixel_index]}} &
                                drain_cout_mask[issue_cout_mask_offset +: 4]);
                end
                if (issue_idx==6'd15) drain_active<=0;
                else issue_idx<=issue_idx+1'b1;
            end else if (stage_fire) rq_stage_valid<=0;

            if (drain_final_fire) begin
                if (drain_bank) begin
                    bank_live1<=0; bank_meta_valid1<=0;
                end else begin
                    bank_live0<=0; bank_meta_valid0<=0;
                end
                alloc_bank_reg<=drain_bank;
                commit_count_reg<=commit_count_reg+1'b1;
`ifndef SYNTHESIS
                if (drain_mode) stem_commit_count_reg<=stem_commit_count_reg+1'b1;
                else ds_commit_count_reg<=ds_commit_count_reg+1'b1;
`endif
            end
        end
    end
endmodule

/* The shared core owns one four-lane requant bank.  It is intentionally kept
 * local to this file so a resource probe need not elaborate the persistent
 * feed wrapper or either complete producer. */
module shared_requant4_wide (
    input wire clk, input wire rst_n, input wire valid_in, output wire ready_in,
    input wire signed [127:0] acc_vec, input wire signed [127:0] bias_vec,
    input wire signed [127:0] multiplier_vec, input wire [23:0] shift_vec,
    input wire [3:0] row_idx, input wire beat_idx,
    input wire [10:0] pixel_base, input wire [8:0] cout_base,
    input wire [3:0] lane_mask,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out, output wire valid_out,
    output wire [3:0] out_row_idx, output wire out_beat_idx,
    output wire [10:0] out_pixel_idx, output wire [8:0] out_channel_base,
    output wire [3:0] out_lane_mask, output wire signed [31:0] out_data,
    output wire busy
);
    wire [3:0] core_ready, core_valid;
    wire signed [7:0] core_data [0:3];
    wire advance = &core_ready;
    assign ready_in = rst_n && advance;
    wire core_input_valid = valid_in && ready_in;
    assign valid_out = &core_valid;
    assign out_data = {core_data[3],core_data[2],core_data[1],core_data[0]};
    reg [9:0] tag_valid;
    reg [3:0] row_tag [0:9]; reg beat_tag [0:9];
    reg [10:0] pixel_tag [0:9]; reg [8:0] cout_tag [0:9]; reg [3:0] mask_tag [0:9];
    genvar q;
    generate for (q=0;q<4;q=q+1) begin : gen_shared_rq
        requant_activation_unit #(.HOLD_BUFFER((q == 0) ? 1 : 0)) u_core (
            .clk(clk), .rst_n(rst_n), .valid_in(core_input_valid), .ready_in(core_ready[q]),
            .acc_int32(acc_vec[(q*32)+:32]), .bias_int32(bias_vec[(q*32)+:32]),
            .multiplier_int32(multiplier_vec[(q*32)+:32]), .shift(shift_vec[(q*6)+:6]),
            .output_zero_point_int32(output_zero_point_int32),
            .activation_min_int32(activation_min_int32), .activation_max_int32(activation_max_int32),
            .ready_out(ready_out), .valid_out(core_valid[q]), .output_int8(core_data[q])
        );
    end endgenerate
    assign out_row_idx=row_tag[9]; assign out_beat_idx=beat_tag[9];
    assign out_pixel_idx=pixel_tag[9]; assign out_channel_base=cout_tag[9];
    assign out_lane_mask=mask_tag[9]; assign busy=valid_out | (|tag_valid);
    integer t;
    always @(posedge clk) begin
        if (!rst_n) begin
            tag_valid<=0;
        end else if (advance) begin
            tag_valid[0]<=core_input_valid;
            if (core_input_valid) begin
                row_tag[0]<=row_idx; beat_tag[0]<=beat_idx;
                pixel_tag[0]<=pixel_base; cout_tag[0]<=cout_base; mask_tag[0]<=lane_mask;
            end
            for (t=1;t<10;t=t+1) begin
                tag_valid[t]<=tag_valid[t-1];
                if (tag_valid[t-1]) begin
                    row_tag[t]<=row_tag[t-1]; beat_tag[t]<=beat_tag[t-1];
                    pixel_tag[t]<=pixel_tag[t-1]; cout_tag[t]<=cout_tag[t-1];
                    mask_tag[t]<=mask_tag[t-1];
                end
            end
        end
    end
endmodule

`default_nettype wire
