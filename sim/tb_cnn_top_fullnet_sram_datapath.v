`timescale 1ns/1ps
`default_nettype none

module tb_cnn_top_fullnet_sram_datapath #(
    parameter USE_UNIFIED64_DS = 0,
    parameter USE_UNIFIED64_STEM = 0,
    parameter USE_SHARED_UNIFIED64 = 0,
    parameter USE_PERSISTENT_DS = 0,
    // Route descriptor slot 1 through the M1.1-A production adapter while
    // leaving the other full-network descriptors on the legacy runner.
    parameter USE_M11A_DS1 = 0,
    // Optional strict DS1 retained orchestrator integration.  The default
    // remains the historical production path; dedicated integration runs
    // override this parameter to exercise the retained layer in the complete
    // descriptor/SRAM network harness.
    parameter USE_DS1_RETAINED_ORCHESTRATOR = 0,
    // Route all six C0 DS descriptors through the group-published shared64
    // production adapter.  Stem/GAP/FC remain on cnn_layer_runner.
    parameter USE_GROUP_SHARED64_DS = 0,
    // Optional deterministic external-bus backpressure for integration
    // proof.  The default retains the historical always-ready fullnet test.
    parameter MEM_READY_STALLS = 0,
    // Select a reproducible pseudo-random ready stream for the stress entry
    // point.  A fixed seed keeps failures replayable across simulators.
    parameter MEM_READY_RANDOM = 0,
    // Select the vector ABI independently of implementation mode so packed
    // and scalar traffic comparisons can use isolated generated files.
    parameter PACKED_WEIGHTS = 1,
    parameter VECTOR_FILE = "tests/vectors/cnn_top_fullnet_sram_cases.hex",
    // Delay an accepted read response by this many cycles.  This exercises
    // the same one-outstanding-request ABI under a nonzero response latency.
    parameter MEM_RESP_DELAY = 0
);
    localparam MEM_WORDS = 262144;
    localparam MAX_EXPECTED = 64;
    localparam MAX_LAYERS = 16;
    localparam M11A_DS1_OUTPUT_WORDS = 8192;

    /* Keep this profiling map synchronized with cnn_layer_runner.v:90-142.
     * These are observability-only labels; no DUT signal or timing is changed. */
    localparam PROFILE_SETUP = 0;
    localparam PROFILE_LOAD = 1;
    localparam PROFILE_ENGINE = 2;
    localparam PROFILE_STORE = 3;
    localparam PROFILE_OTHER = 4;
    localparam PROFILE_UNKNOWN = 5;
    localparam ST_IDLE = 5'd0, ST_VALIDATE = 5'd1, ST_LOAD_SETUP = 5'd2,
        ST_READ_REQ = 5'd3, ST_READ_RESP = 5'd4, ST_ENGINE_START = 5'd5,
        ST_ENGINE_WAIT = 5'd6, ST_STORE_SETUP = 5'd7, ST_WRITE_REQ = 5'd8,
        ST_DONE = 5'd9, ST_ERROR = 5'd10, ST_TILED_INIT = 5'd11,
        ST_TILED_LOAD_SETUP = 5'd12, ST_TILED_LOAD_REQ = 5'd13,
        ST_TILED_LOAD_RESP = 5'd14, ST_TILED_ENGINE_START = 5'd15,
        ST_TILED_ENGINE_WAIT = 5'd16, ST_TILED_STORE_SETUP = 5'd17,
        ST_TILED_WRITE_REQ = 5'd18, ST_TILED_ADVANCE = 5'd19,
        ST_TILED_NEXT_WAIT = 5'd20, ST_TILED_START_WAIT = 5'd21,
        ST_STORE_PREFETCH = 5'd22, ST_TILED_STORE_PREFETCH = 5'd23,
        ST_TILED_ADDR_OFFSETS = 5'd24, ST_TILED_ADDR_BASES = 5'd25,
        ST_TILED_ADDR_INDEX = 5'd26, ST_VALIDATE_SPAN_COUNT = 5'd27,
        ST_VALIDATE_SPAN_RESULT = 5'd28, ST_CALC_SPATIAL = 5'd29,
        ST_TILED_LOAD_WORD_RESP = 5'd30, ST_TILED_LOAD_AREA = 6'd31,
        ST_TILED_LOAD_COUNT = 6'd32, ST_LOAD_COUNT_DECIDE = 6'd33,
        ST_TILED_STORE_BASE_ADD = 6'd34, ST_TILED_STORE_BASE_MUL = 6'd35,
        ST_TILED_STORE_BASE_FINISH = 6'd36, ST_STORE_READ_ISSUE = 6'd37,
        ST_TILED_LOAD_MEM_REQ = 6'd38, ST_VALIDATE_SPAN_VALID = 6'd39,
        ST_LOAD_COUNT_CALC = 6'd40, ST_DS1_RETAINED_START = 6'd41,
        ST_DS1_RETAINED_WAIT = 6'd42, ST_TILED_LOAD_LOOKAHEAD = 6'd43,
        ST_PACKED_WEIGHT_WAIT = 6'd44;
    localparam GROUP_S_IDLE = 4'd0, GROUP_S_SWEEP_START = 4'd1,
        GROUP_S_DW_WEIGHT_FETCH = 4'd2, GROUP_S_DW_PARAM_FETCH = 4'd3,
        GROUP_S_CFG = 4'd4, GROUP_S_CONTEXT = 4'd5, GROUP_S_FILL = 4'd6,
        GROUP_S_WAIT_FILL = 4'd7, GROUP_S_JOB = 4'd8,
        GROUP_S_WAIT_JOB = 4'd9, GROUP_S_FINISH = 4'd10,
        GROUP_S_WAIT_PREFILL = 4'd11, GROUP_S_WAIT_CFG_PREFETCH = 4'd12;

    reg clk;
    reg rst_n;
    reg cmd_valid;
    wire cmd_ready;
    reg [1:0] cmd_type;
    reg [31:0] desc_base_addr;
    reg [31:0] layer_num;
    wire [31:0] status;
    wire mem_req_valid;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    reg mem_req_ready;
    reg mem_resp_valid;
    reg [31:0] mem_resp_rdata;
    reg mem_resp_pending;
    reg [31:0] mem_resp_pending_data;
    integer mem_resp_delay_count;

    reg [31:0] mem [0:MEM_WORDS-1];
    integer bus_phase;
    reg [31:0] mem_ready_lfsr;
    reg [31:0] expected_addr [0:MAX_EXPECTED-1];
    reg [7:0] expected_data [0:MAX_EXPECTED-1];

    integer fd;
    integer report_fd;
    integer layer_metrics_fd;
    integer layer_profile_fd;
    integer persistent_ds_metrics_fd;
    integer group_state_profile_fd;
    integer hw_logits_fd;
    integer expected_logits_fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer entry_count;
    integer expected_count;
    integer layer_num_file;
    integer i;
    integer perf_i;
    integer timeout;
    integer total_checks;
    integer error_count;
    integer case_errors;
    integer mem_read_total;
    integer mem_write_total;
    integer mem_req_stall_total;
    integer desc_read_total;
    integer layer_read_total;
    integer layer_write_total;
    integer sram_read_total;
    integer sram_word_read_total;
    integer sram_write_total;
    reg [31:0] tmp_addr;
    reg [31:0] tmp_data;
    reg [7:0] tmp_i8;
    reg [31:0] case_hw_cycles;
    reg perf_layer_active;
    reg [7:0] perf_layer_idx;
    reg [31:0] perf_layer_cycles [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_reads [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_config_reads [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_writes [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_sram_reads [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_sram_word_reads [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_sram_writes [0:MAX_LAYERS-1];
    integer profile_cycles [0:MAX_LAYERS-1][0:PROFILE_UNKNOWN];
    integer group_state_cycles [0:MAX_LAYERS-1][0:GROUP_S_WAIT_CFG_PREFETCH];
    integer profile_sum;

    function integer profile_bucket;
        input integer state_value;
        begin
            case (state_value)
                ST_VALIDATE, ST_VALIDATE_SPAN_COUNT, ST_VALIDATE_SPAN_RESULT,
                ST_CALC_SPATIAL, ST_LOAD_COUNT_DECIDE,
                ST_TILED_ADDR_OFFSETS, ST_TILED_ADDR_BASES, ST_TILED_ADDR_INDEX,
                ST_TILED_STORE_BASE_ADD, ST_TILED_STORE_BASE_MUL,
                ST_TILED_STORE_BASE_FINISH, ST_VALIDATE_SPAN_VALID,
                ST_LOAD_COUNT_CALC, ST_DS1_RETAINED_START:
                    profile_bucket = PROFILE_SETUP;
                ST_LOAD_SETUP, ST_READ_REQ, ST_READ_RESP, ST_TILED_INIT,
                ST_TILED_LOAD_SETUP, ST_TILED_LOAD_REQ, ST_TILED_LOAD_RESP,
                ST_TILED_LOAD_WORD_RESP, ST_TILED_LOAD_AREA, ST_TILED_LOAD_COUNT,
                ST_TILED_LOAD_MEM_REQ, ST_TILED_LOAD_LOOKAHEAD,
                ST_PACKED_WEIGHT_WAIT:
                    profile_bucket = PROFILE_LOAD;
                ST_ENGINE_START, ST_ENGINE_WAIT, ST_TILED_ENGINE_START,
                ST_TILED_ENGINE_WAIT, ST_DS1_RETAINED_WAIT:
                    profile_bucket = PROFILE_ENGINE;
                ST_STORE_SETUP, ST_WRITE_REQ, ST_STORE_PREFETCH,
                ST_TILED_STORE_SETUP, ST_TILED_WRITE_REQ,
                ST_TILED_STORE_PREFETCH, ST_TILED_ADVANCE, ST_TILED_NEXT_WAIT,
                ST_TILED_START_WAIT, ST_STORE_READ_ISSUE: profile_bucket = PROFILE_STORE;
                ST_IDLE, ST_DONE, ST_ERROR: profile_bucket = PROFILE_OTHER;
                default: profile_bucket = PROFILE_UNKNOWN;
            endcase
        end
    endfunction
    function integer profile_bucket_group;
        input integer state_value;
        begin
            case (state_value)
                GROUP_S_SWEEP_START,
                GROUP_S_DW_WEIGHT_FETCH,
                GROUP_S_DW_PARAM_FETCH,
                GROUP_S_CFG,
                GROUP_S_WAIT_CFG_PREFETCH:
                    profile_bucket_group = PROFILE_LOAD;
                GROUP_S_CONTEXT,
                GROUP_S_FILL,
                GROUP_S_WAIT_FILL,
                GROUP_S_WAIT_PREFILL:
                    profile_bucket_group = PROFILE_SETUP;
                GROUP_S_JOB,
                GROUP_S_WAIT_JOB:
                    profile_bucket_group = PROFILE_ENGINE;
                GROUP_S_FINISH:
                    profile_bucket_group = PROFILE_STORE;
                GROUP_S_IDLE:
                    profile_bucket_group = PROFILE_OTHER;
                default:
                    profile_bucket_group = PROFILE_UNKNOWN;
            endcase
        end
    endfunction
    /* Persistent production-path evidence captured at each DS layer fence. */
    reg [31:0] persistent_ds_preload [0:5];
    reg [31:0] persistent_ds_compute [0:5];
    reg [31:0] persistent_ds_commit [0:5];
    reg [31:0] persistent_ds_reads [0:5];
    reg [31:0] persistent_ds_writes [0:5];
    reg [31:0] persistent_ds_reuse [0:5];
    reg [31:0] persistent_ds_tokens [0:5];
    reg [31:0] persistent_ds_commit_prev;
    reg [31:0] persistent_ds_reads_prev;
    reg [31:0] persistent_ds_reuse_prev;
    reg [31:0] persistent_ds_tokens_prev;

    /* Gate-B observability for the M1.1-A DS1 -> M1.1-A DS2 boundary. */
    reg [31:0] m11a_ds1_output_capture [0:M11A_DS1_OUTPUT_WORDS-1];
    integer m11a_ds1_output_words;
    integer m11a_ds1_last_seen;
    integer m11a_gate_errors;
    integer m11a_ds2_input_requests;
    integer m11a_ds2_input_responses;
    integer m11a_ds2_input_mismatches;
    integer m11a_ds2_scalar_requests;
    integer m11a_ds2_scalar_responses;
    reg m11a_ds2_word_pending;
    reg [14:0] m11a_ds2_word_pending_addr;
    reg m11a_ds2_scalar_pending;
    reg [14:0] m11a_ds2_scalar_pending_addr;
    integer m11a_ds1_config_requests;
    integer m11a_ds2_config_requests;
    integer m11a_ds1_commit_events;
    integer m11a_ds2_commit_events;
    /* Per-layer semantic ledger for the group-published shared64 backend.
     * These counters are exported through stable cnn_top observability nets;
     * aggregate them at the layer fence so the fullnet gate covers all six
     * DS descriptors rather than only final logits. */
    integer group_ledger_errors;
    integer group_ds_layers_seen;
    integer group_total_cycles;
    integer group_total_dw_writes;
    integer group_total_descriptors;
    integer group_total_pw_tokens;
    integer group_total_output_writes;
    integer group_total_jobs;
    integer group_total_stream_beats;
    integer group_total_config_reads;
    integer group_total_dw_macs;
    integer group_total_pw_macs;
    integer group_layer_config_reads [0:MAX_LAYERS-1];
    integer group_layer_word_accepts [0:MAX_LAYERS-1];
    integer group_layer_scalar_writes [0:MAX_LAYERS-1];
`ifdef DEBUG_SHARED_INSTRUMENT
    /* Shared-array event counters are a simulation-only diagnostic.  They
     * deliberately live in the production fullnet harness rather than in
     * the arithmetic datapath, so a diagnosis cannot perturb synthesis or
     * the normal performance measurement. */
    integer shared_dbg_reserve [0:MAX_LAYERS-1];
    integer shared_dbg_meta_commit [0:MAX_LAYERS-1];
    integer shared_dbg_meta_wait [0:MAX_LAYERS-1];
    integer shared_dbg_drain_start [0:MAX_LAYERS-1];
    integer shared_dbg_drain_start_wait [0:MAX_LAYERS-1];
    integer shared_dbg_drain_final [0:MAX_LAYERS-1];
    integer shared_dbg_input_fire [0:MAX_LAYERS-1];
    integer shared_dbg_mac_consume [0:MAX_LAYERS-1];
    integer shared_dbg_input_blocked [0:MAX_LAYERS-1];
    integer shared_dbg_bank_full_blocked [0:MAX_LAYERS-1];
    integer shared_dbg_last_stage_blocked [0:MAX_LAYERS-1];
    integer shared_dbg_rq_stage_load [0:MAX_LAYERS-1];
    integer shared_dbg_rq_stage_fire [0:MAX_LAYERS-1];
    integer shared_dbg_output_fire [0:MAX_LAYERS-1];
    integer shared_dbg_output_stall [0:MAX_LAYERS-1];
    integer shared_dbg_prev_input_fire;
    integer shared_dbg_layer_cycle;
    integer shared_dbg_prev_reserve_cycle;
    integer shared_dbg_reserve_gap_count [0:MAX_LAYERS-1];
    integer shared_dbg_reserve_gap_sum [0:MAX_LAYERS-1];
    integer shared_dbg_reserve_gap_min [0:MAX_LAYERS-1];
    integer shared_dbg_reserve_gap_max [0:MAX_LAYERS-1];
    /* The group backend is instantiated beside cnn_layer_runner, so its
     * shared array is under the top-level group adapter rather than the
     * runner's Stem shared-array generate. */
    wire shared_dbg_input_fire_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.input_fire;
    wire shared_dbg_reserve_fire_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.reserve_fire;
    wire shared_dbg_meta_commit_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.meta_commit0 ||
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.meta_commit1;
    wire shared_dbg_meta_wait_sig =
        (dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_ready0 &&
         !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_meta_valid0) ||
        (dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_ready1 &&
         !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_meta_valid1);
    wire shared_dbg_drain_start_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.drain_start;
    wire shared_dbg_drain_start_wait_sig =
        (dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_ready0 ||
         dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_ready1) &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.drain_active &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.in_stage_valid &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.mac_last_pending &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.rq_stage_valid &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.rq_busy &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.drain_start;
    wire shared_dbg_drain_final_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.drain_final_fire;
    wire shared_dbg_mac_consume_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.in_stage_valid;
    wire shared_dbg_input_blocked_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.valid_in &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.ready_in;
    wire shared_dbg_bank_full_sig = shared_dbg_input_blocked_sig &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.current_active &&
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_live0 &&
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_live1;
    wire shared_dbg_last_stage_sig = shared_dbg_input_blocked_sig &&
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.in_stage_valid &&
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.in_stage_last;
    wire shared_dbg_rq_stage_load_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.stage_load;
    wire shared_dbg_rq_stage_fire_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.stage_fire;
    wire shared_dbg_output_fire_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.output_fire;
    wire shared_dbg_output_stall_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.valid_out &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.ready_out;
    wire [31:0] shared_dbg_core_tokens_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.token_count_reg;
    wire [31:0] shared_dbg_core_commits_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.commit_count_reg;
    /* Sweep/producer diagnostics distinguish a shared-core stall from the
     * surrounding producer publication and bank-ownership schedule.  These
     * are intentionally sampled at the fullnet layer fence only under the
     * debug define; the production RTL and normal performance run are
     * unchanged. */
    wire sweep_dbg_pw_published_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_published;
    wire sweep_dbg_pw_slot_valid_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_slot_valid;
    wire sweep_dbg_pw_owner_match_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_owner_match;
    wire sweep_dbg_pw_generation_match_sig =
        (dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_slot_generation ==
         dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.epoch_q);
    wire sweep_dbg_pw_token_valid_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_token_valid;
    wire sweep_dbg_pw_token_fire_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_token_fire;
    wire sweep_dbg_pw_resp_wait_sig =
        (dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.state == 3'd1) &&
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_published &&
        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_weight_resp_valid;
    wire sweep_dbg_dw_valid_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.dw_valid;
    wire sweep_dbg_dw_ready_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.dw_ready;
    wire sweep_dbg_dw_fire_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.dw_fire;
    wire sweep_dbg_dw_bank_blocked_sig = sweep_dbg_dw_valid_sig && !sweep_dbg_dw_ready_sig &&
        (dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.state == 3'd1);
    wire sweep_dbg_bank_busy0_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.bank_busy0;
    wire sweep_dbg_bank_busy1_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.bank_busy1;
    wire [3:0] sweep_dbg_adapter_state_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.state;
    wire [3:0] sweep_dbg_state_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.state;
    wire sweep_dbg_producer_stream_valid_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.producer_stream_valid;
    wire sweep_dbg_producer_stream_ready_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.producer_stream_ready;
    wire sweep_dbg_producer_stream_blocked_sig =
        sweep_dbg_producer_stream_valid_sig && !sweep_dbg_producer_stream_ready_sig &&
        (sweep_dbg_adapter_state_sig == 4'd10);
    wire sweep_dbg_fill_start_valid_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.fill_start_valid;
    wire sweep_dbg_fill_start_ready_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.fill_start_ready;
    wire sweep_dbg_fill_done_valid_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.fill_done_valid;
    wire sweep_dbg_fill_done_ready_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.fill_done_ready;
    wire sweep_dbg_result_group_final_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.result_group_final;
    wire sweep_dbg_result_row_final_sig =
        dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.result_row_final;
    integer sweep_dbg_pw_published [0:MAX_LAYERS-1];
    integer sweep_dbg_pw_unpublished [0:MAX_LAYERS-1];
    integer sweep_dbg_pw_slot_invalid [0:MAX_LAYERS-1];
    integer sweep_dbg_pw_owner_mismatch [0:MAX_LAYERS-1];
    integer sweep_dbg_pw_generation_mismatch [0:MAX_LAYERS-1];
    integer sweep_dbg_pw_token_valid [0:MAX_LAYERS-1];
    integer sweep_dbg_pw_token_fire [0:MAX_LAYERS-1];
    integer sweep_dbg_pw_resp_wait [0:MAX_LAYERS-1];
    integer sweep_dbg_dw_valid [0:MAX_LAYERS-1];
    integer sweep_dbg_dw_ready [0:MAX_LAYERS-1];
    integer sweep_dbg_dw_fire [0:MAX_LAYERS-1];
    integer sweep_dbg_dw_blocked [0:MAX_LAYERS-1];
    integer sweep_dbg_stream_valid [0:MAX_LAYERS-1];
    integer sweep_dbg_stream_ready [0:MAX_LAYERS-1];
    integer sweep_dbg_stream_blocked [0:MAX_LAYERS-1];
    integer sweep_dbg_bank_both_busy [0:MAX_LAYERS-1];
    integer sweep_dbg_result_group_final [0:MAX_LAYERS-1];
    integer sweep_dbg_result_row_final [0:MAX_LAYERS-1];
    integer sweep_dbg_adapter_state [0:MAX_LAYERS-1][0:15];
    integer sweep_dbg_sweep_state [0:MAX_LAYERS-1][0:7];
`endif
`ifdef M11A_FULLNET_LEDGER
    /* C0 semantic ledger for the canonical M1.1-A DS12 fullnet run.  The
     * M1.1-A core counters are per-layer, so retain them at each layer fence;
     * legacy Stem/DS/FC counters are cumulative and are read at completion. */
    integer ledger_m11a_ds1_dw;
    integer ledger_m11a_ds1_pw;
    integer ledger_m11a_ds2_dw;
    integer ledger_m11a_ds2_pw;
    reg ledger_m11a_ds1_seen;
    reg ledger_m11a_ds2_seen;
    integer ledger_stem_mac;
    integer ledger_legacy_dw_mac;
    integer ledger_legacy_pw_mac;
    integer ledger_fc_mac;
    integer ledger_total_mac;
`endif

    function [31:0] expected_sram_reads_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                0: expected_sram_reads_for_layer = 32'd0;
                // The retained DS1 path fetches each 2x8 microgroup halo
                // directly as aligned words.  Keep the historical scalar
                // expectation for the default runner, and account for the
                // retained source-word ABI only in its dedicated run.
                1: expected_sram_reads_for_layer =
                    USE_M11A_DS1 ? 32'd48128 :
                    (USE_DS1_RETAINED_ORCHESTRATOR ? 32'd37696 : 32'd23104);
                2: expected_sram_reads_for_layer =
                    USE_M11A_DS1 ? 32'd48128 : 32'd34848;
                3: expected_sram_reads_for_layer = 32'd20736;
                4: expected_sram_reads_for_layer = 32'd16384;
                5: expected_sram_reads_for_layer = 32'd8192;
                6: expected_sram_reads_for_layer = 32'd8192;
                7: expected_sram_reads_for_layer = 32'd4096;
                8: expected_sram_reads_for_layer = 32'd256;
                default: expected_sram_reads_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_sram_writes_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                0: expected_sram_writes_for_layer = 32'd16384;
                // DS outputs use one aligned four-byte internal-SRAM
                // transaction when four consecutive channels are ready.
                1: expected_sram_writes_for_layer = 32'd8192;
                2: expected_sram_writes_for_layer = 32'd4096;
                3: expected_sram_writes_for_layer = 32'd4096;
                4: expected_sram_writes_for_layer = 32'd2048;
                5: expected_sram_writes_for_layer = 32'd2048;
                6: expected_sram_writes_for_layer = 32'd1024;
                7: expected_sram_writes_for_layer = 32'd256;
                8: expected_sram_writes_for_layer = 32'd0;
                default: expected_sram_writes_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_ext_reads_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                // Unified Stem reads the 32x32x3 source image directly as
                // 3072 scalar 32-bit transactions (plus 480 parameter
                // words).  The legacy tiled Stem replays its 10x10 halos,
                // hence its larger historical count.
                0: expected_ext_reads_for_layer =
                                                   (USE_UNIFIED64_STEM || USE_SHARED_UNIFIED64) ?
                                                   32'd3552 : 32'd4812;
                // Packed DS weights are real four-byte external words;
                // bias/multiplier/shift remain complete 32-bit reads.  Keep
                // the scalar branch as a direct ABI compatibility baseline.
                /* The group backend starts the following DS descriptor's
                 * look-ahead while the current layer is running.  The
                 * common bus ledger attributes accepted requests to the
                 * layer which owns the bus at that cycle, so layers 1..5
                 * include the next layer's descriptor (32 words) and config
                 * image, while layer 6 includes only the final descriptor
                 * look-ahead.  The group-specific config ledger below keeps
                 * the logical per-layer image counts independent of this
                 * physical request attribution. */
                1: expected_ext_reads_for_layer = USE_GROUP_SHARED64_DS ?
                    (PACKED_WEIGHTS ? 32'd1212 : 32'd3456) :
                    (PACKED_WEIGHTS ? 32'd308 : 32'd800);
                2: expected_ext_reads_for_layer = USE_GROUP_SHARED64_DS ?
                    (PACKED_WEIGHTS ? 32'd1584 : 32'd5088) :
                    (PACKED_WEIGHTS ? 32'd872 : 32'd2624);
                3: expected_ext_reads_for_layer = USE_GROUP_SHARED64_DS ?
                    (PACKED_WEIGHTS ? 32'd2800 : 32'd9376) :
                    (PACKED_WEIGHTS ? 32'd1552 : 32'd5056);
                4: expected_ext_reads_for_layer = USE_GROUP_SHARED64_DS ?
                    (PACKED_WEIGHTS ? 32'd5184 : 32'd18336) :
                    (PACKED_WEIGHTS ? 32'd2768 : 32'd9344);
                5: expected_ext_reads_for_layer = USE_GROUP_SHARED64_DS ?
                    (PACKED_WEIGHTS ? 32'd9664 : 32'd35104) :
                    (PACKED_WEIGHTS ? 32'd5152 : 32'd18304);
                6: expected_ext_reads_for_layer = USE_GROUP_SHARED64_DS ?
                    32'd32 : (PACKED_WEIGHTS ? 32'd9632 : 32'd35072);
                7: expected_ext_reads_for_layer = 32'd0;
                8: expected_ext_reads_for_layer = 32'd2590;
                default: expected_ext_reads_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_ext_writes_for_layer;
        input integer layer_idx;
        begin
            expected_ext_writes_for_layer = (layer_idx == 8) ? 32'd10 : 32'd0;
        end
    endfunction

    function [31:0] expected_group_dw_writes_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                1: expected_group_dw_writes_for_layer = 32'd4096;
                2: expected_group_dw_writes_for_layer = 32'd2048;
                3: expected_group_dw_writes_for_layer = 32'd4096;
                4: expected_group_dw_writes_for_layer = 32'd1024;
                5: expected_group_dw_writes_for_layer = 32'd2048;
                6: expected_group_dw_writes_for_layer = 32'd1024;
                default: expected_group_dw_writes_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_group_descriptors_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                1: expected_group_descriptors_for_layer = 32'd256;
                2: expected_group_descriptors_for_layer = 32'd128;
                3: expected_group_descriptors_for_layer = 32'd256;
                4: expected_group_descriptors_for_layer = 32'd64;
                5: expected_group_descriptors_for_layer = 32'd128;
                6: expected_group_descriptors_for_layer = 32'd64;
                default: expected_group_descriptors_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_group_pw_tokens_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                1: expected_group_pw_tokens_for_layer = 32'd8192;
                2: expected_group_pw_tokens_for_layer = 32'd8192;
                3: expected_group_pw_tokens_for_layer = 32'd16384;
                4: expected_group_pw_tokens_for_layer = 32'd8192;
                5: expected_group_pw_tokens_for_layer = 32'd16384;
                6: expected_group_pw_tokens_for_layer = 32'd16384;
                default: expected_group_pw_tokens_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_group_output_writes_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                1: expected_group_output_writes_for_layer = 32'd8192;
                2: expected_group_output_writes_for_layer = 32'd4096;
                3: expected_group_output_writes_for_layer = 32'd4096;
                4: expected_group_output_writes_for_layer = 32'd2048;
                5: expected_group_output_writes_for_layer = 32'd2048;
                6: expected_group_output_writes_for_layer = 32'd1024;
                default: expected_group_output_writes_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_group_jobs_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                1: expected_group_jobs_for_layer = 32'd32;
                2: expected_group_jobs_for_layer = 32'd16;
                3: expected_group_jobs_for_layer = 32'd32;
                4: expected_group_jobs_for_layer = 32'd8;
                5: expected_group_jobs_for_layer = 32'd16;
                6: expected_group_jobs_for_layer = 32'd8;
                default: expected_group_jobs_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_group_config_reads_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                1: expected_group_config_reads_for_layer =
                    PACKED_WEIGHTS ? 32'd308 : 32'd800;
                2: expected_group_config_reads_for_layer =
                    PACKED_WEIGHTS ? 32'd872 : 32'd2624;
                3: expected_group_config_reads_for_layer =
                    PACKED_WEIGHTS ? 32'd1552 : 32'd5056;
                4: expected_group_config_reads_for_layer =
                    PACKED_WEIGHTS ? 32'd2768 : 32'd9344;
                5: expected_group_config_reads_for_layer =
                    PACKED_WEIGHTS ? 32'd5152 : 32'd18304;
                6: expected_group_config_reads_for_layer =
                    PACKED_WEIGHTS ? 32'd9632 : 32'd35072;
                default: expected_group_config_reads_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_group_dw_macs_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                1: expected_group_dw_macs_for_layer = 32'd147456;
                2: expected_group_dw_macs_for_layer = 32'd73728;
                3: expected_group_dw_macs_for_layer = 32'd147456;
                4: expected_group_dw_macs_for_layer = 32'd36864;
                5: expected_group_dw_macs_for_layer = 32'd73728;
                6: expected_group_dw_macs_for_layer = 32'd18432;
                default: expected_group_dw_macs_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_group_pw_macs_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                1: expected_group_pw_macs_for_layer = 32'd524288;
                2: expected_group_pw_macs_for_layer = 32'd524288;
                3: expected_group_pw_macs_for_layer = 32'd1048576;
                4: expected_group_pw_macs_for_layer = 32'd524288;
                5: expected_group_pw_macs_for_layer = 32'd1048576;
                6: expected_group_pw_macs_for_layer = 32'd524288;
                default: expected_group_pw_macs_for_layer = 32'd0;
            endcase
        end
    endfunction

    cnn_top #(
        .USE_UNIFIED64_DS(USE_UNIFIED64_DS),
        .USE_UNIFIED64_STEM(USE_UNIFIED64_STEM),
        .USE_SHARED_UNIFIED64(USE_SHARED_UNIFIED64),
        .USE_PERSISTENT_DS(USE_PERSISTENT_DS),
        .USE_M11A_DS1(USE_M11A_DS1),
        .USE_DS1_RETAINED_ORCHESTRATOR(USE_DS1_RETAINED_ORCHESTRATOR),
        .USE_GROUP_SHARED64_DS(USE_GROUP_SHARED64_DS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_type(cmd_type),
        .desc_base_addr(desc_base_addr),
        .layer_num(layer_num),
        .status(status),
        .mem_req_valid(mem_req_valid),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            mem_req_ready <= 1'b0;
            mem_resp_pending <= 1'b0;
            mem_resp_pending_data <= 32'd0;
            mem_resp_delay_count <= 0;
            bus_phase <= 0;
            mem_ready_lfsr <= 32'h7f4a7c15;
            mem_req_stall_total <= 0;
        end else begin
            bus_phase <= bus_phase + 1;
            if (MEM_READY_STALLS) begin
                mem_req_ready <= MEM_READY_RANDOM ?
                                  (mem_ready_lfsr[2:0] != 3'b000) :
                                  ((bus_phase % 7) != 0);
                mem_ready_lfsr <= {mem_ready_lfsr[30:0],
                                   mem_ready_lfsr[31] ^
                                   mem_ready_lfsr[21] ^
                                   mem_ready_lfsr[1] ^
                                   mem_ready_lfsr[0]};
            end else begin
                mem_req_ready <= 1'b1;
                mem_ready_lfsr <= 32'h7f4a7c15;
            end
            if (mem_req_valid && !mem_req_ready)
                mem_req_stall_total <= mem_req_stall_total + 1;
            mem_resp_valid <= 1'b0;
            if (mem_resp_pending) begin
                if (mem_resp_delay_count == 0) begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem_resp_pending_data;
                    mem_resp_pending <= 1'b0;
                end else begin
                    mem_resp_delay_count <= mem_resp_delay_count - 1;
                end
            end
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem[mem_req_addr[19:2]] <= mem_req_wdata;
                end else begin
                    if (MEM_RESP_DELAY == 0) begin
                        mem_resp_valid <= 1'b1;
                        mem_resp_rdata <= mem[mem_req_addr[19:2]];
                    end else begin
                        mem_resp_pending <= 1'b1;
                        mem_resp_pending_data <= mem[mem_req_addr[19:2]];
                        mem_resp_delay_count <= MEM_RESP_DELAY - 1;
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            perf_layer_active <= 1'b0;
            perf_layer_idx <= 8'd0;
            mem_read_total <= 0;
            mem_write_total <= 0;
            desc_read_total <= 0;
            layer_read_total <= 0;
            layer_write_total <= 0;
            sram_read_total <= 0;
            sram_word_read_total <= 0;
            sram_write_total <= 0;
            for (perf_i = 0; perf_i < MAX_LAYERS; perf_i = perf_i + 1) begin
                perf_layer_cycles[perf_i] <= 32'd0;
                perf_layer_reads[perf_i] <= 32'd0;
                perf_layer_config_reads[perf_i] <= 32'd0;
                perf_layer_writes[perf_i] <= 32'd0;
                perf_layer_sram_reads[perf_i] <= 32'd0;
                perf_layer_sram_word_reads[perf_i] <= 32'd0;
                perf_layer_sram_writes[perf_i] <= 32'd0;
                for (i = 0; i <= PROFILE_UNKNOWN; i = i + 1)
                    profile_cycles[perf_i][i] <= 0;
                for (i = 0; i <= GROUP_S_WAIT_CFG_PREFETCH; i = i + 1)
                    group_state_cycles[perf_i][i] <= 0;
                group_layer_config_reads[perf_i] <= 0;
                group_layer_word_accepts[perf_i] <= 0;
                group_layer_scalar_writes[perf_i] <= 0;
`ifdef DEBUG_SHARED_INSTRUMENT
                shared_dbg_reserve[perf_i] <= 0;
                shared_dbg_meta_commit[perf_i] <= 0;
                shared_dbg_meta_wait[perf_i] <= 0;
                shared_dbg_drain_start[perf_i] <= 0;
                shared_dbg_drain_start_wait[perf_i] <= 0;
                shared_dbg_drain_final[perf_i] <= 0;
                shared_dbg_input_fire[perf_i] <= 0;
                shared_dbg_mac_consume[perf_i] <= 0;
                shared_dbg_input_blocked[perf_i] <= 0;
                shared_dbg_bank_full_blocked[perf_i] <= 0;
                shared_dbg_last_stage_blocked[perf_i] <= 0;
                shared_dbg_rq_stage_load[perf_i] <= 0;
                shared_dbg_rq_stage_fire[perf_i] <= 0;
                shared_dbg_output_fire[perf_i] <= 0;
                shared_dbg_output_stall[perf_i] <= 0;
                shared_dbg_reserve_gap_count[perf_i] <= 0;
                shared_dbg_reserve_gap_sum[perf_i] <= 0;
                shared_dbg_reserve_gap_min[perf_i] <= 0;
                shared_dbg_reserve_gap_max[perf_i] <= 0;
`endif
            end
            for (perf_i = 0; perf_i < 6; perf_i = perf_i + 1) begin
                persistent_ds_preload[perf_i] <= 32'd0;
                persistent_ds_compute[perf_i] <= 32'd0;
                persistent_ds_commit[perf_i] <= 32'd0;
                persistent_ds_reads[perf_i] <= 32'd0;
                persistent_ds_writes[perf_i] <= 32'd0;
                persistent_ds_reuse[perf_i] <= 32'd0;
                persistent_ds_tokens[perf_i] <= 32'd0;
            end
            persistent_ds_commit_prev <= 32'd0;
            persistent_ds_reads_prev <= 32'd0;
            persistent_ds_reuse_prev <= 32'd0;
            persistent_ds_tokens_prev <= 32'd0;
            m11a_ds1_output_words = 0;
            m11a_ds1_last_seen = 0;
            m11a_gate_errors = 0;
            m11a_ds2_input_requests = 0;
            m11a_ds2_input_responses = 0;
            m11a_ds2_input_mismatches = 0;
            m11a_ds2_scalar_requests = 0;
            m11a_ds2_scalar_responses = 0;
            m11a_ds2_word_pending = 1'b0;
            m11a_ds2_word_pending_addr = 15'd0;
            m11a_ds2_scalar_pending = 1'b0;
            m11a_ds2_scalar_pending_addr = 15'd0;
            m11a_ds1_config_requests = 0;
            m11a_ds2_config_requests = 0;
            m11a_ds1_commit_events = 0;
            m11a_ds2_commit_events = 0;
            group_ledger_errors = 0;
            group_ds_layers_seen = 0;
            group_total_cycles = 0;
            group_total_dw_writes = 0;
            group_total_descriptors = 0;
            group_total_pw_tokens = 0;
            group_total_output_writes = 0;
            group_total_jobs = 0;
            group_total_stream_beats = 0;
            group_total_config_reads = 0;
            group_total_dw_macs = 0;
            group_total_pw_macs = 0;
`ifdef DEBUG_SHARED_INSTRUMENT
            shared_dbg_prev_input_fire = 0;
            shared_dbg_layer_cycle = 0;
            shared_dbg_prev_reserve_cycle = -1;
`endif
`ifdef M11A_FULLNET_LEDGER
            ledger_m11a_ds1_dw = 0;
            ledger_m11a_ds1_pw = 0;
            ledger_m11a_ds2_dw = 0;
            ledger_m11a_ds2_pw = 0;
            ledger_m11a_ds1_seen = 1'b0;
            ledger_m11a_ds2_seen = 1'b0;
`endif
        end else begin
            if (dut.layer_start) begin
                perf_layer_active <= 1'b1;
                perf_layer_idx <= dut.current_layer;
                if (dut.current_layer < MAX_LAYERS) begin
                    perf_layer_cycles[dut.current_layer] <= 32'd1;
                    perf_layer_reads[dut.current_layer] <= 32'd0;
                    perf_layer_config_reads[dut.current_layer] <= 32'd0;
                    perf_layer_writes[dut.current_layer] <= 32'd0;
                    perf_layer_sram_reads[dut.current_layer] <= 32'd0;
                    perf_layer_sram_word_reads[dut.current_layer] <= 32'd0;
                    perf_layer_sram_writes[dut.current_layer] <= 32'd0;
                    if (USE_GROUP_SHARED64_DS &&
                        (dut.current_layer >= 8'd1) &&
                        (dut.current_layer <= 8'd6)) begin
                        profile_cycles[dut.current_layer][profile_bucket_group(dut.group_obs_state)] <= 1;
                        group_state_cycles[dut.current_layer][dut.group_obs_state] <= 1;
                    end else begin
                        profile_cycles[dut.current_layer][profile_bucket(dut.u_layer_runner.state)] <= 1;
                    end
`ifdef DEBUG_SHARED_INSTRUMENT
                    if (USE_GROUP_SHARED64_DS &&
                        (dut.current_layer >= 8'd1) &&
                        (dut.current_layer <= 8'd6)) begin
                        shared_dbg_reserve[dut.current_layer] <= 0;
                        shared_dbg_meta_commit[dut.current_layer] <= 0;
                        shared_dbg_meta_wait[dut.current_layer] <= 0;
                        shared_dbg_drain_start[dut.current_layer] <= 0;
                        shared_dbg_drain_start_wait[dut.current_layer] <= 0;
                        shared_dbg_drain_final[dut.current_layer] <= 0;
                        shared_dbg_input_fire[dut.current_layer] <= 0;
                        shared_dbg_mac_consume[dut.current_layer] <= 0;
                        shared_dbg_input_blocked[dut.current_layer] <= 0;
                        shared_dbg_bank_full_blocked[dut.current_layer] <= 0;
                        shared_dbg_last_stage_blocked[dut.current_layer] <= 0;
                        shared_dbg_rq_stage_load[dut.current_layer] <= 0;
                        shared_dbg_rq_stage_fire[dut.current_layer] <= 0;
                        shared_dbg_output_fire[dut.current_layer] <= 0;
                        shared_dbg_output_stall[dut.current_layer] <= 0;
                        shared_dbg_reserve_gap_count[dut.current_layer] <= 0;
                        shared_dbg_reserve_gap_sum[dut.current_layer] <= 0;
                        shared_dbg_reserve_gap_min[dut.current_layer] <= 0;
                        shared_dbg_reserve_gap_max[dut.current_layer] <= 0;
                        sweep_dbg_pw_published[dut.current_layer] <= 0;
                        sweep_dbg_pw_unpublished[dut.current_layer] <= 0;
                        sweep_dbg_pw_slot_invalid[dut.current_layer] <= 0;
                        sweep_dbg_pw_owner_mismatch[dut.current_layer] <= 0;
                        sweep_dbg_pw_generation_mismatch[dut.current_layer] <= 0;
                        sweep_dbg_pw_token_valid[dut.current_layer] <= 0;
                        sweep_dbg_pw_token_fire[dut.current_layer] <= 0;
                        sweep_dbg_pw_resp_wait[dut.current_layer] <= 0;
                        sweep_dbg_dw_valid[dut.current_layer] <= 0;
                        sweep_dbg_dw_ready[dut.current_layer] <= 0;
                        sweep_dbg_dw_fire[dut.current_layer] <= 0;
                        sweep_dbg_dw_blocked[dut.current_layer] <= 0;
                        sweep_dbg_stream_valid[dut.current_layer] <= 0;
                        sweep_dbg_stream_ready[dut.current_layer] <= 0;
                        sweep_dbg_stream_blocked[dut.current_layer] <= 0;
                        sweep_dbg_bank_both_busy[dut.current_layer] <= 0;
                        sweep_dbg_result_group_final[dut.current_layer] <= 0;
                        sweep_dbg_result_row_final[dut.current_layer] <= 0;
                        for (perf_i = 0; perf_i < 16; perf_i = perf_i + 1)
                            sweep_dbg_adapter_state[dut.current_layer][perf_i] <= 0;
                        for (perf_i = 0; perf_i < 8; perf_i = perf_i + 1)
                            sweep_dbg_sweep_state[dut.current_layer][perf_i] <= 0;
                        shared_dbg_layer_cycle = 0;
                        shared_dbg_prev_reserve_cycle = -1;
                    end
                    shared_dbg_prev_input_fire = 0;
`endif
                end
                if (USE_M11A_DS1 && (dut.current_layer == 8'd1)) begin
                    /* Stem completion must have selected bank 1 as DS1's
                     * input and bank 0 as its output.  No M1.1-A config bank
                     * is committed before the first descriptor starts. */
                    if ((dut.feature_input_bank_sel !== 1'b1) ||
                        (dut.feature_output_bank_sel !== 1'b0))
                        m11a_gate_errors = m11a_gate_errors + 1;
                    if ((dut.m11a_obs_loaded_ds1 !== 1'b0) ||
                        (dut.m11a_obs_loaded_ds2 !== 1'b0))
                        m11a_gate_errors = m11a_gate_errors + 1;
                    m11a_ds1_output_words = 0;
                    m11a_ds1_last_seen = 0;
                    m11a_ds2_word_pending = 1'b0;
                    m11a_ds2_scalar_pending = 1'b0;
                end
                if (USE_M11A_DS1 && (dut.current_layer == 8'd2)) begin
                    /* DS1 completion must have swapped bank 0 into the
                     * logical input position before M1.1-A DS2 starts.  Its
                     * bank is still uncommitted here, while DS1 stays loaded. */
                    if ((dut.feature_input_bank_sel !== 1'b0) ||
                        (dut.feature_output_bank_sel !== 1'b1))
                        m11a_gate_errors = m11a_gate_errors + 1;
                    if ((dut.m11a_obs_loaded_ds1 !== 1'b1) ||
                        (dut.m11a_obs_loaded_ds2 !== 1'b0))
                        m11a_gate_errors = m11a_gate_errors + 1;
                    m11a_ds2_word_pending = 1'b0;
                    m11a_ds2_scalar_pending = 1'b0;
                end
            end else if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                perf_layer_cycles[perf_layer_idx] <= perf_layer_cycles[perf_layer_idx] + 32'd1;
                if (USE_GROUP_SHARED64_DS &&
                    (perf_layer_idx >= 8'd1) &&
                    (perf_layer_idx <= 8'd6)) begin
                    profile_cycles[perf_layer_idx][profile_bucket_group(dut.group_obs_state)] <=
                        profile_cycles[perf_layer_idx][profile_bucket_group(dut.group_obs_state)] + 1;
                    group_state_cycles[perf_layer_idx][dut.group_obs_state] <=
                        group_state_cycles[perf_layer_idx][dut.group_obs_state] + 1;
                end else begin
                    profile_cycles[perf_layer_idx][profile_bucket(dut.u_layer_runner.state)] <=
                        profile_cycles[perf_layer_idx][profile_bucket(dut.u_layer_runner.state)] + 1;
                end
`ifdef DEBUG_SHARED_INSTRUMENT
                if (USE_GROUP_SHARED64_DS &&
                    (perf_layer_idx >= 8'd1) && (perf_layer_idx <= 8'd6)) begin
                    shared_dbg_layer_cycle = shared_dbg_layer_cycle + 1;
                    if (shared_dbg_input_fire_sig) begin
                        shared_dbg_input_fire[perf_layer_idx] <=
                            shared_dbg_input_fire[perf_layer_idx] + 1;
                        if (shared_dbg_prev_reserve_cycle >= 0) begin
                            shared_dbg_reserve_gap_count[perf_layer_idx] <=
                                shared_dbg_reserve_gap_count[perf_layer_idx] + 1;
                            shared_dbg_reserve_gap_sum[perf_layer_idx] <=
                                shared_dbg_reserve_gap_sum[perf_layer_idx] +
                                (shared_dbg_layer_cycle - shared_dbg_prev_reserve_cycle);
                        end
                    end
                    if (shared_dbg_reserve_fire_sig) begin
                        shared_dbg_reserve[perf_layer_idx] <=
                            shared_dbg_reserve[perf_layer_idx] + 1;
                        if (shared_dbg_prev_reserve_cycle >= 0) begin
                            if ((shared_dbg_reserve_gap_min[perf_layer_idx] == 0) ||
                                ((shared_dbg_layer_cycle - shared_dbg_prev_reserve_cycle) <
                                 shared_dbg_reserve_gap_min[perf_layer_idx]))
                                shared_dbg_reserve_gap_min[perf_layer_idx] <=
                                    shared_dbg_layer_cycle - shared_dbg_prev_reserve_cycle;
                            if ((shared_dbg_layer_cycle - shared_dbg_prev_reserve_cycle) >
                                shared_dbg_reserve_gap_max[perf_layer_idx])
                                shared_dbg_reserve_gap_max[perf_layer_idx] <=
                                    shared_dbg_layer_cycle - shared_dbg_prev_reserve_cycle;
                        end
                        shared_dbg_prev_reserve_cycle = shared_dbg_layer_cycle;
                    end
                    if (shared_dbg_meta_commit_sig)
                        shared_dbg_meta_commit[perf_layer_idx] <=
                            shared_dbg_meta_commit[perf_layer_idx] + 1;
                    if (shared_dbg_meta_wait_sig)
                        shared_dbg_meta_wait[perf_layer_idx] <=
                            shared_dbg_meta_wait[perf_layer_idx] + 1;
                    if (shared_dbg_drain_start_sig)
                        shared_dbg_drain_start[perf_layer_idx] <=
                            shared_dbg_drain_start[perf_layer_idx] + 1;
                    if (shared_dbg_drain_start_wait_sig)
                        shared_dbg_drain_start_wait[perf_layer_idx] <=
                            shared_dbg_drain_start_wait[perf_layer_idx] + 1;
                    if (shared_dbg_drain_final_sig)
                        shared_dbg_drain_final[perf_layer_idx] <=
                            shared_dbg_drain_final[perf_layer_idx] + 1;
                    if (shared_dbg_mac_consume_sig)
                        shared_dbg_mac_consume[perf_layer_idx] <=
                            shared_dbg_mac_consume[perf_layer_idx] + 1;
                    if (shared_dbg_input_blocked_sig) begin
                        shared_dbg_input_blocked[perf_layer_idx] <=
                            shared_dbg_input_blocked[perf_layer_idx] + 1;
                        if (shared_dbg_bank_full_sig)
                            shared_dbg_bank_full_blocked[perf_layer_idx] <=
                                shared_dbg_bank_full_blocked[perf_layer_idx] + 1;
                        if (shared_dbg_last_stage_sig)
                            shared_dbg_last_stage_blocked[perf_layer_idx] <=
                                shared_dbg_last_stage_blocked[perf_layer_idx] + 1;
                    end
                    if (shared_dbg_rq_stage_load_sig)
                        shared_dbg_rq_stage_load[perf_layer_idx] <=
                            shared_dbg_rq_stage_load[perf_layer_idx] + 1;
                    if (shared_dbg_rq_stage_fire_sig)
                        shared_dbg_rq_stage_fire[perf_layer_idx] <=
                            shared_dbg_rq_stage_fire[perf_layer_idx] + 1;
                    if (shared_dbg_output_fire_sig)
                        shared_dbg_output_fire[perf_layer_idx] <=
                            shared_dbg_output_fire[perf_layer_idx] + 1;
                     if (shared_dbg_output_stall_sig)
                         shared_dbg_output_stall[perf_layer_idx] <=
                             shared_dbg_output_stall[perf_layer_idx] + 1;
                    if (sweep_dbg_pw_published_sig)
                        sweep_dbg_pw_published[perf_layer_idx] <=
                            sweep_dbg_pw_published[perf_layer_idx] + 1;
                    else if ((sweep_dbg_state_sig == 4'd1) &&
                             !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.schedule_done_q)
                        sweep_dbg_pw_unpublished[perf_layer_idx] <=
                            sweep_dbg_pw_unpublished[perf_layer_idx] + 1;
                    if ((sweep_dbg_state_sig == 4'd1) &&
                        !dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.schedule_done_q) begin
                        if (!sweep_dbg_pw_slot_valid_sig)
                            sweep_dbg_pw_slot_invalid[perf_layer_idx] <=
                                sweep_dbg_pw_slot_invalid[perf_layer_idx] + 1;
                        else if (!sweep_dbg_pw_owner_match_sig)
                            sweep_dbg_pw_owner_mismatch[perf_layer_idx] <=
                                sweep_dbg_pw_owner_mismatch[perf_layer_idx] + 1;
                        else if (!sweep_dbg_pw_generation_match_sig)
                            sweep_dbg_pw_generation_mismatch[perf_layer_idx] <=
                                sweep_dbg_pw_generation_mismatch[perf_layer_idx] + 1;
                    end
                    if (sweep_dbg_pw_token_valid_sig)
                        sweep_dbg_pw_token_valid[perf_layer_idx] <=
                            sweep_dbg_pw_token_valid[perf_layer_idx] + 1;
                    if (sweep_dbg_pw_token_fire_sig)
                        sweep_dbg_pw_token_fire[perf_layer_idx] <=
                            sweep_dbg_pw_token_fire[perf_layer_idx] + 1;
                    if (sweep_dbg_pw_resp_wait_sig)
                        sweep_dbg_pw_resp_wait[perf_layer_idx] <=
                            sweep_dbg_pw_resp_wait[perf_layer_idx] + 1;
                    if (sweep_dbg_dw_valid_sig)
                        sweep_dbg_dw_valid[perf_layer_idx] <=
                            sweep_dbg_dw_valid[perf_layer_idx] + 1;
                    if (sweep_dbg_dw_ready_sig)
                        sweep_dbg_dw_ready[perf_layer_idx] <=
                            sweep_dbg_dw_ready[perf_layer_idx] + 1;
                    if (sweep_dbg_dw_fire_sig)
                        sweep_dbg_dw_fire[perf_layer_idx] <=
                            sweep_dbg_dw_fire[perf_layer_idx] + 1;
                    if (sweep_dbg_dw_bank_blocked_sig)
                        sweep_dbg_dw_blocked[perf_layer_idx] <=
                            sweep_dbg_dw_blocked[perf_layer_idx] + 1;
                    if (sweep_dbg_producer_stream_valid_sig)
                        sweep_dbg_stream_valid[perf_layer_idx] <=
                            sweep_dbg_stream_valid[perf_layer_idx] + 1;
                    if (sweep_dbg_producer_stream_ready_sig)
                        sweep_dbg_stream_ready[perf_layer_idx] <=
                            sweep_dbg_stream_ready[perf_layer_idx] + 1;
                    if (sweep_dbg_producer_stream_blocked_sig)
                        sweep_dbg_stream_blocked[perf_layer_idx] <=
                            sweep_dbg_stream_blocked[perf_layer_idx] + 1;
                    if (sweep_dbg_bank_busy0_sig && sweep_dbg_bank_busy1_sig)
                        sweep_dbg_bank_both_busy[perf_layer_idx] <=
                            sweep_dbg_bank_both_busy[perf_layer_idx] + 1;
                    if (sweep_dbg_result_group_final_sig)
                        sweep_dbg_result_group_final[perf_layer_idx] <=
                            sweep_dbg_result_group_final[perf_layer_idx] + 1;
                    if (sweep_dbg_result_row_final_sig)
                        sweep_dbg_result_row_final[perf_layer_idx] <=
                            sweep_dbg_result_row_final[perf_layer_idx] + 1;
                    sweep_dbg_adapter_state[perf_layer_idx][sweep_dbg_adapter_state_sig] <=
                        sweep_dbg_adapter_state[perf_layer_idx][sweep_dbg_adapter_state_sig] + 1;
                    sweep_dbg_sweep_state[perf_layer_idx][sweep_dbg_state_sig] <=
                        sweep_dbg_sweep_state[perf_layer_idx][sweep_dbg_state_sig] + 1;
                end
                if (shared_dbg_input_fire_sig)
                    shared_dbg_prev_input_fire = 1;
                else
                    shared_dbg_prev_input_fire = 0;
`endif
            end

            /* The M1.1-A commit fence is intentionally observable at the
             * top-level gate: a bank may become loaded only after the full
             * canonical image has been accepted. */
            if (USE_M11A_DS1 &&
                (dut.m11a_obs_state == 4'd5) &&
                dut.m11a_obs_core_cfg_commit_ready) begin
                if (dut.current_layer == 8'd1) begin
                    m11a_ds1_commit_events = m11a_ds1_commit_events + 1;
                    if (dut.m11a_obs_cfg_count_ds1 != 10'd308)
                        m11a_gate_errors = m11a_gate_errors + 1;
                end else if (dut.current_layer == 8'd2) begin
                    m11a_ds2_commit_events = m11a_ds2_commit_events + 1;
                    if (dut.m11a_obs_cfg_count_ds2 != 10'd872)
                        m11a_gate_errors = m11a_gate_errors + 1;
                end else begin
                    m11a_gate_errors = m11a_gate_errors + 1;
                end
            end

            if (USE_M11A_DS1 && perf_layer_active &&
                !dut.desc_bus_active && mem_req_valid && mem_req_ready &&
                !mem_req_write) begin
                if (perf_layer_idx == 8'd1)
                    m11a_ds1_config_requests = m11a_ds1_config_requests + 1;
                else if (perf_layer_idx == 8'd2)
                    m11a_ds2_config_requests = m11a_ds2_config_requests + 1;
            end

            if (dut.layer_sram_input_rd_en) begin
                sram_read_total <= sram_read_total + 1;
                if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                    perf_layer_sram_reads[perf_layer_idx] <=
                        perf_layer_sram_reads[perf_layer_idx] + 32'd1;
                end
            end
            if (dut.layer_sram_input_rd_word_en) begin
                if (sram_word_read_total < 80)
                    $display("WORD layer=%0d addr=%0d idx=%0d ch=%0d x=%0d y=%0d cin=%0d",
                             perf_layer_idx, dut.layer_sram_input_rd_word_addr,
                             dut.u_layer_runner.tiled_load_idx,
                             dut.u_layer_runner.tiled_load_channel,
                             dut.u_layer_runner.tiled_load_x,
                             dut.u_layer_runner.tiled_load_y,
                             dut.u_layer_runner.in_c_reg);
                sram_word_read_total <= sram_word_read_total + 1;
                if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                    perf_layer_sram_word_reads[perf_layer_idx] <=
                        perf_layer_sram_word_reads[perf_layer_idx] + 32'd1;
                    perf_layer_sram_reads[perf_layer_idx] <=
                        perf_layer_sram_reads[perf_layer_idx] + 32'd4;
                end
            end
            if (dut.layer_sram_output_wr_en) begin
                sram_write_total <= sram_write_total + 1;
                if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                    perf_layer_sram_writes[perf_layer_idx] <=
                        perf_layer_sram_writes[perf_layer_idx] + 32'd1;
                end
            end
            if (dut.layer_sram_output_wr4_en) begin
                sram_write_total <= sram_write_total + 1;
                if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                    perf_layer_sram_writes[perf_layer_idx] <=
                        perf_layer_sram_writes[perf_layer_idx] + 32'd1;
                end
                if (USE_M11A_DS1 && (perf_layer_idx == 8'd1)) begin
                    /* M1.1-A DS1 writes the bank that DS2 must consume.  The
                     * accepted stream is required to be aligned, full-beat,
                     * and contiguous; retain it for the DS2 response audit. */
                    if (dut.feature_output_bank_sel !== 1'b0)
                        m11a_gate_errors = m11a_gate_errors + 1;
                    if ((dut.layer_sram_output_wr4_be !== 4'hf) ||
                        (dut.layer_sram_output_wr4_addr !==
                         (m11a_ds1_output_words << 2)) ||
                        (m11a_ds1_output_words >= M11A_DS1_OUTPUT_WORDS)) begin
                        m11a_gate_errors = m11a_gate_errors + 1;
                    end else begin
                        m11a_ds1_output_capture[m11a_ds1_output_words] =
                            dut.layer_sram_output_wr4_data;
                    end
                    if (m11a_ds1_output_words ==
                        (M11A_DS1_OUTPUT_WORDS - 1))
                        m11a_ds1_last_seen = 1;
                    m11a_ds1_output_words = m11a_ds1_output_words + 1;
                end else if (USE_M11A_DS1 && (perf_layer_idx == 8'd2)) begin
                    /* M1.1-A DS2 writes the other bank, leaving the DS1
                     * source bank read-only for the entire layer. */
                    if (dut.feature_output_bank_sel !== 1'b1)
                        m11a_gate_errors = m11a_gate_errors + 1;
                end
            end

            if (USE_M11A_DS1 && perf_layer_active &&
                (perf_layer_idx == 8'd2)) begin
                /* feature_sram_pingpong returns an accepted read one cycle
                 * later.  Check both its aligned-word and scalar ports so the
                 * audit covers the M1.1-A source adapter ABI. */
                if (dut.layer_sram_input_rd_word_valid) begin
                    if (!m11a_ds2_word_pending) begin
                        m11a_gate_errors = m11a_gate_errors + 1;
                    end else begin
                        m11a_ds2_input_responses =
                            m11a_ds2_input_responses + 1;
                        if ((dut.feature_input_bank_sel !== 1'b0) ||
                            (dut.layer_sram_input_rd_word_data !==
                             m11a_ds1_output_capture[
                                 m11a_ds2_word_pending_addr[14:2]]))
                            m11a_ds2_input_mismatches =
                                m11a_ds2_input_mismatches + 1;
                    end
                end
                if (dut.layer_sram_input_rd_valid) begin
                    if (!m11a_ds2_scalar_pending) begin
                        m11a_gate_errors = m11a_gate_errors + 1;
                    end else begin
                        m11a_ds2_scalar_responses =
                            m11a_ds2_scalar_responses + 1;
                        if ((dut.feature_input_bank_sel !== 1'b0) ||
                            ($signed(dut.layer_sram_input_rd_data) !==
                             $signed(m11a_ds1_output_capture[
                                 m11a_ds2_scalar_pending_addr[14:2]][
                                     (m11a_ds2_scalar_pending_addr[1:0] * 8)
                                     +: 8])))
                            m11a_ds2_input_mismatches =
                                m11a_ds2_input_mismatches + 1;
                    end
                end
                if (dut.layer_sram_input_rd_word_en) begin
                    m11a_ds2_input_requests = m11a_ds2_input_requests + 1;
                    if ((dut.feature_input_bank_sel !== 1'b0) ||
                        (dut.layer_sram_input_rd_word_addr[1:0] !== 2'b00) ||
                        (dut.layer_sram_input_rd_word_addr[14:2] >=
                         M11A_DS1_OUTPUT_WORDS))
                        m11a_gate_errors = m11a_gate_errors + 1;
                end
                if (dut.layer_sram_input_rd_en) begin
                    m11a_ds2_scalar_requests =
                        m11a_ds2_scalar_requests + 1;
                    if ((dut.feature_input_bank_sel !== 1'b0) ||
                        (dut.layer_sram_input_rd_addr[14:2] >=
                         M11A_DS1_OUTPUT_WORDS))
                        m11a_gate_errors = m11a_gate_errors + 1;
                end
                m11a_ds2_word_pending = dut.layer_sram_input_rd_word_en;
                m11a_ds2_word_pending_addr = dut.layer_sram_input_rd_word_addr;
                m11a_ds2_scalar_pending = dut.layer_sram_input_rd_en;
                m11a_ds2_scalar_pending_addr = dut.layer_sram_input_rd_addr;
            end

            if (USE_M11A_DS1 && dut.layer_done &&
                (dut.current_layer == 8'd1)) begin
                /* The layer fence is legal only after the final accepted
                 * M1.1-A output beat and carries the requested bank swap. */
                if ((m11a_ds1_output_words != M11A_DS1_OUTPUT_WORDS) ||
                    !m11a_ds1_last_seen ||
                    (dut.desc_sram_swap_on_done !== 1'b1) ||
                    (m11a_ds1_config_requests != 308) ||
                    (m11a_ds1_commit_events != 1) ||
                    (dut.m11a_obs_loaded_ds1 !== 1'b1) ||
                    (dut.m11a_obs_loaded_ds2 !== 1'b0))
                    m11a_gate_errors = m11a_gate_errors + 1;
`ifdef M11A_FULLNET_LEDGER
                ledger_m11a_ds1_dw =
                    dut.m11a_obs_dw_mac_count;
                ledger_m11a_ds1_pw =
                    dut.m11a_obs_pw_mac_count;
                ledger_m11a_ds1_seen = 1'b1;
`endif
            end
            if (USE_M11A_DS1 && dut.layer_done &&
                (dut.current_layer == 8'd2)) begin
                if (m11a_ds2_word_pending || m11a_ds2_scalar_pending ||
                    (m11a_ds2_config_requests != 872) ||
                    (m11a_ds2_commit_events != 1) ||
                    (dut.m11a_obs_loaded_ds1 !== 1'b1) ||
                    (dut.m11a_obs_loaded_ds2 !== 1'b1))
                    m11a_gate_errors = m11a_gate_errors + 1;
`ifdef M11A_FULLNET_LEDGER
                ledger_m11a_ds2_dw =
                    dut.m11a_obs_dw_mac_count;
                ledger_m11a_ds2_pw =
                    dut.m11a_obs_pw_mac_count;
                ledger_m11a_ds2_seen = 1'b1;
`endif
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem_write_total <= mem_write_total + 1;
                    if (perf_layer_active) begin
                        layer_write_total <= layer_write_total + 1;
                        if (perf_layer_idx < MAX_LAYERS) begin
                            perf_layer_writes[perf_layer_idx] <= perf_layer_writes[perf_layer_idx] + 32'd1;
                        end
                    end
                end else begin
                    mem_read_total <= mem_read_total + 1;
                    if (perf_layer_active) begin
                        layer_read_total <= layer_read_total + 1;
                        // PH_INPUT is the activation stream; all other
                        // accepted layer reads are weight/quant config words.
                        if ((dut.u_layer_runner.state == ST_READ_REQ ||
                             dut.u_layer_runner.state == ST_READ_RESP) &&
                            dut.u_layer_runner.phase_idx != 4'd0 &&
                            perf_layer_idx < MAX_LAYERS)
                            perf_layer_config_reads[perf_layer_idx] <=
                                perf_layer_config_reads[perf_layer_idx] + 32'd1;
                        if (perf_layer_idx < MAX_LAYERS) begin
                            perf_layer_reads[perf_layer_idx] <= perf_layer_reads[perf_layer_idx] + 32'd1;
                        end
                    end else begin
                        desc_read_total <= desc_read_total + 1;
                    end
                end
            end

            if (dut.layer_done) begin
                if (USE_GROUP_SHARED64_DS &&
                    (dut.current_layer >= 8'd1) &&
                    (dut.current_layer <= 8'd6)) begin
                    group_ds_layers_seen = group_ds_layers_seen + 1;
                    group_total_cycles = group_total_cycles +
                                         dut.group_obs_perf_cycles;
                    group_total_dw_writes = group_total_dw_writes +
                                            dut.group_obs_perf_dw_writes;
                    group_total_descriptors = group_total_descriptors +
                                              dut.group_obs_perf_descriptors;
                    group_total_pw_tokens = group_total_pw_tokens +
                                            dut.group_obs_perf_pw_tokens;
                    group_total_output_writes = group_total_output_writes +
                                                dut.group_obs_perf_output_writes;
                    group_total_jobs = group_total_jobs +
                                       dut.group_obs_perf_jobs;
                    group_total_stream_beats = group_total_stream_beats +
                                              dut.group_obs_perf_stream_beats;
                     group_total_config_reads = group_total_config_reads +
                                               dut.group_obs_config_read_count;
                     group_layer_config_reads[dut.current_layer] =
                         dut.group_obs_config_read_count;
                     /* The group adapter counters are bank-local.  The
                      * active bank alternates at each layer fence, so a
                      * cross-bank delta would subtract an unrelated layer's
                      * image.  Capture the current bank's complete logical
                      * totals directly. */
                     group_layer_word_accepts[dut.current_layer] =
                         dut.group_obs_config_word_accept_count;
                     group_layer_scalar_writes[dut.current_layer] =
                         dut.group_obs_config_scalar_write_count;
                    group_total_dw_macs = group_total_dw_macs +
                                          expected_group_dw_macs_for_layer(dut.current_layer);
                    group_total_pw_macs = group_total_pw_macs +
                                          expected_group_pw_macs_for_layer(dut.current_layer);
                    if ((dut.group_obs_perf_dw_writes !==
                         expected_group_dw_writes_for_layer(dut.current_layer)) ||
                        (dut.group_obs_perf_stream_beats !==
                         expected_group_dw_writes_for_layer(dut.current_layer)) ||
                        (dut.group_obs_perf_descriptors !==
                         expected_group_descriptors_for_layer(dut.current_layer)) ||
                        (dut.group_obs_perf_pw_tokens !==
                         expected_group_pw_tokens_for_layer(dut.current_layer)) ||
                        (dut.group_obs_perf_output_writes !==
                         expected_group_output_writes_for_layer(dut.current_layer)) ||
                        (dut.group_obs_perf_jobs !==
                         expected_group_jobs_for_layer(dut.current_layer)) ||
                        (dut.group_obs_config_read_count !==
                         expected_group_config_reads_for_layer(dut.current_layer))) begin
                        group_ledger_errors = group_ledger_errors + 1;
                        $display("GROUP_DS_LEDGER_FAIL layer=%0d cycles=%0d dw=%0d/%0d stream=%0d/%0d desc=%0d/%0d tokens=%0d/%0d out=%0d/%0d jobs=%0d/%0d cfg=%0d/%0d",
                                 dut.current_layer, dut.group_obs_perf_cycles,
                                 dut.group_obs_perf_dw_writes,
                                 expected_group_dw_writes_for_layer(dut.current_layer),
                                 dut.group_obs_perf_stream_beats,
                                 expected_group_dw_writes_for_layer(dut.current_layer),
                                 dut.group_obs_perf_descriptors,
                                 expected_group_descriptors_for_layer(dut.current_layer),
                                 dut.group_obs_perf_pw_tokens,
                                 expected_group_pw_tokens_for_layer(dut.current_layer),
                                 dut.group_obs_perf_output_writes,
                                 expected_group_output_writes_for_layer(dut.current_layer),
                                 dut.group_obs_perf_jobs,
                                 expected_group_jobs_for_layer(dut.current_layer),
                         dut.group_obs_config_read_count,
                         expected_group_config_reads_for_layer(dut.current_layer));
                    end else begin
                        $display("GROUP_DS_LEDGER_PASS layer=%0d cycles=%0d dw=%0d dw_mac=%0d pw_mac=%0d desc=%0d tokens=%0d out=%0d jobs=%0d stream=%0d cfg=%0d",
                                 dut.current_layer, dut.group_obs_perf_cycles,
                                 dut.group_obs_perf_dw_writes,
                                 expected_group_dw_macs_for_layer(dut.current_layer),
                                 expected_group_pw_macs_for_layer(dut.current_layer),
                                 dut.group_obs_perf_descriptors,
                                 dut.group_obs_perf_pw_tokens,
                                 dut.group_obs_perf_output_writes,
                                 dut.group_obs_perf_jobs,
                                 dut.group_obs_perf_stream_beats,
                                 dut.group_obs_config_read_count);
                    end
                end
`ifdef DEBUG_SHARED_FULLNET
                if (USE_PERSISTENT_DS && USE_SHARED_UNIFIED64 &&
                    (dut.current_layer >= 1) && (dut.current_layer <= 6)) begin
                    /* current_layer is the descriptor index at layer_done;
                     * shared commit counters are cumulative across DS1..DS6. */
                    persistent_ds_preload[dut.current_layer - 1] <=
                        perf_layer_reads[dut.current_layer];
                    persistent_ds_compute[dut.current_layer - 1] <=
                        perf_layer_cycles[dut.current_layer];
                    persistent_ds_commit[dut.current_layer - 1] <=
                        dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_commit_count_reg -
                        persistent_ds_commit_prev;
                    persistent_ds_commit_prev <=
                        dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_commit_count_reg;
                    persistent_ds_reads[dut.current_layer - 1] <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_source_window_reads -
                        persistent_ds_reads_prev;
                    persistent_ds_writes[dut.current_layer - 1] <=
                        perf_layer_sram_writes[dut.current_layer];
                    persistent_ds_reuse[dut.current_layer - 1] <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_window_reuse -
                        persistent_ds_reuse_prev;
                    persistent_ds_tokens[dut.current_layer - 1] <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_token_count -
                        persistent_ds_tokens_prev;
                    persistent_ds_reads_prev <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_source_window_reads;
                    persistent_ds_reuse_prev <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_window_reuse;
                    persistent_ds_tokens_prev <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_token_count;
                end
`endif
                perf_layer_active <= 1'b0;
            end
        end
    end

    task reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            cmd_valid = 1'b0;
            cmd_type = 2'd0;
            mem_resp_valid = 1'b0;
            mem_resp_rdata = 32'd0;
            mem_resp_pending = 1'b0;
            mem_resp_pending_data = 32'd0;
            mem_resp_delay_count = 0;
            repeat (5) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task start_and_wait_done;
        begin
            while (!cmd_ready) begin
                @(posedge clk);
            end
            @(negedge clk);
            cmd_valid = 1'b1;
            cmd_type = 2'd0;
            @(negedge clk);
            cmd_valid = 1'b0;

            timeout = 0;
            while (!status[1] && timeout < 10000000) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (timeout >= 10000000) begin
                $display("FAIL tb_cnn_top_fullnet_sram_datapath timeout case=%0d status=%08x", case_idx, status);
                `ifdef DEBUG_SHARED_FULLNET
                $display("DBG runner state=%0d op_type=%08x stem=%0d ds=%0d tiled=%0d layer_busy=%0d layer_done=%0d layer_error=%0d",
                         dut.u_layer_runner.state, dut.u_layer_runner.op_type_reg,
                         dut.u_layer_runner.op_is_stem_reg, dut.u_layer_runner.op_is_ds_reg,
                         dut.u_layer_runner.tiled_spatial_mode, dut.layer_busy,
                         dut.layer_done, dut.layer_error);
                $display("DBG runner starts stem=%0d ds=%0d unified_stem busy=%0d done=%0d cfg_ready=%0d",
                         dut.u_layer_runner.stem_start, dut.u_layer_runner.ds_start,
                         dut.u_layer_runner.unified_stem_busy,
                         dut.u_layer_runner.unified_stem_done,
                         dut.u_layer_runner.unified_stem_cfg_ready);
                $display("DBG stem state=%0d busy=%0d done=%0d block=(%0d,%0d) cell_k=%0d load=(%0d,%0d) req=%0d resp=%0d tok=%0d mac=%0d commits=%0d",
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.state,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.busy,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.done,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.block_x,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.block_y,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.cell_k_idx,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.load_row,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.load_word,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.source_req_count_reg,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.source_resp_count_reg,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.token_count_reg,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.mac_count_reg,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.output_commit_count_reg);
                $display("DBG shared state active=%0d drain=%0d in_stage=%0d bank_live=%0d/%0d ready=%0d/%0d issue=%0d mode=%0d token=%0d commit=%0d rq_stage=%0d rq_busy=%0d valid_out=%0d",
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.current_active,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.drain_active,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.in_stage_valid,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.bank_live0,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.bank_live1,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.bank_ready0,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.bank_ready1,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.issue_idx,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.drain_mode,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.token_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.commit_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.rq_stage_valid,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.rq_busy,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.valid_out);
                $display("DBG shared io in v/r=%0d/%0d out v/r=%0d/%0d stem state/v/r=%0d/%0d/%0d core mode=%0d k=%0d",
                         dut.u_layer_runner.shared_stem_valid_in,
                         dut.u_layer_runner.shared_stem_ready_in,
                         dut.u_layer_runner.shared_stem_out_valid,
                         dut.u_layer_runner.shared_stem_out_ready,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.state,
                         dut.u_layer_runner.shared_core_valid_in,
                         dut.u_layer_runner.shared_core_ready_in,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.in_stage_mode,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.in_stage_last,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.in_stage_first);
`endif
                $fatal;
            end
            case_hw_cycles = status[31:8];
        end
    endtask

    initial begin
        rst_n = 1'b0;
        cmd_valid = 1'b0;
        cmd_type = 2'd0;
        desc_base_addr = 32'd0;
        layer_num = 32'd0;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        total_checks = 0;
        error_count = 0;
        case_errors = 0;
        case_hw_cycles = 32'd0;

        fd = $fopen(VECTOR_FILE, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open %0s", VECTOR_FILE);
            $fatal;
        end
        report_fd = $fopen("build/reports/tb_cnn_top_fullnet_sram_datapath_metrics.txt", "w");
        layer_metrics_fd = $fopen("build/reports/fullnet_layer_metrics.csv", "w");
        layer_profile_fd = $fopen("build/reports/fullnet_layer_profile.csv", "w");
        group_state_profile_fd = $fopen("build/reports/fullnet_group_state_profile.csv", "w");
        persistent_ds_metrics_fd = $fopen("build/reports/fullnet_persistent_ds_metrics.csv", "w");
        hw_logits_fd = $fopen("build/reports/fullnet_hw_logits.hex", "w");
        expected_logits_fd = $fopen("build/reports/fullnet_expected_logits.hex", "w");
        if ((report_fd == 0) || (layer_metrics_fd == 0) || (layer_profile_fd == 0) ||
            (group_state_profile_fd == 0) ||
            (persistent_ds_metrics_fd == 0) ||
            (hw_logits_fd == 0) || (expected_logits_fd == 0)) begin
            $display(
                "ERROR: cannot create fullnet reports metrics=%0d layers=%0d hw=%0d expected=%0d",
                report_fd, layer_metrics_fd, hw_logits_fd, expected_logits_fd
            );
            $fatal;
        end
        if (layer_metrics_fd != 0) begin
            $fwrite(
                layer_metrics_fd,
                "case,layer,cycles,mem_reads,config_reads,non_config_cycles,mem_writes,sram_reads,sram_scalar_reads,sram_word_reads,sram_writes,group_config_reads,group_config_word_writes,group_scalar_writes\n"
            );
        end
        if (group_state_profile_fd != 0)
            $fwrite(group_state_profile_fd, "case,layer,state,count\n");
        if (layer_profile_fd != 0) begin
            $fwrite(layer_profile_fd,
                    "case,layer,cycles,setup_validation,load_external_wait,engine_active_wait,store_writeback,other,unknown,sum_check\n");
        end
        $display("PROFILE_STATE_MAP runner_setup={VALIDATE,SPAN_COUNT,SPAN_RESULT,CALC_SPATIAL,LOAD_COUNT_DECIDE,ADDR_OFFSETS,ADDR_BASES,ADDR_INDEX,STORE_BASE_ADD,STORE_BASE_MUL,STORE_BASE_FINISH}; runner_load={LOAD_SETUP,READ_REQ,READ_RESP,TILED_INIT,TILED_LOAD_*}; runner_engine={ENGINE_START,ENGINE_WAIT,TILED_ENGINE_START,TILED_ENGINE_WAIT}; runner_store={STORE_SETUP,WRITE_REQ,STORE_PREFETCH,TILED_STORE_*,TILED_ADVANCE,NEXT_WAIT,START_WAIT}; group_state_profile=GROUP_ADAPTER_STATES_0_TO_12; other={IDLE,DONE,ERROR}; unknown=unmapped state");
        if (persistent_ds_metrics_fd != 0) begin
            $fwrite(persistent_ds_metrics_fd,
                    "case,ds_layer,preload_words,compute_cycles,commit_blocks,source_window_reads,sram_writes,window_reuse,tokens\n");
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            case_errors = 0;
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                mem[i] = 32'd0;
            end
            for (i = 0; i < MAX_EXPECTED; i = i + 1) begin
                expected_addr[i] = 32'd0;
                expected_data[i] = 8'd0;
            end

            scan_count = $fscanf(fd, "%h %d %d %d\n", desc_base_addr, layer_num_file, entry_count, expected_count);
            if (scan_count != 4) begin
                $display("ERROR: bad fullnet sram header case=%0d scan=%0d", case_idx, scan_count);
                $fatal;
            end
            layer_num = layer_num_file[31:0];

            for (i = 0; i < entry_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_data);
                if (scan_count != 2) begin
                    $display("ERROR: bad memory entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                mem[tmp_addr[19:2]] = tmp_data;
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_i8);
                if (scan_count != 2) begin
                    $display("ERROR: bad expected entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                expected_addr[i] = tmp_addr;
                expected_data[i] = tmp_i8;
            end

            reset_dut();
            start_and_wait_done();

            if (status[2]) begin
                $display("MISMATCH case=%0d unexpected error status=%08x", case_idx, status);
                error_count = error_count + 1;
                case_errors = case_errors + 1;
            end

`ifdef M11A_FULLNET_LEDGER
            if (USE_M11A_DS1) begin
                /* M1.1-A counters are retained at the DS1/DS2 layer fences;
                 * legacy Stem/DS/FC counters are read once the full network
                 * completion pulse has been observed. */
                ledger_stem_mac =
                    dut.u_layer_runner.gen_legacy_stem.u_stem_engine.sim_mac_count;
                ledger_legacy_dw_mac =
                    dut.u_layer_runner.gen_legacy_ds_engine.u_ds_block_engine.u_dw_engine.sim_mac_count;
                ledger_legacy_pw_mac =
                    dut.u_layer_runner.gen_legacy_ds_engine.u_ds_block_engine.gen_legacy_pw.u_pw_array.sim_mac_count;
                ledger_fc_mac = dut.u_layer_runner.u_fc_unit.sim_config_weight_count;
                ledger_total_mac = ledger_m11a_ds1_dw + ledger_m11a_ds1_pw +
                                   ledger_m11a_ds2_dw + ledger_m11a_ds2_pw +
                                   ledger_stem_mac + ledger_legacy_dw_mac +
                                   ledger_legacy_pw_mac + ledger_fc_mac;
                if (!ledger_m11a_ds1_seen || !ledger_m11a_ds2_seen ||
                    (ledger_m11a_ds1_dw != 147456) ||
                    (ledger_m11a_ds1_pw != 524288) ||
                    (ledger_m11a_ds2_dw != 73728) ||
                    (ledger_m11a_ds2_pw != 524288) ||
                    (ledger_stem_mac != 442368) ||
                    (ledger_legacy_dw_mac != 276480) ||
                    (ledger_legacy_pw_mac != 3145728) ||
                    (ledger_fc_mac != 2560) ||
                    (ledger_total_mac != 5136896)) begin
                    $display("C0_MAC_LEDGER_FAIL macs=%0d ops=%0d ds1_dw=%0d ds1_pw=%0d ds2_dw=%0d ds2_pw=%0d stem=%0d legacy_dw=%0d legacy_pw=%0d fc=%0d seen=%0d/%0d",
                             ledger_total_mac, ledger_total_mac * 2,
                             ledger_m11a_ds1_dw, ledger_m11a_ds1_pw,
                             ledger_m11a_ds2_dw, ledger_m11a_ds2_pw,
                             ledger_stem_mac, ledger_legacy_dw_mac,
                             ledger_legacy_pw_mac, ledger_fc_mac,
                             ledger_m11a_ds1_seen, ledger_m11a_ds2_seen);
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end else begin
                    $display("C0_MAC_LEDGER_PASS macs=%0d ops=%0d ds1_dw=%0d ds1_pw=%0d ds2_dw=%0d ds2_pw=%0d stem=%0d legacy_dw=%0d legacy_pw=%0d fc=%0d",
                             ledger_total_mac, ledger_total_mac * 2,
                             ledger_m11a_ds1_dw, ledger_m11a_ds1_pw,
                             ledger_m11a_ds2_dw, ledger_m11a_ds2_pw,
                             ledger_stem_mac, ledger_legacy_dw_mac,
                             ledger_legacy_pw_mac, ledger_fc_mac);
                end
            end
`endif

            if (USE_M11A_DS1) begin
                if ((m11a_ds1_output_words != M11A_DS1_OUTPUT_WORDS) ||
                    !m11a_ds1_last_seen ||
                    (m11a_ds2_input_requests == 0) ||
                    (m11a_ds2_input_responses != m11a_ds2_input_requests) ||
                    (m11a_ds2_scalar_responses != m11a_ds2_scalar_requests) ||
                    (m11a_ds2_input_mismatches != 0) ||
                    (m11a_gate_errors != 0)) begin
                    $display("MISMATCH M11A_GATE_B case=%0d ds1_words=%0d last=%0d gate_errors=%0d ds2_word_req=%0d ds2_word_resp=%0d ds2_scalar_req=%0d ds2_scalar_resp=%0d input_mismatches=%0d banks=%0d/%0d",
                             case_idx, m11a_ds1_output_words,
                             m11a_ds1_last_seen, m11a_gate_errors,
                             m11a_ds2_input_requests,
                             m11a_ds2_input_responses,
                             m11a_ds2_scalar_requests,
                             m11a_ds2_scalar_responses,
                             m11a_ds2_input_mismatches,
                             dut.feature_input_bank_sel,
                             dut.feature_output_bank_sel);
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end else begin
                    /* DS2 has no writes to the DS1 bank: every accepted DS2
                     * output was checked for output_bank_sel==1 above, while
                     * every DS2 response was checked against the captured DS1
                     * stream.  Together these checks prove the bank remains
                     * intact without relying on an optimized-away internal
                     * BRAM model array. */
                    $display("M11A_GATE_B_PASS ds1_words=%0d ds2_word_req=%0d ds2_word_resp=%0d ds2_scalar_req=%0d ds2_scalar_resp=%0d input_mismatches=%0d bank0_preserved=1",
                             m11a_ds1_output_words,
                             m11a_ds2_input_requests,
                             m11a_ds2_input_responses,
                             m11a_ds2_scalar_requests,
                             m11a_ds2_scalar_responses,
                             m11a_ds2_input_mismatches);
                end
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                if (expected_logits_fd != 0) begin
                    $fwrite(expected_logits_fd, "%02x\n", expected_data[i]);
                end
                if (hw_logits_fd != 0) begin
                    $fwrite(hw_logits_fd, "%02x\n", mem[expected_addr[i][19:2]][7:0]);
                end
                if (mem[expected_addr[i][19:2]][7:0] !== expected_data[i]) begin
                    $display(
                        "MISMATCH case=%0d i=%0d addr=%08x expected=%0d actual=%0d",
                        case_idx,
                        i,
                        expected_addr[i],
                        $signed(expected_data[i]),
                        $signed(mem[expected_addr[i][19:2]][7:0])
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
                total_checks = total_checks + 1;
            end
            for (i = 0; i < layer_num_file && i < MAX_LAYERS; i = i + 1) begin
                if (perf_layer_sram_word_reads[i] != 0)
                    $display("PERF layer=%0d scalar_sram_reads=%0d word_reads=%0d",
                             i,
                             perf_layer_sram_reads[i] -
                             (perf_layer_sram_word_reads[i] * 4),
                             perf_layer_sram_word_reads[i]);
                if (perf_layer_reads[i] !== expected_ext_reads_for_layer(i)) begin
                    $display(
                        "MISMATCH layer=%0d ext_reads got=%0d expected=%0d",
                        i, perf_layer_reads[i], expected_ext_reads_for_layer(i)
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
                if (perf_layer_writes[i] !== expected_ext_writes_for_layer(i)) begin
                    $display(
                        "MISMATCH layer=%0d ext_writes got=%0d expected=%0d",
                        i, perf_layer_writes[i], expected_ext_writes_for_layer(i)
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
                if (!USE_GROUP_SHARED64_DS &&
                    (perf_layer_sram_reads[i] !== expected_sram_reads_for_layer(i))) begin
                    $display(
                        "MISMATCH layer=%0d sram_reads got=%0d expected=%0d",
                        i, perf_layer_sram_reads[i], expected_sram_reads_for_layer(i)
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
                if (!USE_GROUP_SHARED64_DS &&
                    (perf_layer_sram_writes[i] !== expected_sram_writes_for_layer(i))) begin
                    $display(
                        "MISMATCH layer=%0d sram_writes got=%0d expected=%0d",
                        i, perf_layer_sram_writes[i], expected_sram_writes_for_layer(i)
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
            end
            if (USE_GROUP_SHARED64_DS) begin
                if ((group_ledger_errors != 0) ||
                    (group_ds_layers_seen != 6) ||
                    (group_total_dw_macs != 497664) ||
                    (group_total_pw_macs != 4194304) ||
                    (group_total_dw_writes != 14336) ||
                    (group_total_stream_beats != 14336) ||
                    (group_total_descriptors != 896) ||
                    (group_total_pw_tokens != 73728) ||
                    (group_total_output_writes != 21504) ||
                    (group_total_jobs != 112) ||
                    (group_total_config_reads !=
                     (PACKED_WEIGHTS ? 20284 : 71200))) begin
                    $display("GROUP_C0_LEDGER_FAIL layers=%0d errors=%0d dw_mac=%0d pw_mac=%0d ds_mac=%0d ds_ops=%0d dw=%0d stream=%0d desc=%0d tokens=%0d out=%0d jobs=%0d cfg=%0d",
                             group_ds_layers_seen, group_ledger_errors,
                             group_total_dw_macs, group_total_pw_macs,
                             group_total_dw_macs + group_total_pw_macs,
                             (group_total_dw_macs + group_total_pw_macs) * 2,
                             group_total_dw_writes, group_total_stream_beats,
                             group_total_descriptors, group_total_pw_tokens,
                             group_total_output_writes, group_total_jobs,
                             group_total_config_reads);
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end else begin
                    /* Stem and FC remain on cnn_layer_runner in this build;
                     * include their fixed C0 workload to make the network
                     * MAC/ops total explicit at the integration boundary. */
                    $display("GROUP_C0_LEDGER_PASS layers=%0d ds_dw_mac=%0d ds_pw_mac=%0d ds_mac=%0d ds_ops=%0d dw=%0d stream=%0d desc=%0d tokens=%0d out=%0d jobs=%0d cfg=%0d network_mac=%0d network_ops=%0d",
                             group_ds_layers_seen, group_total_dw_macs,
                             group_total_pw_macs,
                             group_total_dw_macs + group_total_pw_macs,
                             (group_total_dw_macs + group_total_pw_macs) * 2,
                             group_total_dw_writes, group_total_stream_beats,
                             group_total_descriptors, group_total_pw_tokens,
                             group_total_output_writes, group_total_jobs,
                             group_total_config_reads,
                             group_total_dw_macs + group_total_pw_macs +
                             442368 + 2560,
                             (group_total_dw_macs + group_total_pw_macs +
                              442368 + 2560) * 2);
                end
            end
            if (MEM_READY_STALLS && MEM_READY_RANDOM &&
                (mem_req_stall_total == 0)) begin
                $display("GROUP_BACKPRESSURE_FAIL random_ready=1 stalls=0");
                error_count = error_count + 1;
                case_errors = case_errors + 1;
            end
            if (USE_M11A_DS1 && (case_errors == 0)) begin
                $display("M11A_CONFIG_BANK_PASS ds1_cfg=%0d ds2_cfg=%0d ds1_commit=%0d ds2_commit=%0d loaded_ds1=1 loaded_ds2=1 commit_after_full_image=1",
                         m11a_ds1_config_requests, m11a_ds2_config_requests,
                         m11a_ds1_commit_events, m11a_ds2_commit_events);
            end
            if (report_fd != 0) begin
                $fwrite(
                    report_fd,
                    "case=%0d hw_cycles=%0d checks=%0d errors=%0d status=%08x mem_reads=%0d mem_writes=%0d desc_reads=%0d layer_reads=%0d layer_writes=%0d sram_reads=%0d sram_scalar_reads=%0d sram_word_reads=%0d sram_logical_reads=%0d sram_writes=%0d\n",
                    case_idx,
                    case_hw_cycles,
                    expected_count,
                    case_errors,
                    status,
                    mem_read_total,
                    mem_write_total,
                    desc_read_total,
                    layer_read_total,
                    layer_write_total,
                    sram_read_total,
                    sram_read_total,
                    sram_word_read_total,
                    sram_read_total + (sram_word_read_total * 4),
                    sram_write_total
                );
            end
            if (layer_metrics_fd != 0) begin
                for (i = 0; i < layer_num_file && i < MAX_LAYERS; i = i + 1) begin
                    $fwrite(
                        layer_metrics_fd,
                        "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        case_idx,
                        i,
                        perf_layer_cycles[i],
                        perf_layer_reads[i],
                        perf_layer_config_reads[i],
                        perf_layer_cycles[i] - perf_layer_config_reads[i],
                        perf_layer_writes[i],
                        perf_layer_sram_reads[i],
                        perf_layer_sram_reads[i] -
                        (perf_layer_sram_word_reads[i] * 4),
                        perf_layer_sram_word_reads[i],
                        perf_layer_sram_writes[i],
                        group_layer_config_reads[i],
                        group_layer_word_accepts[i],
                        group_layer_scalar_writes[i]
                    );
                end
            end
            if (layer_profile_fd != 0) begin
                for (i = 0; i < layer_num_file && i < MAX_LAYERS; i = i + 1) begin
                    profile_sum = 0;
                    for (perf_i = 0; perf_i <= PROFILE_UNKNOWN; perf_i = perf_i + 1)
                        profile_sum = profile_sum + profile_cycles[i][perf_i];
                    $fwrite(layer_profile_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0s\n",
                            case_idx, i, perf_layer_cycles[i],
                            profile_cycles[i][PROFILE_SETUP], profile_cycles[i][PROFILE_LOAD],
                            profile_cycles[i][PROFILE_ENGINE], profile_cycles[i][PROFILE_STORE],
                            profile_cycles[i][PROFILE_OTHER], profile_cycles[i][PROFILE_UNKNOWN],
                            (profile_sum == perf_layer_cycles[i]) ? "PASS" : "FAIL");
                    $display("PROFILE layer=%0d cycles=%0d setup=%0d load=%0d engine=%0d store=%0d other=%0d unknown=%0d sum=%0d check=%0s",
                             i, perf_layer_cycles[i], profile_cycles[i][PROFILE_SETUP],
                             profile_cycles[i][PROFILE_LOAD], profile_cycles[i][PROFILE_ENGINE],
                             profile_cycles[i][PROFILE_STORE], profile_cycles[i][PROFILE_OTHER],
                             profile_cycles[i][PROFILE_UNKNOWN], profile_sum,
                              (profile_sum == perf_layer_cycles[i]) ? "PASS" : "FAIL");
                    if (USE_GROUP_SHARED64_DS && (i >= 1) && (i <= 6)) begin
                        for (perf_i = 0; perf_i <= GROUP_S_WAIT_CFG_PREFETCH; perf_i = perf_i + 1)
                            if (group_state_profile_fd != 0)
                                $fwrite(group_state_profile_fd, "%0d,%0d,%0d,%0d\n",
                                        case_idx, i, perf_i,
                                        group_state_cycles[i][perf_i]);
                        $display("GROUP_PROFILE layer=%0d cycles=%0d sweep_start=%0d dw_fetch=%0d param_fetch=%0d cfg=%0d context=%0d fill=%0d wait_fill=%0d job=%0d wait_job=%0d finish=%0d wait_prefill=%0d wait_cfg_prefetch=%0d cfg_reads=%0d cfg_word_writes=%0d cfg_scalar_writes=%0d",
                                 i, perf_layer_cycles[i],
                                 group_state_cycles[i][GROUP_S_SWEEP_START],
                                 group_state_cycles[i][GROUP_S_DW_WEIGHT_FETCH],
                                 group_state_cycles[i][GROUP_S_DW_PARAM_FETCH],
                                 group_state_cycles[i][GROUP_S_CFG],
                                 group_state_cycles[i][GROUP_S_CONTEXT],
                                 group_state_cycles[i][GROUP_S_FILL],
                                 group_state_cycles[i][GROUP_S_WAIT_FILL],
                                 group_state_cycles[i][GROUP_S_JOB],
                                 group_state_cycles[i][GROUP_S_WAIT_JOB],
                                 group_state_cycles[i][GROUP_S_FINISH],
                                 group_state_cycles[i][GROUP_S_WAIT_PREFILL],
                                 group_state_cycles[i][GROUP_S_WAIT_CFG_PREFETCH],
                                 group_layer_config_reads[i],
                                 group_layer_word_accepts[i],
                                 group_layer_scalar_writes[i]);
                    end
                end
            end
            if (persistent_ds_metrics_fd != 0 && USE_PERSISTENT_DS && USE_SHARED_UNIFIED64) begin
                for (i = 0; i < 6; i = i + 1) begin
                    $fwrite(persistent_ds_metrics_fd,
                            "%0d,DS%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                            case_idx, i + 1,
                            persistent_ds_preload[i], persistent_ds_compute[i],
                            persistent_ds_commit[i], persistent_ds_reads[i],
                            persistent_ds_writes[i], persistent_ds_reuse[i],
                            persistent_ds_tokens[i]);
                    $display("PERSISTENT_DS layer=DS%0d preload_words=%0d compute_cycles=%0d commit_blocks=%0d source_window_reads=%0d sram_writes=%0d window_reuse=%0d tokens=%0d",
                             i + 1,
                             persistent_ds_preload[i], persistent_ds_compute[i],
                             persistent_ds_commit[i], persistent_ds_reads[i],
                             persistent_ds_writes[i], persistent_ds_reuse[i],
                             persistent_ds_tokens[i]);
                end
            end
`ifdef DEBUG_SHARED_INSTRUMENT
            if (USE_GROUP_SHARED64_DS) begin
                for (i = 1; i <= 6; i = i + 1) begin
                    $display("SHARED_PROFILE layer=%0d reserve=%0d meta_commit=%0d meta_wait=%0d drain_start=%0d drain_wait=%0d drain_final=%0d input_fire=%0d mac_consume=%0d input_blocked=%0d bank_full=%0d last_stage=%0d rq_load=%0d rq_fire=%0d output_fire=%0d output_stall=%0d reserve_gaps=%0d gap_sum=%0d gap_min=%0d gap_max=%0d core_tokens=%0d core_commits=%0d",
                             i,
                             shared_dbg_reserve[i], shared_dbg_meta_commit[i],
                             shared_dbg_meta_wait[i], shared_dbg_drain_start[i],
                             shared_dbg_drain_start_wait[i], shared_dbg_drain_final[i],
                             shared_dbg_input_fire[i], shared_dbg_mac_consume[i],
                             shared_dbg_input_blocked[i], shared_dbg_bank_full_blocked[i],
                             shared_dbg_last_stage_blocked[i], shared_dbg_rq_stage_load[i],
                             shared_dbg_rq_stage_fire[i], shared_dbg_output_fire[i],
                             shared_dbg_output_stall[i], shared_dbg_reserve_gap_count[i],
                             shared_dbg_reserve_gap_sum[i], shared_dbg_reserve_gap_min[i],
                             shared_dbg_reserve_gap_max[i],
                             shared_dbg_core_tokens_sig,
                             shared_dbg_core_commits_sig);
                    $display("SWEEP_PROFILE layer=%0d pw_published=%0d pw_unpublished=%0d pw_slot_invalid=%0d pw_owner_mismatch=%0d pw_generation_mismatch=%0d pw_token_valid=%0d pw_token_fire=%0d pw_resp_wait=%0d dw_valid=%0d dw_ready=%0d dw_fire=%0d dw_blocked=%0d stream_valid=%0d stream_ready=%0d stream_blocked=%0d bank_both_busy=%0d result_group_final=%0d result_row_final=%0d adapter_states=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d sweep_states=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                             i,
                             sweep_dbg_pw_published[i], sweep_dbg_pw_unpublished[i],
                             sweep_dbg_pw_slot_invalid[i], sweep_dbg_pw_owner_mismatch[i],
                             sweep_dbg_pw_generation_mismatch[i],
                             sweep_dbg_pw_token_valid[i], sweep_dbg_pw_token_fire[i],
                             sweep_dbg_pw_resp_wait[i], sweep_dbg_dw_valid[i],
                             sweep_dbg_dw_ready[i], sweep_dbg_dw_fire[i],
                             sweep_dbg_dw_blocked[i], sweep_dbg_stream_valid[i],
                             sweep_dbg_stream_ready[i], sweep_dbg_stream_blocked[i],
                             sweep_dbg_bank_both_busy[i],
                             sweep_dbg_result_group_final[i], sweep_dbg_result_row_final[i],
                             sweep_dbg_adapter_state[i][0], sweep_dbg_adapter_state[i][1],
                             sweep_dbg_adapter_state[i][2], sweep_dbg_adapter_state[i][3],
                             sweep_dbg_adapter_state[i][4], sweep_dbg_adapter_state[i][5],
                             sweep_dbg_adapter_state[i][6], sweep_dbg_adapter_state[i][7],
                             sweep_dbg_adapter_state[i][8], sweep_dbg_adapter_state[i][9],
                             sweep_dbg_adapter_state[i][10], sweep_dbg_adapter_state[i][11],
                             sweep_dbg_adapter_state[i][12], sweep_dbg_adapter_state[i][13],
                             sweep_dbg_adapter_state[i][14], sweep_dbg_adapter_state[i][15],
                             sweep_dbg_sweep_state[i][0], sweep_dbg_sweep_state[i][1],
                             sweep_dbg_sweep_state[i][2], sweep_dbg_sweep_state[i][3],
                             sweep_dbg_sweep_state[i][4], sweep_dbg_sweep_state[i][5],
                             sweep_dbg_sweep_state[i][6], sweep_dbg_sweep_state[i][7]);
                end
            end
`endif
            $display(
                "PERF tb_cnn_top_fullnet_sram_datapath case=%0d hw_cycles=%0d checks=%0d errors=%0d status=%08x mem_reads=%0d mem_writes=%0d mem_req_stalls=%0d ready_random=%0d resp_delay=%0d",
                case_idx,
                case_hw_cycles,
                expected_count,
                case_errors,
                status,
                mem_read_total,
                mem_write_total,
                mem_req_stall_total,
                MEM_READY_RANDOM,
                MEM_RESP_DELAY
            );
`ifdef DEBUG_SHARED_FULLNET
            if (USE_SHARED_UNIFIED64) begin
                $display("SHARED_METRIC stem_tok=%0d stem_mac=%0d stem_commit=%0d ds_tok=%0d ds_mac=%0d ds_commit=%0d total_tok=%0d total_commit=%0d",
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.stem_token_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.stem_token_count_reg * 64,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.stem_commit_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_token_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_token_count_reg * 64,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_commit_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.token_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.commit_count_reg);
            end
`endif
        end

        $fclose(fd);
        if (report_fd != 0) begin
            $fclose(report_fd);
        end
        if (layer_metrics_fd != 0) begin
            $fclose(layer_metrics_fd);
        end
        if (layer_profile_fd != 0) begin
            $fclose(layer_profile_fd);
        end
        if (persistent_ds_metrics_fd != 0) begin
            $fclose(persistent_ds_metrics_fd);
        end
        if (hw_logits_fd != 0) begin
            $fclose(hw_logits_fd);
        end
        if (expected_logits_fd != 0) begin
            $fclose(expected_logits_fd);
        end
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_cnn_top_fullnet_sram_datapath cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_cnn_top_fullnet_sram_datapath checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
