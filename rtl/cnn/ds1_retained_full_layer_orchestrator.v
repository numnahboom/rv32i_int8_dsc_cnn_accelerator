`timescale 1ns/1ps
`default_nettype none

/*
 * Standalone full-layer composition for the retained DS1 path.
 *
 * ds1_retained_microgroup_bridge enumerates the 64 2x8 microgroups of the
 * 32x32x16 -> 32x32x32 layer.  This module accepts one bridge job at a time,
 * runs it through a single-microgroup retained session, and routes the eight
 * resulting 8x8 PW blocks into ds1_final_requant_write.  The next bridge job
 * is not accepted until the session has released its retained bank and all
 * 512 final bytes (8 pixels x 32 channels) have handshaken at the layer
 * output.
 *
 * The DW configuration stream is passed through to the session before (or
 * between) layer starts.  PW weight lookup is likewise passed through as a
 * narrow valid/index boundary; the external table supplies pw_weight_vec for
 * the requested K/Cout pair.  Final PW quantization is captured by the final
 * writer for each raw block, preserving the production fixed-point path.
 */
module ds1_retained_full_layer_orchestrator #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH = 8,
    parameter integer FIFO_DEPTH = 8,
    /* The original standalone proof supplies one 8-channel final-quantizer
     * vector.  The runner integration owns the complete 32-channel table and
     * enables this selector so each Cout replay group gets its own params. */
    parameter integer USE_FINAL_PARAM_TABLE = 0
) (
    input wire clk,
    input wire rst_n,

    input wire start_valid,
    output wire start_ready,
    input wire [ADDR_WIDTH-1:0] input_base_addr,
    input wire [7:0] input_zero_point,
    input wire [EPOCH_WIDTH-1:0] start_epoch,

    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,

    input wire cfg_valid,
    output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,
    input wire [31:0] dw_output_zero_point,
    input wire [31:0] dw_activation_min,
    input wire [31:0] dw_activation_max,

    input wire signed [63:0] pw_weight_vec,
    output wire weight_valid,
    output wire [3:0] weight_k_index,
    output wire [1:0] weight_cout_group,

    input wire signed [255:0] final_bias_vec,
    input wire signed [255:0] final_multiplier_vec,
    input wire [47:0] final_shift_vec,
    input wire signed [1023:0] final_bias_table,
    input wire signed [1023:0] final_multiplier_table,
    input wire [191:0] final_shift_table,
    input wire signed [31:0] final_output_zero_point_int32,
    input wire signed [31:0] final_activation_min_int32,
    input wire signed [31:0] final_activation_max_int32,

    output wire out_valid_vec4,
    input wire out_ready_vec4,
    output wire signed [31:0] out_data_int8_vec4,
    output wire [9:0] out_pixel_idx_vec4,
    output wire [5:0] out_channel_idx_vec4,
    output wire [15:0] out_byte_addr_vec4,
    output wire [15:0] out_word_addr_vec4,
    output wire [3:0] out_byte_en_vec4,

    output wire error,
    output wire busy,
    output reg done,
    /* DS1-only overlap evidence: accepted look-ahead jobs and producer-side
     * overlap cycles (the former remains meaningful even when the generic
     * producer metric is not enabled). */
    output wire [7:0] overlap_count,
    output wire [31:0] overlap_cycles
);
    localparam [2:0] ST_IDLE       = 3'd0;
    localparam [2:0] ST_WAIT_JOB   = 3'd1;
    localparam [2:0] ST_START_SESS = 3'd2;
    localparam [2:0] ST_REPLAY     = 3'd3;
    localparam [2:0] ST_WAIT_BYTES = 3'd4;

    reg [2:0] state;
    reg [ADDR_WIDTH-1:0] input_base_q;
    reg [7:0] input_zero_point_q;
    reg [3:0] job_tile_q;
    reg [EPOCH_WIDTH-1:0] job_epoch_q;
    reg [5:0] job_global_y_q, job_global_x_q;
    reg [9:0] job_pixel_base_q;
    reg last_job_q;
    reg [3:0] raw_group_count_q;
    reg [9:0] byte_count_q;
    reg [7:0] jobs_started_q;
    reg [7:0] jobs_completed_q;
    reg [15:0] bytes_emitted_q;
    reg [15:0] vec4_writes_q;
    reg error_q;

    /* Bridge/session look-ahead slots for DS1 prefill overlap. */
    reg pending_job_valid_q;
    reg [3:0] pending_tile_q;
    reg [EPOCH_WIDTH-1:0] pending_epoch_q;
    reg [5:0] pending_y_q, pending_x_q;
    reg [9:0] pending_pixel_base_q;
    reg pending_last_q;
    reg next_job_valid_q;
    reg [3:0] next_tile_q;
    reg [EPOCH_WIDTH-1:0] next_epoch_q;
    reg [5:0] next_y_q, next_x_q;
    reg [9:0] next_pixel_base_q;
    reg next_last_q;

    /* Global 64-job scheduler.  Its map outputs are retained for a caller
     * that wants to inspect the source footprint; the composed datapath uses
     * the session's adapter directly for the accepted job. */
    wire bridge_start_valid = (state == ST_IDLE) && start_valid;
    wire bridge_start_ready;
    wire bridge_start_fire = bridge_start_valid && bridge_start_ready;
    wire bridge_job_valid;
    wire bridge_job_ready = (state == ST_WAIT_JOB) ||
                            ((state == ST_REPLAY) && !pending_job_valid_q);
    wire bridge_job_fire = bridge_job_valid && bridge_job_ready;
    wire [3:0] bridge_job_tile;
    wire [1:0] bridge_job_micro;
    wire [7:0] bridge_job_sequence;
    wire bridge_job_bank;
    wire [EPOCH_WIDTH-1:0] bridge_job_epoch;
    wire [5:0] bridge_job_y, bridge_job_x;
    wire [9:0] bridge_job_pixel_base;
    wire [5:0] bridge_job_cout_base;
    wire [7:0] bridge_job_pixel_count, bridge_job_cout_count;
    wire bridge_map_padding;
    wire [ADDR_WIDTH-1:0] bridge_map_addr;
    wire [7:0] bridge_map_padding_word;

    ds1_retained_microgroup_bridge #(
        .ADDR_WIDTH(ADDR_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH)
    ) u_bridge (
        .clk(clk), .rst_n(rst_n),
        .start_valid(bridge_start_valid), .start_ready(bridge_start_ready),
        .input_base_addr(input_base_addr),
        .input_zero_point(input_zero_point), .start_epoch(start_epoch),
        .job_valid(bridge_job_valid), .job_ready(bridge_job_ready),
        .job_tile_index(bridge_job_tile), .job_micro_row(bridge_job_micro),
        .job_sequence(bridge_job_sequence), .job_bank(bridge_job_bank),
        .job_epoch(bridge_job_epoch), .job_global_y(bridge_job_y),
        .job_global_x(bridge_job_x),
        .job_global_pixel_base(bridge_job_pixel_base),
        .job_cout_base(bridge_job_cout_base),
        .job_pixel_count(bridge_job_pixel_count),
        .job_cout_count(bridge_job_cout_count),
        .fill_word_index(8'd0), .map_is_padding(bridge_map_padding),
        .map_addr(bridge_map_addr),
        .map_padding_word(bridge_map_padding_word), .done()
    );

    assign start_ready = rst_n && (state == ST_IDLE) && bridge_start_ready;

    /* The retained session is intentionally single-microgroup.  The outer
     * bridge owns layer ordering and therefore supplies one fresh context
     * for every accepted 2x8 job. */
    wire session_start_valid = (state == ST_START_SESS) ||
                               ((state == ST_REPLAY) && pending_job_valid_q);
    wire session_start_ready;
    wire session_start_fire = session_start_valid && session_start_ready;
    wire session_out_valid;
    wire session_out_ready;
    wire session_out_row;
    wire [1:0] session_out_cout_group;
    wire signed [2047:0] session_out_psum;
    wire session_done;
    wire session_error;
    wire session_busy;
    wire [31:0] session_fill_count;
    wire [31:0] session_dw_done_count;
    wire [31:0] session_release_count;

    wire session_cfg_ready;
    wire session_weight_valid;
    wire [3:0] session_weight_k_index;
    wire [1:0] session_weight_cout_group;

    ds1_retained_session_wrapper #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH),
        .EPOCH_WIDTH(EPOCH_WIDTH), .TILE_WIDTH(TILE_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH), .OUTPUT_HEIGHT(2),
        .MICROGROUPS_PER_START(1), .ENABLE_PREFILL_OVERLAP(1)
    ) u_session (
        .clk(clk), .rst_n(rst_n),
        .start_valid(session_start_valid), .start_ready(session_start_ready),
        .input_base_addr(input_base_q),
        .global_y((state == ST_REPLAY) ? pending_y_q : job_global_y_q),
        .global_x((state == ST_REPLAY) ? pending_x_q : job_global_x_q),
        .input_zero_point(input_zero_point_q),
        .start_epoch((state == ST_REPLAY) ? pending_epoch_q : job_epoch_q),
        .start_tile({{(TILE_WIDTH-4){1'b0}},
                     (state == ST_REPLAY) ? pending_tile_q : job_tile_q}),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .cfg_valid(cfg_valid),
        .cfg_ready(session_cfg_ready), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min),
        .dw_activation_max(dw_activation_max),
        .pw_weight_vec(pw_weight_vec), .weight_valid(session_weight_valid),
        .weight_k_index(session_weight_k_index),
        .weight_cout_group(session_weight_cout_group),
        .out_valid(session_out_valid), .out_ready(session_out_ready),
        .out_row_idx(session_out_row),
        .out_cout_group(session_out_cout_group),
        .out_psum(session_out_psum), .state(), .microgroup(),
        .fill_count(session_fill_count), .dw_done_count(session_dw_done_count),
        .replay_release_count(session_release_count), .error(session_error),
        .busy(session_busy), .done(session_done), .overlap_count(overlap_count)
    );

    assign cfg_ready = session_cfg_ready;
    assign weight_valid = session_weight_valid;
    assign weight_k_index = session_weight_k_index;
    assign weight_cout_group = session_weight_cout_group;

    /* One raw row/Cout block maps to eight pixels in one of the four Cout
     * groups.  job_pixel_base_q is a global pixel-major base, so advancing
     * to the second 8-pixel row uses the global row stride (32), not the
     * local tile width.  final_requant_write drains all eight lanes in NHWC
     * order. */
    wire final_valid_in;
    wire final_ready_in;
    wire final_valid_out;
    wire final_busy;
    wire final_output_fire = final_valid_out && out_ready_vec4;
    wire raw_output_fire = session_out_valid && session_out_ready;
    wire [9:0] final_pixel_base = job_pixel_base_q +
                                   (session_out_row ? 10'd32 : 10'd0);
    wire [5:0] final_cout_base = {session_out_cout_group, 3'b000};
    wire signed [255:0] final_bias_selected;
    wire signed [255:0] final_multiplier_selected;
    wire [47:0] final_shift_selected;

    generate
        if (USE_FINAL_PARAM_TABLE != 0) begin : gen_final_param_table
            assign final_bias_selected =
                final_bias_table[(session_out_cout_group * 256) +: 256];
            assign final_multiplier_selected =
                final_multiplier_table[(session_out_cout_group * 256) +: 256];
            assign final_shift_selected =
                final_shift_table[(session_out_cout_group * 48) +: 48];
        end else begin : gen_final_param_vector
            assign final_bias_selected = final_bias_vec;
            assign final_multiplier_selected = final_multiplier_vec;
            assign final_shift_selected = final_shift_vec;
        end
    endgenerate

    assign session_out_ready = (state == ST_REPLAY) && final_ready_in;
    assign final_valid_in = (state == ST_REPLAY) && session_out_valid;

    ds1_final_requant_write u_final (
        .clk(clk), .rst_n(rst_n), .valid_in(final_valid_in),
        .ready_in(final_ready_in), .psum_in(session_out_psum),
        .pixel_base(final_pixel_base), .cout_base(final_cout_base),
         .bias_vec(final_bias_selected),
         .multiplier_vec(final_multiplier_selected),
         .shift_vec(final_shift_selected),
        .output_zero_point_int32(final_output_zero_point_int32),
        .activation_min_int32(final_activation_min_int32),
        .activation_max_int32(final_activation_max_int32),
        .valid_out_vec4(final_valid_out), .ready_out_vec4(out_ready_vec4),
        .out_data_int8_vec4(out_data_int8_vec4),
        .out_pixel_idx_vec4(out_pixel_idx_vec4),
        .out_channel_idx_vec4(out_channel_idx_vec4),
        .out_byte_addr_vec4(out_byte_addr_vec4),
        .out_word_addr_vec4(out_word_addr_vec4),
        .out_byte_en_vec4(out_byte_en_vec4),
        .busy(final_busy)
    );

    assign out_valid_vec4 = final_valid_out;
    assign busy = rst_n && (state != ST_IDLE);
    assign error = error_q || session_error;
    assign overlap_cycles = u_session.overlap_cycles;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            input_base_q <= {ADDR_WIDTH{1'b0}};
            input_zero_point_q <= 8'd0;
            job_tile_q <= 4'd0;
            job_epoch_q <= {EPOCH_WIDTH{1'b0}};
            job_global_y_q <= 6'd0;
            job_global_x_q <= 6'd0;
            job_pixel_base_q <= 10'd0;
            last_job_q <= 1'b0;
            raw_group_count_q <= 4'd0;
            byte_count_q <= 10'd0;
            jobs_started_q <= 8'd0;
            jobs_completed_q <= 8'd0;
            bytes_emitted_q <= 16'd0;
            vec4_writes_q <= 16'd0;
            error_q <= 1'b0;
            pending_job_valid_q <= 1'b0;
            pending_tile_q <= 4'd0;
            pending_epoch_q <= {EPOCH_WIDTH{1'b0}};
            pending_y_q <= 6'd0; pending_x_q <= 6'd0;
            pending_pixel_base_q <= 10'd0; pending_last_q <= 1'b0;
            next_job_valid_q <= 1'b0;
            next_tile_q <= 4'd0;
            next_epoch_q <= {EPOCH_WIDTH{1'b0}};
            next_y_q <= 6'd0; next_x_q <= 6'd0;
            next_pixel_base_q <= 10'd0; next_last_q <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (bridge_start_fire) begin
                input_base_q <= input_base_addr;
                input_zero_point_q <= input_zero_point;
                state <= ST_WAIT_JOB;
            end
            if (bridge_job_fire) begin
                if (state == ST_REPLAY) begin
                    pending_job_valid_q <= 1'b1;
                    pending_tile_q <= bridge_job_tile;
                    pending_epoch_q <= bridge_job_epoch;
                    pending_y_q <= bridge_job_y;
                    pending_x_q <= bridge_job_x;
                    pending_pixel_base_q <= bridge_job_pixel_base;
                    pending_last_q <= (bridge_job_sequence == 8'd63);
                end else begin
                    job_tile_q <= bridge_job_tile;
                    job_epoch_q <= bridge_job_epoch;
                    job_global_y_q <= bridge_job_y;
                    job_global_x_q <= bridge_job_x;
                    job_pixel_base_q <= bridge_job_pixel_base;
                    last_job_q <= (bridge_job_sequence == 8'd63);
                    raw_group_count_q <= 4'd0;
                    byte_count_q <= 10'd0;
                    state <= ST_START_SESS;
                end
                jobs_started_q <= jobs_started_q + 1'b1;
            end
            if (session_start_fire) begin
                if (state == ST_START_SESS) begin
                    state <= ST_REPLAY;
                end else if (state == ST_REPLAY) begin
                    next_job_valid_q <= 1'b1;
                    next_tile_q <= pending_tile_q;
                    next_epoch_q <= pending_epoch_q;
                    next_y_q <= pending_y_q;
                    next_x_q <= pending_x_q;
                    next_pixel_base_q <= pending_pixel_base_q;
                    next_last_q <= pending_last_q;
                    pending_job_valid_q <= 1'b0;
                end
            end

            if (raw_output_fire)
                raw_group_count_q <= raw_group_count_q + 1'b1;
            if (final_output_fire) begin
                byte_count_q <= byte_count_q + 10'd4;
                bytes_emitted_q <= bytes_emitted_q + 16'd4;
                vec4_writes_q <= vec4_writes_q + 16'd1;
            end

            /* Session done is the release fence.  The final writer may still
             * contain the eighth raw block, so wait for its byte fence too. */
            if ((state == ST_REPLAY) && session_done && next_job_valid_q) begin
                if (raw_group_count_q != 4'd8)
                    error_q <= 1'b1;
                job_tile_q <= next_tile_q;
                job_epoch_q <= next_epoch_q;
                job_global_y_q <= next_y_q;
                job_global_x_q <= next_x_q;
                job_pixel_base_q <= next_pixel_base_q;
                last_job_q <= next_last_q;
                raw_group_count_q <= 4'd0;
                jobs_completed_q <= jobs_completed_q + 1'b1;
                next_job_valid_q <= session_start_fire;
                if (session_start_fire) begin
                    next_tile_q <= pending_tile_q;
                    next_epoch_q <= pending_epoch_q;
                    next_y_q <= pending_y_q;
                    next_x_q <= pending_x_q;
                    next_pixel_base_q <= pending_pixel_base_q;
                    next_last_q <= pending_last_q;
                    pending_job_valid_q <= 1'b0;
                end
            end else if ((state == ST_REPLAY) && session_done) begin
                if (raw_group_count_q != 4'd8)
                    error_q <= 1'b1;
                state <= ST_WAIT_BYTES;
            end
            if ((state == ST_WAIT_BYTES) && !final_busy &&
                (raw_group_count_q == 4'd8) &&
                (bytes_emitted_q == 16'd32768)) begin
                jobs_completed_q <= jobs_completed_q + 1'b1;
                if (last_job_q) begin
                    done <= 1'b1;
                    state <= ST_IDLE;
                end else begin
                    state <= ST_WAIT_JOB;
                end
            end
        end
    end
endmodule

`default_nettype wire
