`timescale 1ns/1ps
`default_nettype none

// DS12 fallback integration shell.
//
// This name is intentionally separate from the original layer controller so
// that a system can select the vector-bank implementation without changing
// the default runner or the retained DS1 path.  The existing DS1 controller
// already owns the verified transaction sequencing (308-word DS1 load,
// overlapped 872-word DS2 preload, and the final drain/commit fence); this
// shell exposes that contract under the fallback integration name.
module ds12_stream_ds1_vector_bank_layer #(
    parameter integer INPUT_BASE = 0,
    parameter integer SINK_BASE = 32'h00100000
) (
    input wire clk, input wire rst_n, input wire start,
    output wire cfg_mem_req_valid, input wire cfg_mem_req_ready,
    output wire [31:0] cfg_mem_req_addr, output wire [3:0] cfg_mem_req_strb,
    output wire [1:0] cfg_mem_req_layer, output wire [15:0] cfg_mem_req_word_index,
    input wire cfg_mem_resp_valid, input wire [31:0] cfg_mem_resp_data,
    output wire input_mem_req_valid, input wire input_mem_req_ready,
    output wire input_mem_req_write, output wire [31:0] input_mem_req_addr,
    output wire [127:0] input_mem_req_wdata, output wire [15:0] input_mem_req_strb,
    output wire [1:0] input_mem_req_context, output wire input_mem_req_owner,
    output wire [31:0] input_mem_req_epoch,
    input wire input_mem_resp_valid, input wire [127:0] input_mem_resp_data,
    output wire output_write_valid, input wire output_ready,
    output wire output_write_bank, output wire [31:0] output_write_epoch,
    output wire [31:0] output_write_addr, output wire [31:0] output_write_data,
    output wire [3:0] output_write_be, output wire output_write_last,
    output wire layer_done, output wire error,
    output wire ds1_config_done, output wire ds2_preload_done,
    output wire [31:0] cycle_count, output wire [31:0] dw_first_cycle,
    output wire [31:0] dw_last_cycle, output wire [31:0] pw_first_cycle,
    output wire [31:0] pw_last_cycle, output wire [31:0] overlap_cycles,
    output wire [31:0] dw_idle_cycles, output wire [31:0] pw_idle_cycles,
    output wire [31:0] dw_mac_count, output wire [31:0] pw_mac_count,
    output wire [31:0] output_word_count, output wire [31:0] config_read_count,
    output wire [31:0] config_write_count, output wire [1:0] active_config_layer,
    output wire [31:0] active_config_epoch, output wire active_config_bank,
    output wire [1:0] activation_bank0_state, output wire [1:0] activation_bank1_state,
    output wire [31:0] activation_write_count, output wire activation_commit_done,
    output wire [31:0] activation_write_expected_bytes, output wire activation_write_last_seen,
    output wire [31:0] ds1_input_read_count, output wire [31:0] ds1_dw_vector_count
);
    ds12_stream_ds1_layer #(.INPUT_BASE(INPUT_BASE), .SINK_BASE(SINK_BASE)) impl (
        .clk(clk), .rst_n(rst_n), .start(start),
        .cfg_mem_req_valid(cfg_mem_req_valid), .cfg_mem_req_ready(cfg_mem_req_ready),
        .cfg_mem_req_addr(cfg_mem_req_addr), .cfg_mem_req_strb(cfg_mem_req_strb),
        .cfg_mem_req_layer(cfg_mem_req_layer), .cfg_mem_req_word_index(cfg_mem_req_word_index),
        .cfg_mem_resp_valid(cfg_mem_resp_valid), .cfg_mem_resp_data(cfg_mem_resp_data),
        .input_mem_req_valid(input_mem_req_valid), .input_mem_req_ready(input_mem_req_ready),
        .input_mem_req_write(input_mem_req_write), .input_mem_req_addr(input_mem_req_addr),
        .input_mem_req_wdata(input_mem_req_wdata), .input_mem_req_strb(input_mem_req_strb),
        .input_mem_req_context(input_mem_req_context), .input_mem_req_owner(input_mem_req_owner),
        .input_mem_req_epoch(input_mem_req_epoch), .input_mem_resp_valid(input_mem_resp_valid),
        .input_mem_resp_data(input_mem_resp_data), .output_write_valid(output_write_valid),
        .output_ready(output_ready), .output_write_bank(output_write_bank),
        .output_write_epoch(output_write_epoch), .output_write_addr(output_write_addr),
        .output_write_data(output_write_data), .output_write_be(output_write_be),
        .output_write_last(output_write_last), .layer_done(layer_done), .error(error),
        .ds1_config_done(ds1_config_done), .ds2_preload_done(ds2_preload_done),
        .cycle_count(cycle_count), .dw_first_cycle(dw_first_cycle), .dw_last_cycle(dw_last_cycle),
        .pw_first_cycle(pw_first_cycle), .pw_last_cycle(pw_last_cycle),
        .overlap_cycles(overlap_cycles), .dw_idle_cycles(dw_idle_cycles), .pw_idle_cycles(pw_idle_cycles),
        .dw_mac_count(dw_mac_count), .pw_mac_count(pw_mac_count), .output_word_count(output_word_count),
        .config_read_count(config_read_count), .config_write_count(config_write_count),
        .active_config_layer(active_config_layer), .active_config_epoch(active_config_epoch),
        .active_config_bank(active_config_bank), .activation_bank0_state(activation_bank0_state),
        .activation_bank1_state(activation_bank1_state), .activation_write_count(activation_write_count),
        .activation_commit_done(activation_commit_done),
        .activation_write_expected_bytes(activation_write_expected_bytes),
        .activation_write_last_seen(activation_write_last_seen), .ds1_input_read_count(ds1_input_read_count),
        .ds1_dw_vector_count(ds1_dw_vector_count)
    );
endmodule

`default_nettype wire
