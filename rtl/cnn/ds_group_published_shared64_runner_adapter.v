`timescale 1ns/1ps
`default_nettype none

/*
 * Full descriptor-facing bridge for the producer-driven shared64 DS path.
 * One 4x8 DW producer is reused for every 16-channel slice; its stream is
 * published into one ds_group_published_shared64_sweep instance.  Thus the
 * only 64-MAC arithmetic island remains the sweep's shared array while Cin
 * up to 128 is covered by sequential channel-slice jobs.
 *
 * This is an optional backend boundary.  It owns no descriptor fetch or
 * parameter SRAM protocol: callers present the same scalar DS config writes
 * emitted by cnn_layer_runner and the bridge presents one word SRAM source
 * plus packed output writes.
 */
module ds_group_published_shared64_runner_adapter #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer SRAM_ADDR_WIDTH = 15,
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer FIFO_DEPTH = 8
) (
    input wire clk, input wire rst_n,
    input wire start_valid, output wire start_ready,
    input wire [31:0] input_base_addr, input wire [31:0] output_base_addr,
    input wire [15:0] input_height, input wire [15:0] input_width,
    input wire [15:0] input_channels, input wire [15:0] output_channels,
    input wire [7:0] stride, input wire [7:0] input_zero_point,
    input wire [31:0] dw_output_zero_point,
    input wire signed [31:0] dw_activation_min,
    input wire signed [31:0] dw_activation_max,
    input wire signed [31:0] pw_output_zero_point,
    input wire signed [31:0] pw_activation_min,
    input wire signed [31:0] pw_activation_max,
    input wire config_write_en, input wire [3:0] config_target,
    input wire [15:0] config_index, input wire [31:0] config_data,
    /* DW weight writes arrive in channel-major order.  The descriptor
     * wrapper carries the already-registered row/tap tuple so the physical
     * RAM write does not infer a variable divide/modulo cone from the scalar
     * ABI index.  Direct benches may derive these two fields from
     * config_index; the production top keeps them as traversal counters. */
    input wire [6:0] config_dw_channel, input wire [3:0] config_dw_tap,
    /* Packed weight words are accepted as one physical-store transaction.
     * The top wrapper still performs one real external read per word and
     * supplies the valid-byte mask, but need not replay four scalar writes
     * through this boundary.  config_word_index is the aligned byte index
     * of the word in the canonical external array; only weight targets use
     * this sideband. */
    input wire config_word_write_en, input wire [3:0] config_word_target,
    input wire [15:0] config_word_index, input wire [31:0] config_word_data,
    input wire [3:0] config_word_be,
    /* Configuration stores are double-buffered so a following DS layer can
     * be loaded while the active layer is still reading its own weights.
     * Unconnected legacy benches are treated as bank zero. */
    input wire config_write_bank,
    input wire config_read_bank,
    input wire config_clear_en,
    input wire config_clear_bank,
    output wire source_word_en, output wire [SRAM_ADDR_WIDTH-1:0] source_word_addr,
    input wire source_word_ready,
    input wire source_word_valid, input wire [31:0] source_word_data,
    output wire output_word_en, output wire [15:0] output_word_addr,
    output wire [31:0] output_word_data, output wire [3:0] output_word_be,
    output wire output_word_last,
    input wire output_word_ready,
    output wire busy, output wire done, output wire error,
    output wire [31:0] perf_cycles, output wire [31:0] perf_dw_writes,
    output wire [31:0] perf_descriptors, output wire [31:0] perf_pw_tokens,
    output wire [31:0] perf_output_writes, output wire [31:0] perf_jobs,
    output wire [31:0] perf_stream_beats,
    output wire [31:0] config_accept_count, output wire [31:0] config_phase_count,
    output wire [31:0] config_word_accept_count,
    output wire [31:0] config_scalar_write_count
);
    localparam [3:0] CFG_DW_WEIGHT=4'd1, CFG_DW_BIAS=4'd2,
                     CFG_DW_MUL=4'd3, CFG_DW_SHIFT=4'd4,
                     CFG_PW_WEIGHT=4'd5, CFG_PW_BIAS=4'd6,
                     CFG_PW_MUL=4'd7, CFG_PW_SHIFT=4'd8;
    localparam integer DW_WEIGHT_DEPTH = MAX_CIN;
    localparam integer PW_WEIGHT_DEPTH = ((MAX_COUT + 7) / 8) * MAX_CIN;
    localparam integer GROUPS = (MAX_CIN + 15) / 16;
    localparam integer TILE_COLS_MAX = 4;
    localparam integer JOB_MAX = 256;
    localparam [3:0] S_IDLE=4'd0, S_SHAPE=4'd1, S_SWEEP_START=4'd2,
                     S_DW_WEIGHT_FETCH=4'd3, S_DW_PARAM_FETCH=4'd4,
                     S_CFG=4'd5, S_CONTEXT=4'd6, S_FILL=4'd7,
                     S_WAIT_FILL=4'd8, S_JOB=4'd9, S_WAIT_JOB=4'd10,
                     S_FINISH=4'd11, S_WAIT_PREFILL=4'd12,
                     S_WAIT_CFG_PREFETCH=4'd13;

    reg [3:0] state;
    reg [4:0] cfg_tap_q;
    reg [4:0] dw_fetch_idx_q;
    reg [4:0] dw_resp_idx_q;
    reg dw_read_valid_q;
    reg [4:0] dw_param_fetch_idx_q;
    reg [4:0] dw_param_resp_idx_q;
    reg dw_param_read_valid_q;
    reg [7:0] macro_q;
    reg [15:0] macro_row_q, macro_col_q;
    reg [3:0] channel_group_q;
    reg [7:0] job_stream_count_q;
    reg [31:0] total_stream_beats_q;
    reg producer_done_seen_q;
    reg [7:0] job_seq_q;
    reg [3:0] base_epoch_q;
    reg [31:0] total_cycles_q;
    /* Descriptor geometry is committed before the sweep start fence.  The
     * runner previously left these expressions as wires from the top-level
     * descriptor registers, which let stride/width/height feed the sweep's
     * target/count logic in the same timing interval as start acceptance. */
    reg [15:0] shape_input_height_q, shape_input_width_q;
    reg [15:0] shape_input_channels_q, shape_output_channels_q;
    reg [7:0] shape_stride_q, shape_input_zero_point_q;
    reg [31:0] shape_input_base_q, shape_output_base_q;
    reg [15:0] out_h_q, out_w_q, tile_cols_q, tile_rows_q;
    reg [15:0] macro_count_q, group_count_q;
    reg [7:0] footprint_h_q, footprint_w_q;
    reg [15:0] output_pixels_q;
    reg shape_valid_q;
    reg [31:0] config_accept_count_q [0:1];
    reg [31:0] config_phase_count_q [0:1];
    reg [31:0] config_word_accept_count_q [0:1];
    reg [31:0] config_scalar_write_count_q [0:1];
    wire config_write_bank_i = (config_write_bank === 1'b1);
    wire config_read_bank_i = (config_read_bank === 1'b1);
    wire config_clear_bank_i = (config_clear_bank === 1'b1);
    reg cfg_active_bank_q;
    reg cfg_prefetch_active_q, cfg_prefetch_param_phase_q,
        cfg_prefetch_read_valid_q, cfg_prefetch_done_q;
    reg [4:0] cfg_prefetch_idx_q, cfg_prefetch_resp_q;
    reg cfg_prefetch_bank_q;
    reg [3:0] cfg_prefetch_group_q;
    reg [7:0] cfg_prefetch_job_seq_q;
    reg [3:0] cfg_prefetch_epoch_q;

    /* One command of look-ahead is enough to remove the fill hole without
     * adding a producer.  The command is captured when the current producer
     * job is admitted; its context and fill can then run while that job is
     * emitting into the shared sweep.  These tags are the ownership fence
     * for the one-entry prefetch command and are deliberately kept separate
     * from the current-job counters. */
    reg prefetch_active_q, prefetch_context_sent_q, prefetch_fill_started_q,
        prefetch_done_q;
    reg [7:0] prefetch_job_seq_q, prefetch_macro_q;
    reg [15:0] prefetch_row_q, prefetch_col_q;
    reg [3:0] prefetch_group_q;
    reg prefetch_bank_q;
    reg [3:0] prefetch_epoch_q;

    /* The configuration ABI is scalar, but physical storage is packed by the
     * consumer.  One 4096x64 PW row contains eight output lanes for one Cin;
     * one 128x72 DW row contains all nine taps for one input channel; and one
     * 128x72 parameter row contains bias/multiplier/shift.  These memories are
     * instantiated as XPM below; the simulation declarations are only a
     * behavioral model of the same single physical store. */
`ifndef SYNTHESIS
    reg signed [63:0] pw_weight_mem [0:1][0:PW_WEIGHT_DEPTH-1];
    reg [71:0] dw_weight_mem [0:1][0:DW_WEIGHT_DEPTH-1];
    reg [71:0] dw_param_mem [0:1][0:MAX_CIN-1];
    reg [71:0] pw_param_mem [0:1][0:MAX_COUT-1];
`endif
    reg [71:0] dw_weight_cache [0:1][0:15];
    reg [71:0] dw_param_cache [0:1][0:15];

    wire [15:0] shape_out_h_calc = (shape_stride_q == 2) ?
                                    ((shape_input_height_q + 1) >> 1) :
                                    shape_input_height_q;
    wire [15:0] shape_out_w_calc = (shape_stride_q == 2) ?
                                    ((shape_input_width_q + 1) >> 1) :
                                    shape_input_width_q;
    wire [15:0] shape_tile_cols_calc = (shape_out_w_calc + 7) >> 3;
    wire [15:0] shape_tile_rows_calc = (shape_out_h_calc + 3) >> 2;
    wire [15:0] shape_macro_count_calc = shape_tile_rows_calc * shape_tile_cols_calc;
    wire [15:0] shape_group_count_calc = (shape_input_channels_q + 15) >> 4;
    wire [15:0] shape_output_pixels_calc = shape_out_h_calc * shape_out_w_calc;
    wire [15:0] out_h = out_h_q;
    wire [15:0] out_w = out_w_q;
    wire [15:0] tile_cols = tile_cols_q;
    wire [15:0] tile_rows = tile_rows_q;
    /* Macro traversal is a registered row/column walk.  macro_q remains only
     * the compact tile tag/metric consumed by the sweep; no / or % sits on
     * the source-context path. */
    wire [7:0] footprint_h = footprint_h_q;
    wire [7:0] footprint_w = footprint_w_q;
    wire [15:0] macro_count = macro_count_q;
    wire [15:0] group_count = group_count_q;
    /* Preload only the physical rows which the active shape can address.  A
     * sweep weight row is one eight-output tile by one input channel, so the
     * active footprint is ceil(Cout/8) tiles x Cin rows.  The sweep itself
     * still bounds every runtime lookup from the captured start shape; unused
     * physical slots therefore never become effective tokens. */
    wire [3:0] job_epoch = base_epoch_q + job_seq_q + 1'b1;

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
    wire sweep_result_valid;
    wire [10:0] sweep_result_pixel;
    wire [8:0] sweep_result_channel;
    wire [3:0] sweep_result_mask;
    wire signed [31:0] sweep_result_data;
    wire sweep_done, sweep_error;
    wire [31:0] sweep_cycles, sweep_dw_writes, sweep_desc, sweep_tokens,
                sweep_out_writes;
    wire [31:0] sweep_out_groups, sweep_preload;

    reg source_context_valid;
    wire source_context_ready, source_adapter_context_ready, source_context_complete, feature_error;
    wire producer_mem_req_valid, producer_mem_req_ready;
    wire [ADDR_WIDTH-1:0] producer_mem_req_addr;
    wire [ADDR_WIDTH-1:0] adapter_mem_req_addr;
    wire producer_mem_resp_valid;
    wire [31:0] producer_mem_resp_data;
    wire source_adapter_resp_valid;
    wire [31:0] source_adapter_resp_data;
    wire producer_mem_resp_ready;
    wire source_adapter_resp_ready = 1'b1;
    reg fill_start_valid;
    wire fill_start_ready, fill_done_valid, fill_done_ready;
    wire fill_done_bank;
    wire [3:0] fill_done_epoch;
    reg producer_job_valid;
    wire producer_job_ready, producer_done_valid, producer_done_ready;
    wire producer_stream_valid, producer_stream_ready;
    wire [5:0] producer_stream_pixel;
    wire [1:0] producer_stream_lane_base;
    wire [31:0] producer_stream_data;
    wire [3:0] producer_stream_mask;
    wire [31:0] producer_dw_writes, producer_overlap, producer_reads;

    reg signed [127:0] producer_cfg_weight;
    reg signed [511:0] producer_cfg_bias, producer_cfg_mul;
    reg [95:0] producer_cfg_shift;
    integer vi;
    always @* begin
        producer_cfg_weight = 128'sd0;
        producer_cfg_bias = 512'sd0;
        producer_cfg_mul = 512'sd0;
        producer_cfg_shift = 96'd0;
        for (vi = 0; vi < 16; vi = vi + 1) begin
            /* The cache was filled from channel-major rows before S_CFG. */
            producer_cfg_weight[vi*8 +: 8] =
            dw_weight_cache[cfg_active_bank_q][vi][cfg_tap_q*8 +: 8];
            producer_cfg_bias[vi*32 +: 32] =
                dw_param_cache[cfg_active_bank_q][vi][31:0];
            producer_cfg_mul[vi*32 +: 32] =
                dw_param_cache[cfg_active_bank_q][vi][63:32];
            producer_cfg_shift[vi*6 +: 6] =
                dw_param_cache[cfg_active_bank_q][vi][64 +: 6];
        end
    end

    wire pw_weight_req_valid;
    wire pw_weight_req_cancel;
    wire [11:0] pw_weight_req_addr;
    wire pw_weight_resp_valid;
    wire [11:0] pw_weight_resp_addr;
    wire signed [63:0] pw_weight_resp_data;
    wire pw_param_req_valid;
    wire [7:0] pw_param_req_addr;
    wire pw_param_resp_valid;
    wire [7:0] pw_param_resp_addr;
    wire [71:0] pw_param_resp_data;
    ds_group_published_shared64_sweep #(
        .MAX_GROUPS(16), .MAX_COUT_TILES(32), .MAX_BLOCKS(128), .DESC_DEPTH(64),
        .USE_EXTERNAL_MEM(1)
    ) u_sweep (
         .clk(clk), .rst_n(rst_n),
         .start_valid((state == S_SWEEP_START) && shape_valid_q),
          .start_ready(sweep_start_ready), .start_pixels(output_pixels_q[10:0]),
          .start_output_height(out_h[10:0]), .start_output_width(out_w[10:0]),
        .start_cin(shape_input_channels_q[7:0]),
        .start_cout(shape_output_channels_q[8:0]),
        .start_bank(1'b0), .start_session(2'd0), .start_epoch(base_epoch_q),
        .dw_valid(sweep_dw_valid), .dw_ready(sweep_dw_ready),
        .dw_macro(sweep_dw_macro), .dw_row(sweep_dw_row),
        .dw_group(sweep_dw_group), .dw_channel_half(sweep_dw_half),
        .dw_pixel(sweep_dw_pixel), .dw_data(sweep_dw_data),
        .dw_mask(sweep_dw_mask), .dw_last(sweep_dw_last),
        .pw_weight_req_valid(pw_weight_req_valid), .pw_weight_req_ready(),
        .pw_weight_req_addr(pw_weight_req_addr),
        .pw_weight_req_cancel(pw_weight_req_cancel),
        .pw_weight_resp_valid(pw_weight_resp_valid),
        .pw_weight_resp_addr(pw_weight_resp_addr),
        .pw_weight_resp_data(pw_weight_resp_data),
        .pw_param_req_valid(pw_param_req_valid), .pw_param_req_ready(),
        .pw_param_req_addr(pw_param_req_addr), .pw_param_resp_valid(pw_param_resp_valid),
        .pw_param_resp_addr(pw_param_resp_addr), .pw_param_resp_data(pw_param_resp_data),
        .pw_output_zero_point_int32(pw_output_zero_point),
        .pw_activation_min_int32(pw_activation_min),
        .pw_activation_max_int32(pw_activation_max),
        .result_valid(sweep_result_valid), .result_ready(output_word_ready),
        .result_pixel_idx(sweep_result_pixel),
        .result_channel_base(sweep_result_channel), .result_lane_mask(sweep_result_mask),
        .result_data(sweep_result_data), .done(sweep_done), .error(sweep_error),
        .perf_total_cycles(sweep_cycles), .perf_dw_writes(sweep_dw_writes),
        .perf_group_descriptors(sweep_desc), .perf_pw_tokens(sweep_tokens),
        .perf_output_writes(sweep_out_writes), .perf_output_groups(sweep_out_groups),
        .perf_preload_rows(sweep_preload)
    );

    wire active_start_ready = sweep_start_ready;
    wire active_dw_ready = sweep_dw_ready;
    wire active_result_valid = sweep_result_valid;
    wire [10:0] active_result_pixel = sweep_result_pixel;
    wire [8:0] active_result_channel = sweep_result_channel;
    wire [3:0] active_result_mask = sweep_result_mask;
    wire signed [31:0] active_result_data = sweep_result_data;
    wire active_done = sweep_done;
    wire active_error = sweep_error;
    wire [31:0] active_cycles = sweep_cycles;
    wire [31:0] active_dw_writes = sweep_dw_writes;
    wire [31:0] active_desc = sweep_desc;
    wire [31:0] active_tokens = sweep_tokens;
    wire [31:0] active_out_writes = sweep_out_writes;

    /* Configuration writes are intentionally decoded only at this boundary.
     * The PW ABI is cout*128+cin; its physical address is {cout/8,cin} and
     * its byte lane is cout%8.  DW weight and parameter rows are channel
     * major and are read into a 16-channel job cache before cfg_valid. */
    wire cfg_dw_weight = config_write_en && (config_target == CFG_DW_WEIGHT) &&
                         (config_index < (MAX_CIN*9));
    wire cfg_dw_param = config_write_en &&
                        ((config_target == CFG_DW_BIAS) ||
                         (config_target == CFG_DW_MUL) ||
                         (config_target == CFG_DW_SHIFT)) &&
                        (config_index < MAX_CIN);
    wire cfg_pw_weight = config_write_en && (config_target == CFG_PW_WEIGHT) &&
                         (config_index < (MAX_COUT*MAX_CIN));
    wire cfg_pw_param = config_write_en &&
                        ((config_target == CFG_PW_BIAS) ||
                         (config_target == CFG_PW_MUL) ||
                         (config_target == CFG_PW_SHIFT)) &&
                        (config_index < MAX_COUT);
    wire [6:0] dw_cfg_addr = config_dw_channel;
    wire [3:0] dw_cfg_tap = config_dw_tap;
    wire [11:0] pw_cfg_addr = {config_index[15:10],config_index[6:0]};
    wire [2:0] pw_cfg_lane = config_index[9:7];
    wire [1:0] pw_cfg_bank = pw_cfg_addr[1:0];
    wire [9:0] pw_cfg_bank_addr = pw_cfg_addr[11:2];
    wire cfg_word_pw_weight = (config_word_write_en === 1'b1) &&
                               (config_word_target == CFG_PW_WEIGHT) &&
                               (config_word_index < (MAX_COUT*MAX_CIN));
    wire [11:0] pw_word_cfg_addr =
        {config_word_index[15:10],config_word_index[6:0]};
    wire [2:0] pw_word_cfg_lane = config_word_index[9:7];
    wire [9:0] pw_word_cfg_bank_addr = pw_word_cfg_addr[11:2];
    wire [7:0] pw_param_cfg_addr = config_index[7:0];
    reg [71:0] dw_cfg_data;
    reg [8:0] dw_cfg_we;
    reg [71:0] dw_param_cfg_data;
    reg [8:0] dw_param_cfg_we;
    reg signed [63:0] pw_cfg_data;
    reg [7:0] pw_cfg_we;
    reg signed [63:0] pw_cfg_bank_data [0:3];
    reg [7:0] pw_cfg_bank_we [0:3];
    /* The PW weight store is logically four transposed 64-bit banks packed
     * into one physical 256-bit XPM word.  Keep the complete write sideband
     * together for one edge before it reaches the XPM: otherwise the
     * scalar/packed lane decode and bank byte-enable remain a live mux cone
     * on the RAM write port.  The q sideband is also the atomic handoff point
     * between foreground and prefetch writes. */
    reg signed [63:0] pw_cfg_bank_data_q [0:3];
    reg [7:0] pw_cfg_bank_we_q [0:3];
    reg [9:0] pw_cfg_bank_addr_q [0:3];
    reg pw_cfg_write_bank_q;
    integer cfg_qi;
    reg [71:0] pw_param_cfg_data;
    reg [8:0] pw_param_cfg_we;
    integer cfgb;
    always @* begin
        dw_cfg_data = 72'd0; dw_cfg_we = 9'd0;
        if (cfg_dw_weight) begin
            dw_cfg_data[config_dw_tap*8 +: 8] = config_data[7:0];
            dw_cfg_we[config_dw_tap] = 1'b1;
        end
        dw_param_cfg_data = 72'd0; dw_param_cfg_we = 9'd0;
        if (cfg_dw_param) begin
            case (config_target)
                CFG_DW_BIAS: begin dw_param_cfg_data[31:0] = config_data; dw_param_cfg_we[3:0] = 4'hf; end
                CFG_DW_MUL: begin dw_param_cfg_data[63:32] = config_data; dw_param_cfg_we[7:4] = 4'hf; end
                default: begin dw_param_cfg_data[64 +: 6] = config_data[5:0]; dw_param_cfg_we[8] = 1'b1; end
            endcase
        end
        pw_cfg_data = 64'd0; pw_cfg_we = 8'd0;
        if (cfg_pw_weight) begin
            pw_cfg_data[pw_cfg_lane*8 +: 8] = config_data[7:0];
            pw_cfg_we[pw_cfg_lane] = 1'b1;
        end
        /* PW storage is banked by input-channel modulo four.  The canonical
         * packed word is four consecutive Cin bytes, so one word can update
         * one lane in each of four physical rows in the same cycle.  The
         * aligned external index makes all four banks share this row address. */
        for (cfgb=0; cfgb<4; cfgb=cfgb+1) begin
            pw_cfg_bank_data[cfgb] = 64'd0;
            pw_cfg_bank_we[cfgb] = 8'd0;
        end
        if (cfg_pw_weight) begin
            pw_cfg_bank_data[pw_cfg_bank][pw_cfg_lane*8 +: 8] = config_data[7:0];
            pw_cfg_bank_we[pw_cfg_bank][pw_cfg_lane] = 1'b1;
        end
        if (cfg_word_pw_weight) begin
            for (cfgb=0; cfgb<4; cfgb=cfgb+1) begin
                if (config_word_be[cfgb]) begin
                    pw_cfg_bank_data[cfgb][pw_word_cfg_lane*8 +: 8] =
                        config_word_data[cfgb*8 +: 8];
                    pw_cfg_bank_we[cfgb][pw_word_cfg_lane] = 1'b1;
                end
            end
        end
        pw_param_cfg_data = 72'd0; pw_param_cfg_we = 9'd0;
        if (cfg_pw_param) begin
            case (config_target)
                CFG_PW_BIAS: begin pw_param_cfg_data[31:0] = config_data; pw_param_cfg_we[3:0] = 4'hf; end
                CFG_PW_MUL: begin pw_param_cfg_data[63:32] = config_data; pw_param_cfg_we[7:4] = 4'hf; end
                default: begin pw_param_cfg_data[64 +: 6] = config_data[5:0]; pw_param_cfg_we[8] = 1'b1; end
            endcase
        end
        for (cfgb=0; cfgb<9; cfgb=cfgb+1) begin
            if (!dw_cfg_we[cfgb]) dw_cfg_data[cfgb*8 +: 8] = 8'd0;
            if (!dw_param_cfg_we[cfgb]) dw_param_cfg_data[cfgb*8 +: 8] = 8'd0;
            if (!pw_param_cfg_we[cfgb]) pw_param_cfg_data[cfgb*8 +: 8] = 8'd0;
        end
    end

    wire cfg_prefetch_weight_en = cfg_prefetch_active_q &&
                                   !cfg_prefetch_param_phase_q;
    wire cfg_prefetch_param_en = cfg_prefetch_active_q &&
                                  cfg_prefetch_param_phase_q;
    wire cfg_prefetch_match = (cfg_prefetch_job_seq_q == job_seq_q) &&
                              (cfg_prefetch_epoch_q == job_epoch);
    wire dw_weight_fetch_en = (state == S_DW_WEIGHT_FETCH) ||
                              cfg_prefetch_weight_en;
    wire dw_param_fetch_en = (state == S_DW_PARAM_FETCH) ||
                             cfg_prefetch_param_en;
    wire [4:0] dw_weight_issue_idx = cfg_prefetch_weight_en ?
                                      cfg_prefetch_idx_q : dw_fetch_idx_q;
    wire [4:0] dw_param_issue_idx = cfg_prefetch_param_en ?
                                     cfg_prefetch_idx_q : dw_param_fetch_idx_q;
    wire [3:0] dw_weight_group_sel = cfg_prefetch_weight_en ?
                                      cfg_prefetch_group_q : channel_group_q;
    wire [3:0] dw_param_group_sel = cfg_prefetch_param_en ?
                                     cfg_prefetch_group_q : channel_group_q;
    /* The sweep owns the one-outstanding request/response contract.  Keep the
     * physical BRAM read port directly driven by that request; the response
     * metadata below is still registered at the synchronous-memory boundary. */
    wire [11:0] pw_weight_read_addr = pw_weight_req_addr;
    wire pw_weight_read_en = pw_weight_req_valid;
    wire [63:0] pw_weight_read_data;
    wire [7:0] dw_read_addr_full = {dw_weight_group_sel,4'd0} +
                                    dw_weight_issue_idx;
    wire [7:0] dw_param_read_addr_full = {dw_param_group_sel,4'd0} +
                                         dw_param_issue_idx;
    wire [6:0] dw_read_addr = dw_read_addr_full[6:0];
    wire [6:0] dw_param_read_addr = dw_param_read_addr_full[6:0];
    wire [71:0] dw_weight_read_data, dw_param_read_data;
    wire [71:0] pw_param_read_data;
    wire [255:0] pw_weight_word_read_data;
    wire [1:0] pw_weight_read_bank = pw_weight_read_addr[1:0];
    wire [9:0] pw_weight_read_bank_addr = pw_weight_read_addr[11:2];
    /* Response valid/address are delayed with the XPM's one-cycle read
     * latency.  The read enable/address themselves intentionally remain the
     * sweep's look-ahead request (see above). */
    reg pw_param_resp_valid_q;
    reg [7:0] pw_param_resp_addr_q;
    reg pw_weight_resp_valid_q;
    reg [11:0] pw_weight_resp_addr_q;
    reg [1:0] pw_weight_resp_bank_q;

`ifdef SYNTHESIS
    /* The four transposed 64-bit rows share one 256-bit physical read/write
     * word.  Byte enables preserve independent scalar/packed updates while a
     * single XPM read enable removes the live k->bank decode from ENBWREN. */
    wire [255:0] pw_cfg_word_data_q = {
        pw_cfg_bank_data_q[3], pw_cfg_bank_data_q[2],
        pw_cfg_bank_data_q[1], pw_cfg_bank_data_q[0]
    };
    wire [31:0] pw_cfg_word_we_q = {
        pw_cfg_bank_we_q[3], pw_cfg_bank_we_q[2],
        pw_cfg_bank_we_q[1], pw_cfg_bank_we_q[0]
    };
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE((PW_WEIGHT_DEPTH/4)*256*2), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(256), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(256), .WRITE_MODE_B("read_first")
    ) u_pw_weight_mem (
        .clka(clk), .clkb(clk), .ena(|pw_cfg_word_we_q), .enb(pw_weight_read_en),
        /* All four transposed rows share the same aligned physical word
         * address.  The per-bank sideband array is intentionally kept so the
         * byte enables/data remain independent, but XPM's single write port
         * takes one packed row address. */
        .addra({pw_cfg_write_bank_q, pw_cfg_bank_addr_q[0]}),
        .addrb({config_read_bank_i, pw_weight_read_bank_addr}),
        .dina(pw_cfg_word_data_q), .wea(pw_cfg_word_we_q),
        .doutb(pw_weight_word_read_data), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
    assign pw_weight_read_data =
        (pw_weight_resp_bank_q == 2'd0) ? pw_weight_word_read_data[63:0] :
        (pw_weight_resp_bank_q == 2'd1) ? pw_weight_word_read_data[127:64] :
        (pw_weight_resp_bank_q == 2'd2) ? pw_weight_word_read_data[191:128] :
                                          pw_weight_word_read_data[255:192];
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(8), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(MAX_CIN*72*2), .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(72),
        .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(72),
        .WRITE_MODE_B("read_first")
    ) u_dw_weight_mem (
        .clka(clk), .clkb(clk), .ena(cfg_dw_weight), .enb(dw_weight_fetch_en),
        .addra({config_write_bank_i, dw_cfg_addr}),
        .addrb({config_read_bank_i, dw_read_addr}), .dina(dw_cfg_data), .wea(dw_cfg_we),
        .doutb(dw_weight_read_data), .regceb(1'b1), .rstb(!rst_n), .sleep(1'b0),
        .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb()
    );
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(8), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(MAX_CIN*72*2), .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(72),
        .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(72),
        .WRITE_MODE_B("read_first")
    ) u_dw_param_mem (
        .clka(clk), .clkb(clk), .ena(cfg_dw_param), .enb(dw_param_fetch_en),
        .addra({config_write_bank_i, config_index[6:0]}),
        .addrb({config_read_bank_i, dw_param_read_addr}),
        .dina(dw_param_cfg_data),
        .wea(dw_param_cfg_we), .doutb(dw_param_read_data), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb()
    );
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(9), .ADDR_WIDTH_B(9), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(MAX_COUT*72*2), .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(72),
        .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(72),
        .WRITE_MODE_B("read_first")
    ) u_pw_param_mem (
        .clka(clk), .clkb(clk), .ena(cfg_pw_param), .enb(pw_param_req_valid),
        .addra({config_write_bank_i, pw_param_cfg_addr}),
        .addrb({config_read_bank_i, pw_param_req_addr}),
        .dina(pw_param_cfg_data),
        .wea(pw_param_cfg_we), .doutb(pw_param_read_data), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb()
    );
`else
    reg [63:0] pw_weight_read_data_q;
    reg [71:0] dw_weight_read_data_q, dw_param_read_data_q, pw_param_read_data_q;
    assign pw_weight_read_data = pw_weight_read_data_q;
    assign dw_weight_read_data = dw_weight_read_data_q;
    assign dw_param_read_data = dw_param_read_data_q;
    assign pw_param_read_data = pw_param_read_data_q;
    always @(posedge clk) begin
        if (pw_weight_read_en)
                pw_weight_read_data_q <=
                pw_weight_mem[config_read_bank_i][pw_weight_read_addr];
        if (dw_weight_fetch_en)
            dw_weight_read_data_q <=
                dw_weight_mem[config_read_bank_i][dw_read_addr];
        if (dw_param_fetch_en)
            dw_param_read_data_q <=
                dw_param_mem[config_read_bank_i][dw_param_read_addr];
        if (pw_param_req_valid) begin
            pw_param_read_data_q <=
                pw_param_mem[config_read_bank_i][pw_param_req_addr];
        end
    end
`endif
    assign pw_param_resp_valid = pw_param_resp_valid_q;
    assign pw_param_resp_addr = pw_param_resp_addr_q;
    assign pw_param_resp_data = pw_param_read_data;
    assign pw_weight_resp_data = pw_weight_read_data;
    assign pw_weight_resp_valid = pw_weight_resp_valid_q;
    assign pw_weight_resp_addr = pw_weight_resp_addr_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            pw_cfg_write_bank_q <= 1'b0;
            for (cfg_qi=0; cfg_qi<4; cfg_qi=cfg_qi+1) begin
                pw_cfg_bank_data_q[cfg_qi] <= 64'd0;
                pw_cfg_bank_we_q[cfg_qi] <= 8'd0;
                pw_cfg_bank_addr_q[cfg_qi] <= 10'd0;
            end
            pw_param_resp_valid_q <= 1'b0;
            pw_param_resp_addr_q <= 8'd0;
            pw_weight_resp_valid_q <= 1'b0;
            pw_weight_resp_addr_q <= 12'd0;
            pw_weight_resp_bank_q <= 2'd0;
        end else begin
            pw_weight_resp_valid_q <= pw_weight_read_en && !pw_weight_req_cancel;
            if (pw_weight_read_en && !pw_weight_req_cancel) begin
                pw_weight_resp_addr_q <= pw_weight_read_addr;
                pw_weight_resp_bank_q <= pw_weight_read_bank;
            end
            pw_cfg_write_bank_q <= config_write_bank_i;
            for (cfg_qi=0; cfg_qi<4; cfg_qi=cfg_qi+1) begin
                pw_cfg_bank_data_q[cfg_qi] <= pw_cfg_bank_data[cfg_qi];
                pw_cfg_bank_we_q[cfg_qi] <= pw_cfg_bank_we[cfg_qi];
                pw_cfg_bank_addr_q[cfg_qi] <= cfg_word_pw_weight ?
                                          pw_word_cfg_bank_addr :
                                          pw_cfg_bank_addr;
            end
            pw_param_resp_valid_q <= pw_param_req_valid;
            if (pw_param_req_valid) pw_param_resp_addr_q <= pw_param_req_addr;
        end
    end

    ds_group_feature_word_address_adapter #(.ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH))
    u_source_adapter (
        .clk(clk), .rst_n(rst_n), .context_valid(source_context_valid),
        .context_ready(source_adapter_context_ready), .context_linear_base(context_base_sel),
        .context_input_base(shape_input_base_q[ADDR_WIDTH-1:0]),
        .context_global_y(context_row_sel[7:0] << 2),
        .context_global_x(context_col_sel[7:0] << 3),
        .context_input_zero_point(shape_input_zero_point_q),
        .context_stride(shape_stride_q),
        .context_input_width(shape_input_width_q),
        .context_input_height(shape_input_height_q),
        .context_input_channels(shape_input_channels_q),
        .context_channel_offset(context_group_sel * 16),
        .context_footprint_width(footprint_w), .context_footprint_height(footprint_h),
        .context_complete(source_context_complete),
        .producer_req_valid(producer_mem_req_valid), .producer_req_ready(producer_mem_req_ready),
        .producer_req_addr(producer_mem_req_addr), .producer_resp_valid(source_adapter_resp_valid),
        .producer_resp_ready(source_adapter_resp_ready),
        .producer_resp_data(source_adapter_resp_data), .mem_req_valid(source_word_en),
        .mem_req_ready(source_word_ready), .mem_req_addr(adapter_mem_req_addr),
        .mem_resp_valid(source_word_valid), .mem_resp_data(source_word_data),
        .error(feature_error)
    );
    assign source_word_addr = adapter_mem_req_addr[SRAM_ADDR_WIDTH-1:0];

    assign producer_mem_resp_valid = source_adapter_resp_valid;
    assign producer_mem_resp_data = source_adapter_resp_data;
    assign source_context_ready = source_adapter_context_ready;

    ds_word_window_dw_tagless_stream4_4x8 #(
        .MAX_IN_H(17), .MAX_IN_W(17), .ADDR_WIDTH(ADDR_WIDTH),
        .WORD_COUNT_WIDTH(16), .EPOCH_WIDTH(4), .TILE_WIDTH(8),
        .FIFO_DEPTH(FIFO_DEPTH), .USE_QUADLOCAL_CORE(1),
        .USE_LOCAL_REQUANT(1), .STREAM4_ONLY(1), .OUTPUT_HEIGHT(4)
    ) u_producer (
        .clk(clk), .rst_n(rst_n), .fill_start_valid(fill_start_valid),
        .fill_start_ready(fill_start_ready), .fill_start_bank(fill_bank_sel),
        .fill_start_epoch(fill_epoch_sel), .fill_start_base_addr(fill_base_sel),
        .fill_start_word_count(footprint_h * footprint_w * 4),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(producer_mem_req_valid), .mem_req_ready(producer_mem_req_ready),
        .mem_req_addr(producer_mem_req_addr), .mem_resp_valid(producer_mem_resp_valid),
        .mem_resp_ready(producer_mem_resp_ready),
        .mem_resp_data(producer_mem_resp_data), .cfg_valid(state == S_CFG),
        .cfg_ready(), .cfg_tap_idx(cfg_tap_q[3:0]), .cfg_weight_vec(producer_cfg_weight),
        .cfg_bias_vec(producer_cfg_bias), .cfg_multiplier_vec(producer_cfg_mul),
        .cfg_shift_vec(producer_cfg_shift), .dw_job_valid(producer_job_valid),
        .dw_job_ready(producer_job_ready), .dw_source_bank(job_seq_q[0]),
        .dw_source_epoch(job_epoch), .dw_source_base_addr(24'h100000),
        .dw_source_lane_mask(16'hffff), .dw_source_stride(shape_stride_q[1:0]),
        .dw_footprint_height(footprint_h), .dw_footprint_width(footprint_w),
        .dw_footprint_pitch(footprint_w), .dw_target_bank(job_seq_q[0]),
        .dw_target_epoch(job_epoch), .dw_target_tile(macro_q),
        .dw_channel_group(3'd0), .dw_group_count(4'd1),
        .dw_pixel_count(8'd32), .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min), .dw_activation_max(dw_activation_max),
        .dw_done_valid(producer_done_valid), .dw_done_ready(producer_done_ready),
        .dw_done_bank(), .dw_done_epoch(), .dw_done_tile(), .dw_done_group(),
        .read_acquire_valid(1'b0), .read_acquire_ready(), .read_bank(1'b0),
        .read_epoch(4'd0), .read_tile(8'd0), .read_valid(1'b0), .read_ready(),
        .read_channel_idx(7'd0), .read_pixel_base(6'd0), .read_out_valid(),
        .read_out_ready(1'b1), .read_out_data(), .read_out_lane_mask(),
        .read_release_valid(1'b0), .read_release_ready(), .scratch0_state(),
        .scratch1_state(), .dw_write_count(producer_dw_writes),
        .overlap_cycles(producer_overlap), .read_count(producer_reads),
        .stream4_valid(producer_stream_valid), .stream4_ready(producer_stream_ready),
        .stream4_pixel(producer_stream_pixel), .stream4_lane_base(producer_stream_lane_base),
        .stream4_data(producer_stream_data), .stream4_lane_mask(producer_stream_mask)
    );

    /* The next producer command is known from the registered traversal
     * counters.  Keep the arithmetic here, at the scheduler boundary; the
     * producer/sweep ready-valid paths only see registered command fields. */
    wire current_job_has_next = !((channel_group_q + 1 >= group_count) &&
                                   (macro_row_q + 1 >= tile_rows) &&
                                   (macro_col_q + 1 >= tile_cols));
    wire [3:0] next_group = (channel_group_q + 1 >= group_count) ? 4'd0 :
                             (channel_group_q + 1'b1);
    wire [15:0] next_row = (channel_group_q + 1 >= group_count) ?
                            ((macro_col_q + 1 >= tile_cols) ?
                             (macro_row_q + 1'b1) : macro_row_q) : macro_row_q;
    wire [15:0] next_col = (channel_group_q + 1 >= group_count) ?
                            ((macro_col_q + 1 >= tile_cols) ? 16'd0 :
                             (macro_col_q + 1'b1)) : macro_col_q;
    wire [7:0] next_macro = (next_row * tile_cols) + next_col;
    wire [7:0] next_job_seq = job_seq_q + 1'b1;
    wire next_job_bank = next_job_seq[0];
    wire [3:0] next_job_epoch = base_epoch_q + next_job_seq + 1'b1;

    wire prefetch_context_valid = prefetch_active_q && !prefetch_context_sent_q;
    wire prefetch_fill_valid = prefetch_active_q && prefetch_context_sent_q &&
                                !prefetch_fill_started_q;
    always @* begin
        source_context_valid = (state == S_CONTEXT) || prefetch_context_valid;
        fill_start_valid = (state == S_FILL) || prefetch_fill_valid;
        producer_job_valid = (state == S_JOB);
    end

    /* Select look-ahead fields whenever its command is active.  The old
     * S_CONTEXT/S_FILL path remains the safe first-job fallback. */
    wire source_context_select_prefetch = prefetch_context_valid ||
                                          (prefetch_active_q &&
                                           !prefetch_done_q);
    wire [15:0] context_row_sel = source_context_select_prefetch ?
                                  prefetch_row_q : macro_row_q;
    wire [15:0] context_col_sel = source_context_select_prefetch ?
                                  prefetch_col_q : macro_col_q;
    wire [3:0] context_group_sel = source_context_select_prefetch ?
                                    prefetch_group_q : channel_group_q;
    wire [ADDR_WIDTH-1:0] context_base_sel = 24'h700000 +
        ((source_context_select_prefetch ? prefetch_job_seq_q : job_seq_q) * 24'h1000);
    wire fill_select_prefetch = prefetch_fill_valid ||
                                 (prefetch_active_q &&
                                  !prefetch_done_q);
    wire fill_bank_sel = fill_select_prefetch ? prefetch_bank_q : job_seq_q[0];
    wire [3:0] fill_epoch_sel = fill_select_prefetch ? prefetch_epoch_q : job_epoch;
    wire [ADDR_WIDTH-1:0] fill_base_sel = 24'h700000 +
        ((fill_select_prefetch ? prefetch_job_seq_q : job_seq_q) * 24'h1000);

    assign sweep_dw_valid = (state == S_WAIT_JOB) && producer_stream_valid;
    assign producer_stream_ready = (state == S_WAIT_JOB) && active_dw_ready;
    assign sweep_dw_macro = macro_q;
    assign sweep_dw_row = producer_stream_pixel[5:3];
    assign sweep_dw_group = (channel_group_q * 2) + producer_stream_lane_base[1];
    assign sweep_dw_half = producer_stream_lane_base[0];
    assign sweep_dw_pixel = producer_stream_pixel[2:0];
    assign sweep_dw_data = producer_stream_data;
    assign sweep_dw_mask = producer_stream_mask;
    assign sweep_dw_last = (macro_q + 1 >= macro_count) &&
                           (channel_group_q + 1 >= group_count) &&
                           (producer_stream_pixel == 6'd31) &&
                           (producer_stream_lane_base == 2'd3);
    /* A prefetched fill may complete while the producer is still streaming
     * the previous job.  Consume its tagged completion here and remember it;
     * the scheduler later waits on prefetch_done_q before admitting the next
     * job.  The original S_WAIT_FILL fence is retained for the first job. */
    wire current_fill_done_match = (fill_done_bank == job_seq_q[0]) &&
                                    (fill_done_epoch == job_epoch);
    wire prefetch_fill_done_match = (fill_done_bank == prefetch_bank_q) &&
                                     (fill_done_epoch == prefetch_epoch_q);
    assign source_context_complete = fill_done_valid && fill_done_ready;
    assign fill_done_ready = ((state == S_WAIT_FILL) && current_fill_done_match) ||
                             (prefetch_active_q && prefetch_fill_started_q &&
                              !prefetch_done_q && prefetch_fill_done_match);
    assign producer_done_ready = (state == S_WAIT_JOB);
    assign output_word_en = active_result_valid;
    assign output_word_addr = shape_output_base_q[15:0] +
        ((active_result_pixel * shape_output_channels_q) + active_result_channel);
    assign output_word_data = active_result_data;
    assign output_word_be = active_result_mask;
    assign output_word_last = active_result_valid &&
        (({5'd0,active_result_pixel} + 16'd1) >= output_pixels_q) &&
        (({7'd0,active_result_channel} + 16'd4) >= shape_output_channels_q);
    assign start_ready = rst_n && (state == S_IDLE);
    assign busy = rst_n && (state != S_IDLE);
    assign done = (state == S_FINISH) && active_done;
    assign error = active_error | feature_error;
    /* This is the adapter boundary's wall-clock ledger: parameter/weight
     * preload, source service, DW jobs, shared sweep, output drains, and the
     * final done fence are all inside it. */
    assign perf_cycles = total_cycles_q;
    assign perf_dw_writes = active_dw_writes;
    assign perf_descriptors = active_desc;
    assign perf_pw_tokens = active_tokens;
    assign perf_output_writes = active_out_writes;
    assign perf_jobs = job_seq_q;
    assign perf_stream_beats = total_stream_beats_q;
    assign config_accept_count = config_accept_count_q[config_read_bank_i];
    assign config_phase_count = config_phase_count_q[config_read_bank_i];
    assign config_word_accept_count =
        config_word_accept_count_q[config_read_bank_i];
    assign config_scalar_write_count =
        config_scalar_write_count_q[config_read_bank_i];

    integer ri, ci;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; cfg_tap_q <= 0;
            dw_fetch_idx_q <= 0; dw_resp_idx_q <= 0; dw_read_valid_q <= 0;
            dw_param_fetch_idx_q <= 0; dw_param_resp_idx_q <= 0; dw_param_read_valid_q <= 0;
            macro_q <= 0; macro_row_q <= 0; macro_col_q <= 0;
            channel_group_q <= 0; job_seq_q <= 0;
            job_stream_count_q <= 0; producer_done_seen_q <= 0; base_epoch_q <= 0;
            total_stream_beats_q <= 0; total_cycles_q <= 0;
            shape_input_height_q <= 0; shape_input_width_q <= 0;
            shape_input_channels_q <= 0; shape_output_channels_q <= 0;
            shape_stride_q <= 8'd1; shape_input_zero_point_q <= 0;
            shape_input_base_q <= 0; shape_output_base_q <= 0;
            out_h_q <= 0; out_w_q <= 0; tile_cols_q <= 0; tile_rows_q <= 0;
            macro_count_q <= 0; group_count_q <= 0;
            footprint_h_q <= 0; footprint_w_q <= 0;
            output_pixels_q <= 0; shape_valid_q <= 1'b0;
            config_accept_count_q[0] <= 0; config_accept_count_q[1] <= 0;
            config_phase_count_q[0] <= 0; config_phase_count_q[1] <= 0;
            config_word_accept_count_q[0] <= 0;
            config_word_accept_count_q[1] <= 0;
            config_scalar_write_count_q[0] <= 0;
            config_scalar_write_count_q[1] <= 0;
            prefetch_active_q <= 1'b0;
            prefetch_context_sent_q <= 1'b0;
            prefetch_fill_started_q <= 1'b0;
            prefetch_done_q <= 1'b0;
            prefetch_job_seq_q <= 0; prefetch_macro_q <= 0;
            prefetch_row_q <= 0; prefetch_col_q <= 0;
            prefetch_group_q <= 0; prefetch_bank_q <= 0;
            prefetch_epoch_q <= 0;
            cfg_active_bank_q <= 1'b0;
            cfg_prefetch_active_q <= 1'b0;
            cfg_prefetch_param_phase_q <= 1'b0;
            cfg_prefetch_read_valid_q <= 1'b0;
            cfg_prefetch_done_q <= 1'b0;
            cfg_prefetch_idx_q <= 0; cfg_prefetch_resp_q <= 0;
            cfg_prefetch_bank_q <= 1'b0; cfg_prefetch_group_q <= 0;
            cfg_prefetch_job_seq_q <= 0; cfg_prefetch_epoch_q <= 0;
            for (ri=0; ri<2; ri=ri+1) begin
                for (ci=0; ci<16; ci=ci+1) begin
                    dw_weight_cache[ri][ci] <= 0;
                    dw_param_cache[ri][ci] <= 0;
                end
            end
`ifndef SYNTHESIS
`endif
        end else begin
            /* Advance the one-entry look-ahead command independently of the
             * current producer state.  Context acceptance and fill start are
             * separate handshakes so the source adapter can spend its normal
             * two preparation cycles while the fill engine is being armed. */
            if (prefetch_context_valid && source_context_ready)
                prefetch_context_sent_q <= 1'b1;
            if (prefetch_fill_valid && fill_start_ready)
                prefetch_fill_started_q <= 1'b1;
            if (prefetch_active_q && prefetch_fill_started_q &&
                !prefetch_done_q && fill_done_valid && fill_done_ready)
                prefetch_done_q <= 1'b1;

            /* The scalar ABI has no bubble/ready signal at this boundary:
             * every presented write is accepted and counted. */
            if (config_clear_en) begin
                config_accept_count_q[config_clear_bank_i] <= 0;
                config_phase_count_q[config_clear_bank_i] <= 0;
                config_word_accept_count_q[config_clear_bank_i] <= 0;
                config_scalar_write_count_q[config_clear_bank_i] <= 0;
            end
            if (config_write_en) begin
                config_accept_count_q[config_write_bank_i] <=
                    config_accept_count_q[config_write_bank_i] + 1'b1;
                config_scalar_write_count_q[config_write_bank_i] <=
                    config_scalar_write_count_q[config_write_bank_i] + 1'b1;
                if (state == S_IDLE)
                    config_phase_count_q[config_write_bank_i] <=
                        config_phase_count_q[config_write_bank_i] + 1'b1;
`ifndef SYNTHESIS
                if (cfg_dw_weight)
                    dw_weight_mem[config_write_bank_i][config_dw_channel]
                        [config_dw_tap*8 +: 8] <= config_data[7:0];
                if (cfg_dw_param) begin
                    case (config_target)
                        CFG_DW_BIAS:
                            dw_param_mem[config_write_bank_i][config_index]
                                [31:0] <= config_data;
                        CFG_DW_MUL:
                            dw_param_mem[config_write_bank_i][config_index]
                                [63:32] <= config_data;
                        default:
                            dw_param_mem[config_write_bank_i][config_index]
                                [64 +: 6] <= config_data[5:0];
                    endcase
                end
                if (cfg_pw_weight)
                    pw_weight_mem[config_write_bank_i][pw_cfg_addr]
                        [pw_cfg_lane*8 +: 8] <= config_data[7:0];
                if (cfg_pw_param) begin
                    case (config_target)
                        CFG_PW_BIAS:
                            pw_param_mem[config_write_bank_i][config_index]
                                [31:0] <= config_data;
                        CFG_PW_MUL:
                            pw_param_mem[config_write_bank_i][config_index]
                                [63:32] <= config_data;
                        default:
                            pw_param_mem[config_write_bank_i][config_index]
                                [64 +: 6] <= config_data[5:0];
                    endcase
                end
`endif
            end
            if (cfg_word_pw_weight) begin
                /* One packed external word represents four canonical scalar
                 * PW entries.  The four-way physical bank decomposition
                 * makes these writes simultaneous in synthesis; the
                 * behavioral model updates the same transposed store one
                 * byte at a time for an identical readback contract. */
                config_accept_count_q[config_write_bank_i] <=
                    config_accept_count_q[config_write_bank_i] + 1'b1;
                config_word_accept_count_q[config_write_bank_i] <=
                    config_word_accept_count_q[config_write_bank_i] + 1'b1;
                config_scalar_write_count_q[config_write_bank_i] <=
                    config_scalar_write_count_q[config_write_bank_i] +
                                               ((config_word_be[0] ? 1 : 0) +
                                                (config_word_be[1] ? 1 : 0) +
                                                (config_word_be[2] ? 1 : 0) +
                                                (config_word_be[3] ? 1 : 0));
`ifndef SYNTHESIS
                for (ri=0; ri<4; ri=ri+1) begin
                    if (config_word_be[ri]) begin
                        pw_weight_mem[config_write_bank_i][
                            (((config_word_index + ri) >> 10) * 128) +
                            ((config_word_index + ri) & 16'h007f)][
                            ((((config_word_index + ri) >> 7) & 16'h0007) * 8) +: 8] <=
                            config_word_data[ri*8 +: 8];
                    end
                end
`endif
            end

            /* Fetch the next 16-channel DW records into the inactive cache
             * while the current producer/sweep job is live.  The physical
             * stores remain single-read-port; this engine only uses the
             * previously idle cycles of the adapter's DW fetch path and its
             * registered read response. */
            if (cfg_prefetch_active_q) begin
                if (cfg_prefetch_read_valid_q) begin
                    if (cfg_prefetch_param_phase_q)
                        dw_param_cache[cfg_prefetch_bank_q][cfg_prefetch_resp_q] <=
                            dw_param_read_data;
                    else
                        dw_weight_cache[cfg_prefetch_bank_q][cfg_prefetch_resp_q] <=
                            dw_weight_read_data;
                    if (cfg_prefetch_resp_q == 15) begin
                        if (cfg_prefetch_param_phase_q) begin
                            cfg_prefetch_active_q <= 1'b0;
                            cfg_prefetch_done_q <= 1'b1;
                            cfg_prefetch_read_valid_q <= 1'b0;
                        end else begin
                            cfg_prefetch_param_phase_q <= 1'b1;
                            cfg_prefetch_idx_q <= 0;
                            cfg_prefetch_resp_q <= 0;
                            cfg_prefetch_read_valid_q <= 1'b0;
                        end
                    end else begin
                        cfg_prefetch_resp_q <= cfg_prefetch_resp_q + 1'b1;
                    end
                end
                if (cfg_prefetch_idx_q < 16) begin
                    cfg_prefetch_idx_q <= cfg_prefetch_idx_q + 1'b1;
                    cfg_prefetch_read_valid_q <= 1'b1;
                end else if (!cfg_prefetch_read_valid_q) begin
                    cfg_prefetch_read_valid_q <= 1'b0;
                end
            end

            if (state == S_IDLE && start_valid && start_ready) begin
                base_epoch_q <= base_epoch_q + 1'b1;
                total_stream_beats_q <= 0; total_cycles_q <= 0;
                macro_q <= 0; macro_row_q <= 0; macro_col_q <= 0;
                channel_group_q <= 0; job_seq_q <= 0;
                shape_input_height_q <= input_height;
                shape_input_width_q <= input_width;
                shape_input_channels_q <= input_channels;
                shape_output_channels_q <= output_channels;
                shape_stride_q <= stride;
                shape_input_zero_point_q <= input_zero_point;
                shape_input_base_q <= input_base_addr;
                shape_output_base_q <= output_base_addr;
                shape_valid_q <= 1'b0;
                cfg_active_bank_q <= 1'b0;
                cfg_prefetch_active_q <= 1'b0;
                cfg_prefetch_param_phase_q <= 1'b0;
                cfg_prefetch_read_valid_q <= 1'b0;
                cfg_prefetch_done_q <= 1'b0;
                state <= S_SHAPE;
            end else if (state == S_SHAPE) begin
                /* Geometry is a committed configuration record.  The raw
                 * descriptor fields were captured on the previous edge, so
                 * no top-level stride/shape register can reach the sweep
                 * start or its target/count fence in this cycle. */
                out_h_q <= shape_out_h_calc;
                out_w_q <= shape_out_w_calc;
                tile_cols_q <= shape_tile_cols_calc;
                tile_rows_q <= shape_tile_rows_calc;
                macro_count_q <= shape_macro_count_calc;
                group_count_q <= shape_group_count_calc;
                output_pixels_q <= shape_output_pixels_calc;
                footprint_h_q <= (shape_stride_q == 2) ? 8'd9 : 8'd6;
                footprint_w_q <= (shape_stride_q == 2) ? 8'd17 : 8'd10;
                shape_valid_q <= 1'b1;
                state <= S_SWEEP_START;
            end else if (state == S_SWEEP_START && active_start_ready &&
                         shape_valid_q) begin
                cfg_tap_q <= 0; dw_fetch_idx_q <= 0; dw_resp_idx_q <= 0;
                dw_read_valid_q <= 0; state <= S_DW_WEIGHT_FETCH;
            end else if (state == S_DW_WEIGHT_FETCH) begin
                if (dw_read_valid_q) begin
                    dw_weight_cache[0][dw_resp_idx_q] <= dw_weight_read_data;
                    if (dw_resp_idx_q == 15) begin
                        dw_param_fetch_idx_q <= 0; dw_param_resp_idx_q <= 0;
                        dw_param_read_valid_q <= 0; state <= S_DW_PARAM_FETCH;
                    end else dw_resp_idx_q <= dw_resp_idx_q + 1'b1;
                end
                if (dw_fetch_idx_q < 16) begin
                    dw_fetch_idx_q <= dw_fetch_idx_q + 1'b1;
                    dw_read_valid_q <= 1'b1;
                end else dw_read_valid_q <= 1'b0;
            end else if (state == S_DW_PARAM_FETCH) begin
                if (dw_param_read_valid_q) begin
                    dw_param_cache[0][dw_param_resp_idx_q] <= dw_param_read_data;
                    if (dw_param_resp_idx_q == 15) begin
                        cfg_tap_q <= 0; state <= S_CFG;
                    end else dw_param_resp_idx_q <= dw_param_resp_idx_q + 1'b1;
                end
                if (dw_param_fetch_idx_q < 16) begin
                    dw_param_fetch_idx_q <= dw_param_fetch_idx_q + 1'b1;
                    dw_param_read_valid_q <= 1'b1;
                end else dw_param_read_valid_q <= 1'b0;
            end else if (state == S_CFG && producer_job_ready === 1'b1) begin
                if (cfg_tap_q == 8) begin
                    /* For all jobs after the first, the corresponding fill
                     * was launched during the preceding job.  Do not replay
                     * the context/fill sequence unless the look-ahead is not
                     * the expected next command (a conservative recovery
                     * path for reset/shape fences). */
                    if (prefetch_active_q &&
                        (prefetch_job_seq_q == job_seq_q)) begin
                        if (prefetch_done_q && cfg_prefetch_done_q &&
                            cfg_prefetch_match) begin
                            cfg_active_bank_q <= cfg_prefetch_bank_q;
                            state <= S_JOB;
                        end
                        else state <= S_WAIT_PREFILL;
                    end else state <= S_CONTEXT;
                end
                else cfg_tap_q <= cfg_tap_q + 1'b1;
            end else if (state == S_CONTEXT && source_context_ready) begin
                state <= S_FILL;
            end else if (state == S_FILL && fill_start_ready) begin
                state <= S_WAIT_FILL;
            end else if (state == S_WAIT_FILL && fill_done_valid && fill_done_ready) begin
                state <= S_JOB;
            end else if (state == S_WAIT_PREFILL && prefetch_done_q) begin
                if (cfg_prefetch_done_q && cfg_prefetch_match) begin
                    cfg_active_bank_q <= cfg_prefetch_bank_q;
                    cfg_tap_q <= 0;
                    state <= S_CFG;
                end
            end else if (state == S_WAIT_CFG_PREFETCH && cfg_prefetch_done_q &&
                         cfg_prefetch_match) begin
                cfg_active_bank_q <= cfg_prefetch_bank_q;
                cfg_tap_q <= 0;
                state <= S_CFG;
            end else if (state == S_JOB && producer_job_ready) begin
                job_stream_count_q <= 0; producer_done_seen_q <= 0; state <= S_WAIT_JOB;
                /* Arm the next command at current-job admission.  Its fill
                 * executes in the opposite source bank while this job is
                 * consumed by the shared64 sweep. */
                if (current_job_has_next) begin
                    prefetch_active_q <= 1'b1;
                    prefetch_context_sent_q <= 1'b0;
                    prefetch_fill_started_q <= 1'b0;
                    prefetch_done_q <= 1'b0;
                    prefetch_job_seq_q <= next_job_seq;
                    prefetch_macro_q <= next_macro;
                    prefetch_row_q <= next_row;
                    prefetch_col_q <= next_col;
                    prefetch_group_q <= next_group;
                    prefetch_bank_q <= next_job_bank;
                    prefetch_epoch_q <= next_job_epoch;
                    cfg_prefetch_active_q <= 1'b1;
                    cfg_prefetch_param_phase_q <= 1'b0;
                    cfg_prefetch_read_valid_q <= 1'b0;
                    cfg_prefetch_done_q <= 1'b0;
                    cfg_prefetch_idx_q <= 0;
                    cfg_prefetch_resp_q <= 0;
                    cfg_prefetch_group_q <= next_group;
                    cfg_prefetch_bank_q <= ~cfg_active_bank_q;
                    cfg_prefetch_job_seq_q <= next_job_seq;
                    cfg_prefetch_epoch_q <= next_job_epoch;
                end else begin
                    prefetch_active_q <= 1'b0;
                    prefetch_context_sent_q <= 1'b0;
                    prefetch_fill_started_q <= 1'b0;
                    prefetch_done_q <= 1'b0;
                    cfg_prefetch_active_q <= 1'b0;
                    cfg_prefetch_done_q <= 1'b0;
                end
            end else if (state == S_WAIT_JOB) begin
                if (producer_done_valid && producer_done_ready) producer_done_seen_q <= 1'b1;
                if (producer_stream_valid && producer_stream_ready) begin
                    job_stream_count_q <= job_stream_count_q + 1'b1;
                    total_stream_beats_q <= total_stream_beats_q + 1'b1;
                end
                if ((producer_done_seen_q || (producer_done_valid && producer_done_ready)) &&
                    producer_stream_valid && producer_stream_ready && (job_stream_count_q == 127)) begin
                    job_seq_q <= job_seq_q + 1'b1;
                    if (channel_group_q + 1 >= group_count) begin
                        channel_group_q <= 0;
                        if (macro_row_q + 1 >= tile_rows &&
                            macro_col_q + 1 >= tile_cols) state <= S_FINISH;
                        else begin
                            macro_q <= macro_q + 1'b1;
                            if (macro_col_q + 1 >= tile_cols) begin
                                macro_col_q <= 0;
                                macro_row_q <= macro_row_q + 1'b1;
                            end else begin
                                macro_col_q <= macro_col_q + 1'b1;
                            end
                            cfg_tap_q <= 0;
                            dw_fetch_idx_q <= 0; dw_resp_idx_q <= 0; dw_read_valid_q <= 0;
                            if (cfg_prefetch_done_q &&
                                (cfg_prefetch_job_seq_q == (job_seq_q + 1'b1))) begin
                                cfg_active_bank_q <= cfg_prefetch_bank_q;
                                state <= S_CFG;
                            end else if (cfg_prefetch_active_q)
                                state <= S_WAIT_CFG_PREFETCH;
                            else state <= S_DW_WEIGHT_FETCH;
                            end
                    end else begin
                        channel_group_q <= channel_group_q + 1'b1; cfg_tap_q <= 0;
                        dw_fetch_idx_q <= 0; dw_resp_idx_q <= 0; dw_read_valid_q <= 0;
                        if (cfg_prefetch_done_q &&
                            (cfg_prefetch_job_seq_q == (job_seq_q + 1'b1))) begin
                            cfg_active_bank_q <= cfg_prefetch_bank_q;
                            state <= S_CFG;
                        end else if (cfg_prefetch_active_q)
                            state <= S_WAIT_CFG_PREFETCH;
                        else state <= S_DW_WEIGHT_FETCH;
                    end
                end
            end else if (state == S_FINISH && active_done) begin
                state <= S_IDLE;
            end
            if (state != S_IDLE) total_cycles_q <= total_cycles_q + 1'b1;
        end
    end
endmodule

`default_nettype wire
