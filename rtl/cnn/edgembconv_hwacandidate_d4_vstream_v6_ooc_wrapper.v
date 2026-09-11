`timescale 1ns/1ps
`default_nettype none

/*
 * Standalone OOC shell for the v6 mb16_down candidate.
 *
 * The complete candidate interface is kept at the OOC boundary so Vivado
 * cannot constant-fold away the cfg/start, arithmetic, or sink service while
 * screening the implementation.  This shell is physical-screening only;
 * it is not a production runner and is not instantiated by cnn_top.
 */
module edgembconv_hwacandidate_d4_vstream_v6_ooc_wrapper (
    input wire clk,
    input wire rst_n,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [2:0] cfg_kind,
    input wire [15:0] cfg_addr,
    input wire [31:0] cfg_data,
    input wire start_valid,
    output wire start_ready,
    input wire [3:0] start_epoch,
    output wire done_valid,
    input wire done_ready,
    output wire [3:0] done_epoch,
    output wire out_valid,
    input wire out_ready,
    output wire [15:0] out_index,
    output wire signed [7:0] out_data,
    output wire busy,
    output wire [1:0] scratch0_state,
    output wire [1:0] scratch1_state,
    output wire [3:0] active_epoch,
    output wire [31:0] cycle_count,
    output wire [31:0] pw_mac_count,
    output wire [31:0] dw_mac_count,
    output wire [31:0] overlap_cycles,
    output wire [31:0] protocol_errors,
    input wire scratch_read_ready,
    output wire sink_valid,
    input wire sink_ready,
    output wire [31:0] sink_addr,
    output wire [31:0] sink_data,
    output wire [3:0] sink_byte_enable,
    output wire [15:0] sink_index,
    output wire [3:0] sink_epoch,
    output wire [31:0] word_sink_fire_count,
    output wire [31:0] byte_commit_count,
    output wire [31:0] sink_stall_count,
    output wire [31:0] sink_protocol_errors
);
    edgembconv_hwacandidate_d4_vstream_v6_mb16_controller u_candidate (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready),
        .cfg_kind(cfg_kind),
        .cfg_addr(cfg_addr),
        .cfg_data(cfg_data),
        .start_valid(start_valid),
        .start_ready(start_ready),
        .start_epoch(start_epoch),
        .done_valid(done_valid),
        .done_ready(done_ready),
        .done_epoch(done_epoch),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_index(out_index),
        .out_data(out_data),
        .busy(busy),
        .scratch0_state(scratch0_state),
        .scratch1_state(scratch1_state),
        .active_epoch(active_epoch),
        .cycle_count(cycle_count),
        .pw_mac_count(pw_mac_count),
        .dw_mac_count(dw_mac_count),
        .overlap_cycles(overlap_cycles),
        .protocol_errors(protocol_errors),
        .scratch_read_ready(scratch_read_ready),
        .sink_valid(sink_valid),
        .sink_ready(sink_ready),
        .sink_addr(sink_addr),
        .sink_data(sink_data),
        .sink_byte_enable(sink_byte_enable),
        .sink_index(sink_index),
        .sink_epoch(sink_epoch),
        .word_sink_fire_count(word_sink_fire_count),
        .byte_commit_count(byte_commit_count),
        .sink_stall_count(sink_stall_count),
        .sink_protocol_errors(sink_protocol_errors)
    );
endmodule

`default_nettype wire

