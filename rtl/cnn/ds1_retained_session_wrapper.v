`timescale 1ns/1ps
`default_nettype none

/*
 * Standalone retained-session proof for two adjacent DS1 2x8 microgroups.
 *
 * The source-memory side is deliberately kept outside the word-window/DW
 * shell.  ds1_group_fill_address_adapter translates the shell's 160 linear
 * word requests to the global pixel-major source layout and inserts SAME
 * padding words in order.  One 4x10 fill is then consumed by one 2x8 DW job;
 * the committed tagless result is retained while ds1_pw_replay_controller
 * performs its eight row/Cout jobs.  The second microgroup repeats this
 * sequence without resetting any child.  Banks alternate to make reuse
 * visible at both ownership boundaries.
 */
module ds1_retained_session_wrapper #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH = 8,
    parameter integer FIFO_DEPTH = 8,
    parameter integer OUTPUT_HEIGHT = 2,
    /* One start normally covers two adjacent 2x8 microgroups.  Set to one
     * when an outer DS1 scheduler owns the 64 individual layer jobs. */
    parameter integer MICROGROUPS_PER_START = 2,
    /* When set, a one-microgroup session accepts the next descriptor as soon
     * as PW starts.  The inactive retained bank is filled while the current
     * bank is replayed; the next DW command is fenced by both completions. */
    parameter integer ENABLE_PREFILL_OVERLAP = 0
) (
    input wire clk, input wire rst_n,

    input wire start_valid, output wire start_ready,
    input wire [ADDR_WIDTH-1:0] input_base_addr,
    input wire [5:0] global_y, input wire [5:0] global_x,
    input wire [7:0] input_zero_point,
    input wire [EPOCH_WIDTH-1:0] start_epoch,
    input wire [TILE_WIDTH-1:0] start_tile,

    output wire mem_req_valid, input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,

    input wire cfg_valid, output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,

    /* Explicit DW output post-processing controls. */
    input wire [31:0] dw_output_zero_point,
    input wire [31:0] dw_activation_min,
    input wire [31:0] dw_activation_max,

    input wire signed [63:0] pw_weight_vec,
    /* Retained replay weight lookup boundary.  The external table must
     * provide pw_weight_vec for this K/Cout request while weight_valid is
     * asserted and hold it until the read is accepted. */
    output wire weight_valid,
    output wire [3:0] weight_k_index,
    output wire [1:0] weight_cout_group,
    output wire out_valid, input wire out_ready,
    output wire out_row_idx, output wire [1:0] out_cout_group,
    output wire signed [2047:0] out_psum,

    output reg [1:0] state,
    output reg [1:0] microgroup,
    output reg [31:0] fill_count,
    output reg [31:0] dw_done_count,
    output reg [31:0] replay_release_count,
    /* Number of accepted look-ahead descriptors (one per overlapped job). */
    output reg [7:0] overlap_count,
    output wire error,
    output wire busy,
    output reg done
);
    localparam [1:0] ST_IDLE = 2'd0, ST_CONTEXT = 2'd1,
                     ST_FILL = 2'd2, ST_DW = 2'd3;
    localparam [3:0] PH_FILL = 4'd0, PH_DW = 4'd1,
                     PH_PW_START = 4'd2, PH_PW_RUN = 4'd3,
                     PH_NEXT = 4'd4, PH_OVERLAP_CONTEXT = 4'd5,
                     PH_OVERLAP_FILL = 4'd6, PH_OVERLAP_WAIT = 4'd7,
                     PH_WAIT_NEXT_FILL = 4'd8;
    reg [3:0] phase;

    reg [ADDR_WIDTH-1:0] input_base_q;
    reg [5:0] global_y_q, global_x_q;
    reg [7:0] zero_point_q;
    reg [EPOCH_WIDTH-1:0] epoch_q;
    reg [TILE_WIDTH-1:0] tile_q;

    /* Descriptor captured for the prefill which runs behind the current PW
     * replay.  The current descriptor registers remain untouched until the
     * release fence, so output metadata cannot change under backpressure. */
    reg [ADDR_WIDTH-1:0] next_input_base_q;
    reg [5:0] next_global_y_q, next_global_x_q;
    reg [7:0] next_zero_point_q;
    reg [EPOCH_WIDTH-1:0] next_epoch_q;
    reg [TILE_WIDTH-1:0] next_tile_q;
    reg next_bank_q;
    reg prefill_requested_q;
    reg next_fill_done_q;
    reg replay_released_q;
    reg bank_q;

    wire session_bank = (ENABLE_PREFILL_OVERLAP != 0) ? bank_q : microgroup[0];
    wire [EPOCH_WIDTH-1:0] session_epoch = (ENABLE_PREFILL_OVERLAP != 0) ?
        epoch_q : (epoch_q + microgroup);
    wire [TILE_WIDTH-1:0] session_tile = (ENABLE_PREFILL_OVERLAP != 0) ?
        tile_q : (tile_q + microgroup);
    wire [5:0] session_y = (ENABLE_PREFILL_OVERLAP != 0) ? global_y_q :
        (global_y_q + (microgroup ? 6'd2 : 6'd0));
    wire fill_is_overlap = (phase == PH_OVERLAP_CONTEXT) ||
                           (phase == PH_OVERLAP_FILL) ||
                           (phase == PH_OVERLAP_WAIT) ||
                           (phase == PH_WAIT_NEXT_FILL);
    wire fill_bank = (ENABLE_PREFILL_OVERLAP != 0 && fill_is_overlap) ?
                     next_bank_q : session_bank;
    wire [EPOCH_WIDTH-1:0] fill_epoch =
        (ENABLE_PREFILL_OVERLAP != 0 && fill_is_overlap) ? next_epoch_q :
        session_epoch;
    wire [TILE_WIDTH-1:0] fill_tile =
        (ENABLE_PREFILL_OVERLAP != 0 && fill_is_overlap) ? next_tile_q :
        session_tile;
    wire [5:0] fill_y =
        (ENABLE_PREFILL_OVERLAP != 0 && fill_is_overlap) ? next_global_y_q :
        session_y;
    wire [ADDR_WIDTH-1:0] fill_input_base =
        (ENABLE_PREFILL_OVERLAP != 0 && fill_is_overlap) ? next_input_base_q :
        input_base_q;
    wire [7:0] fill_zero_point =
        (ENABLE_PREFILL_OVERLAP != 0 && fill_is_overlap) ? next_zero_point_q :
        zero_point_q;

    /* Fill adapter context and the producer's linear 160-word interface. */
    wire adapter_context_valid = ((phase == PH_FILL) ||
                                  (phase == PH_OVERLAP_CONTEXT)) &&
                                 (state == ST_CONTEXT);
    wire adapter_context_ready;
    /* Keep the adapter live for the complete next fill.  Once its fill fence
     * is observed, the wait/replay phases let the adapter retire and become
     * ready for a later descriptor. */
    wire adapter_context_complete = ((phase != PH_FILL) &&
                                     (phase != PH_OVERLAP_CONTEXT) &&
                                     (phase != PH_OVERLAP_FILL) &&
                                     (phase != PH_OVERLAP_WAIT) &&
                                     (phase != PH_WAIT_NEXT_FILL)) ||
                                    ((phase == PH_OVERLAP_WAIT) &&
                                     next_fill_done_q);
    wire producer_req_valid;
    wire producer_req_ready;
    wire [ADDR_WIDTH-1:0] producer_req_addr;
    wire producer_resp_valid;
    wire [31:0] producer_resp_data;
    wire adapter_error;

    ds1_group_fill_address_adapter #(
        .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_fill_adapter (
        .clk(clk), .rst_n(rst_n),
        .context_valid(adapter_context_valid), .context_ready(adapter_context_ready),
        .context_linear_base({ADDR_WIDTH{1'b0}}),
        .context_input_base(fill_input_base), .context_global_y(fill_y),
        .context_global_x((fill_is_overlap) ? next_global_x_q : global_x_q),
        .context_input_zero_point(fill_zero_point),
        .context_complete(adapter_context_complete),
        .producer_req_valid(producer_req_valid), .producer_req_ready(producer_req_ready),
        .producer_req_addr(producer_req_addr), .producer_resp_valid(producer_resp_valid),
        .producer_resp_data(producer_resp_data), .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr),
        .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
        .error(adapter_error)
    );

    wire fill_start_valid = ((phase == PH_FILL) ||
                             (phase == PH_OVERLAP_FILL)) &&
                            (state == ST_FILL);
    wire fill_start_ready;
    wire fill_done_valid;
    wire fill_done_ready = (state == ST_DW) &&
                           ((phase == PH_FILL) ||
                            (phase == PH_OVERLAP_FILL) ||
                            (phase == PH_OVERLAP_WAIT) ||
                            (phase == PH_WAIT_NEXT_FILL));
    wire fill_done_bank;
    wire [EPOCH_WIDTH-1:0] fill_done_epoch;
    wire dw_job_valid = (phase == PH_DW);
    wire dw_job_ready;
    wire dw_done_valid;
    wire dw_done_ready = (phase == PH_DW);
    wire dw_done_bank;
    wire [EPOCH_WIDTH-1:0] dw_done_epoch;
    wire [TILE_WIDTH-1:0] dw_done_tile;
    wire [2:0] dw_done_group;

    wire read_acquire_valid, read_acquire_ready, read_bank;
    wire [EPOCH_WIDTH-1:0] read_epoch;
    wire [TILE_WIDTH-1:0] read_tile;
    wire read_valid, read_ready;
    wire [6:0] read_channel_idx;
    wire [5:0] read_pixel_base;
    wire read_out_valid, read_out_ready;
    wire [63:0] read_out_data;
    wire [7:0] read_out_lane_mask;
    wire read_release_valid, read_release_ready;
    wire [1:0] scratch0_state, scratch1_state;
    wire [31:0] scratch_dw_writes, overlap_cycles, scratch_reads;

    ds_word_window_dw_tagless_stream4_4x8 #(
        .MAX_IN_H(17), .MAX_IN_W(17), .ADDR_WIDTH(ADDR_WIDTH),
        .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH),
        .TILE_WIDTH(TILE_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
        .STREAM4_ONLY(0), .OUTPUT_HEIGHT(OUTPUT_HEIGHT)
    ) u_dw (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_bank), .fill_start_epoch(fill_epoch),
        .fill_start_base_addr({ADDR_WIDTH{1'b0}}),
        .fill_start_word_count(16'd160), .fill_done_valid(fill_done_valid),
        .fill_done_ready(fill_done_ready), .fill_done_bank(fill_done_bank),
        .fill_done_epoch(fill_done_epoch), .mem_req_valid(producer_req_valid),
        .mem_req_ready(producer_req_ready), .mem_req_addr(producer_req_addr),
        .mem_resp_valid(producer_resp_valid), .mem_resp_data(producer_resp_data),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .dw_job_valid(dw_job_valid), .dw_job_ready(dw_job_ready),
        .dw_source_bank(session_bank), .dw_source_epoch(session_epoch),
        .dw_source_base_addr({ADDR_WIDTH{1'b0}}), .dw_source_lane_mask(16'hffff),
        .dw_source_stride(2'd1), .dw_footprint_height(8'd4),
        .dw_footprint_width(8'd10), .dw_footprint_pitch(8'd10),
        .dw_target_bank(session_bank), .dw_target_epoch(session_epoch),
        .dw_target_tile(session_tile), .dw_channel_group(3'd0),
        .dw_group_count(4'd1), .dw_pixel_count(8'd16),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min),
        .dw_activation_max(dw_activation_max), .dw_done_valid(dw_done_valid),
        .dw_done_ready(dw_done_ready), .dw_done_bank(dw_done_bank),
        .dw_done_epoch(dw_done_epoch), .dw_done_tile(dw_done_tile),
        .dw_done_group(dw_done_group), .read_acquire_valid(read_acquire_valid),
        .read_acquire_ready(read_acquire_ready), .read_bank(read_bank),
        .read_epoch(read_epoch), .read_tile(read_tile), .read_valid(read_valid),
        .read_ready(read_ready), .read_channel_idx(read_channel_idx),
        .read_pixel_base(read_pixel_base), .read_out_valid(read_out_valid),
        .read_out_ready(read_out_ready), .read_out_data(read_out_data),
        .read_out_lane_mask(read_out_lane_mask), .read_release_valid(read_release_valid),
        .read_release_ready(read_release_ready), .scratch0_state(scratch0_state),
        .scratch1_state(scratch1_state), .dw_write_count(scratch_dw_writes),
        .overlap_cycles(overlap_cycles), .read_count(scratch_reads),
        .stream4_valid(), .stream4_ready(1'b1), .stream4_pixel(),
        .stream4_lane_base(), .stream4_data(), .stream4_lane_mask()
    );

    wire pw_start_valid = (phase == PH_PW_START);
    wire pw_start_ready;
    wire pw_acquire_valid, pw_acquire_ready, pw_acquire_bank;
    wire [EPOCH_WIDTH-1:0] pw_acquire_epoch;
    wire [TILE_WIDTH-1:0] pw_acquire_tile;
    wire pw_read_valid, pw_read_ready;
    wire [6:0] pw_read_channel_idx;
    wire [5:0] pw_read_pixel_base;
    wire pw_out_valid, pw_out_ready;
    wire [63:0] pw_out_data;
    wire [7:0] pw_out_lane_mask;
    wire pw_release_valid, pw_release_ready, pw_release_bank;
    wire [EPOCH_WIDTH-1:0] pw_release_epoch;
    wire [TILE_WIDTH-1:0] pw_release_tile;
    wire replay_busy, replay_done;

    assign read_acquire_valid = pw_acquire_valid;
    assign pw_acquire_ready = read_acquire_ready;
    assign read_bank = pw_acquire_bank;
    assign read_epoch = pw_acquire_epoch;
    assign read_tile = pw_acquire_tile;
    assign read_valid = pw_read_valid;
    assign pw_read_ready = read_ready;
    assign read_channel_idx = pw_read_channel_idx;
    assign read_pixel_base = pw_read_pixel_base;
    assign pw_out_valid = read_out_valid;
    assign read_out_ready = pw_out_ready;
    assign pw_out_data = read_out_data;
    assign pw_out_lane_mask = read_out_lane_mask;
    assign read_release_valid = pw_release_valid;
    assign pw_release_ready = read_release_ready;

    ds1_pw_replay_controller #(.EPOCH_WIDTH(EPOCH_WIDTH), .TILE_WIDTH(TILE_WIDTH))
    u_replay (
        .clk(clk), .rst_n(rst_n), .start_valid(pw_start_valid),
        .start_ready(pw_start_ready), .start_bank(session_bank),
        .start_epoch(session_epoch), .start_tile(session_tile),
        .start_row0_pixel_base(6'd0), .start_row1_pixel_base(6'd8),
        .pw_acquire_valid(pw_acquire_valid), .pw_acquire_ready(pw_acquire_ready),
        .pw_acquire_bank(pw_acquire_bank), .pw_acquire_epoch(pw_acquire_epoch),
        .pw_acquire_tile(pw_acquire_tile), .pw_read_valid(pw_read_valid),
        .pw_read_ready(pw_read_ready), .pw_read_channel_idx(pw_read_channel_idx),
        .pw_read_pixel_base(pw_read_pixel_base), .pw_out_valid(pw_out_valid),
        .pw_out_ready(pw_out_ready), .pw_out_data(pw_out_data),
        .pw_out_lane_mask(pw_out_lane_mask), .weight_valid(weight_valid),
        .weight_k_index(weight_k_index), .weight_cout_group(weight_cout_group),
        .weight_vec(pw_weight_vec), .out_valid(out_valid), .out_ready(out_ready),
        .out_row_idx(out_row_idx), .out_cout_group(out_cout_group),
        .out_psum(out_psum), .pw_release_valid(pw_release_valid),
        .pw_release_ready(pw_release_ready), .pw_release_bank(pw_release_bank),
        .pw_release_epoch(pw_release_epoch), .pw_release_tile(pw_release_tile),
        .busy(replay_busy), .done(replay_done)
    );

    wire fill_fire = fill_start_valid && fill_start_ready;
    wire context_fire = adapter_context_valid && adapter_context_ready;
    wire fill_done_fire = fill_done_valid && fill_done_ready;
    wire dw_fire = dw_job_valid && dw_job_ready;
    wire dw_done_fire = dw_done_valid && dw_done_ready;
    wire release_fire = pw_release_valid && pw_release_ready;
    wire overlap_start_fire = start_valid && start_ready &&
                              (ENABLE_PREFILL_OVERLAP != 0) &&
                              (MICROGROUPS_PER_START == 1) &&
                              (phase == PH_PW_RUN);

    assign start_ready = rst_n &&
        (((phase == PH_FILL) && (state == ST_IDLE)) ||
         ((ENABLE_PREFILL_OVERLAP != 0) && (MICROGROUPS_PER_START == 1) &&
          (phase == PH_PW_RUN) && (state == ST_DW) &&
          !prefill_requested_q));
    assign busy = rst_n && (phase != PH_FILL || state != ST_IDLE);
    assign error = adapter_error;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            phase <= PH_FILL;
            microgroup <= 2'd0;
            input_base_q <= 0; global_y_q <= 0; global_x_q <= 0;
            zero_point_q <= 0; epoch_q <= 0; tile_q <= 0;
            next_input_base_q <= 0; next_global_y_q <= 0; next_global_x_q <= 0;
            next_zero_point_q <= 0; next_epoch_q <= 0; next_tile_q <= 0;
            next_bank_q <= 1'b1; prefill_requested_q <= 1'b0;
            next_fill_done_q <= 1'b0; bank_q <= 1'b0;
            replay_released_q <= 1'b0;
            fill_count <= 0; dw_done_count <= 0; replay_release_count <= 0;
            overlap_count <= 0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start_valid && start_ready) begin
                if ((ENABLE_PREFILL_OVERLAP != 0) &&
                    (phase == PH_PW_RUN) && (state == ST_DW)) begin
                    /* This is the only legal overlap admission.  Do not
                     * disturb the current descriptor until its PW release. */
                    next_input_base_q <= input_base_addr;
                    next_global_y_q <= global_y;
                    next_global_x_q <= global_x;
                    next_zero_point_q <= input_zero_point;
                    next_epoch_q <= start_epoch;
                    next_tile_q <= start_tile;
                    next_bank_q <= ~session_bank;
                    prefill_requested_q <= 1'b1;
                    next_fill_done_q <= 1'b0;
                    replay_released_q <= 1'b0;
                    overlap_count <= overlap_count + 1'b1;
                    phase <= PH_OVERLAP_CONTEXT;
                    state <= ST_CONTEXT;
                end else begin
                    input_base_q <= input_base_addr; global_y_q <= global_y;
                    global_x_q <= global_x; zero_point_q <= input_zero_point;
                    epoch_q <= start_epoch; tile_q <= start_tile;
                    microgroup <= 2'd0; phase <= PH_FILL; state <= ST_CONTEXT;
                    replay_released_q <= 1'b0;
                    if (ENABLE_PREFILL_OVERLAP != 0)
                        bank_q <= 1'b0;
                end
            end
            if (context_fire) begin
                state <= ST_FILL;
                if (phase == PH_OVERLAP_CONTEXT)
                    phase <= PH_OVERLAP_FILL;
            end
            if (fill_fire) begin
                fill_count <= fill_count + 1'b1;
                state <= ST_DW;
                if (phase == PH_OVERLAP_FILL)
                    phase <= PH_OVERLAP_WAIT;
            end
            if (fill_done_fire) begin
                state <= ST_DW;
                if (phase == PH_WAIT_NEXT_FILL) begin
                    /* PW already released first; this fill fence is now the
                     * sole condition needed to launch the next DW. */
                    input_base_q <= next_input_base_q;
                    global_y_q <= next_global_y_q;
                    global_x_q <= next_global_x_q;
                    zero_point_q <= next_zero_point_q;
                    epoch_q <= next_epoch_q;
                    tile_q <= next_tile_q;
                    bank_q <= next_bank_q;
                    prefill_requested_q <= 1'b0;
                    next_fill_done_q <= 1'b0;
                    phase <= PH_DW;
                end else if (phase == PH_OVERLAP_WAIT) begin
                    if (replay_released_q) begin
                        input_base_q <= next_input_base_q;
                        global_y_q <= next_global_y_q;
                        global_x_q <= next_global_x_q;
                        zero_point_q <= next_zero_point_q;
                        epoch_q <= next_epoch_q;
                        tile_q <= next_tile_q;
                        bank_q <= next_bank_q;
                        prefill_requested_q <= 1'b0;
                        replay_released_q <= 1'b0;
                        phase <= PH_DW;
                    end else begin
                        next_fill_done_q <= 1'b1;
                    end
                end else begin
                    phase <= PH_DW;
                end
            end
            if (dw_fire) state <= ST_DW;
            if (dw_done_fire) begin
                dw_done_count <= dw_done_count + 1'b1;
                phase <= PH_PW_START; state <= ST_DW;
            end
            if (pw_start_valid && pw_start_ready) begin
                phase <= PH_PW_RUN; state <= ST_DW;
            end
            if (release_fire) begin
                replay_release_count <= replay_release_count + 1'b1;
                if ((ENABLE_PREFILL_OVERLAP != 0) &&
                    (MICROGROUPS_PER_START == 1) &&
                    (prefill_requested_q || overlap_start_fire)) begin
                    /* The old bank is free now.  The next DW is admitted only
                     * after its independent fill fence has arrived. */
                    done <= 1'b1;
                    if (next_fill_done_q || fill_done_fire) begin
                        input_base_q <= next_input_base_q;
                        global_y_q <= next_global_y_q;
                        global_x_q <= next_global_x_q;
                        zero_point_q <= next_zero_point_q;
                        epoch_q <= next_epoch_q;
                        tile_q <= next_tile_q;
                        bank_q <= next_bank_q;
                        prefill_requested_q <= 1'b0;
                        next_fill_done_q <= 1'b0;
                        replay_released_q <= 1'b0;
                        phase <= PH_DW;
                        state <= ST_DW;
                    end else if (overlap_start_fire ||
                                 phase == PH_OVERLAP_CONTEXT ||
                                 phase == PH_OVERLAP_FILL) begin
                        /* The replay can finish before adapter context
                         * admission under a long source stall.  Preserve the
                         * fill phase instead of abandoning the prefill. */
                        replay_released_q <= 1'b1;
                    end else begin
                        replay_released_q <= 1'b1;
                        phase <= PH_WAIT_NEXT_FILL;
                        state <= ST_DW;
                    end
                end else if (microgroup == MICROGROUPS_PER_START-1) begin
                    done <= 1'b1; phase <= PH_FILL; state <= ST_IDLE;
                end else begin
                    microgroup <= 2'd1; phase <= PH_FILL; state <= ST_CONTEXT;
                end
            end
        end
    end
endmodule

`default_nettype wire
