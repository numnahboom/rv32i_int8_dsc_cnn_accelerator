`timescale 1ns/1ps
`default_nettype none

// Real DS1 -> DS2 top for M1.  Exactly one ds12_shared_pw_service instance
// owns the PW MAC/RQ/result path; the two adapters below are DW/token
// producers and the activation/config banks are the only shared memories.
module ds12_shared_pw_two_layer_top (
    input wire clk,
    input wire rst_n,
    input wire start,
    output wire cfg_mem_req_valid,
    input wire cfg_mem_req_ready,
    output wire [31:0] cfg_mem_req_addr,
    output wire [15:0] cfg_mem_req_index,
    output wire [1:0] cfg_mem_req_layer,
    output wire [3:0] cfg_mem_req_strb,
    input wire cfg_mem_resp_valid,
    output wire cfg_mem_resp_ready,
    input wire [31:0] cfg_mem_resp_data,
    output wire input_mem_req_valid,
    input wire input_mem_req_ready,
    output wire input_mem_req_write,
    output wire [31:0] input_mem_req_addr,
    output wire [127:0] input_mem_req_wdata,
    output wire [15:0] input_mem_req_strb,
    output wire [1:0] input_mem_req_context,
    output wire input_mem_req_owner,
    output wire [31:0] input_mem_req_epoch,
    input wire input_mem_resp_valid,
    input wire [127:0] input_mem_resp_data,
    output wire ds1_output_valid,
    input wire ds1_output_ready,
    output wire [31:0] ds1_output_addr,
    output wire [31:0] ds1_output_data,
    output wire [3:0] ds1_output_be,
    output wire ds1_output_last,
    output wire ds2_output_valid,
    input wire ds2_output_ready,
    output wire [31:0] ds2_output_addr,
    output wire [31:0] ds2_output_data,
    output wire [3:0] ds2_output_be,
    output wire ds2_output_last,
    output wire ds1_done,
    output wire ds2_done,
    output wire done,
    output wire error,
    output wire [7:0] error_code,
    output wire [31:0] cycle_count,
    output wire [31:0] ds1_dw_mac_count,
    output wire [31:0] ds1_pw_mac_count,
    output wire [31:0] ds1_output_word_count,
    output wire [31:0] ds2_dw_mac_count,
    output wire [31:0] ds2_pw_mac_count,
    output wire [31:0] ds2_output_word_count,
    output wire atomic_swap
);
    wire cfg_start_valid, cfg_start_ready;
    wire [1:0] cfg_start_layer;
    wire [15:0] cfg_start_count;
    wire [31:0] cfg_start_base;
    wire cfg_load_done;
    wire cfg_busy, cfg_error;
    wire cfg_word_valid, cfg_word_ready;
    wire [1:0] cfg_word_layer;
    wire [9:0] cfg_word_index;
    wire [31:0] cfg_word_data;

    ds12_shared_pw_config_port #(.DS1_BASE(32'd0), .DS2_BASE(32'd168)) cfg_port (
        .clk(clk), .rst_n(rst_n), .start(cfg_start_valid),
        .start_layer(cfg_start_layer), .start_word_count(cfg_start_count),
        .start_base_addr(cfg_start_base), .start_ready(cfg_start_ready),
        .mem_req_valid(cfg_mem_req_valid), .mem_req_ready(cfg_mem_req_ready),
        .mem_req_addr(cfg_mem_req_addr), .mem_req_index(cfg_mem_req_index),
        .mem_req_layer(cfg_mem_req_layer), .mem_req_strb(cfg_mem_req_strb),
        .mem_resp_valid(cfg_mem_resp_valid), .mem_resp_ready(cfg_mem_resp_ready),
        .mem_resp_data(cfg_mem_resp_data), .word_valid(cfg_word_valid),
        .word_ready(cfg_word_ready), .word_layer(cfg_word_layer),
        .word_index(cfg_word_index), .word_data(cfg_word_data),
        .busy(cfg_busy), .load_done(cfg_load_done), .error(cfg_error)
    );

    wire service_cfg_ready;
    wire d1_cfg_ready, d2_cfg_ready;
    assign cfg_word_ready = service_cfg_ready &&
        (((cfg_word_layer == 2'd1) && (cfg_word_index < 10'd84)) ? d1_cfg_ready :
         ((cfg_word_layer == 2'd2) && (cfg_word_index < 10'd168)) ? d2_cfg_ready : 1'b1);

    wire service_start_valid, service_start_ready;
    wire [1:0] service_start_layer;
    wire service_layer_done;
    wire sched_ds1_start, sched_ds2_start;
    wire sched_ds1_ready, sched_ds2_ready;
    wire sched_ds1_done, sched_ds2_done;
    wire sched_act_start, sched_act_start_ready;
    wire sched_act_commit, sched_act_commit_ready, sched_act_commit_done;
    wire sched_running, sched_done, sched_ds1_active, sched_ds2_active;
    wire [31:0] sched_cycles;

    ds12_shared_pw_scheduler scheduler (
        .clk(clk), .rst_n(rst_n), .start(start),
        .cfg_start_valid(cfg_start_valid), .cfg_start_ready(cfg_start_ready),
        .cfg_start_layer(cfg_start_layer), .cfg_start_count(cfg_start_count),
        .cfg_start_base(cfg_start_base), .cfg_load_done(cfg_load_done),
        .service_start_valid(service_start_valid), .service_start_ready(service_start_ready),
        .service_start_layer(service_start_layer), .service_done(service_layer_done),
        .ds1_start_valid(sched_ds1_start), .ds1_start_ready(sched_ds1_ready),
        .ds1_done(sched_ds1_done), .ds2_start_valid(sched_ds2_start),
        .ds2_start_ready(sched_ds2_ready), .ds2_done(sched_ds2_done),
        .activation_start_valid(sched_act_start), .activation_start_ready(sched_act_start_ready),
        .activation_start_bank(), .activation_start_epoch(),
        .activation_start_words(), .activation_commit_valid(sched_act_commit),
        .activation_commit_ready(sched_act_commit_ready),
        .activation_commit_done(sched_act_commit_done), .running(sched_running),
        .done(sched_done), .ds1_active(sched_ds1_active), .ds2_active(sched_ds2_active),
        .cycle_count(sched_cycles)
    );

    wire d1_token_valid, d1_token_ready;
    wire [1:0] d1_token_layer, d1_token_context;
    wire d1_token_owner;
    wire [31:0] d1_token_epoch;
    wire [2:0] d1_token_tile;
    wire [5:0] d1_token_k;
    wire [63:0] d1_token_activation;
    wire d1_token_last_k, d1_token_last_tile;
    wire d1_weight_query_valid;
    wire [1:0] d1_weight_query_layer;
    wire [2:0] d1_weight_query_tile;
    wire [5:0] d1_weight_query_k;
    wire [63:0] shared_weight_data;
    wire d1_error;

    ds12_shared_pw_ds1_adapter ds1_adapter (
        .clk(clk), .rst_n(rst_n), .cfg_word_valid(cfg_word_valid && cfg_word_layer == 2'd1 && cfg_word_index < 10'd84),
        .cfg_word_ready(d1_cfg_ready), .cfg_word_layer(cfg_word_layer), .cfg_word_index(cfg_word_index),
        .cfg_word_data(cfg_word_data), .start(sched_ds1_start), .ready(sched_ds1_ready), .done(sched_ds1_done),
        .input_mem_req_valid(input_mem_req_valid), .input_mem_req_ready(input_mem_req_ready),
        .input_mem_req_write(input_mem_req_write), .input_mem_req_addr(input_mem_req_addr),
        .input_mem_req_wdata(input_mem_req_wdata), .input_mem_req_strb(input_mem_req_strb),
        .input_mem_req_context(input_mem_req_context), .input_mem_req_owner(input_mem_req_owner),
        .input_mem_req_epoch(input_mem_req_epoch), .input_mem_resp_valid(input_mem_resp_valid),
        .input_mem_resp_data(input_mem_resp_data), .token_valid(d1_token_valid), .token_ready(d1_token_ready),
        .token_layer(d1_token_layer), .token_context(d1_token_context), .token_owner(d1_token_owner),
        .token_epoch(d1_token_epoch), .token_cout_tile(d1_token_tile), .token_k(d1_token_k),
        .token_activation(d1_token_activation), .token_weight(shared_weight_data),
        .token_last_k(d1_token_last_k), .token_last_tile(d1_token_last_tile),
        .weight_query_valid(d1_weight_query_valid), .weight_query_layer(d1_weight_query_layer),
        .weight_query_tile(d1_weight_query_tile), .weight_query_k(d1_weight_query_k),
        .dw_mac_count(ds1_dw_mac_count), .error(d1_error)
    );

    wire d2_token_valid, d2_token_ready;
    wire [1:0] d2_token_layer, d2_token_context;
    wire d2_token_owner;
    wire [31:0] d2_token_epoch;
    wire [2:0] d2_token_tile;
    wire [5:0] d2_token_k;
    wire [63:0] d2_token_activation;
    wire d2_token_last_k, d2_token_last_tile;
    wire d2_weight_query_valid;
    wire [1:0] d2_weight_query_layer;
    wire [2:0] d2_weight_query_tile;
    wire [5:0] d2_weight_query_k;
    wire d2_error;
    wire d2_rd_valid, d2_rd_ready, d2_rd_bank;
    wire [31:0] d2_rd_epoch, d2_rd_addr;
    wire d2_rd_resp_valid, d2_rd_resp_bank;
    wire [127:0] d2_rd_resp_data;
    wire [31:0] d2_rd_resp_epoch, d2_rd_resp_addr;
    wire active_read_bank;
    wire [31:0] active_read_epoch;

    ds12_shared_pw_ds2_adapter ds2_adapter (
        .clk(clk), .rst_n(rst_n), .cfg_word_valid(cfg_word_valid && cfg_word_layer == 2'd2 && cfg_word_index < 10'd168),
        .cfg_word_ready(d2_cfg_ready), .cfg_word_layer(cfg_word_layer), .cfg_word_index(cfg_word_index),
        .cfg_word_data(cfg_word_data), .start(sched_ds2_start), .ready(sched_ds2_ready), .done(sched_ds2_done),
        .active_bank(active_read_bank), .active_epoch(active_read_epoch),
        .activation_rd_valid(d2_rd_valid), .activation_rd_ready(d2_rd_ready), .activation_rd_bank(d2_rd_bank),
        .activation_rd_epoch(d2_rd_epoch), .activation_rd_addr(d2_rd_addr),
        .activation_rd_resp_valid(d2_rd_resp_valid), .activation_rd_resp_data(d2_rd_resp_data),
        .activation_rd_resp_bank(d2_rd_resp_bank), .activation_rd_resp_epoch(d2_rd_resp_epoch),
        .activation_rd_resp_addr(d2_rd_resp_addr), .token_valid(d2_token_valid), .token_ready(d2_token_ready),
        .token_layer(d2_token_layer), .token_context(d2_token_context), .token_owner(d2_token_owner),
        .token_epoch(d2_token_epoch), .token_cout_tile(d2_token_tile), .token_k(d2_token_k),
        .token_activation(d2_token_activation), .token_weight(shared_weight_data),
        .token_last_k(d2_token_last_k), .token_last_tile(d2_token_last_tile),
        .weight_query_valid(d2_weight_query_valid), .weight_query_layer(d2_weight_query_layer),
        .weight_query_tile(d2_weight_query_tile), .weight_query_k(d2_weight_query_k),
        .dw_mac_count(ds2_dw_mac_count), .error(d2_error)
    );

    wire service_token_valid = sched_ds1_active ? d1_token_valid :
                               (sched_ds2_active ? d2_token_valid : 1'b0);
    wire service_token_ready;
    wire [1:0] service_token_layer = sched_ds1_active ? d1_token_layer : d2_token_layer;
    wire [1:0] service_token_context = sched_ds1_active ? d1_token_context : d2_token_context;
    wire service_token_owner = sched_ds1_active ? d1_token_owner : d2_token_owner;
    wire [31:0] service_token_epoch = sched_ds1_active ? d1_token_epoch : d2_token_epoch;
    wire [2:0] service_token_tile = sched_ds1_active ? d1_token_tile : d2_token_tile;
    wire [5:0] service_token_k = sched_ds1_active ? d1_token_k : d2_token_k;
    wire [63:0] service_token_activation = sched_ds1_active ? d1_token_activation : d2_token_activation;
    wire service_token_last_k = sched_ds1_active ? d1_token_last_k : d2_token_last_k;
    wire service_token_last_tile = sched_ds1_active ? d1_token_last_tile : d2_token_last_tile;
    assign d1_token_ready = sched_ds1_active && service_token_ready;
    assign d2_token_ready = sched_ds2_active && service_token_ready;

    wire service_weight_query_valid = d1_weight_query_valid || d2_weight_query_valid;
    wire [1:0] service_weight_query_layer = d1_weight_query_valid ? d1_weight_query_layer : d2_weight_query_layer;
    wire [2:0] service_weight_query_tile = d1_weight_query_valid ? d1_weight_query_tile : d2_weight_query_tile;
    wire [5:0] service_weight_query_k = d1_weight_query_valid ? d1_weight_query_k : d2_weight_query_k;
    wire service_error;
    wire [7:0] service_error_code;
    wire service_cfg_word_ready;
    wire service_sink_valid;
    wire service_sink_ready;
    wire service_sink_layer;
    wire [31:0] service_sink_addr, service_sink_data;
    wire [3:0] service_sink_be;
    wire service_sink_last;
    wire [31:0] service_ds1_pw_tokens, service_ds2_pw_tokens;
    wire [31:0] service_ds1_pw_macs, service_ds2_pw_macs;
    wire [31:0] service_ds1_out_words, service_ds2_out_words;

    ds12_shared_pw_service service (
        .clk(clk), .rst_n(rst_n), .cfg_word_valid(cfg_word_valid), .cfg_word_ready(service_cfg_word_ready),
        .cfg_word_layer(cfg_word_layer), .cfg_word_index(cfg_word_index), .cfg_word_data(cfg_word_data),
        .layer_start_valid(service_start_valid), .layer_start_ready(service_start_ready),
        .layer_start_layer(service_start_layer), .layer_done(service_layer_done),
        .token_valid(service_token_valid), .token_ready(service_token_ready), .token_layer(service_token_layer),
        .token_context(service_token_context), .token_owner(service_token_owner), .token_epoch(service_token_epoch),
        .token_cout_tile(service_token_tile), .token_k(service_token_k), .token_activation(service_token_activation),
        .token_weight(shared_weight_data), .token_last_k(service_token_last_k), .token_last_tile(service_token_last_tile),
        .weight_query_valid(service_weight_query_valid), .weight_query_layer(service_weight_query_layer),
        .weight_query_tile(service_weight_query_tile), .weight_query_k(service_weight_query_k),
        .weight_query_data(shared_weight_data), .sink_valid(service_sink_valid), .sink_ready(service_sink_ready),
        .sink_layer(service_sink_layer), .sink_addr(service_sink_addr), .sink_data(service_sink_data),
        .sink_be(service_sink_be), .sink_last(service_sink_last), .error(service_error),
        .error_code(service_error_code), .pw_token_count(), .pw_mac_count(),
        .output_word_count(), .ds1_pw_token_count(service_ds1_pw_tokens), .ds2_pw_token_count(service_ds2_pw_tokens),
        .ds1_pw_mac_count(service_ds1_pw_macs), .ds2_pw_mac_count(service_ds2_pw_macs),
        .ds1_output_word_count(service_ds1_out_words), .ds2_output_word_count(service_ds2_out_words)
    );

    assign service_cfg_ready = service_cfg_word_ready;
    assign ds1_pw_mac_count = service_ds1_pw_macs;
    assign ds2_pw_mac_count = service_ds2_pw_macs;
    assign ds1_output_word_count = service_ds1_out_words;
    assign ds2_output_word_count = service_ds2_out_words;

    // The DS1 sink is accepted only when both the external sink and the
    // vector activation bank accept the same word.  This makes the bank
    // commit fence exact under arbitrary output backpressure.
    wire store_write_ready;
    wire store_write_valid = service_sink_valid && !service_sink_layer &&
                             ds1_output_ready && store_write_ready;
    assign service_sink_ready = service_sink_layer ? ds2_output_ready :
                                (ds1_output_ready && store_write_ready);
    assign ds1_output_valid = service_sink_valid && !service_sink_layer;
    assign ds1_output_addr = service_sink_addr;
    assign ds1_output_data = service_sink_data;
    assign ds1_output_be = service_sink_be;
    assign ds1_output_last = service_sink_last && !service_sink_layer;
    assign ds2_output_valid = service_sink_valid && service_sink_layer;
    assign ds2_output_addr = service_sink_addr;
    assign ds2_output_data = service_sink_data;
    assign ds2_output_be = service_sink_be;
    assign ds2_output_last = service_sink_last && service_sink_layer;

    wire store_error;
    wire [7:0] store_error_code;
    ds12_stream_dual_vector_activation_store #(.LINE_WORDS(2048)) activation_store (
        .clk(clk), .rst_n(rst_n), .layer_start_valid(sched_act_start),
        .layer_start_ready(sched_act_start_ready), .layer_start_bank(1'b1),
        .layer_start_epoch(32'd1), .layer_start_expected_words(32'd8192),
        .write_valid(store_write_valid), .write_ready(store_write_ready),
        .write_bank(1'b1), .write_epoch(32'd1),
        .write_addr(service_sink_addr - 32'h0010_0000), .write_data(service_sink_data),
        .write_be(service_sink_be), .write_last(service_sink_last),
        .write_resp_valid(), .write_resp_ready(1'b1), .write_resp_bank(),
        .write_resp_epoch(), .write_resp_addr(), .layer_end_valid(sched_act_commit),
        .layer_end_ready(sched_act_commit_ready), .layer_end_bank(1'b1),
        .layer_end_epoch(32'd1), .commit_valid(1'b0), .commit_ready(),
        .commit_bank(1'b0), .commit_epoch(0), .commit_done(sched_act_commit_done),
        .layer_end_done(), .atomic_swap(atomic_swap), .read_req_valid(d2_rd_valid),
        .read_req_ready(d2_rd_ready), .read_req_bank(d2_rd_bank), .read_req_epoch(d2_rd_epoch),
        .read_req_addr(d2_rd_addr), .read_resp_valid(d2_rd_resp_valid), .read_resp_ready(1'b1),
        .read_resp_data(d2_rd_resp_data), .read_resp_bank(d2_rd_resp_bank),
        .read_resp_epoch(d2_rd_resp_epoch), .read_resp_addr(d2_rd_resp_addr),
        .bank0_state(), .bank1_state(), .bank0_epoch(), .bank1_epoch(),
        .active_read_bank(active_read_bank), .active_read_epoch(active_read_epoch),
        .active_write(), .active_write_bank(), .write_epoch_active(), .write_count(),
        .write_expected_words(), .write_last_seen(), .error(store_error), .error_code(store_error_code)
    );

    assign ds1_done = sched_ds1_done;
    assign ds2_done = sched_ds2_done;
    assign done = sched_done;
    assign cycle_count = sched_cycles;
    assign error = cfg_error | service_error | d1_error | d2_error | store_error;
    assign error_code = cfg_error ? 8'h01 :
                        service_error ? service_error_code :
                        d1_error ? 8'h11 : d2_error ? 8'h22 : store_error_code;
endmodule

// Friendly alternate top name used by the M1 scripts and structural audit.
module ds12_stream_pure_two_layer_shared_top (
    input wire clk, input wire rst_n, input wire start,
    output wire cfg_mem_req_valid, input wire cfg_mem_req_ready,
    output wire [31:0] cfg_mem_req_addr, output wire [15:0] cfg_mem_req_index,
    output wire [1:0] cfg_mem_req_layer, output wire [3:0] cfg_mem_req_strb,
    input wire cfg_mem_resp_valid, output wire cfg_mem_resp_ready, input wire [31:0] cfg_mem_resp_data,
    output wire input_mem_req_valid, input wire input_mem_req_ready, output wire input_mem_req_write,
    output wire [31:0] input_mem_req_addr, output wire [127:0] input_mem_req_wdata,
    output wire [15:0] input_mem_req_strb, output wire [1:0] input_mem_req_context,
    output wire input_mem_req_owner, output wire [31:0] input_mem_req_epoch,
    input wire input_mem_resp_valid, input wire [127:0] input_mem_resp_data,
    output wire ds1_output_valid, input wire ds1_output_ready, output wire [31:0] ds1_output_addr,
    output wire [31:0] ds1_output_data, output wire [3:0] ds1_output_be, output wire ds1_output_last,
    output wire ds2_output_valid, input wire ds2_output_ready, output wire [31:0] ds2_output_addr,
    output wire [31:0] ds2_output_data, output wire [3:0] ds2_output_be, output wire ds2_output_last,
    output wire ds1_done, output wire ds2_done, output wire done, output wire error,
    output wire [7:0] error_code, output wire [31:0] cycle_count,
    output wire [31:0] ds1_dw_mac_count, output wire [31:0] ds1_pw_mac_count,
    output wire [31:0] ds1_output_word_count, output wire [31:0] ds2_dw_mac_count,
    output wire [31:0] ds2_pw_mac_count, output wire [31:0] ds2_output_word_count,
    output wire atomic_swap
);
    ds12_shared_pw_two_layer_top u_shared (.*);
endmodule

`default_nettype wire
