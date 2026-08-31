`timescale 1ns/1ps
`default_nettype none

/*
 * Non-production end-to-end spatial screen.
 *
 * This shell is intentionally a narrow integration experiment.  Two 4x8
 * word-window DW producer islands feed one shared stream4/requant island and
 * an eight-row BRAM scratch image.  A row is transferred to the
 * paired-half ownership bank through its acquire/write/commit fence while
 * the packed row-bank PW consumer may drain the other bank.  The production
 * runner and cnn_top are not instantiated here.
 *
 * A producer command computes one 4x8 half and one 16-channel DW group.  The
 * stream packer retains the first eight lanes (the paired scratch ABI is
 * 4-pixel by 8-channel) and records both 4-pixel halves for every row.  The
 * second producer is offset by four rows.  Consequently all 8x8 rows and all
 * K groups are retained; no arithmetic result is dropped.  A transfer_start
 * command selects one completed row and moves it to the packed consumer's
 * scratch bank.  This explicit row command keeps the fence visible for
 * timing/traffic measurements and permits a consumer job on the opposite
 * bank to overlap the next DW producer job.
 */
module ds_word_window_dw_pw_pair_scratch_pipeline #(
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer MAX_GROUPS = 16,
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer FIFO_DEPTH = 8,
    parameter integer SESSION_WIDTH = 2,
    parameter integer GROUP_WIDTH = 5
) (
    input wire clk, input wire rst_n,

    /* Independent source-word fills for the two adjacent 4x8 halves. */
    input wire fill0_start_valid, output wire fill0_start_ready,
    input wire fill0_start_bank, input wire [EPOCH_WIDTH-1:0] fill0_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill0_start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] fill0_start_word_count,
    output wire fill0_done_valid, input wire fill0_done_ready,
    output wire fill0_done_bank, output wire [EPOCH_WIDTH-1:0] fill0_done_epoch,
    output wire fill0_mem_req_valid, input wire fill0_mem_req_ready,
    output wire [ADDR_WIDTH-1:0] fill0_mem_req_addr,
    input wire fill0_mem_resp_valid, input wire [31:0] fill0_mem_resp_data,
    input wire fill1_start_valid, output wire fill1_start_ready,
    input wire fill1_start_bank, input wire [EPOCH_WIDTH-1:0] fill1_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill1_start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] fill1_start_word_count,
    output wire fill1_done_valid, input wire fill1_done_ready,
    output wire fill1_done_bank, output wire [EPOCH_WIDTH-1:0] fill1_done_epoch,
    output wire fill1_mem_req_valid, input wire fill1_mem_req_ready,
    output wire [ADDR_WIDTH-1:0] fill1_mem_req_addr,
    input wire fill1_mem_resp_valid, input wire [31:0] fill1_mem_resp_data,

    /* One broadcast parameter write is captured by both DW islands. */
    input wire cfg_valid, output wire cfg_ready, input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,

    /* One-group commands for the upper and lower producer islands. */
    input wire dw0_job_valid, output wire dw0_job_ready,
    input wire dw0_source_bank, input wire [EPOCH_WIDTH-1:0] dw0_source_epoch,
    input wire [ADDR_WIDTH-1:0] dw0_source_base_addr,
    input wire [15:0] dw0_source_lane_mask, input wire [1:0] dw0_source_stride,
    input wire [7:0] dw0_footprint_height, input wire [7:0] dw0_footprint_width,
    input wire [7:0] dw0_footprint_pitch, input wire [2:0] dw0_group,
    input wire [3:0] dw0_group_count, input wire [31:0] dw0_zp,
    input wire [31:0] dw0_min, input wire [31:0] dw0_max,
    input wire dw1_job_valid, output wire dw1_job_ready,
    input wire dw1_source_bank, input wire [EPOCH_WIDTH-1:0] dw1_source_epoch,
    input wire [ADDR_WIDTH-1:0] dw1_source_base_addr,
    input wire [15:0] dw1_source_lane_mask, input wire [1:0] dw1_source_stride,
    input wire [7:0] dw1_footprint_height, input wire [7:0] dw1_footprint_width,
    input wire [7:0] dw1_footprint_pitch, input wire [2:0] dw1_group,
    input wire [3:0] dw1_group_count, input wire [31:0] dw1_zp,
    input wire [31:0] dw1_min, input wire [31:0] dw1_max,
    output reg dw_done_valid, input wire dw_done_ready,
    output reg dw_done_half, output reg [2:0] dw_done_group,

    /* Select and fence one completed row into the packed consumer. */
    input wire transfer_start_valid, output wire transfer_start_ready,
    input wire transfer_bank, input wire [SESSION_WIDTH-1:0] transfer_session,
    input wire [EPOCH_WIDTH-1:0] transfer_epoch,
    input wire [2:0] transfer_row, input wire [GROUP_WIDTH-1:0] transfer_groups,
    output reg transfer_done_valid, input wire transfer_done_ready,

    /* Packed PW loader/job ABI is passed through unchanged. */
    input wire pw_load_begin_valid, output wire pw_load_begin_ready,
    input wire [1:0] pw_load_epoch, input wire [7:0] pw_load_cin,
    input wire [8:0] pw_load_cout, input wire pw_load_word_valid,
    output wire pw_load_word_ready, input wire [31:0] pw_load_word_data,
    input wire pw_load_commit_valid, output wire pw_load_commit_ready,
    output wire pw_load_commit_reject, output wire pw_load_extra_error,
    output wire pw_load_active, output wire pw_committed_valid,
    output wire [1:0] pw_committed_epoch,
    output wire [13:0] pw_expected_word_count, output wire [13:0] pw_load_word_count,
    output wire [15:0] pw_packed_load_count,
    input wire pw_job_valid, output wire pw_job_ready,
    input wire [4:0] pw_job_cout_tile, input wire pw_job_bank,
    input wire [SESSION_WIDTH-1:0] pw_job_session,
    input wire [EPOCH_WIDTH-1:0] pw_job_epoch,
    input wire [GROUP_WIDTH-1:0] pw_job_group_count,
    input wire pw_job_reverse_groups, input wire [5:0] pw_job_pixel_base,
    input wire [8:0] pw_job_cout_base, input wire [7:0] pw_job_output_pixels,
    input wire [8:0] pw_job_output_channels,
    input wire signed [255:0] pw_job_bias_vec,
    input wire signed [255:0] pw_job_multiplier_vec,
    input wire [47:0] pw_job_shift_vec,
    input wire signed [31:0] pw_job_zp, input wire signed [31:0] pw_job_min,
    input wire signed [31:0] pw_job_max,
    output wire out_valid, input wire out_ready, output wire [2:0] out_row_idx,
    output wire [1:0] out_beat_idx, output wire [5:0] out_pixel_idx,
    output wire [8:0] out_channel_base, output wire [1:0] out_lane_mask,
    output wire signed [15:0] out_data, output wire pw_job_done,

    output wire busy, output reg [31:0] dw_overlap_cycles,
    output wire [31:0] dw_source_words, output wire [31:0] dw_tokens,
    output wire [31:0] dw_half_writes, output wire [31:0] pw_row_reads
);
    localparam integer VAW = (MAX_IN_H*MAX_IN_W*3 > 1) ?
                             $clog2(MAX_IN_H*MAX_IN_W*3) : 1;

    /* ------------------------- DW islands ------------------------- */
    wire c0_start_v, c1_start_v, c0_start_r, c1_start_r;
    wire c0_done_v, c1_done_v;
    wire c0_done_r, c1_done_r;
    wire c0_busy, c1_busy;
    wire v0, v1, r0, r1;
    wire [7:0] p0, p1; wire [15:0] m0, m1;
    wire signed [511:0] raw0, raw1, mul0, mul1;
    wire signed [511:0] b0, b1; wire [95:0] sh0, sh1;
    reg active, active_half;
    reg [2:0] active_group;
    reg [15:0] active_mask;
    reg [1:0] active_stride;
    reg [7:0] active_fh, active_fw, active_pitch;
    reg active_bank; reg [EPOCH_WIDTH-1:0] active_epoch;
    reg [ADDR_WIDTH-1:0] active_base;
    reg [31:0] active_zp, active_min, active_max;
    reg start_pending;
    wire choose0 = !active && dw0_job_valid;
    wire choose1 = !active && !dw0_job_valid && dw1_job_valid;
    assign dw0_job_ready = rst_n && !active && !start_pending && !dw_done_valid;
    assign dw1_job_ready = rst_n && !active && !start_pending && !dw_done_valid && !dw0_job_valid;
    wire job0_fire = dw0_job_valid && dw0_job_ready;
    wire job1_fire = dw1_job_valid && dw1_job_ready;
    assign c0_start_v = active && !active_half && start_pending;
    assign c1_start_v = active && active_half && start_pending;
    assign c0_done_r = active && !active_half && !pack_busy;
    assign c1_done_r = active && active_half && !pack_busy;
    assign r0 = (active && !active_half) ? pack_in_r : 1'b0;
    assign r1 = (active && active_half) ? pack_in_r : 1'b0;
    wire cfg_ready0, cfg_ready1;
    assign cfg_ready = cfg_ready0 && cfg_ready1;

    ds_word_window_dw_producer_island #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W), .MAX_CHANNEL_GROUPS(3),
        .LAYOUT_GROUPS(1), .ADDR_WIDTH(ADDR_WIDTH),
        .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH), .VECTOR_ADDR_WIDTH(VAW),
        .EPOCH_WIDTH(EPOCH_WIDTH), .TAG_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH),
        .OUTPUT_HEIGHT(4), .OUTPUT_WIDTH(8)
    ) u_dw0 (
        .clk(clk), .rst_n(rst_n), .fill_start_valid(fill0_start_valid),
        .fill_start_ready(fill0_start_ready), .fill_start_bank(fill0_start_bank),
        .fill_start_epoch(fill0_start_epoch), .fill_start_base_addr(fill0_start_base_addr),
        .fill_start_word_count(fill0_start_word_count), .fill_done_valid(fill0_done_valid),
        .fill_done_ready(fill0_done_ready), .fill_done_bank(fill0_done_bank),
        .fill_done_epoch(fill0_done_epoch), .mem_req_valid(fill0_mem_req_valid),
        .mem_req_ready(fill0_mem_req_ready), .mem_req_addr(fill0_mem_req_addr),
        .mem_resp_valid(fill0_mem_resp_valid), .mem_resp_data(fill0_mem_resp_data),
        .cfg_valid(cfg_valid && cfg_ready), .cfg_ready(cfg_ready0), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .compute_start_valid(c0_start_v), .compute_start_ready(c0_start_r),
        .compute_bank(active_bank), .compute_epoch(active_epoch),
        .compute_lane_mask(active_mask), .compute_stride(active_stride),
        .compute_footprint_height(active_fh), .compute_footprint_width(active_fw),
        .compute_pitch(active_pitch), .compute_done_valid(c0_done_v),
        .compute_done_ready(c0_done_r), .compute_done_bank(), .compute_done_epoch(),
        .compute_busy(c0_busy), .valid_out(v0), .ready_out(r0),
        .out_pixel_idx(p0), .out_lane_mask(m0), .out_raw_vec(raw0),
        .out_bias_vec(b0), .out_multiplier_vec(mul0), .out_shift_vec(sh0),
        .bank0_state(), .bank1_state(), .fill_busy(), .read_busy(),
        .fill_word_count_seen(source_words0), .read_vector_count(), .token_count(dw_tokens0),
        .overlap_cycles(), .stale_command_count()
    );
    ds_word_window_dw_producer_island #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W), .MAX_CHANNEL_GROUPS(3),
        .LAYOUT_GROUPS(1), .ADDR_WIDTH(ADDR_WIDTH),
        .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH), .VECTOR_ADDR_WIDTH(VAW),
        .EPOCH_WIDTH(EPOCH_WIDTH), .TAG_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH),
        .OUTPUT_HEIGHT(4), .OUTPUT_WIDTH(8)
    ) u_dw1 (
        .clk(clk), .rst_n(rst_n), .fill_start_valid(fill1_start_valid),
        .fill_start_ready(fill1_start_ready), .fill_start_bank(fill1_start_bank),
        .fill_start_epoch(fill1_start_epoch), .fill_start_base_addr(fill1_start_base_addr),
        .fill_start_word_count(fill1_start_word_count), .fill_done_valid(fill1_done_valid),
        .fill_done_ready(fill1_done_ready), .fill_done_bank(fill1_done_bank),
        .fill_done_epoch(fill1_done_epoch), .mem_req_valid(fill1_mem_req_valid),
        .mem_req_ready(fill1_mem_req_ready), .mem_req_addr(fill1_mem_req_addr),
        .mem_resp_valid(fill1_mem_resp_valid), .mem_resp_data(fill1_mem_resp_data),
        .cfg_valid(cfg_valid && cfg_ready), .cfg_ready(cfg_ready1), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .compute_start_valid(c1_start_v), .compute_start_ready(c1_start_r),
        .compute_bank(active_bank), .compute_epoch(active_epoch),
        .compute_lane_mask(active_mask), .compute_stride(active_stride),
        .compute_footprint_height(active_fh), .compute_footprint_width(active_fw),
        .compute_pitch(active_pitch), .compute_done_valid(c1_done_v),
        .compute_done_ready(c1_done_r), .compute_done_bank(), .compute_done_epoch(),
        .compute_busy(c1_busy), .valid_out(v1), .ready_out(r1),
        .out_pixel_idx(p1), .out_lane_mask(m1), .out_raw_vec(raw1),
        .out_bias_vec(b1), .out_multiplier_vec(mul1), .out_shift_vec(sh1),
        .bank0_state(), .bank1_state(), .fill_busy(), .read_busy(),
        .fill_word_count_seen(source_words1), .read_vector_count(), .token_count(dw_tokens1),
        .overlap_cycles(), .stale_command_count()
    );
    wire [31:0] dw_tokens0, dw_tokens1;
    wire [31:0] source_words0, source_words1;
    assign dw_tokens = dw_tokens0 + dw_tokens1;
    assign dw_source_words = source_words0 + source_words1;

    /* Shared requant island.  Only one producer is active at a time; this
     * preserves the 104-DSP target (two DW cores plus one PW core). */
    wire pack_in_v = active_half ? v1 : v0;
    wire pack_in_r;
    wire [7:0] pack_in_p = active_half ? p1 : p0;
    wire [15:0] pack_in_m = active_half ? m1 : m0;
    wire signed [511:0] pack_in_raw = active_half ? raw1 : raw0;
    wire signed [511:0] pack_in_mul = active_half ? mul1 : mul0;
    wire [95:0] pack_in_sh = active_half ? sh1 : sh0;
    wire pack_v, pack_r; wire [5:0] pack_p; wire [1:0] pack_base;
    wire [31:0] pack_data; wire [3:0] pack_mask;
    wire pack_busy;
    ds_dw_requant_stream4_write_adapter_local u_shared_requant (
        .clk(clk), .rst_n(rst_n), .valid_in(pack_in_v), .ready_in(pack_in_r),
        .pixel_idx_in(pack_in_p[5:0]), .lane_mask_in(pack_in_m),
        .raw_vec_in(pack_in_raw), .multiplier_vec_in(pack_in_mul),
        .shift_vec_in(pack_in_sh), .output_zero_point(active_zp),
        .activation_min(active_min), .activation_max(active_max),
        .valid_out(pack_v), .ready_out(pack_r), .pixel_idx_out(pack_p),
        .lane_base_out(pack_base), .data_out(pack_data), .lane_mask_out(pack_mask),
        .busy(pack_busy)
    );
    wire pack_active = pack_busy || pack_in_v;
    /* The row packer feeds the dedicated BRAM image and therefore
     * never backpressures the stream4 serializer. */
    assign pack_r = 1'b1;
    wire pack_fire = pack_v && pack_r;

    /* Eight output rows, each group has two 4-pixel halves.  Each stream4
     * beat updates one 36-bit plane in the dedicated BRAM image. */
    wire row_wr_ready;
    wire row_rd_req_ready;
    wire row_rd_valid;
    wire [255:0] row_rd_data;
    wire [31:0] row_rd_mask;
    wire row_rd_req_valid;
    wire [7:0] row_rd_addr;
    wire row_rd_ready;
    wire row_wr_valid = pack_fire;
    wire [7:0] row_wr_addr = {
        (active_half ? 3'd4 : 3'd0) + pack_p[5:3],
        (pack_group << 1) + (pack_base >> 1),
        pack_p[2]
    };
    wire [2:0] row_wr_word_sel = pack_p[1:0];
    wire [35:0] row_wr_data36 = {pack_mask, pack_data};
    row_image_bram_store u_row_image (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(row_wr_valid), .wr_ready(row_wr_ready),
        .wr_addr(row_wr_addr), .wr_word_sel(row_wr_word_sel),
        .wr_data36(row_wr_data36),
        .rd_req_valid(row_rd_req_valid), .rd_req_ready(row_rd_req_ready),
        .rd_addr(row_rd_addr), .rd_valid(row_rd_valid),
        .rd_ready(row_rd_ready), .rd_data(row_rd_data), .rd_mask(row_rd_mask)
    );
    reg [1:0] pack_half_seen;
    reg [2:0] pack_row;
    reg [2:0] pack_col;
    reg [3:0] pack_group;
    reg pack_valid;
    reg [31:0] dw_half_writes_reg;
    assign dw_half_writes = dw_half_writes_reg;
    /* Each 16-lane DW bundle becomes two adjacent eight-channel PW groups.
     * stream4 bases 0/1 fill group 2*g and bases 2/3 fill group 2*g+1;
     * therefore no DW arithmetic result is discarded. */
    wire active_done = active_half ? c1_done_v : c0_done_v;
    wire active_done_fire = active_done && (active_half ? c1_done_r : c0_done_r);
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0; active_half <= 1'b0; active_group <= 0;
            active_mask <= 0; active_stride <= 1; active_fh <= 0;
            active_fw <= 0; active_pitch <= 0; active_bank <= 0;
            active_epoch <= 0; active_base <= 0; active_zp <= 0;
            active_min <= 0; active_max <= 0; start_pending <= 1'b0;
            dw_done_valid <= 1'b0; dw_done_half <= 0; dw_done_group <= 0;
            pack_half_seen <= 0; pack_row <= 0; pack_col <= 0; pack_group <= 0;
            pack_valid <= 0; dw_half_writes_reg <= 0;
        end else begin
            if (dw_done_valid && dw_done_ready) dw_done_valid <= 1'b0;
            if (job0_fire || job1_fire) begin
                active <= 1'b1; active_half <= job1_fire; start_pending <= 1'b1;
                if (job1_fire) begin
                    active_group <= dw1_group; active_mask <= dw1_source_lane_mask;
                    active_stride <= (dw1_source_stride==0)?1:dw1_source_stride;
                    active_fh <= dw1_footprint_height; active_fw <= dw1_footprint_width;
                    active_pitch <= dw1_footprint_pitch; active_bank <= dw1_source_bank;
                    active_epoch <= dw1_source_epoch; active_base <= dw1_source_base_addr;
                    active_zp <= dw1_zp; active_min <= dw1_min; active_max <= dw1_max;
                    pack_group <= dw1_group;
                end else begin
                    active_group <= dw0_group; active_mask <= dw0_source_lane_mask;
                    active_stride <= (dw0_source_stride==0)?1:dw0_source_stride;
                    active_fh <= dw0_footprint_height; active_fw <= dw0_footprint_width;
                    active_pitch <= dw0_footprint_pitch; active_bank <= dw0_source_bank;
                    active_epoch <= dw0_source_epoch; active_base <= dw0_source_base_addr;
                    active_zp <= dw0_zp; active_min <= dw0_min; active_max <= dw0_max;
                    pack_group <= dw0_group;
                end
                pack_half_seen <= 0; pack_row <= 0; pack_col <= 0;
            end
            if (start_pending && (active_half ? c1_start_r : c0_start_r))
                start_pending <= 1'b0;
            if (pack_fire && (pack_base == 1 || pack_base == 3))
                dw_half_writes_reg <= dw_half_writes_reg + 1'b1;
            if (active_done_fire) begin
                active <= 1'b0;
                dw_done_valid <= 1'b1; dw_done_half <= active_half;
                dw_done_group <= active_group;
            end
        end
    end

    /* -------------------- paired consumer ------------------------- */
    wire c_dw_acq_v, c_dw_acq_r, c_dw_wr_v, c_dw_wr_r, c_dw_cm_v, c_dw_cm_r;
    wire c_dw_acq_bank;
    wire [SESSION_WIDTH-1:0] c_dw_acq_session;
    wire [EPOCH_WIDTH-1:0] c_dw_acq_epoch;
    reg [GROUP_WIDTH-1:0] tr_group;
    reg [2:0] tr_row;
    reg tr_bank; reg [SESSION_WIDTH-1:0] tr_session; reg [EPOCH_WIDTH-1:0] tr_epoch;
    reg [2:0] tr_state;
    localparam TR_IDLE=3'd0, TR_ACQ=3'd1, TR_READ_REQ=3'd2,
               TR_READ_WAIT=3'd3, TR_WRITE=3'd4, TR_COMMIT=3'd5;
    assign transfer_start_ready = rst_n && (tr_state == TR_IDLE) && !transfer_done_valid;
    assign c_dw_acq_v = (tr_state == TR_ACQ);
    assign c_dw_cm_v = (tr_state == TR_COMMIT);
    assign c_dw_acq_bank = tr_bank;
    assign c_dw_acq_session = tr_session;
    assign c_dw_acq_epoch = tr_epoch;
    reg [255:0] tr_data_reg;
    reg [31:0] tr_mask_reg;
    wire [255:0] tr_data = tr_data_reg;
    wire [31:0] tr_mask = tr_mask_reg;
    assign row_rd_req_valid = (tr_state == TR_READ_REQ);
    assign row_rd_addr = {tr_row, tr_group[3:0], tr_half_sel};
    assign row_rd_ready = (tr_state == TR_READ_WAIT);
    reg tr_half_sel;
    assign c_dw_wr_v = (tr_state == TR_WRITE);
    wire [GROUP_WIDTH-1:0] c_dw_group = tr_group;
    wire c_dw_half = tr_half_sel;
    wire [SESSION_WIDTH-1:0] c_dw_cm_session = tr_session;
    wire [EPOCH_WIDTH-1:0] c_dw_cm_epoch = tr_epoch;
    wire c_job_done; wire c_busy;
    wire [1:0] c_s0, c_s1;
    wire [15:0] c_pr, c_aa, c_as;
    dw_pw_pair_scratch_rowbank2_packed_consumer #(
        .MAX_CIN(MAX_CIN), .MAX_COUT(MAX_COUT), .MAX_GROUPS(MAX_GROUPS),
        .SESSION_WIDTH(SESSION_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH),
        .GROUP_WIDTH(GROUP_WIDTH), .ROWBANK_ACT_REPLICATE(1)
    ) u_pw (
        .clk(clk), .rst_n(rst_n), .dw_acquire_valid(c_dw_acq_v),
        .dw_acquire_ready(c_dw_acq_r), .dw_acquire_bank(c_dw_acq_bank),
        .dw_acquire_session(c_dw_acq_session), .dw_acquire_epoch(c_dw_acq_epoch),
        .dw_acquire_group_count(transfer_groups), .dw_write_valid(c_dw_wr_v),
        .dw_write_ready(c_dw_wr_r), .dw_write_bank(tr_bank), .dw_write_group(c_dw_group),
        .dw_write_half(c_dw_half), .dw_write_data(tr_data), .dw_write_lane_mask(tr_mask),
        .dw_commit_valid(c_dw_cm_v), .dw_commit_ready(c_dw_cm_r),
        .dw_commit_bank(tr_bank), .dw_commit_session(c_dw_cm_session),
        .dw_commit_epoch(c_dw_cm_epoch), .pw_load_begin_valid(pw_load_begin_valid),
        .pw_load_begin_ready(pw_load_begin_ready), .pw_load_epoch(pw_load_epoch),
        .pw_load_cin(pw_load_cin), .pw_load_cout(pw_load_cout),
        .pw_load_word_valid(pw_load_word_valid), .pw_load_word_ready(pw_load_word_ready),
        .pw_load_word_data(pw_load_word_data), .pw_load_commit_valid(pw_load_commit_valid),
        .pw_load_commit_ready(pw_load_commit_ready), .pw_load_commit_reject(pw_load_commit_reject),
        .pw_load_extra_error(pw_load_extra_error), .pw_load_active(pw_load_active),
        .pw_committed_valid(pw_committed_valid), .pw_committed_epoch(pw_committed_epoch),
        .pw_expected_word_count(pw_expected_word_count), .pw_load_word_count(pw_load_word_count),
        .pw_packed_load_count(pw_packed_load_count), .job_valid(pw_job_valid),
        .job_ready(pw_job_ready), .job_cout_tile(pw_job_cout_tile), .job_bank(pw_job_bank),
        .job_session(pw_job_session), .job_epoch(pw_job_epoch),
        .job_group_count(pw_job_group_count), .job_reverse_groups(pw_job_reverse_groups),
        .job_pixel_base(pw_job_pixel_base), .job_cout_base(pw_job_cout_base),
        .job_output_pixels(pw_job_output_pixels), .job_output_channels(pw_job_output_channels),
        .job_bias_vec(pw_job_bias_vec), .job_multiplier_vec(pw_job_multiplier_vec),
        .job_shift_vec(pw_job_shift_vec), .job_output_zero_point_int32(pw_job_zp),
        .job_activation_min_int32(pw_job_min), .job_activation_max_int32(pw_job_max),
        .out_valid(out_valid), .out_ready(out_ready), .out_row_idx(out_row_idx),
        .out_beat_idx(out_beat_idx), .out_pixel_idx(out_pixel_idx),
        .out_channel_base(out_channel_base), .out_lane_mask(out_lane_mask),
        .out_data(out_data), .job_done(c_job_done), .busy(c_busy),
        .scratch_bank0_state(c_s0), .scratch_bank1_state(c_s1),
        .packed_read_count(c_pr), .activation_accept_count(c_aa),
        .activation_stall_count(c_as)
    );
    assign pw_row_reads = c_pr;
    assign pw_job_done = c_job_done;
    assign busy = active || pack_busy || c_busy || (tr_state != TR_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            tr_state <= TR_IDLE; tr_group <= 0; tr_row <= 0; tr_bank <= 0;
            tr_session <= 0; tr_epoch <= 0; tr_half_sel <= 0;
            tr_data_reg <= 0; tr_mask_reg <= 0;
            transfer_done_valid <= 1'b0; dw_overlap_cycles <= 0;
        end else begin
            if (transfer_done_valid && transfer_done_ready) transfer_done_valid <= 1'b0;
            if (transfer_start_valid && transfer_start_ready) begin
                tr_row <= transfer_row; tr_group <= 0; tr_bank <= transfer_bank;
                tr_session <= transfer_session; tr_epoch <= transfer_epoch;
                tr_group_count_latched <= transfer_groups; tr_state <= TR_ACQ;
            end
            if (tr_state == TR_ACQ && c_dw_acq_r) begin
                tr_group <= 0; tr_half_sel <= 0; tr_state <= TR_READ_REQ;
            end
            if (tr_state == TR_READ_REQ && row_rd_req_valid && row_rd_req_ready) begin
                tr_state <= TR_READ_WAIT;
            end
            if (tr_state == TR_READ_WAIT && row_rd_valid && row_rd_ready) begin
                tr_data_reg <= row_rd_data;
                tr_mask_reg <= row_rd_mask;
                tr_state <= TR_WRITE;
            end
            if (tr_state == TR_WRITE && c_dw_wr_r) begin
                if (!tr_half_sel) tr_half_sel <= 1'b1;
                else begin
                    tr_half_sel <= 0;
                    if (tr_group + 1 >= tr_group_count_latched) tr_state <= TR_COMMIT;
                    else begin
                        tr_group <= tr_group + 1'b1;
                        tr_state <= TR_READ_REQ;
                    end
                end
            end
            if (tr_state == TR_COMMIT && c_dw_cm_r) begin
                tr_state <= TR_IDLE; transfer_done_valid <= 1'b1;
            end
            if ((active || pack_busy) && c_busy) dw_overlap_cycles <= dw_overlap_cycles + 1'b1;
        end
    end
    reg [GROUP_WIDTH-1:0] tr_group_count_latched;
endmodule

`default_nettype wire
