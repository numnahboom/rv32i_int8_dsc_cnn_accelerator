`timescale 1ns/1ps
`default_nettype none

/*
 * Group-ready, output-stationary partial-K DS prototype.
 *
 * The module is intentionally a local integration island, not a replacement
 * for cnn_layer_runner.  A stream4 result (one 16-lane DW pixel as four
 * beats) is assembled into two 256-bit four-channel halves.  Once both halves
 * for one row/group are in the local scratch bank, a narrow descriptor is
 * queued and the PW array starts consuming that group.  The remaining groups
 * may continue arriving from the DW producer while PW is replaying the
 * earlier groups.  FENCE_MODE retains the exact same source and arithmetic
 * but postpones descriptor publication until all halves are present, which is
 * used only for a same-shape cycle comparison.
 */
module ds_group_ready_partial_k_pipeline #(
    parameter integer MAX_PIXELS = 17,
    parameter integer MAX_CIN = 64,
    parameter integer MAX_BUNDLES = 8,
    parameter integer MAX_ROWS = 8,
    parameter integer MAX_GROUPS = 16,
    parameter integer DESC_DEPTH = 32,
    parameter integer FENCE_MODE = 0
) (
    input wire clk, input wire rst_n,

    input wire start_valid, output wire start_ready,
    input wire [7:0] start_cin,
    input wire [7:0] start_pixels,
    input wire [7:0] start_cout,
    input wire start_bank,
    input wire [1:0] start_session,
    input wire [3:0] start_epoch,

    /* Four stream4 beats per sixteen-channel DW pixel. */
    input wire stream_valid, output wire stream_ready,
    input wire [5:0] stream_pixel,
    input wire [2:0] stream_bundle,
    input wire [1:0] stream_lane_base,
    input wire [31:0] stream_data,
    input wire [3:0] stream_lane_mask,

    /* One 8-output PW weight row per global K. */
    input wire weight_load_valid, output wire weight_load_ready,
    input wire [7:0] weight_load_k,
    input wire [63:0] weight_load_vec,

    output wire out_valid, input wire out_ready,
    output wire signed [2047:0] out_psum,
    output wire [7:0] out_pixel_mask,
    output wire [7:0] out_cout_mask,
    output wire [63:0] out_lane_mask,
    output wire [3:0] out_group_count,
    output reg done,
    output reg error,

    output reg [31:0] perf_total_cycles,
    output reg [31:0] perf_half_writes,
    output reg [31:0] perf_group_descriptors,
    output reg [31:0] perf_pw_tokens,
    output reg [31:0] perf_output_groups,
    output reg [31:0] perf_first_output_cycle
);
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_ACQUIRE = 3'd1;
    localparam [2:0] ST_RUN = 3'd2;
    localparam [2:0] ST_RELEASE = 3'd3;

    reg [2:0] state;
    reg [7:0] cin_reg, pixels_reg, cout_reg;
    (* max_fanout = 32 *) reg start_bank_reg;
    reg [1:0] session_reg;
    reg [3:0] epoch_reg;
    reg [3:0] group_count_reg;
    reg [3:0] bundle_count_reg;
    reg [3:0] row_count_reg;
    reg input_done_reg;
    reg commit_done_reg;
    reg final_output_done;

    (* ram_style = "block" *) reg signed [63:0] weight_mem [0:MAX_CIN-1];
    wire weight_load_fire = weight_load_valid && weight_load_ready;
    assign weight_load_ready = rst_n && (state == ST_IDLE) &&
                               (weight_load_k < MAX_CIN);

    wire start_fire = start_valid && start_ready;
    assign start_ready = rst_n && (state == ST_IDLE) && !weight_load_valid;

    wire asm_cfg_valid = (state == ST_ACQUIRE);
    wire asm_cfg_ready;
    wire [3:0] asm_half_group;
    wire [2:0] asm_half_row;
    wire asm_half_sel;
    wire [255:0] asm_half_data;
    wire [31:0] asm_half_mask;
    wire asm_half_valid, asm_half_ready, asm_done, asm_error;
    wire asm_stream_ready;

    ds_group_ready_half_assembler #(
        .MAX_PIXELS(MAX_PIXELS), .MAX_BUNDLES(MAX_BUNDLES),
        .PIXEL_WIDTH(6), .BUNDLE_WIDTH(3)
    ) u_assembler (
        .clk(clk), .rst_n(rst_n),
        .total_pixels(pixels_reg), .total_bundles(bundle_count_reg),
        .config_valid(asm_cfg_valid), .config_ready(asm_cfg_ready),
        .stream_valid(stream_valid && (state == ST_RUN)),
        .stream_ready(asm_stream_ready), .stream_pixel(stream_pixel),
        .stream_bundle(stream_bundle), .stream_lane_base(stream_lane_base),
        .stream_data(stream_data), .stream_lane_mask(stream_lane_mask),
        .half_valid(asm_half_valid), .half_ready(asm_half_ready),
        .half_row(asm_half_row), .half_group(asm_half_group),
        .half_sel(asm_half_sel), .half_data(asm_half_data),
        .half_lane_mask(asm_half_mask), .half_done(asm_done), .error(asm_error)
    );

    wire [3:0] target_groups = (cin_reg + 7) >> 3;
    wire [3:0] target_bundles = (cin_reg + 15) >> 4;
    wire [3:0] target_rows = (pixels_reg + 7) >> 3;
    wire [7:0] pixel_mask_cfg = (pixels_reg >= 8) ? 8'hff :
        ((pixels_reg == 0) ? 8'd0 : ((8'h01 << pixels_reg) - 1'b1));
    wire [7:0] cout_mask_cfg = (cout_reg >= 8) ? 8'hff :
        ((cout_reg == 0) ? 8'd0 : ((8'h01 << cout_reg) - 1'b1));
    function automatic [7:0] row_pixel_mask;
        input [2:0] row_value;
        input [7:0] pixel_total;
        integer rem;
        begin
            rem = pixel_total - (row_value * 8);
            if (rem >= 8) row_pixel_mask = 8'hff;
            else if (rem <= 0) row_pixel_mask = 8'd0;
            else row_pixel_mask = (8'h01 << rem) - 1'b1;
        end
    endfunction

    wire s0_acq_ready, s1_acq_ready;
    wire s0_half_ready, s1_half_ready;
    wire s0_commit_ready, s1_commit_ready;
    wire s0_req_valid, s1_req_valid;
    wire s0_req_ready, s1_req_ready;
    wire s0_gvalid, s1_gvalid;
    wire s0_gready, s1_gready;
    wire [1:0] s0_state, s1_state;
    wire s0_all_writes, s1_all_writes, s0_all_drained, s1_all_drained;
    wire [15:0] s0_write_count, s1_write_count;
    wire [15:0] s0_desc_count, s1_desc_count;
    wire s0_bank_error, s1_bank_error;
    wire [1:0] acq_bank = start_bank_reg;
    wire asm_to_bank = (state == ST_RUN) || (state == ST_RELEASE);

    wire acq_valid_i = (state == ST_ACQUIRE);
    wire acq_fire_i = acq_valid_i && (start_bank_reg ? s1_acq_ready : s0_acq_ready) &&
                      asm_cfg_ready;
    wire half_bank = start_bank_reg;
    reg half_pipe_valid;
    reg [2:0] half_pipe_row;
    reg [3:0] half_pipe_group;
    reg half_pipe_sel;
    reg [255:0] half_pipe_data;
    reg [31:0] half_pipe_mask;
    wire half_ready_i = start_bank_reg ? s1_half_ready : s0_half_ready;
    assign asm_half_ready = !half_pipe_valid || half_ready_i;
    wire half_pipe_push = asm_half_valid && asm_half_ready;
    wire half_pipe_pop = half_pipe_valid && half_ready_i;
    wire half_valid_i = half_pipe_valid && asm_to_bank;

    wire commit_valid_i = (state == ST_RUN) && input_done_reg && !commit_done_reg;
    wire commit_ready_i = start_bank_reg ? s1_commit_ready : s0_commit_ready;
    wire commit_fire_i = commit_valid_i && commit_ready_i;

    /* Keep accepting ready groups into a row/group reorder cache while PW is
     * consuming an earlier reduction. */
    wire req_ready_i = (state == ST_RUN) && (cache_count < DESC_DEPTH);
    wire req_valid_i = start_bank_reg ? s1_req_valid : s0_req_valid;
    assign s0_req_ready = req_ready_i && !start_bank_reg;
    assign s1_req_ready = req_ready_i && start_bank_reg;
    wire gvalid_i = start_bank_reg ? s1_gvalid : s0_gvalid;
    wire gready_i = (state == ST_RUN) &&
                    !cache_valid[{group_idx_i, group_row_i}];
    assign s0_gready = gready_i && !start_bank_reg;
    assign s1_gready = gready_i && start_bank_reg;

    wire [1:0] bank0_owner_state, bank1_owner_state;
    wire [511:0] s0_gdata, s1_gdata;
    wire [2:0] s0_grow, s1_grow;
    wire [3:0] s0_ggroup, s1_ggroup;
    wire s0_gfirst, s1_gfirst, s0_glast, s1_glast;
    wire [7:0] s0_gkcount, s1_gkcount, s0_gpmask, s1_gpmask;
    wire [7:0] s0_gcmask, s1_gcmask;

    ds_group_ready_scratch_bank #(
        .MAX_ROWS(MAX_ROWS), .MAX_GROUPS(MAX_GROUPS), .ROW_WIDTH(3),
        .GROUP_WIDTH(4), .DESC_DEPTH(DESC_DEPTH), .FENCE_MODE(FENCE_MODE),
        .BANK_ID(0)
    ) u_scratch0 (
        .clk(clk), .rst_n(rst_n),
        .acquire_valid(acq_valid_i && !start_bank_reg), .acquire_ready(s0_acq_ready),
        .acquire_bank(1'b0), .acquire_session(session_reg), .acquire_epoch(epoch_reg),
        .acquire_rows(row_count_reg[2:0]), .acquire_groups(group_count_reg),
        .acquire_cin(cin_reg), .acquire_pixel_mask(pixel_mask_cfg),
        .acquire_cout_mask(cout_mask_cfg),
        .half_valid(half_valid_i && !start_bank_reg), .half_ready(s0_half_ready),
        .half_bank(1'b0), .half_session(session_reg), .half_epoch(epoch_reg),
        .half_row(half_pipe_row), .half_group(half_pipe_group), .half_sel(half_pipe_sel),
        .half_data(half_pipe_data), .half_lane_mask(half_pipe_mask),
        .commit_valid(commit_valid_i && !start_bank_reg), .commit_ready(s0_commit_ready),
        .commit_bank(1'b0), .commit_session(session_reg), .commit_epoch(epoch_reg),
        .group_req_valid(s0_req_valid), .group_req_ready(s0_req_ready),
        .group_bank(), .group_session(), .group_epoch(), .group_row(),
        .group_index(), .group_first_k(), .group_last_k(), .group_k_count(),
        .group_pixel_mask(), .group_cout_mask(),
        .group_data_valid(s0_gvalid), .group_data_ready(s0_gready),
        .group_data(s0_gdata), .group_data_row(s0_grow),
        .group_data_index(s0_ggroup), .group_data_first_k(s0_gfirst),
        .group_data_last_k(s0_glast), .group_data_k_count(s0_gkcount),
        .group_data_pixel_mask(s0_gpmask), .group_data_cout_mask(s0_gcmask),
        .release_valid((state == ST_RELEASE) && !start_bank_reg),
        .release_ready(), .release_bank(1'b0), .release_session(session_reg),
        .release_epoch(epoch_reg), .all_writes_done(s0_all_writes),
        .all_descriptors_drained(s0_all_drained), .write_count(s0_write_count),
        .descriptor_count(s0_desc_count), .bank_state(bank0_owner_state), .error(s0_bank_error)
    );
    ds_group_ready_scratch_bank #(
        .MAX_ROWS(MAX_ROWS), .MAX_GROUPS(MAX_GROUPS), .ROW_WIDTH(3),
        .GROUP_WIDTH(4), .DESC_DEPTH(DESC_DEPTH), .FENCE_MODE(FENCE_MODE),
        .BANK_ID(1)
    ) u_scratch1 (
        .clk(clk), .rst_n(rst_n),
        .acquire_valid(acq_valid_i && start_bank_reg), .acquire_ready(s1_acq_ready),
        .acquire_bank(1'b1), .acquire_session(session_reg), .acquire_epoch(epoch_reg),
        .acquire_rows(row_count_reg[2:0]), .acquire_groups(group_count_reg),
        .acquire_cin(cin_reg), .acquire_pixel_mask(pixel_mask_cfg),
        .acquire_cout_mask(cout_mask_cfg),
        .half_valid(half_valid_i && start_bank_reg), .half_ready(s1_half_ready),
        .half_bank(1'b1), .half_session(session_reg), .half_epoch(epoch_reg),
        .half_row(half_pipe_row), .half_group(half_pipe_group), .half_sel(half_pipe_sel),
        .half_data(half_pipe_data), .half_lane_mask(half_pipe_mask),
        .commit_valid(commit_valid_i && start_bank_reg), .commit_ready(s1_commit_ready),
        .commit_bank(1'b1), .commit_session(session_reg), .commit_epoch(epoch_reg),
        .group_req_valid(s1_req_valid), .group_req_ready(s1_req_ready),
        .group_bank(), .group_session(), .group_epoch(), .group_row(),
        .group_index(), .group_first_k(), .group_last_k(), .group_k_count(),
        .group_pixel_mask(), .group_cout_mask(),
        .group_data_valid(s1_gvalid), .group_data_ready(s1_gready),
        .group_data(s1_gdata), .group_data_row(s1_grow),
        .group_data_index(s1_ggroup), .group_data_first_k(s1_gfirst),
        .group_data_last_k(s1_glast), .group_data_k_count(s1_gkcount),
        .group_data_pixel_mask(s1_gpmask), .group_data_cout_mask(s1_gcmask),
        .release_valid((state == ST_RELEASE) && start_bank_reg),
        .release_ready(), .release_bank(1'b1), .release_session(session_reg),
        .release_epoch(epoch_reg), .all_writes_done(s1_all_writes),
        .all_descriptors_drained(s1_all_drained), .write_count(s1_write_count),
        .descriptor_count(s1_desc_count), .bank_state(bank1_owner_state), .error(s1_bank_error)
    );

    assign stream_ready = (state == ST_RUN) && asm_stream_ready;
    /* The assembler's own ready is the authoritative source handshake. */
    wire stream_fire = stream_valid && stream_ready;

    wire [511:0] group_data_i = start_bank_reg ? s1_gdata : s0_gdata;
    wire [2:0] group_row_i = start_bank_reg ? s1_grow : s0_grow;
    wire [3:0] group_idx_i = start_bank_reg ? s1_ggroup : s0_ggroup;
    wire group_first_i = start_bank_reg ? s1_gfirst : s0_gfirst;
    wire group_last_i = start_bank_reg ? s1_glast : s0_glast;
    wire [7:0] group_kcount_i = start_bank_reg ? s1_gkcount : s0_gkcount;
    wire [7:0] group_pmask_i = row_pixel_mask(group_row_i, pixels_reg);
    wire [7:0] group_cmask_i = start_bank_reg ? s1_gcmask : s0_gcmask;

    reg token_active, waiting_output;
    /* Row/group reorder cache.  DW producer traffic is bundle-major, whereas
     * one PW output transaction must see all K groups of one row contiguously.
     * This cache stores only one 8-pixel group per address and avoids exposing
     * bank ownership or live cursors to the top-level control cone. */
    reg [7:0] cache_count;
    reg [127:0] cache_valid;
    reg [511:0] cache_data [0:127];
    reg [7:0] cache_kcount [0:127];
    reg [7:0] cache_pmask [0:127];
    reg [7:0] cache_cmask [0:127];
    reg [2:0] pw_row_expect;
    reg [3:0] pw_group_expect;
    reg [3:0] token_idx;
    reg [511:0] token_group_data;
    reg [3:0] token_group_idx;
    reg token_group_first, token_group_last;
    reg [7:0] token_group_kcount, token_group_pmask, token_group_cmask;
    reg signed [63:0] pw_wgt_vec;
    reg signed [63:0] pw_act_vec;
    integer ti;
    always @* begin
        pw_wgt_vec = weight_mem[(token_group_idx * 8) + token_idx];
        pw_act_vec = 64'sd0;
        for (ti = 0; ti < 8; ti = ti + 1) begin
            if (token_idx < 4)
                pw_act_vec[(ti*8) +: 8] =
                    token_group_data[(ti*32) + (token_idx*8) +: 8];
            else
                pw_act_vec[(ti*8) +: 8] =
                    token_group_data[256 + (ti*32) + ((token_idx-4)*8) +: 8];
        end
    end

    wire pw_ready_in;
    wire pw_valid_out;
    wire signed [2047:0] pw_psum_out;
    wire group_data_fire = gvalid_i && gready_i;
    wire [6:0] group_cache_addr = {group_idx_i, group_row_i};
    wire [6:0] expected_cache_addr = {pw_group_expect, pw_row_expect};
    wire cache_start_fire = (state == ST_RUN) && !token_active &&
                            !waiting_output && cache_valid[expected_cache_addr];
    wire token_first = token_group_first && (token_idx == 0);
    wire token_last = token_group_last &&
                      (token_idx + 1'b1 >= token_group_kcount);
    wire group_token_end = (token_idx + 1'b1 >= token_group_kcount);
    wire token_fire = token_active && pw_ready_in;
    wire output_fire = pw_valid_out && out_ready;

    pw_systolic_array_8x8 u_pw (
        .clk(clk), .rst_n(rst_n), .valid_in(token_active),
        .ready_in(pw_ready_in), .first_k(token_first), .last_k(token_last),
        .k_group({4'd0, token_group_idx}), .k_count(token_group_kcount),
        .clear_acc(1'b0), .k_last(1'b0), .act_vec(pw_act_vec),
        .wgt_vec(pw_wgt_vec), .ready_out(out_ready),
        .valid_out(pw_valid_out), .psum_out(pw_psum_out)
    );

    assign out_valid = pw_valid_out;
    assign out_psum = pw_psum_out;
    assign out_pixel_mask = token_group_pmask;
    assign out_cout_mask = token_group_cmask;
    assign out_group_count = group_count_reg;
    genvar oi, oj;
    generate
        for (oi = 0; oi < 8; oi = oi + 1) begin : gen_out_mask_p
            for (oj = 0; oj < 8; oj = oj + 1) begin : gen_out_mask_c
                assign out_lane_mask[(oi*8)+oj] =
                    token_group_pmask[oi] & token_group_cmask[oj];
            end
        end
    endgenerate

    wire release_ready_i = start_bank_reg ? s1_all_drained : s0_all_drained;
    wire final_condition = commit_done_reg && final_output_done &&
                           !token_active && !waiting_output && release_ready_i;

    integer wi;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            cin_reg <= 0; pixels_reg <= 0; cout_reg <= 0;
            start_bank_reg <= 0; session_reg <= 0; epoch_reg <= 0;
            group_count_reg <= 0; bundle_count_reg <= 0; row_count_reg <= 0;
            input_done_reg <= 0; commit_done_reg <= 0; final_output_done <= 0;
            token_active <= 0; waiting_output <= 0; token_idx <= 0;
            token_group_data <= 0; token_group_idx <= 0;
            token_group_first <= 0; token_group_last <= 0;
            token_group_kcount <= 0; token_group_pmask <= 0;
            token_group_cmask <= 0;
            half_pipe_valid <= 1'b0;
            half_pipe_row <= 0;
            half_pipe_group <= 0;
            half_pipe_sel <= 0;
            half_pipe_data <= 0;
            half_pipe_mask <= 0;
            cache_count <= 0;
            pw_row_expect <= 0;
            pw_group_expect <= 0;
            done <= 0; error <= 0;
            perf_total_cycles <= 0; perf_half_writes <= 0;
            perf_group_descriptors <= 0; perf_pw_tokens <= 0;
            perf_output_groups <= 0; perf_first_output_cycle <= 0;
            cache_valid <= 128'd0;
        end else begin
            done <= 0;
            if (half_pipe_push) begin
                half_pipe_valid <= 1'b1;
                half_pipe_row <= asm_half_row;
                half_pipe_group <= asm_half_group;
                half_pipe_sel <= asm_half_sel;
                half_pipe_data <= asm_half_data;
                half_pipe_mask <= asm_half_mask;
            end else if (half_pipe_pop) begin
                half_pipe_valid <= 1'b0;
            end
            if (weight_load_fire)
                weight_mem[weight_load_k] <= weight_load_vec;

            if (start_fire) begin
                cin_reg <= start_cin;
                pixels_reg <= start_pixels;
                cout_reg <= start_cout;
                start_bank_reg <= start_bank;
                session_reg <= start_session;
                epoch_reg <= start_epoch;
                group_count_reg <= (start_cin + 7) >> 3;
                bundle_count_reg <= (start_cin + 15) >> 4;
                row_count_reg <= (start_pixels + 7) >> 3;
                input_done_reg <= 0;
                commit_done_reg <= 0;
                final_output_done <= 0;
                token_active <= 0;
                waiting_output <= 0;
                token_idx <= 0;
                cache_count <= 0;
                pw_row_expect <= 0;
                pw_group_expect <= 0;
                perf_total_cycles <= 0;
                perf_half_writes <= 0;
                perf_group_descriptors <= 0;
                perf_pw_tokens <= 0;
                perf_output_groups <= 0;
                perf_first_output_cycle <= 0;
                error <= 0;
                state <= ST_ACQUIRE;
            end
            if ((state == ST_ACQUIRE) && acq_fire_i)
                state <= ST_RUN;

            if ((state == ST_RUN) || (state == ST_RELEASE))
                perf_total_cycles <= perf_total_cycles + 1'b1;
            if (half_valid_i && half_ready_i)
                perf_half_writes <= perf_half_writes + 1'b1;
            if (group_data_fire)
                perf_group_descriptors <= perf_group_descriptors + 1'b1;
            if (token_fire)
                perf_pw_tokens <= perf_pw_tokens + 1'b1;
            if (output_fire) begin
                perf_output_groups <= perf_output_groups + 1'b1;
                if (perf_first_output_cycle == 0)
                    perf_first_output_cycle <= perf_total_cycles;
            end

            if (asm_error)
                error <= 1'b1;
            if (s0_bank_error || s1_bank_error)
                error <= 1'b1;
            if (asm_done)
                input_done_reg <= 1'b1;
            if (commit_fire_i)
                commit_done_reg <= 1'b1;

            if (group_data_fire) begin
                cache_valid[group_cache_addr] <= 1'b1;
                cache_data[group_cache_addr] <= group_data_i;
                cache_kcount[group_cache_addr] <= group_kcount_i;
                cache_pmask[group_cache_addr] <= group_pmask_i;
                cache_cmask[group_cache_addr] <= group_cmask_i;
            end
            if (cache_start_fire) begin
                token_group_data <= cache_data[expected_cache_addr];
                token_group_idx <= pw_group_expect;
                token_group_first <= (pw_group_expect == 0);
                token_group_last <= (pw_group_expect + 1'b1 >= group_count_reg);
                token_group_kcount <= cache_kcount[expected_cache_addr];
                token_group_pmask <= cache_pmask[expected_cache_addr];
                token_group_cmask <= cache_cmask[expected_cache_addr];
                cache_valid[expected_cache_addr] <= 1'b0;
                token_idx <= 0;
                token_active <= 1'b1;
                waiting_output <= 1'b0;
            end else if (token_fire) begin
                if (group_token_end) begin
                    token_active <= 1'b0;
                    /* Only the final K group closes the complete PW
                     * reduction.  Intermediate groups hand the output-
                     * stationary array back to the descriptor/cache
                     * scheduler without causing replay or requantization. */
                    waiting_output <= token_group_last;
                    if (!token_group_last)
                        pw_group_expect <= pw_group_expect + 1'b1;
                end else begin
                    token_idx <= token_idx + 1'b1;
                end
            end
            case ({group_data_fire, cache_start_fire})
                2'b10: cache_count <= cache_count + 1'b1;
                2'b01: cache_count <= cache_count - 1'b1;
                default: ;
            endcase
            if (output_fire && waiting_output) begin
                waiting_output <= 1'b0;
                if (token_group_last) begin
                    if (pw_row_expect + 1'b1 >= row_count_reg)
                        final_output_done <= 1'b1;
                    else begin
                        pw_row_expect <= pw_row_expect + 1'b1;
                        pw_group_expect <= 0;
                    end
                end else begin
                    pw_group_expect <= pw_group_expect + 1'b1;
                end
            end

            if (final_condition)
                state <= ST_RELEASE;
            if ((state == ST_RELEASE) && release_ready_i) begin
                done <= 1'b1;
                state <= ST_IDLE;
            end
        end
    end
endmodule

`default_nettype wire
