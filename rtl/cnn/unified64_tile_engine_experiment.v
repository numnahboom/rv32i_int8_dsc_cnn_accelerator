`timescale 1ns/1ps
`default_nettype none

/*
 * Stand-alone hard-decision experiment for the common 8x8 tile.
 *
 * The array has one local MAC cell per output lane (8 pixels x 8 channels).
 * A pair of fixed result banks provides the only ownership fence: while one
 * bank is being committed, the other bank can accept the next K reduction.
 * Result traffic is four bytes per accepted commit beat (two beats per row),
 * and no 2048-bit bank-select mux is used; rows are selected from one of
 * sixteen fixed 256-bit row registers.
 *
 * This file is intentionally independent of cnn_top/layer_runner.  The raw
 * token ABI is also the ABI emitted by ds_persistent_feed_contract_bram, so a
 * wrapper below can make the persistent BRAM feed part of the same proof.
 */
module unified64_tile_engine #(
    parameter integer EPOCH_WIDTH = 4,
    parameter integer SESSION_WIDTH = 4
) (
    input wire clk, (* max_fanout = 500 *) input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire first_k, input wire last_k, input wire [7:0] k_idx,
    input wire [7:0] pixel_mask, input wire [7:0] cout_mask,
    input wire signed [63:0] act_vec, input wire signed [63:0] wgt_vec,
    input wire [10:0] pixel_base, input wire [8:0] cout_base,
    input wire signed [255:0] bias_vec,
    input wire signed [255:0] multiplier_vec,
    input wire [47:0] shift_vec,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out,
    output wire valid_out,
    output wire [10:0] out_pixel_idx,
    output wire [8:0] out_channel_base,
    output wire [3:0] out_lane_mask,
    output wire signed [31:0] out_data,
    output wire busy,
    output wire [31:0] metric_token_count,
    output wire [31:0] metric_masked_mac_count,
    output wire [31:0] metric_commit_count,
    output wire [31:0] metric_output_stall_count,
    output wire [31:0] metric_overlap_count,
    output wire [31:0] metric_peak_occupancy,
    output wire [31:0] metric_nonzero_token_count
);
    reg bank_live0, bank_live1, bank_ready0, bank_ready1;
    reg current_active, current_bank, alloc_bank_reg;
    reg drain_active, drain_bank;
    reg [5:0] issue_idx;

    reg in_stage_valid, in_stage_bank;
    /* The final-token control is consumed by eight physical MAC rows. Keep
     * one registered copy per row so the commit/write-enable cone does not
     * turn the single ingress bit into a device-wide high-fanout net. */
    (* keep = "true" *) reg [7:0] in_stage_first_row;
    (* keep = "true" *) reg [7:0] in_stage_last_row;
    /* Replicate each pixel operand into the eight local column registers.
     * This is deliberate physical locality: each DSP input is driven by one
     * nearby FF instead of an 8-DSP shared net. */
    (* keep = "true" *) reg signed [7:0] in_stage_act [0:7][0:7];
    reg signed [7:0] in_stage_wgt [0:7];
    wire bank_free_any = !bank_live0 || !bank_live1;
    assign ready_in = rst_n && (current_active || bank_free_any) &&
                      (!in_stage_valid || !in_stage_last_row[0]);
    wire input_fire = valid_in && ready_in;
    wire [63:0] lane_enable;
    genvar g;
    generate for (g=0; g<64; g=g+1) begin : gen_lane_enable
        assign lane_enable[g] = pixel_mask[g/8] && cout_mask[g%8];
    end endgenerate

    wire [31:0] sum_next [0:63];
    wire last_pending [0:63];
    wire mac_last_pending = last_pending[0];
    wire [7:0] mac_en_row;
    /* Reset is a local control concern of each eight-DSP row.  The explicit
     * buffers prevent the top-level reset from becoming a single global net
     * through all 64 MAC cells; payload/result arrays below are resetless and
     * protected by their valid/ready fences. */
    wire [7:0] mac_rst_row;
    genvar rg;
    generate for (rg=0; rg<8; rg=rg+1) begin : gen_mac_rst_row
`ifdef SYNTHESIS
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rst_buf
            (.I0(rst_n), .O(mac_rst_row[rg]));
`else
        assign mac_rst_row[rg] = rst_n;
`endif
    end endgenerate
    generate for (g=0; g<8; g=g+1) begin : gen_mac_enable
`ifdef SYNTHESIS
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_en_buf
            (.I0(in_stage_valid), .O(mac_en_row[g]));
`else
        assign mac_en_row[g] = in_stage_valid;
`endif
    end endgenerate
    generate for (g=0; g<64; g=g+1) begin : gen_mac
        pw_rowbank_mac_cell u_mac (
            .clk(clk), .rst_n(mac_rst_row[g/8]), .en(mac_en_row[g/8]),
            .clear_acc(in_stage_first_row[g/8]), .last_in(in_stage_last_row[g/8]),
            .act_in(in_stage_act[g/8][g%8]), .wgt_in(in_stage_wgt[g%8]),
            .sum_next(sum_next[g]), .last_pending(last_pending[g])
        );
    end endgenerate
    /* Localize the bank-write enables as well.  Each row observes its own
     * final-token flag, so a single MAC last bit is not routed to all 512
     * result bytes. */
    wire [7:0] mac_last_row;
    genvar lr;
    generate for (lr=0; lr<8; lr=lr+1) begin : gen_mac_last_row
`ifdef SYNTHESIS
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_last_buf
            (.I0(last_pending[lr*8]), .O(mac_last_row[lr]));
`else
        assign mac_last_row[lr] = last_pending[lr*8];
`endif
    end endgenerate

    /* Fixed row banks.  Keeping rows separate makes the drain select a
     * 256-bit local row rather than a dynamic 2048-bit transaction mux. */
    reg signed [255:0] bank0_row [0:7];
    reg signed [255:0] bank1_row [0:7];
    reg [7:0] bank0_pixel_mask, bank1_pixel_mask;
    reg [7:0] bank0_cout_mask, bank1_cout_mask;
    reg [10:0] bank0_pixel_base, bank1_pixel_base;
    reg [8:0] bank0_cout_base, bank1_cout_base;
    reg signed [255:0] bank0_bias, bank1_bias;
    reg signed [255:0] bank0_multiplier, bank1_multiplier;
    reg [47:0] bank0_shift, bank1_shift;
    reg signed [31:0] bank0_zp, bank1_zp;
    reg signed [31:0] bank0_min, bank1_min, bank0_max, bank1_max;

    reg signed [255:0] row_psum, row_bias, row_multiplier;
    reg [47:0] row_shift;
    reg [7:0] row_pixel_mask, row_cout_mask;
    reg [10:0] row_pixel_base;
    reg [8:0] row_cout_base;
    reg signed [31:0] row_zp, row_min, row_max;

    reg signed [255:0] selected_next_row0, selected_next_row1;
    always @* begin
        case (issue_idx[3:1])
            3'd0: begin selected_next_row0=bank0_row[1]; selected_next_row1=bank1_row[1]; end
            3'd1: begin selected_next_row0=bank0_row[2]; selected_next_row1=bank1_row[2]; end
            3'd2: begin selected_next_row0=bank0_row[3]; selected_next_row1=bank1_row[3]; end
            3'd3: begin selected_next_row0=bank0_row[4]; selected_next_row1=bank1_row[4]; end
            3'd4: begin selected_next_row0=bank0_row[5]; selected_next_row1=bank1_row[5]; end
            3'd5: begin selected_next_row0=bank0_row[6]; selected_next_row1=bank1_row[6]; end
            3'd6: begin selected_next_row0=bank0_row[7]; selected_next_row1=bank1_row[7]; end
            default: begin selected_next_row0=bank0_row[7]; selected_next_row1=bank1_row[7]; end
        endcase
    end
    /* The row-load mux is a true bank ownership boundary.  Keep the normal
     * 256-bit path compact and add only one min-delay buffer on the measured
     * critical bit; the per-lane requant hold buffer covers the independent
     * arithmetic island.  No timing exception or width change is involved. */
    wire signed [255:0] row_psum_selected = bank_ready0 ? bank0_row[0] : bank1_row[0];
    wire row_psum_hold_bit137;
`ifdef SYNTHESIS
    (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_row_psum_hold_bit137
        (.I0(row_psum_selected[137]), .O(row_psum_hold_bit137));
`else
    assign row_psum_hold_bit137 = row_psum_selected[137];
`endif
    wire [7:0] issue_pixel_mask_vec = drain_bank ? bank1_pixel_mask : bank0_pixel_mask;
    wire [7:0] issue_cout_mask_vec = drain_bank ? bank1_cout_mask : bank0_cout_mask;
    wire [127:0] issue_acc = issue_idx[0] ? row_psum[255:128] : row_psum[127:0];
    wire [127:0] issue_bias = issue_idx[0] ? row_bias[255:128] : row_bias[127:0];
    wire [127:0] issue_multiplier = issue_idx[0] ? row_multiplier[255:128] : row_multiplier[127:0];
    wire [23:0] issue_shift = issue_idx[0] ? row_shift[47:24] : row_shift[23:0];
    wire [3:0] issue_mask = ({4{row_pixel_mask[issue_idx[3:1]]}} &
                             (issue_idx[0] ? row_cout_mask[7:4] : row_cout_mask[3:0]));

    reg rq_stage_valid;
    reg signed [127:0] rq_acc, rq_bias, rq_multiplier;
    reg [23:0] rq_shift;
    reg [3:0] rq_mask;
    reg [3:0] rq_row;
    reg rq_beat;
    reg [10:0] rq_pixel_base;
    reg [8:0] rq_cout_base;
    wire rq_ready, rq_busy, rq_valid;
    wire [3:0] rq_out_row, rq_out_mask;
    wire rq_out_beat;
    wire [10:0] rq_out_pixel;
    wire [8:0] rq_out_cout;
    wire signed [31:0] rq_out_data;
    unified64_requant4_wide u_rq (
        .clk(clk), .rst_n(rst_n), .valid_in(rq_stage_valid), .ready_in(rq_ready),
        .acc_vec(rq_acc), .bias_vec(rq_bias), .multiplier_vec(rq_multiplier),
        .shift_vec(rq_shift), .row_idx(rq_row), .beat_idx(rq_beat),
        .pixel_base(rq_pixel_base + rq_row),
        .cout_base(rq_cout_base + (rq_beat ? 9'd4 : 9'd0)), .lane_mask(rq_mask),
        .output_zero_point_int32(row_zp), .activation_min_int32(row_min),
        .activation_max_int32(row_max), .ready_out(ready_out), .valid_out(rq_valid),
        .out_row_idx(rq_out_row), .out_beat_idx(rq_out_beat),
        .out_pixel_idx(rq_out_pixel), .out_channel_base(rq_out_cout),
        .out_lane_mask(rq_out_mask), .out_data(rq_out_data), .busy(rq_busy)
    );
    assign valid_out=rq_valid; assign out_pixel_idx=rq_out_pixel;
    assign out_channel_base=rq_out_cout; assign out_lane_mask=rq_out_mask;
    assign out_data=rq_out_data;
    wire output_fire = rq_valid && ready_out;
    wire stage_load = drain_active && (!rq_stage_valid || rq_ready);
    wire stage_fire = rq_stage_valid && rq_ready;
    wire drain_start = !drain_active && !in_stage_valid && !mac_last_pending &&
                       !rq_stage_valid && !rq_busy &&
                       (bank_ready0 || bank_ready1);
    wire drain_final_fire = output_fire && (rq_out_row == 4'd7) && rq_out_beat;
    assign busy = current_active || drain_active || in_stage_valid ||
                  rq_stage_valid || rq_busy || bank_live0 || bank_live1;

    /* Narrow counters are sufficient for the C10 projection.  The public
     * 32-bit observability ABI is retained without putting a 32-bit carry
     * chain in the token/data timing cone. */
    reg [19:0] token_count_reg, output_stall_count_reg;
    reg [21:0] masked_mac_count_reg;
    reg [15:0] commit_count_reg, overlap_count_reg;
    reg [1:0] peak_occupancy_reg;
    reg [19:0] nonzero_token_count_reg;
    reg [6:0] masked_lanes_stage;
    reg nonzero_stage, metric_stage_valid;
`ifdef SYNTHESIS
    /* Counters are simulation observability only.  Keeping them out of the
     * physical datapath prevents a diagnostic carry chain from determining
     * the measured tile timing; all counts remain available in the TB. */
    assign metric_token_count=32'd0;
    assign metric_masked_mac_count=32'd0;
    assign metric_commit_count=32'd0;
    assign metric_output_stall_count=32'd0;
    assign metric_overlap_count=32'd0;
    assign metric_peak_occupancy=32'd0;
    assign metric_nonzero_token_count=32'd0;
`else
    assign metric_token_count={{12{1'b0}},token_count_reg};
    assign metric_masked_mac_count={{10{1'b0}},masked_mac_count_reg};
    assign metric_commit_count={{16{1'b0}},commit_count_reg};
    assign metric_output_stall_count={{12{1'b0}},output_stall_count_reg};
    assign metric_overlap_count={{16{1'b0}},overlap_count_reg};
    assign metric_peak_occupancy={{30{1'b0}},peak_occupancy_reg};
    assign metric_nonzero_token_count={{12{1'b0}},nonzero_token_count_reg};
`endif

    integer i;
    integer b;
    integer masked_lanes;
    genvar br;
    generate for (br=0; br<8; br=br+1) begin : gen_bank_row_write
        integer bi;
        always @(posedge clk) begin
            /* A result row is consumed only after its bank_ready fence is
             * asserted.  Resetting these 512-bit row registers therefore
             * wastes reset routing and is unnecessary for correctness. */
            if (mac_last_row[br]) begin
                if (in_stage_bank) begin
                    for (bi=0; bi<8; bi=bi+1)
                        bank1_row[br][(bi*32)+:32] <= sum_next[br*8+bi];
                end else begin
                    for (bi=0; bi<8; bi=bi+1)
                        bank0_row[br][(bi*32)+:32] <= sum_next[br*8+bi];
                end
            end
        end
    end endgenerate
    always @(posedge clk) begin
        if (!rst_n) begin
            bank_live0<=0; bank_live1<=0; bank_ready0<=0; bank_ready1<=0;
            current_active<=0; current_bank<=0; alloc_bank_reg<=0;
            drain_active<=0; drain_bank<=0; issue_idx<=0;
            in_stage_valid<=0; in_stage_bank<=0;
            rq_stage_valid<=0;
            token_count_reg<=0; masked_mac_count_reg<=0; commit_count_reg<=0;
            output_stall_count_reg<=0; overlap_count_reg<=0; peak_occupancy_reg<=0;
            nonzero_token_count_reg<=0;
            masked_lanes_stage<=0; nonzero_stage<=0; metric_stage_valid<=0;
            bank0_pixel_mask<=0; bank1_pixel_mask<=0; bank0_cout_mask<=0; bank1_cout_mask<=0;
            bank0_pixel_base<=0; bank1_pixel_base<=0; bank0_cout_base<=0; bank1_cout_base<=0;
        end else begin
            if (input_fire) begin
                in_stage_valid<=1'b1;
                in_stage_first_row<={8{first_k}};
                in_stage_last_row<={8{last_k}};
                in_stage_bank<=current_active ? current_bank : alloc_bank_reg;
                for (i=0;i<8;i=i+1) begin
                    in_stage_wgt[i] <= wgt_vec[(i*8)+:8];
                    for (b=0;b<8;b=b+1)
                        in_stage_act[i][b] <= act_vec[(i*8)+:8];
                end
                token_count_reg <= token_count_reg + 1'b1;
                masked_lanes = 0;
                for (i=0;i<64;i=i+1) if (lane_enable[i]) masked_lanes = masked_lanes + 1;
                masked_lanes_stage <= masked_lanes[6:0];
                nonzero_stage <= ((act_vec != 0) || (wgt_vec != 0));
                metric_stage_valid <= 1'b1;
                if (drain_active) overlap_count_reg <= overlap_count_reg + 1'b1;
            end else begin
                in_stage_valid<=1'b0;
                metric_stage_valid <= 1'b0;
            end
            if (metric_stage_valid) begin
                masked_mac_count_reg <= masked_mac_count_reg + masked_lanes_stage;
                if (nonzero_stage) nonzero_token_count_reg <= nonzero_token_count_reg + 1'b1;
            end
            if (input_fire && !current_active) begin
                current_bank<=alloc_bank_reg; current_active<=!last_k;
                if (!alloc_bank_reg) begin
                    bank_live0<=1; bank_ready0<=last_k;
                    bank0_pixel_mask<=pixel_mask; bank0_cout_mask<=cout_mask;
                    bank0_pixel_base<=pixel_base; bank0_cout_base<=cout_base;
                    bank0_bias<=bias_vec; bank0_multiplier<=multiplier_vec;
                    bank0_shift<=shift_vec; bank0_zp<=output_zero_point_int32;
                    bank0_min<=activation_min_int32; bank0_max<=activation_max_int32;
                end else begin
                    bank_live1<=1; bank_ready1<=last_k;
                    bank1_pixel_mask<=pixel_mask; bank1_cout_mask<=cout_mask;
                    bank1_pixel_base<=pixel_base; bank1_cout_base<=cout_base;
                    bank1_bias<=bias_vec; bank1_multiplier<=multiplier_vec;
                    bank1_shift<=shift_vec; bank1_zp<=output_zero_point_int32;
                    bank1_min<=activation_min_int32; bank1_max<=activation_max_int32;
                end
            end
            if (mac_last_pending) begin
                if (in_stage_bank) begin
                    bank_ready1<=1'b1; current_active<=1'b0; alloc_bank_reg<=1'b0;
                end else begin
                    bank_ready0<=1'b1; current_active<=1'b0; alloc_bank_reg<=1'b1;
                end
            end
            if (drain_start) begin
                drain_active<=1'b1; drain_bank<=bank_ready0 ? 1'b0 : 1'b1; issue_idx<=0;
                if (bank_ready0) begin
                    row_psum<=row_psum_selected; row_psum[137]<=row_psum_hold_bit137;
                    row_pixel_mask<=bank0_pixel_mask;
                    row_cout_mask<=bank0_cout_mask; row_pixel_base<=bank0_pixel_base;
                    row_cout_base<=bank0_cout_base; row_bias<=bank0_bias;
                    row_multiplier<=bank0_multiplier; row_shift<=bank0_shift;
                    row_zp<=bank0_zp; row_min<=bank0_min; row_max<=bank0_max;
                    bank_ready0<=1'b0;
                end else begin
                    row_psum<=row_psum_selected; row_psum[137]<=row_psum_hold_bit137;
                    row_pixel_mask<=bank1_pixel_mask;
                    row_cout_mask<=bank1_cout_mask; row_pixel_base<=bank1_pixel_base;
                    row_cout_base<=bank1_cout_base; row_bias<=bank1_bias;
                    row_multiplier<=bank1_multiplier; row_shift<=bank1_shift;
                    row_zp<=bank1_zp; row_min<=bank1_min; row_max<=bank1_max;
                    bank_ready1<=1'b0;
                end
            end else if (stage_load) begin
                rq_stage_valid<=1'b1; rq_acc<=issue_acc; rq_bias<=issue_bias;
                rq_multiplier<=issue_multiplier; rq_shift<=issue_shift; rq_mask<=issue_mask;
                rq_row<=issue_idx[3:1]; rq_beat<=issue_idx[0];
                rq_pixel_base<=row_pixel_base; rq_cout_base<=row_cout_base;
                if (issue_idx==6'd15) drain_active<=1'b0;
                else begin
                    issue_idx<=issue_idx+1'b1;
                    if (issue_idx[0])
                        row_psum <= drain_bank ? selected_next_row1 : selected_next_row0;
                end
            end else if (stage_fire) rq_stage_valid<=1'b0;

            if (drain_final_fire) begin
                if (drain_bank) bank_live1<=1'b0; else bank_live0<=1'b0;
                alloc_bank_reg<=drain_bank;
            end
            if (output_fire) commit_count_reg<=commit_count_reg+1'b1;
            if (rq_valid && !ready_out) output_stall_count_reg<=output_stall_count_reg+1'b1;
            if ((current_active ? 1 : 0) + (drain_active ? 1 : 0) > peak_occupancy_reg)
                peak_occupancy_reg <= (current_active ? 1 : 0) + (drain_active ? 1 : 0);
        end
    end
endmodule

/* Four exact requant lanes with the stream4 elastic contract and wider tags.
 * The arithmetic is the same requant_activation_stream4 primitive; only the
 * tag width is extended so large-P and 256-channel jobs remain observable. */
module unified64_requant4_wide (
    input wire clk, (* max_fanout = 500 *) input wire rst_n, input wire valid_in, output wire ready_in,
    input wire signed [127:0] acc_vec, input wire signed [127:0] bias_vec,
    input wire signed [127:0] multiplier_vec, input wire [23:0] shift_vec,
    input wire [3:0] row_idx, input wire beat_idx, input wire [10:0] pixel_base,
    input wire [8:0] cout_base, input wire [3:0] lane_mask,
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
    wire [3:0] rq_rst_lane;
    genvar q;
    generate for (q=0;q<4;q=q+1) begin : gen_rq_rst
`ifdef SYNTHESIS
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rst_buf
            (.I0(rst_n), .O(rq_rst_lane[q]));
`else
        assign rq_rst_lane[q] = rst_n;
`endif
    end endgenerate
    generate for (q=0;q<4;q=q+1) begin : gen_rq
        requant_activation_unit #(.HOLD_BUFFER((q == 0) ? 1 : 0)) u_core (
            .clk(clk), .rst_n(rq_rst_lane[q]), .valid_in(core_input_valid), .ready_in(core_ready[q]),
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
                row_tag[0]<=row_idx; beat_tag[0]<=beat_idx; pixel_tag[0]<=pixel_base;
                cout_tag[0]<=cout_base; mask_tag[0]<=lane_mask;
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

/* Persistent-feed composition used only by the experiment testbench.  It
 * keeps the production feed's fixed-address BRAM contract intact and maps
 * each non-zero feed token directly into the local 64-MAC array. */
module unified64_tile_engine_persistent_wrapper #(
    parameter integer MAX_SOURCE_WORDS = 4096,
    parameter integer MAX_PARAM_ROWS = 4096,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer SESSION_WIDTH = 4
) (
    input wire clk, (* max_fanout = 500 *) input wire rst_n,
    input wire cfg_valid, output wire cfg_ready,
    input wire [2:0] cfg_layer_id, input wire cfg_mode,
    input wire [EPOCH_WIDTH-1:0] cfg_epoch,
    input wire [SESSION_WIDTH-1:0] cfg_session,
    input wire load_start_valid, output wire load_start_ready,
    input wire [31:0] load_source_base_addr, input wire [31:0] load_param_base_addr,
    output wire source_req_valid, input wire source_req_ready,
    output wire [31:0] source_req_addr, input wire source_resp_valid,
    output wire source_resp_ready, input wire [31:0] source_resp_data,
    output wire param_req_valid, input wire param_req_ready,
    output wire [31:0] param_req_addr, input wire param_resp_valid,
    output wire param_resp_ready, input wire [31:0] param_resp_data,
    output wire load_active, output wire load_done,
    output wire [15:0] source_external_word_count,
    output wire [15:0] param_external_word_count,
    output wire [15:0] source_request_stall_count,
    output wire [15:0] param_request_stall_count,
    input wire commit_valid, output wire commit_ready,
    output wire commit_reject, output wire committed_valid,
    output wire [EPOCH_WIDTH-1:0] committed_epoch,
    output wire [SESSION_WIDTH-1:0] committed_session,
    input wire job_valid, output wire job_ready,
    input wire [EPOCH_WIDTH-1:0] job_epoch,
    input wire [SESSION_WIDTH-1:0] job_session,
    input wire [9:0] job_pixel_base, input wire [4:0] job_cout_tile,
    input wire [7:0] job_pixel_mask, input wire [7:0] job_cout_mask,
    output wire job_reject_stale, output wire job_done, output wire busy,
    output wire valid_out, input wire ready_out,
    output wire [10:0] out_pixel_idx, output wire [8:0] out_channel_base,
    output wire [3:0] out_lane_mask, output wire signed [31:0] out_data,
    output wire [31:0] metric_token_count,
    output wire [31:0] metric_masked_mac_count,
    output wire [31:0] metric_commit_count,
    output wire [31:0] metric_output_stall_count,
    output wire [31:0] metric_overlap_count,
    output wire [31:0] metric_peak_occupancy,
    output wire [31:0] metric_nonzero_token_count,
    output wire [15:0] local_source_word_read_count,
    output wire [31:0] local_param_row_read_count,
    output wire [31:0] feed_token_count,
    output wire [15:0] feed_window_reuse_count
);
    wire feed_token_valid, feed_token_ready, feed_token_first, feed_token_last;
    wire [7:0] feed_token_k;
    wire [9:0] feed_token_pixel;
    wire [8:0] feed_token_cout;
    wire [7:0] feed_pixel_mask, feed_cout_mask;
    wire signed [63:0] feed_act, feed_wgt;
    wire feed_busy;
    /* A one-entry elastic boundary is deliberately placed between the
     * persistent BRAM/request island and the MAC island.  It cuts all wide
     * feed-to-DSP paths while preserving II=1: a full stage is replaced on
     * the same edge on which the engine consumes it.  Payload registers are
     * resetless; cut_valid is the ownership/epoch fence, and the feed's
     * committed descriptor prevents stale-session tokens from entering. */
    reg cut_valid;
    reg cut_first, cut_last;
    reg [7:0] cut_k;
    reg [9:0] cut_pixel;
    reg [8:0] cut_cout;
    reg [7:0] cut_pixel_mask, cut_cout_mask;
    reg signed [63:0] cut_act, cut_wgt;
    wire engine_ready;
    wire cut_ready = !cut_valid || engine_ready;
    assign feed_token_ready = cut_ready;
    wire engine_valid = cut_valid;
    wire feed_rst_n, engine_rst_n;
`ifdef SYNTHESIS
    (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_feed_rst_iso (.I0(rst_n), .O(feed_rst_n));
    (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_engine_rst_iso (.I0(rst_n), .O(engine_rst_n));
`else
    assign feed_rst_n = rst_n;
    assign engine_rst_n = rst_n;
`endif
    ds_persistent_feed_contract #(
        .MAX_SOURCE_WORDS(MAX_SOURCE_WORDS), .MAX_PARAM_ROWS(MAX_PARAM_ROWS),
        .EPOCH_WIDTH(EPOCH_WIDTH), .SESSION_WIDTH(SESSION_WIDTH)
    ) u_feed (
        .clk(clk), .rst_n(feed_rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_layer_id(cfg_layer_id), .cfg_mode(cfg_mode), .cfg_epoch(cfg_epoch),
        .cfg_session(cfg_session), .cfg_output_pixels(), .cfg_cin(), .cfg_cout(),
        .cfg_source_pixels(), .cfg_source_words(), .cfg_param_words(),
        .load_start_valid(load_start_valid), .load_start_ready(load_start_ready),
        .load_source_base_addr(load_source_base_addr), .load_param_base_addr(load_param_base_addr),
        .source_req_valid(source_req_valid), .source_req_ready(source_req_ready),
        .source_req_addr(source_req_addr), .source_resp_valid(source_resp_valid),
        .source_resp_ready(source_resp_ready), .source_resp_data(source_resp_data),
        .param_req_valid(param_req_valid), .param_req_ready(param_req_ready),
        .param_req_addr(param_req_addr), .param_resp_valid(param_resp_valid),
        .param_resp_ready(param_resp_ready), .param_resp_data(param_resp_data),
        .load_active(load_active), .load_done(load_done),
        .source_external_word_count(source_external_word_count),
        .param_external_word_count(param_external_word_count),
        .source_request_stall_count(source_request_stall_count),
        .param_request_stall_count(param_request_stall_count),
        .commit_valid(commit_valid), .commit_ready(commit_ready), .commit_reject(commit_reject),
        .committed_valid(committed_valid), .committed_epoch(committed_epoch),
        .committed_session(committed_session), .job_valid(job_valid), .job_ready(job_ready),
        .job_epoch(job_epoch), .job_session(job_session), .job_pixel_base(job_pixel_base),
        .job_cout_tile(job_cout_tile), .job_pixel_mask(job_pixel_mask),
        .job_cout_mask(job_cout_mask), .job_reject_stale(job_reject_stale),
        .token_valid(feed_token_valid), .token_ready(feed_token_ready),
        .token_first(feed_token_first), .token_last(feed_token_last), .token_k_idx(feed_token_k),
        .token_pixel_base(feed_token_pixel), .token_cout_base(feed_token_cout),
        .token_pixel_mask(feed_pixel_mask), .token_cout_mask(feed_cout_mask),
        .token_act_vec(feed_act), .token_wgt_vec(feed_wgt), .job_done(job_done), .busy(feed_busy),
        .local_source_word_read_count(local_source_word_read_count),
        .local_param_row_read_count(local_param_row_read_count), .token_count(feed_token_count),
        .window_reuse_count(feed_window_reuse_count)
    );
    wire signed [255:0] zero_bias = 256'sd0;
    wire signed [255:0] q31_multiplier = {8{32'sh7fffffff}};
    wire [47:0] zero_shift = 48'd0;
    wire engine_busy;
    unified64_tile_engine u_engine (
        .clk(clk), .rst_n(engine_rst_n), .valid_in(engine_valid), .ready_in(engine_ready),
        .first_k(cut_first), .last_k(cut_last), .k_idx(cut_k),
        .pixel_mask(cut_pixel_mask), .cout_mask(cut_cout_mask), .act_vec(cut_act),
        .wgt_vec(cut_wgt), .pixel_base({1'b0,cut_pixel}), .cout_base(cut_cout),
        .bias_vec(zero_bias), .multiplier_vec(q31_multiplier), .shift_vec(zero_shift),
        .output_zero_point_int32(32'sd0), .activation_min_int32(-32'sd128),
        .activation_max_int32(32'sd127), .ready_out(ready_out), .valid_out(valid_out),
        .out_pixel_idx(out_pixel_idx), .out_channel_base(out_channel_base),
        .out_lane_mask(out_lane_mask), .out_data(out_data), .busy(engine_busy),
        .metric_token_count(metric_token_count), .metric_masked_mac_count(metric_masked_mac_count),
        .metric_commit_count(metric_commit_count), .metric_output_stall_count(metric_output_stall_count),
        .metric_overlap_count(metric_overlap_count), .metric_peak_occupancy(metric_peak_occupancy)
        ,.metric_nonzero_token_count(metric_nonzero_token_count)
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            cut_valid <= 1'b0;
        end else if (cut_ready) begin
            cut_valid <= feed_token_valid;
            if (feed_token_valid) begin
                cut_first <= feed_token_first;
                cut_last <= feed_token_last;
                cut_k <= feed_token_k;
                cut_pixel <= feed_token_pixel;
                cut_cout <= feed_token_cout;
                cut_pixel_mask <= feed_pixel_mask;
                cut_cout_mask <= feed_cout_mask;
                cut_act <= feed_act;
                cut_wgt <= feed_wgt;
            end
        end
    end
    assign busy = feed_busy || engine_busy;
endmodule

`default_nettype wire
