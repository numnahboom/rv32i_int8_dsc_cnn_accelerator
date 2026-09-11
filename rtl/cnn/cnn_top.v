`timescale 1ns/1ps
`default_nettype none

module cnn_top #(
    /* Keep the production/fullnet default unchanged; integration benches can
     * select the unified64 DS data path through the complete top. */
    parameter USE_UNIFIED64_DS = 0,
    parameter USE_UNIFIED64_STEM = 0,
    parameter USE_SHARED_UNIFIED64 = 0,
    parameter USE_PERSISTENT_DS = 0,
    /* Compile-time M1.1-A DS production branch.  The selected build keeps
     * the legacy runner for non-M1.1-A descriptors and routes DS1/DS2
     * through the dedicated M1.1-A adapter. */
    parameter USE_M11A_DS1 = 0,
    parameter USE_DS1_RETAINED_ORCHESTRATOR = 0,
    /* Physical-envelope selector.  When set together with the retained DS1
     * hook, the legacy DS engine is excluded at elaboration; this is not a
     * production/fullnet configuration and does not support other DS shapes. */
    parameter USE_RETAINED_ONLY_DS = 0,
    /* Route every OP_DS_BLOCK descriptor through the descriptor-facing
     * group-published shared64 backend.  The selected cnn_layer_runner build
     * omits its legacy DS engine at elaboration. */
    parameter USE_GROUP_SHARED64_DS = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [1:0]  cmd_type,
    input  wire [31:0] desc_base_addr,
    input  wire [31:0] layer_num,

    output wire [31:0] status,

    output wire        mem_req_valid,
    output wire        mem_req_write,
    output wire [31:0] mem_req_addr,
    output wire [31:0] mem_req_wdata,
    input  wire        mem_req_ready,

    input  wire        mem_resp_valid,
    input  wire [31:0] mem_resp_rdata
);
    localparam CMD_START = 2'd0;

    wire cmd_fire;
    wire ctrl_start;
    wire ctrl_busy;
    wire ctrl_done;
    wire ctrl_error;
    wire [7:0] current_layer;
    wire fetch_start;
    wire [31:0] fetch_layer_index;
    wire desc_busy;
    wire desc_valid;
    wire [1023:0] desc_words;
    wire [31:0] desc_op_type;
    wire layer_start;
    wire layer_busy;
    wire layer_done;
    wire layer_error;
    wire layer_mem_req_valid;
    wire layer_mem_req_write;
    wire [31:0] layer_mem_req_addr;
    wire [31:0] layer_mem_req_wdata;
    wire layer_sram_input_rd_en;
    wire [14:0] layer_sram_input_rd_addr;
    wire layer_sram_input_rd_valid;
    wire signed [7:0] layer_sram_input_rd_data;
    wire layer_sram_input_rd_word_en;
    wire [14:0] layer_sram_input_rd_word_addr;
    wire layer_sram_input_rd_word_valid;
    wire [31:0] layer_sram_input_rd_word_data;
    wire layer_sram_output_wr_en;
    wire [14:0] layer_sram_output_wr_addr;
    wire signed [7:0] layer_sram_output_wr_data;
    wire layer_sram_output_wr4_en;
    wire [14:0] layer_sram_output_wr4_addr;
    wire [31:0] layer_sram_output_wr4_data;
    wire [3:0] layer_sram_output_wr4_be;
    wire desc_mem_req_valid;
    wire desc_mem_req_write;
    wire [31:0] desc_mem_req_addr;
    wire [31:0] desc_mem_req_wdata;
    /* Independent descriptor look-ahead used only by the group DS backend.
     * It runs while a current DS layer owns the external bus and feeds the
     * group's inactive configuration bank. */
    wire group_prefetch_desc_busy;
    wire group_prefetch_desc_valid;
    wire [1023:0] group_prefetch_desc_words;
    wire group_prefetch_mem_req_valid;
    wire group_prefetch_mem_req_write;
    wire [31:0] group_prefetch_mem_req_addr;
    wire [31:0] group_prefetch_mem_req_wdata;
    wire group_prefetch_fetch_start;
    wire group_prefetch_bus_active;
    reg group_prefetch_desc_issued;
    // Keep the legacy runner's response gate one clocked boundary away from
    // current_layer/group_prefetch.  The legacy runner is never started for
    // a group-selected layer, but its idle tiled-loader response predicate
    // still exists in the netlist.  A combinational bus-owner mux therefore
    // allowed the descriptor look-ahead control to reach tiled cursor CEs.
    // This bit preserves the response fence for the only case where a
    // prefetched descriptor can overlap a following legacy layer, while its
    // registered Q keeps current_layer out of that timing cone.
    reg legacy_mem_resp_block_q;
    wire desc_bus_active;
    wire [31:0] total_cycles;
    wire [31:0] layer_cycles;
    wire [7:0] counter_layer;
    wire [31:0] ctrl_layer_num;
    wire feature_input_bank_sel;
    wire feature_output_bank_sel;
    wire feature_host_rd_valid_unused;
    wire signed [7:0] feature_host_rdata_unused;
    wire desc_sram_swap_on_done;

    /* Keep the legacy runner as the stable top-level instance.  In the M1.1-A
     * build it remains the owner for every descriptor except the production
     * DS1/DS2 slots (layer indices 1 and 2); the M1.1-A runner is selected only
     * for those slots.  This preserves the existing hierarchy for baseline
     * benches and prevents a default build from elaborating any M1.1-A data
     * plane. */
    wire legacy_layer_busy;
    wire legacy_layer_done;
    wire legacy_layer_error;
    wire legacy_layer_mem_req_valid;
    wire legacy_layer_mem_req_write;
    wire [31:0] legacy_layer_mem_req_addr;
    wire [31:0] legacy_layer_mem_req_wdata;
    wire legacy_sram_input_rd_en;
    wire [14:0] legacy_sram_input_rd_addr;
    wire legacy_sram_input_rd_valid = layer_sram_input_rd_valid;
    wire signed [7:0] legacy_sram_input_rd_data = layer_sram_input_rd_data;
    wire legacy_sram_input_rd_word_en;
    wire [14:0] legacy_sram_input_rd_word_addr;
    wire legacy_sram_input_rd_word_valid = layer_sram_input_rd_word_valid;
    wire [31:0] legacy_sram_input_rd_word_data = layer_sram_input_rd_word_data;
    wire legacy_sram_output_wr_en;
    wire [14:0] legacy_sram_output_wr_addr;
    wire signed [7:0] legacy_sram_output_wr_data;
    wire legacy_sram_output_wr4_en;
    wire [14:0] legacy_sram_output_wr4_addr;
    wire [31:0] legacy_sram_output_wr4_data;
    wire [3:0] legacy_sram_output_wr4_be;

    wire m11a_layer_busy;
    wire m11a_layer_done;
    wire m11a_layer_error;
    wire m11a_layer_mem_req_valid;
    wire m11a_layer_mem_req_write;
    wire [31:0] m11a_layer_mem_req_addr;
    wire [31:0] m11a_layer_mem_req_wdata;
    wire m11a_sram_input_rd_en;
    wire [14:0] m11a_sram_input_rd_addr;
    wire m11a_sram_input_rd_valid = layer_sram_input_rd_valid;
    wire signed [7:0] m11a_sram_input_rd_data = layer_sram_input_rd_data;
    wire m11a_sram_input_rd_word_en;
    wire [14:0] m11a_sram_input_rd_word_addr;
    wire m11a_sram_input_rd_word_valid = layer_sram_input_rd_word_valid;
    wire [31:0] m11a_sram_input_rd_word_data = layer_sram_input_rd_word_data;
    wire m11a_sram_output_wr_en;
    wire [14:0] m11a_sram_output_wr_addr;
    wire signed [7:0] m11a_sram_output_wr_data;
    wire m11a_sram_output_wr4_en;
    wire [14:0] m11a_sram_output_wr4_addr;
    wire [31:0] m11a_sram_output_wr4_data;
    wire [3:0] m11a_sram_output_wr4_be;

    /* Stable observability for integration testbenches.  The production
     * M1.1-A hierarchy is optional, so expose zero-valued nets when that
     * backend is not elaborated instead of making consumers resolve a
     * parameter-dependent generate path. */
    wire m11a_obs_loaded_ds1;
    wire m11a_obs_loaded_ds2;
    wire [9:0] m11a_obs_cfg_count_ds1;
    wire [9:0] m11a_obs_cfg_count_ds2;
    wire [3:0] m11a_obs_state;
    wire m11a_obs_core_cfg_commit_ready;
    wire [31:0] m11a_obs_dw_mac_count;
    wire [31:0] m11a_obs_pw_mac_count;

    wire group_layer_busy;
    wire group_layer_done;
    wire group_layer_error;
    wire group_layer_mem_req_valid;
    wire group_layer_mem_req_write;
    wire [31:0] group_layer_mem_req_addr;
    wire [31:0] group_layer_mem_req_wdata;
    wire group_sram_input_rd_en;
    wire [14:0] group_sram_input_rd_addr;
    wire group_sram_input_rd_valid = layer_sram_input_rd_valid;
    wire signed [7:0] group_sram_input_rd_data = layer_sram_input_rd_data;
    wire group_sram_input_rd_word_en;
    wire [14:0] group_sram_input_rd_word_addr;
    wire group_sram_input_rd_word_valid = layer_sram_input_rd_word_valid;
    wire [31:0] group_sram_input_rd_word_data = layer_sram_input_rd_word_data;
    wire group_sram_output_wr_en;
    wire [14:0] group_sram_output_wr_addr;
    wire signed [7:0] group_sram_output_wr_data;
    wire group_sram_output_wr4_en;
    wire [14:0] group_sram_output_wr4_addr;
    wire [31:0] group_sram_output_wr4_data;
    wire [3:0] group_sram_output_wr4_be;
    wire [31:0] group_obs_perf_cycles;
    wire [31:0] group_obs_perf_dw_writes;
    wire [31:0] group_obs_perf_descriptors;
    wire [31:0] group_obs_perf_pw_tokens;
    wire [31:0] group_obs_perf_output_writes;
    wire [31:0] group_obs_perf_jobs;
    wire [31:0] group_obs_perf_stream_beats;
    wire [31:0] group_obs_config_read_count;
    wire [31:0] group_obs_config_word_accept_count;
    wire [31:0] group_obs_config_scalar_write_count;
    wire [3:0] group_obs_state;

    wire m11a_layer_select = (current_layer == 8'd1) ||
                             (current_layer == 8'd2);
    wire group_layer_select = (USE_GROUP_SHARED64_DS != 0) &&
                              (desc_op_type == 32'd1);

    reg [31:0] desc_base_latched;
    reg [31:0] layer_num_latched;
    reg done_latched;
    reg error_latched;

    assign cmd_ready = !ctrl_busy;
    assign cmd_fire = cmd_valid && cmd_ready;
    assign ctrl_start = cmd_fire && (cmd_type == CMD_START);
    assign ctrl_layer_num = ctrl_start ? layer_num : layer_num_latched;
    assign group_prefetch_fetch_start =
        (USE_GROUP_SHARED64_DS != 0) && group_layer_select && ctrl_busy &&
        (group_obs_state == 4'd6) &&
        !group_prefetch_desc_issued &&
        (({24'd0,current_layer} + 32'd1) < ctrl_layer_num);

    cnn_top_ctrl u_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .start(ctrl_start),
        .layer_num(ctrl_layer_num),
        .desc_valid(desc_valid),
        .desc_op_type(desc_op_type),
        .layer_done(layer_done),
        .layer_error(layer_error),
        .busy(ctrl_busy),
        .done(ctrl_done),
        .error(ctrl_error),
        .current_layer(current_layer),
        .fetch_start(fetch_start),
        .fetch_layer_index(fetch_layer_index),
        .layer_start(layer_start)
    );

    descriptor_fetch u_descriptor_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .start(fetch_start),
        .desc_base_addr(desc_base_latched),
        .layer_index(fetch_layer_index),
        .busy(desc_busy),
        .valid(desc_valid),
        .desc_words(desc_words),
        .op_type(desc_op_type),
        .mem_req_valid(desc_mem_req_valid),
        .mem_req_write(desc_mem_req_write),
        .mem_req_addr(desc_mem_req_addr),
        .mem_req_wdata(desc_mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(desc_bus_active ? mem_resp_valid : 1'b0),
        .mem_resp_rdata(mem_resp_rdata)
    );

    descriptor_fetch u_group_prefetch_descriptor_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .start(group_prefetch_fetch_start),
        .desc_base_addr(desc_base_latched),
        .layer_index({24'd0,current_layer} + 32'd1),
        .busy(group_prefetch_desc_busy),
        .valid(group_prefetch_desc_valid),
        .desc_words(group_prefetch_desc_words),
        .op_type(),
        .mem_req_valid(group_prefetch_mem_req_valid),
        .mem_req_write(group_prefetch_mem_req_write),
        .mem_req_addr(group_prefetch_mem_req_addr),
        .mem_req_wdata(group_prefetch_mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid((!desc_bus_active && group_prefetch_desc_busy) ?
                        mem_resp_valid : 1'b0),
        .mem_resp_rdata(mem_resp_rdata)
    );

    cnn_layer_runner #(
        .USE_UNIFIED64_DS(USE_UNIFIED64_DS),
        .USE_UNIFIED64_STEM(USE_UNIFIED64_STEM),
        .USE_SHARED_UNIFIED64(USE_SHARED_UNIFIED64),
        .USE_PERSISTENT_DS(USE_PERSISTENT_DS),
        .USE_DS1_RETAINED_ORCHESTRATOR(USE_DS1_RETAINED_ORCHESTRATOR),
        .USE_RETAINED_ONLY_DS(USE_RETAINED_ONLY_DS),
        .USE_GROUP_SHARED64_DS(USE_GROUP_SHARED64_DS)
    ) u_layer_runner (
        .clk(clk),
        .rst_n(rst_n),
        .start(layer_start && (!USE_M11A_DS1 || !m11a_layer_select) &&
               !group_layer_select),
        .desc_words(desc_words),
        .busy(legacy_layer_busy),
        .done(legacy_layer_done),
        .error(legacy_layer_error),
        .mem_req_valid(legacy_layer_mem_req_valid),
        .mem_req_write(legacy_layer_mem_req_write),
        .mem_req_addr(legacy_layer_mem_req_addr),
        .mem_req_wdata(legacy_layer_mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid((desc_bus_active || legacy_mem_resp_block_q ||
                         (USE_M11A_DS1 && m11a_layer_select) ||
                         group_layer_select) ?
                        1'b0 : mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata),
        .sram_input_rd_en(legacy_sram_input_rd_en),
        .sram_input_rd_addr(legacy_sram_input_rd_addr),
        .sram_input_rd_valid(legacy_sram_input_rd_valid),
        .sram_input_rd_data(legacy_sram_input_rd_data),
        .sram_input_rd_word_en(legacy_sram_input_rd_word_en),
        .sram_input_rd_word_addr(legacy_sram_input_rd_word_addr),
        .sram_input_rd_word_valid(legacy_sram_input_rd_word_valid),
        .sram_input_rd_word_data(legacy_sram_input_rd_word_data),
        .sram_output_wr_en(legacy_sram_output_wr_en),
        .sram_output_wr_addr(legacy_sram_output_wr_addr),
        .sram_output_wr_data(legacy_sram_output_wr_data),
        .sram_output_wr4_en(legacy_sram_output_wr4_en),
        .sram_output_wr4_addr(legacy_sram_output_wr4_addr),
        .sram_output_wr4_data(legacy_sram_output_wr4_data),
        .sram_output_wr4_be(legacy_sram_output_wr4_be)
    );

    generate
        if (USE_M11A_DS1 != 0) begin : gen_m11a_ds1_runner
            m11a_runner_adapter #(
                .SRAM_ADDR_WIDTH(15)
            ) u_m11a_runner_adapter (
                .clk(clk),
                .rst_n(rst_n),
                .start(layer_start && m11a_layer_select),
                .desc_layer(current_layer[1:0]),
                .desc_words(desc_words),
                .busy(m11a_layer_busy),
                .done(m11a_layer_done),
                .error(m11a_layer_error),
                .mem_req_valid(m11a_layer_mem_req_valid),
                .mem_req_write(m11a_layer_mem_req_write),
                .mem_req_addr(m11a_layer_mem_req_addr),
                .mem_req_wdata(m11a_layer_mem_req_wdata),
                .mem_req_ready(mem_req_ready),
                .mem_resp_valid((!desc_bus_active &&
                                 !legacy_mem_resp_block_q &&
                                 m11a_layer_select) ?
                                mem_resp_valid : 1'b0),
                .mem_resp_rdata(mem_resp_rdata),
                .sram_input_rd_en(m11a_sram_input_rd_en),
                .sram_input_rd_addr(m11a_sram_input_rd_addr),
                .sram_input_rd_valid(m11a_sram_input_rd_valid),
                .sram_input_rd_data(m11a_sram_input_rd_data),
                .sram_input_rd_word_en(m11a_sram_input_rd_word_en),
                .sram_input_rd_word_addr(m11a_sram_input_rd_word_addr),
                .sram_input_rd_word_valid(m11a_sram_input_rd_word_valid),
                .sram_input_rd_word_data(m11a_sram_input_rd_word_data),
                .sram_output_wr_en(m11a_sram_output_wr_en),
                .sram_output_wr_addr(m11a_sram_output_wr_addr),
                .sram_output_wr_data(m11a_sram_output_wr_data),
                .sram_output_wr4_en(m11a_sram_output_wr4_en),
                .sram_output_wr4_addr(m11a_sram_output_wr4_addr),
                .sram_output_wr4_data(m11a_sram_output_wr4_data),
                .sram_output_wr4_be(m11a_sram_output_wr4_be)
            );
        end
    endgenerate

    generate
        if (USE_M11A_DS1 != 0) begin : gen_m11a_observability
            assign m11a_obs_loaded_ds1 =
                gen_m11a_ds1_runner.u_m11a_runner_adapter.u_m11a_core.cfg_store.loaded_ds1;
            assign m11a_obs_loaded_ds2 =
                gen_m11a_ds1_runner.u_m11a_runner_adapter.u_m11a_core.cfg_store.loaded_ds2;
            assign m11a_obs_cfg_count_ds1 =
                gen_m11a_ds1_runner.u_m11a_runner_adapter.u_m11a_core.cfg_store.cfg_count_ds1;
            assign m11a_obs_cfg_count_ds2 =
                gen_m11a_ds1_runner.u_m11a_runner_adapter.u_m11a_core.cfg_store.cfg_count_ds2;
            assign m11a_obs_state =
                gen_m11a_ds1_runner.u_m11a_runner_adapter.state;
            assign m11a_obs_core_cfg_commit_ready =
                gen_m11a_ds1_runner.u_m11a_runner_adapter.core_cfg_commit_ready;
            assign m11a_obs_dw_mac_count =
                gen_m11a_ds1_runner.u_m11a_runner_adapter.u_m11a_core.dw_mac_count;
            assign m11a_obs_pw_mac_count =
                gen_m11a_ds1_runner.u_m11a_runner_adapter.u_m11a_core.pw_mac_count;
        end else begin : gen_no_m11a_observability
            assign m11a_obs_loaded_ds1 = 1'b0;
            assign m11a_obs_loaded_ds2 = 1'b0;
            assign m11a_obs_cfg_count_ds1 = 10'd0;
            assign m11a_obs_cfg_count_ds2 = 10'd0;
            assign m11a_obs_state = 4'd0;
            assign m11a_obs_core_cfg_commit_ready = 1'b0;
            assign m11a_obs_dw_mac_count = 32'd0;
            assign m11a_obs_pw_mac_count = 32'd0;
        end
    endgenerate

    generate
        if (USE_GROUP_SHARED64_DS != 0) begin : gen_group_shared64_ds_runner
            ds_group_published_shared64_top_adapter #(
                .ADDR_WIDTH(24),
                .SRAM_ADDR_WIDTH(15),
                .MAX_CIN(128),
                .MAX_COUT(256),
                .FIFO_DEPTH(8)
            ) u_group_shared64_runner_adapter (
                .clk(clk),
                .rst_n(rst_n),
                .start(layer_start && group_layer_select),
                .desc_layer(current_layer),
                .desc_words(desc_words),
                .prefetch_valid(group_prefetch_desc_valid),
                .prefetch_layer(current_layer + 8'd1),
                .prefetch_desc_words(group_prefetch_desc_words),
                .prefetch_busy(group_prefetch_bus_active),
                .busy(group_layer_busy),
                .done(group_layer_done),
                .error(group_layer_error),
                .mem_req_valid(group_layer_mem_req_valid),
                .mem_req_write(group_layer_mem_req_write),
                .mem_req_addr(group_layer_mem_req_addr),
                .mem_req_wdata(group_layer_mem_req_wdata),
                /* A descriptor fetch may begin at the same edge that a
                 * prefetched configuration image is still waiting for its
                 * response.  The group adapter must see ready only when its
                 * request actually owns the shared external bus; otherwise
                 * it would retire PREF_REQ behind the descriptor request and
                 * consume the descriptor response as configuration data. */
                .mem_req_ready((!desc_bus_active &&
                                !group_prefetch_bus_active) ?
                               mem_req_ready : 1'b0),
                .mem_resp_valid((!desc_bus_active &&
                                 !group_prefetch_bus_active &&
                                 group_layer_select) ?
                                mem_resp_valid : 1'b0),
                .mem_resp_rdata(mem_resp_rdata),
                .sram_input_rd_en(group_sram_input_rd_en),
                .sram_input_rd_addr(group_sram_input_rd_addr),
                .sram_input_rd_valid(group_sram_input_rd_valid),
                .sram_input_rd_data(group_sram_input_rd_data),
                .sram_input_rd_word_en(group_sram_input_rd_word_en),
                .sram_input_rd_word_addr(group_sram_input_rd_word_addr),
                .sram_input_rd_word_valid(group_sram_input_rd_word_valid),
                .sram_input_rd_word_data(group_sram_input_rd_word_data),
                .sram_output_wr_en(group_sram_output_wr_en),
                .sram_output_wr_addr(group_sram_output_wr_addr),
                .sram_output_wr_data(group_sram_output_wr_data),
                .sram_output_wr4_en(group_sram_output_wr4_en),
                .sram_output_wr4_addr(group_sram_output_wr4_addr),
                .sram_output_wr4_data(group_sram_output_wr4_data),
                .sram_output_wr4_be(group_sram_output_wr4_be),
                .sram_output_wr_ready(1'b1),
                .sram_output_wr_bank(feature_output_bank_sel),
                .perf_cycles(group_obs_perf_cycles),
                .perf_dw_writes(group_obs_perf_dw_writes),
                .perf_descriptors(group_obs_perf_descriptors),
                .perf_pw_tokens(group_obs_perf_pw_tokens),
                .perf_output_writes(group_obs_perf_output_writes),
                .perf_jobs(group_obs_perf_jobs),
                .perf_stream_beats(group_obs_perf_stream_beats),
                .config_read_count(group_obs_config_read_count),
                .config_word_accept_count(group_obs_config_word_accept_count),
                .config_scalar_write_count(group_obs_config_scalar_write_count),
                .profile_state(group_obs_state)
            );
        end else begin : gen_no_group_shared64_ds_runner
            assign group_layer_busy = 1'b0;
            assign group_layer_done = 1'b0;
            assign group_layer_error = 1'b0;
            assign group_layer_mem_req_valid = 1'b0;
            assign group_layer_mem_req_write = 1'b0;
            assign group_layer_mem_req_addr = 32'd0;
            assign group_layer_mem_req_wdata = 32'd0;
            assign group_sram_input_rd_en = 1'b0;
            assign group_sram_input_rd_addr = 15'd0;
            assign group_sram_input_rd_word_en = 1'b0;
            assign group_sram_input_rd_word_addr = 15'd0;
            assign group_sram_output_wr_en = 1'b0;
            assign group_sram_output_wr_addr = 15'd0;
            assign group_sram_output_wr_data = 8'sd0;
            assign group_sram_output_wr4_en = 1'b0;
            assign group_sram_output_wr4_addr = 15'd0;
            assign group_sram_output_wr4_data = 32'd0;
            assign group_sram_output_wr4_be = 4'd0;
            assign group_obs_perf_cycles = 32'd0;
            assign group_obs_perf_dw_writes = 32'd0;
            assign group_obs_perf_descriptors = 32'd0;
            assign group_obs_perf_pw_tokens = 32'd0;
            assign group_obs_perf_output_writes = 32'd0;
            assign group_obs_perf_jobs = 32'd0;
            assign group_obs_perf_stream_beats = 32'd0;
            assign group_obs_config_read_count = 32'd0;
            assign group_obs_config_word_accept_count = 32'd0;
            assign group_obs_config_scalar_write_count = 32'd0;
            assign group_obs_state = 4'd0;
        end
    endgenerate

    generate
        if (USE_GROUP_SHARED64_DS != 0) begin : gen_group_shared64_runner_mux
            assign layer_busy = group_layer_select ? group_layer_busy :
                                legacy_layer_busy;
            assign layer_done = group_layer_select ? group_layer_done :
                                legacy_layer_done;
            assign layer_error = group_layer_select ? group_layer_error :
                                 legacy_layer_error;
            assign layer_mem_req_valid = group_layer_select ?
                                         group_layer_mem_req_valid :
                                         legacy_layer_mem_req_valid;
            assign layer_mem_req_write = group_layer_select ?
                                         group_layer_mem_req_write :
                                         legacy_layer_mem_req_write;
            assign layer_mem_req_addr = group_layer_select ?
                                        group_layer_mem_req_addr :
                                        legacy_layer_mem_req_addr;
            assign layer_mem_req_wdata = group_layer_select ?
                                         group_layer_mem_req_wdata :
                                         legacy_layer_mem_req_wdata;
            assign layer_sram_input_rd_en = group_layer_select ?
                                            group_sram_input_rd_en :
                                            legacy_sram_input_rd_en;
            assign layer_sram_input_rd_addr = group_layer_select ?
                                              group_sram_input_rd_addr :
                                              legacy_sram_input_rd_addr;
            assign layer_sram_input_rd_word_en = group_layer_select ?
                                                 group_sram_input_rd_word_en :
                                                 legacy_sram_input_rd_word_en;
            assign layer_sram_input_rd_word_addr = group_layer_select ?
                                                   group_sram_input_rd_word_addr :
                                                   legacy_sram_input_rd_word_addr;
            assign layer_sram_output_wr_en = group_layer_select ?
                                             group_sram_output_wr_en :
                                             legacy_sram_output_wr_en;
            assign layer_sram_output_wr_addr = group_layer_select ?
                                               group_sram_output_wr_addr :
                                               legacy_sram_output_wr_addr;
            assign layer_sram_output_wr_data = group_layer_select ?
                                               group_sram_output_wr_data :
                                               legacy_sram_output_wr_data;
            assign layer_sram_output_wr4_en = group_layer_select ?
                                              group_sram_output_wr4_en :
                                              legacy_sram_output_wr4_en;
            assign layer_sram_output_wr4_addr = group_layer_select ?
                                                group_sram_output_wr4_addr :
                                                legacy_sram_output_wr4_addr;
            assign layer_sram_output_wr4_data = group_layer_select ?
                                                group_sram_output_wr4_data :
                                                legacy_sram_output_wr4_data;
            assign layer_sram_output_wr4_be = group_layer_select ?
                                              group_sram_output_wr4_be :
                                              legacy_sram_output_wr4_be;
        end else if (USE_M11A_DS1 != 0) begin : gen_m11a_runner_mux
            assign layer_busy = m11a_layer_select ? m11a_layer_busy :
                                legacy_layer_busy;
            assign layer_done = m11a_layer_select ? m11a_layer_done :
                                legacy_layer_done;
            assign layer_error = m11a_layer_select ? m11a_layer_error :
                                 legacy_layer_error;
            assign layer_mem_req_valid = m11a_layer_select ?
                                         m11a_layer_mem_req_valid :
                                         legacy_layer_mem_req_valid;
            assign layer_mem_req_write = m11a_layer_select ?
                                         m11a_layer_mem_req_write :
                                         legacy_layer_mem_req_write;
            assign layer_mem_req_addr = m11a_layer_select ?
                                        m11a_layer_mem_req_addr :
                                        legacy_layer_mem_req_addr;
            assign layer_mem_req_wdata = m11a_layer_select ?
                                         m11a_layer_mem_req_wdata :
                                         legacy_layer_mem_req_wdata;
            assign layer_sram_input_rd_en = m11a_layer_select ?
                                            m11a_sram_input_rd_en :
                                            legacy_sram_input_rd_en;
            assign layer_sram_input_rd_addr = m11a_layer_select ?
                                              m11a_sram_input_rd_addr :
                                              legacy_sram_input_rd_addr;
            assign layer_sram_input_rd_word_en = m11a_layer_select ?
                                                 m11a_sram_input_rd_word_en :
                                                 legacy_sram_input_rd_word_en;
            assign layer_sram_input_rd_word_addr = m11a_layer_select ?
                                                   m11a_sram_input_rd_word_addr :
                                                   legacy_sram_input_rd_word_addr;
            assign layer_sram_output_wr_en = m11a_layer_select ?
                                             m11a_sram_output_wr_en :
                                             legacy_sram_output_wr_en;
            assign layer_sram_output_wr_addr = m11a_layer_select ?
                                               m11a_sram_output_wr_addr :
                                               legacy_sram_output_wr_addr;
            assign layer_sram_output_wr_data = m11a_layer_select ?
                                               m11a_sram_output_wr_data :
                                               legacy_sram_output_wr_data;
            assign layer_sram_output_wr4_en = m11a_layer_select ?
                                              m11a_sram_output_wr4_en :
                                              legacy_sram_output_wr4_en;
            assign layer_sram_output_wr4_addr = m11a_layer_select ?
                                                m11a_sram_output_wr4_addr :
                                                legacy_sram_output_wr4_addr;
            assign layer_sram_output_wr4_data = m11a_layer_select ?
                                                m11a_sram_output_wr4_data :
                                                legacy_sram_output_wr4_data;
            assign layer_sram_output_wr4_be = m11a_layer_select ?
                                              m11a_sram_output_wr4_be :
                                              legacy_sram_output_wr4_be;
        end else begin : gen_legacy_runner_mux
            assign layer_busy = legacy_layer_busy;
            assign layer_done = legacy_layer_done;
            assign layer_error = legacy_layer_error;
            assign layer_mem_req_valid = legacy_layer_mem_req_valid;
            assign layer_mem_req_write = legacy_layer_mem_req_write;
            assign layer_mem_req_addr = legacy_layer_mem_req_addr;
            assign layer_mem_req_wdata = legacy_layer_mem_req_wdata;
            assign layer_sram_input_rd_en = legacy_sram_input_rd_en;
            assign layer_sram_input_rd_addr = legacy_sram_input_rd_addr;
            assign layer_sram_input_rd_word_en = legacy_sram_input_rd_word_en;
            assign layer_sram_input_rd_word_addr = legacy_sram_input_rd_word_addr;
            assign layer_sram_output_wr_en = legacy_sram_output_wr_en;
            assign layer_sram_output_wr_addr = legacy_sram_output_wr_addr;
            assign layer_sram_output_wr_data = legacy_sram_output_wr_data;
            assign layer_sram_output_wr4_en = legacy_sram_output_wr4_en;
            assign layer_sram_output_wr4_addr = legacy_sram_output_wr4_addr;
            assign layer_sram_output_wr4_data = legacy_sram_output_wr4_data;
            assign layer_sram_output_wr4_be = legacy_sram_output_wr4_be;
        end
    endgenerate

    feature_sram_pingpong u_feature_sram (
        .clk(clk),
        .rst_n(rst_n),
        .reset_to_a(ctrl_start),
        .layer_done(layer_done && desc_sram_swap_on_done),
        .input_bank_sel(feature_input_bank_sel),
        .output_bank_sel(feature_output_bank_sel),
        .input_rd_en(layer_sram_input_rd_en),
        .input_rd_addr(layer_sram_input_rd_addr),
        .input_rd_valid(layer_sram_input_rd_valid),
        .input_rd_data(layer_sram_input_rd_data),
        .input_rd_word_en(layer_sram_input_rd_word_en),
        .input_rd_word_addr(layer_sram_input_rd_word_addr),
        .input_rd_word_valid(layer_sram_input_rd_word_valid),
        .input_rd_word_data(layer_sram_input_rd_word_data),
        .output_wr_en(layer_sram_output_wr_en),
        .output_wr_addr(layer_sram_output_wr_addr),
        .output_wr_data(layer_sram_output_wr_data),
        .output_wr_word_en(layer_sram_output_wr4_en),
        .output_wr_word_addr(layer_sram_output_wr4_addr),
        .output_wr_word_data(layer_sram_output_wr4_data),
        .output_wr_word_be(layer_sram_output_wr4_be),
        .host_wr_en(1'b0),
        .host_bank_sel(1'b0),
        .host_addr(15'd0),
        .host_wdata(8'sd0),
        .host_rd_en(1'b0),
        .host_rd_valid(feature_host_rd_valid_unused),
        .host_rdata(feature_host_rdata_unused)
    );

    status_counter u_status_counter (
        .clk(clk),
        .rst_n(rst_n),
        .clear(ctrl_start),
        .enable(ctrl_busy),
        .layer_start(layer_start),
        .layer_idx(current_layer),
        .total_cycles(total_cycles),
        .layer_cycles(layer_cycles),
        .active_layer(counter_layer)
    );

    assign desc_bus_active = desc_busy || fetch_start;
    assign group_prefetch_bus_active = group_prefetch_desc_busy ||
                                       group_prefetch_fetch_start;
    assign desc_sram_swap_on_done = desc_words[(18*32) + 4];
    assign mem_req_valid = desc_bus_active ? desc_mem_req_valid :
                           group_prefetch_bus_active ?
                               group_prefetch_mem_req_valid :
                               layer_mem_req_valid;
    assign mem_req_write = desc_bus_active ? desc_mem_req_write :
                           group_prefetch_bus_active ?
                               group_prefetch_mem_req_write :
                               layer_mem_req_write;
    assign mem_req_addr = desc_bus_active ? desc_mem_req_addr :
                          group_prefetch_bus_active ?
                              group_prefetch_mem_req_addr :
                              layer_mem_req_addr;
    assign mem_req_wdata = desc_bus_active ? desc_mem_req_wdata :
                           group_prefetch_bus_active ?
                               group_prefetch_mem_req_wdata :
                               layer_mem_req_wdata;

    assign status = {
        total_cycles[23:0],
        current_layer[3:0],
        1'b0,
        error_latched || ctrl_error,
        done_latched,
        ctrl_busy
    };

    always @(posedge clk) begin
        if (!rst_n) begin
            desc_base_latched <= 32'd0;
            layer_num_latched <= 32'd0;
            done_latched <= 1'b0;
            error_latched <= 1'b0;
            group_prefetch_desc_issued <= 1'b0;
            legacy_mem_resp_block_q <= 1'b0;
        end else begin
            if (!ctrl_busy || ctrl_start || layer_start)
                group_prefetch_desc_issued <= 1'b0;
            else if (group_prefetch_fetch_start)
                group_prefetch_desc_issued <= 1'b1;
            // Hold the legacy response fence from the accepted prefetch
            // start through the descriptor response.  Clearing from the
            // registered busy indication intentionally leaves one harmless
            // bubble after the final response and avoids any combinational
            // current_layer -> runner enable path.
            if (group_prefetch_fetch_start)
                legacy_mem_resp_block_q <= 1'b1;
            else if (!group_prefetch_desc_busy)
                legacy_mem_resp_block_q <= 1'b0;
            if (cmd_fire) begin
                done_latched <= 1'b0;
                error_latched <= (cmd_type != CMD_START);
                if (cmd_type == CMD_START) begin
                    desc_base_latched <= desc_base_addr;
                    layer_num_latched <= layer_num;
                end
            end

            if (ctrl_done) begin
                done_latched <= 1'b1;
            end
            if (ctrl_error) begin
                error_latched <= 1'b1;
            end

        end
    end

endmodule

`default_nettype wire
