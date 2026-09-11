`timescale 1ns/1ps
`default_nettype none

/*
 * Direct DS1 integration vehicle.
 *
 * This shell deliberately instantiates the real 4x8 word-window producer
 * beside ds_group_published_shared64_sweep.  It does not instantiate the
 * ds_group_ready_real_producer legacy wrapper (whose STREAM4_ONLY job fence
 * can replay a command).  One producer job covers one 4x8 macro; stream4's
 * four lane beats are translated into the sweep's two 8-channel groups.
 *
 * The scheduler is intentionally DS1-shaped: 1024 pixels, Cin=16,
 * Cout=32, stride=1.  Its only job is to sequence the 32 producer windows;
 * descriptor FIFO, shared64 PW, and synchronous scratch behavior remain in
 * the sweep vehicle under test.
 */
module ds_group_published_shared64_real_producer #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer FIFO_DEPTH = 2
) (
    input wire clk,
    input wire rst_n,

    input wire start_valid,
    output wire start_ready,
    input wire [10:0] start_pixels,
    input wire [7:0] start_cin,
    input wire [8:0] start_cout,
    input wire start_bank,
    input wire [1:0] start_session,
    input wire [3:0] start_epoch,

    input wire weight_load_valid,
    output wire weight_load_ready,
    input wire [4:0] weight_load_tile,
    input wire [7:0] weight_load_k,
    input wire signed [63:0] weight_load_vec,

    output wire result_valid,
    input wire result_ready,
    output wire [10:0] result_pixel_idx,
    output wire [8:0] result_channel_base,
    output wire [3:0] result_lane_mask,
    output wire signed [31:0] result_data,
    output wire done,
    output wire error,
    output wire [31:0] perf_total_cycles,
    output wire [31:0] perf_dw_writes,
    output wire [31:0] perf_group_descriptors,
    output wire [31:0] perf_pw_tokens,
    output wire [31:0] perf_output_writes,
    output wire [31:0] perf_output_groups,
    output wire [31:0] perf_preload_rows,

    /* Producer configuration/source memory boundary. */
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,

    output wire [31:0] perf_producer_jobs,
    output wire [31:0] perf_producer_stream_beats
);
    localparam [ADDR_WIDTH-1:0] SOURCE_BASE = 24'h100000;
    localparam [ADDR_WIDTH-1:0] LINEAR_BASE = 24'h700000;
    localparam integer FOOTPRINT_WORDS = 6*10*4;

    wire sweep_start_ready;
    wire sweep_dw_ready;
    wire sweep_dw_valid;
    reg [7:0] sweep_dw_macro;
    wire [1:0] sweep_dw_row;
    wire [4:0] sweep_dw_group;
    wire sweep_dw_half;
    wire [2:0] sweep_dw_pixel;
    wire [31:0] sweep_dw_data;
    wire [3:0] sweep_dw_mask;
    wire sweep_dw_last;
    wire sweep_error;

    ds_group_published_shared64_sweep u_sweep (
        .clk(clk), .rst_n(rst_n),
         .start_valid(start_valid), .start_ready(sweep_start_ready),
         .start_pixels(start_pixels), .start_cin(start_cin),
         .start_output_height(11'd0), .start_output_width(11'd8),
         .start_cout(start_cout), .start_bank(start_bank),
        .start_session(start_session), .start_epoch(start_epoch),
        .dw_valid(sweep_dw_valid), .dw_ready(sweep_dw_ready),
        .dw_macro(sweep_dw_macro), .dw_row(sweep_dw_row),
        .dw_group(sweep_dw_group), .dw_channel_half(sweep_dw_half),
        .dw_pixel(sweep_dw_pixel), .dw_data(sweep_dw_data),
        .dw_mask(sweep_dw_mask), .dw_last(sweep_dw_last),
        .weight_load_valid(weight_load_valid),
        .weight_load_ready(weight_load_ready),
        .weight_load_tile(weight_load_tile), .weight_load_k(weight_load_k),
        .weight_load_vec(weight_load_vec), .result_valid(result_valid),
        .result_ready(result_ready), .result_pixel_idx(result_pixel_idx),
        .result_channel_base(result_channel_base),
        .result_lane_mask(result_lane_mask), .result_data(result_data),
        /* The legacy real-producer vehicle relies on the sweep's historical
         * half-scale PW parameters, but the quantization bounds are still
         * explicit interface inputs.  Leaving these ports omitted makes the
         * standalone instance float them, which clamps every shared64 result
         * to zero despite correct scratch rows and accumulators. */
        .pw_output_zero_point_int32(32'sd0),
        .pw_activation_min_int32(32'sh8000_0000),
        .pw_activation_max_int32(32'sh7fff_ffff),
        .done(done), .error(sweep_error), .perf_total_cycles(perf_total_cycles),
        .perf_dw_writes(perf_dw_writes),
        .perf_group_descriptors(perf_group_descriptors),
        .perf_pw_tokens(perf_pw_tokens),
        .perf_output_writes(perf_output_writes),
        .perf_output_groups(perf_output_groups),
        .perf_preload_rows(perf_preload_rows)
    );
    assign start_ready = sweep_start_ready;

    /* One ordered response FIFO ties the real producer's linear word source
     * to the global pixel-major DS1 feature map. */
    reg source_context_valid;
    wire source_context_ready;
    reg [ADDR_WIDTH-1:0] source_linear_base;
    reg [5:0] source_global_y, source_global_x;
    wire source_context_complete;
    wire feature_adapter_error;
    wire producer_req_valid, producer_req_ready;
    wire [ADDR_WIDTH-1:0] producer_req_addr;
    wire producer_resp_valid;
    wire [31:0] producer_resp_data;

    ds1_feature_word_address_adapter #(
        .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(8), .FOOTPRINT_HEIGHT(6),
        .FOOTPRINT_WIDTH(10), .GLOBAL_HEIGHT(32), .GLOBAL_WIDTH(32),
        .CHANNELS(16)
    ) u_feature_adapter (
        .clk(clk), .rst_n(rst_n), .context_valid(source_context_valid),
        .context_ready(source_context_ready),
        .context_linear_base(source_linear_base),
        .context_input_base(SOURCE_BASE), .context_global_y(source_global_y),
        .context_global_x(source_global_x),
        .context_input_zero_point(8'd0),
        .context_complete(source_context_complete),
        .producer_req_valid(producer_req_valid),
        .producer_req_ready(producer_req_ready),
        .producer_req_addr(producer_req_addr),
        .producer_resp_valid(producer_resp_valid),
        .producer_resp_data(producer_resp_data),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .error(feature_adapter_error)
    );

    reg fill_start_valid;
    wire fill_start_ready;
    reg fill_start_bank;
    reg [3:0] fill_start_epoch;
    reg [ADDR_WIDTH-1:0] fill_start_base_addr;
    reg [WORD_COUNT_WIDTH-1:0] fill_start_word_count;
    wire fill_done_valid;
    wire fill_done_ready;
    wire fill_done_bank;
    wire [3:0] fill_done_epoch;

    reg producer_job_valid;
    wire producer_job_ready;
    reg producer_source_bank;
    reg [3:0] producer_source_epoch;
    wire producer_done_valid;
    wire producer_done_ready;

    wire stream4_valid;
    wire stream4_ready;
    wire [5:0] stream4_pixel;
    wire [1:0] stream4_lane_base;
    wire [31:0] stream4_data;
    wire [3:0] stream4_lane_mask;
    wire [31:0] producer_dw_write_count;
    wire [31:0] producer_overlap_cycles;
    wire [31:0] producer_read_count;

    ds_word_window_dw_tagless_stream4_4x8 #(
        .MAX_IN_H(17), .MAX_IN_W(17), .ADDR_WIDTH(ADDR_WIDTH),
        .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH),
        .TILE_WIDTH(8), .FIFO_DEPTH(FIFO_DEPTH), .USE_QUADLOCAL_CORE(1),
        .USE_LOCAL_REQUANT(1), .STREAM4_ONLY(1), .OUTPUT_HEIGHT(4)
    ) u_real_producer (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr),
        .fill_start_word_count(fill_start_word_count),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(producer_req_valid), .mem_req_ready(producer_req_ready),
        .mem_req_addr(producer_req_addr), .mem_resp_valid(producer_resp_valid),
        .mem_resp_data(producer_resp_data), .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .dw_job_valid(producer_job_valid), .dw_job_ready(producer_job_ready),
        .dw_source_bank(producer_source_bank),
        .dw_source_epoch(producer_source_epoch),
        .dw_source_base_addr(SOURCE_BASE), .dw_source_lane_mask(16'hffff),
        .dw_source_stride(2'd1), .dw_footprint_height(8'd6),
        .dw_footprint_width(8'd10), .dw_footprint_pitch(8'd10),
        .dw_target_bank(producer_source_bank),
        .dw_target_epoch(producer_source_epoch), .dw_target_tile(8'd0),
        .dw_channel_group(3'd0), .dw_group_count(4'd1),
        .dw_pixel_count(8'd32), .dw_output_zero_point(32'd0),
        .dw_activation_min(32'sh8000_0000),
        .dw_activation_max(32'sh7fff_ffff),
        .dw_done_valid(producer_done_valid),
        .dw_done_ready(producer_done_ready), .dw_done_bank(),
        .dw_done_epoch(), .dw_done_tile(), .dw_done_group(),
        .read_acquire_valid(1'b0), .read_acquire_ready(), .read_bank(1'b0),
        .read_epoch(4'd0), .read_tile(8'd0), .read_valid(1'b0),
        .read_ready(), .read_channel_idx(7'd0), .read_pixel_base(6'd0),
        .read_out_valid(), .read_out_ready(1'b1), .read_out_data(),
        .read_out_lane_mask(), .read_release_valid(1'b0),
        .read_release_ready(), .scratch0_state(), .scratch1_state(),
        .dw_write_count(producer_dw_write_count),
        .overlap_cycles(producer_overlap_cycles), .read_count(producer_read_count),
        .stream4_valid(stream4_valid), .stream4_ready(stream4_ready),
        .stream4_pixel(stream4_pixel), .stream4_lane_base(stream4_lane_base),
        .stream4_data(stream4_data), .stream4_lane_mask(stream4_lane_mask)
    );

    localparam [2:0] S_IDLE = 3'd0, S_CONTEXT = 3'd1, S_FILL = 3'd2,
                     S_WAIT_FILL = 3'd3, S_JOB = 3'd4, S_WAIT_JOB = 3'd5,
                     S_FINISH = 3'd6;
    reg [2:0] sched_state;
    reg [5:0] macro_q;
    reg [3:0] base_epoch_q;
    wire [3:0] macro_epoch = base_epoch_q + macro_q + 1'b1;
    wire [5:0] macro_y = {3'd0,macro_q[5:3]} << 2;
    wire [5:0] macro_x = {3'd0,macro_q[2:0]} << 3;
    wire start_fire = start_valid && sweep_start_ready;
    assign source_context_complete = fill_done_valid && fill_done_ready;
    assign fill_done_ready = (sched_state == S_WAIT_FILL);
    assign producer_done_ready = (sched_state == S_WAIT_JOB);
    assign stream4_ready = (sched_state == S_WAIT_JOB) && sweep_dw_ready;
    assign sweep_dw_valid = (sched_state == S_WAIT_JOB) && stream4_valid;
    assign sweep_dw_row = stream4_pixel[5:3];
    assign sweep_dw_group = {4'd0,stream4_lane_base[1]};
    assign sweep_dw_half = stream4_lane_base[0];
    assign sweep_dw_pixel = stream4_pixel[2:0];
    assign sweep_dw_data = stream4_data;
    assign sweep_dw_mask = stream4_lane_mask;
    assign sweep_dw_last = (macro_q == 6'd31) && (stream4_pixel == 6'd31) &&
                           (stream4_lane_base == 2'd3);

    assign perf_producer_jobs = producer_job_count_q;
    assign perf_producer_stream_beats = producer_stream_count_q;
    assign error = sweep_error | feature_adapter_error;
    reg [31:0] producer_job_count_q, producer_stream_count_q;
    reg [7:0] job_stream_count_q;
    reg job_done_seen_q;
    wire stream_fire = stream4_valid && stream4_ready;
    wire job_fire = producer_job_valid && producer_job_ready;

    always @* begin
        source_context_valid = (sched_state == S_CONTEXT);
        source_linear_base = LINEAR_BASE + (macro_q * 24'h1000);
        source_global_y = macro_y;
        source_global_x = macro_x;
        fill_start_valid = (sched_state == S_FILL);
        fill_start_bank = macro_q[0];
        fill_start_epoch = macro_epoch;
        fill_start_base_addr = LINEAR_BASE + (macro_q * 24'h1000);
        fill_start_word_count = FOOTPRINT_WORDS;
        producer_job_valid = (sched_state == S_JOB);
        producer_source_bank = macro_q[0];
        producer_source_epoch = macro_epoch;
        sweep_dw_macro = macro_q;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sched_state <= S_IDLE;
            macro_q <= 0;
            base_epoch_q <= 0;
            producer_job_count_q <= 0;
            producer_stream_count_q <= 0;
            job_stream_count_q <= 0;
            job_done_seen_q <= 1'b0;
        end else begin
            if (stream_fire)
                producer_stream_count_q <= producer_stream_count_q + 1'b1;
            if (job_fire)
                begin
                    producer_job_count_q <= producer_job_count_q + 1'b1;
                    job_stream_count_q <= 0;
                    job_done_seen_q <= 1'b0;
                end
            if (stream_fire)
                job_stream_count_q <= job_stream_count_q + 1'b1;
            if (producer_done_valid && producer_done_ready)
                job_done_seen_q <= 1'b1;
            case (sched_state)
                S_IDLE: if (start_fire) begin
                    macro_q <= 0;
                    base_epoch_q <= start_epoch;
                    sched_state <= S_CONTEXT;
                end
                S_CONTEXT: if (source_context_ready)
                    sched_state <= S_FILL;
                S_FILL: if (fill_start_ready)
                    sched_state <= S_WAIT_FILL;
                S_WAIT_FILL: if (fill_done_valid && fill_done_ready)
                    sched_state <= S_JOB;
                S_JOB: if (producer_job_ready)
                    sched_state <= S_WAIT_JOB;
                /* The producer's compute-done fence can precede the final
                 * four serializer beats.  Retain the job ownership until
                 * all 32 pixels x 4 stream4 beats have crossed the sweep. */
                S_WAIT_JOB: if ((job_done_seen_q ||
                                 (producer_done_valid && producer_done_ready)) &&
                                stream_fire && (job_stream_count_q == 8'd127)) begin
                    if (macro_q == 6'd31) sched_state <= S_FINISH;
                    else begin
                        macro_q <= macro_q + 1'b1;
                        sched_state <= S_CONTEXT;
                    end
                end
                S_FINISH: if (done) sched_state <= S_IDLE;
                default: sched_state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
