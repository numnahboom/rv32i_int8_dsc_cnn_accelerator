`timescale 1ns/1ps
`default_nettype none

/*
 * D4 vstream v5 integration candidate.
 *
 * This is an intentionally independent output-service shell around the
 * byte-exact v2 arithmetic candidate.  It gives the next dataflow revision a
 * real banked, aligned 32-bit sink contract: four accepted byte results are
 * packed into one word, byte enables and epoch are carried with the word, and
 * no word is committed until the sink accepts it.  The arithmetic child is
 * kept unchanged so this milestone isolates the memory-service contract and
 * prevents a sink experiment from changing the D4 workload or quantization.
 *
 * The child remains a serial v2 schedule.  Consequently this candidate is a
 * functional/service milestone, not a claim of the v3 <=25k cycle target;
 * the report records that boundary explicitly.
 */
module edgembconv_hwacandidate_d4_vstream_v5_mb16_controller #(
    parameter integer INPUT_BYTES=32*32*16,
    parameter integer EXP_BYTES=32*32*32,
    parameter integer DW_OUT_BYTES=16*16*32,
    parameter integer OUTPUT_BYTES=16*16*32,
    parameter integer PW_WEIGHT_BYTES=4096,
    parameter integer DW_WEIGHT_BYTES=288,
    parameter integer CFG_ADDR_WIDTH=16
) (
    input wire clk, input wire rst_n,
    input wire cfg_valid, output wire cfg_ready, input wire [2:0] cfg_kind,
    input wire [CFG_ADDR_WIDTH-1:0] cfg_addr, input wire [31:0] cfg_data,
    input wire start_valid, output wire start_ready, input wire [3:0] start_epoch,
    output wire done_valid, input wire done_ready, output wire [3:0] done_epoch,
    output wire out_valid, input wire out_ready, output wire [15:0] out_index,
    output wire signed [7:0] out_data, output wire busy,
    output wire [1:0] scratch0_state, output wire [1:0] scratch1_state,
    output wire [3:0] active_epoch,
    output wire [31:0] cycle_count, output wire [31:0] pw_mac_count,
    output wire [31:0] dw_mac_count, output wire [31:0] overlap_cycles,
    output wire [31:0] protocol_errors, input wire scratch_read_ready,

    /* Real aligned worded feature-memory service.  sink_addr is a byte
     * address aligned to four bytes; sink_data byte 0 is the lowest byte. */
    output wire sink_valid, input wire sink_ready,
    output wire [31:0] sink_addr, output wire [31:0] sink_data,
    output wire [3:0] sink_byte_enable, output wire [15:0] sink_index,
    output wire [3:0] sink_epoch,
    output reg [31:0] word_sink_fire_count,
    output reg [31:0] byte_commit_count,
    output reg [31:0] sink_stall_count,
    output reg [31:0] sink_protocol_errors
);
    wire child_out_valid, child_out_ready;
    wire [15:0] child_out_index;
    wire signed [7:0] child_out_data;
    wire child_done_valid;
    wire [3:0] child_done_epoch;
    wire [3:0] child_active_epoch;
    wire child_busy;
    wire [31:0] child_cycle_count, child_pw_mac_count, child_dw_mac_count;
    wire [31:0] child_overlap_cycles, child_protocol_errors;
    wire [1:0] child_scratch0_state, child_scratch1_state;
    wire child_word_valid, child_word_ready;
    wire [31:0] child_word_data;
    wire [15:0] child_word_index;
    wire [3:0] child_word_epoch;

    /* The arithmetic/dataflow child is an existing, independently verified
     * D4 primitive.  No old file is modified and no additional DSP island is
     * instantiated by this shell. */
    edgembconv_hwacandidate_d4_vstream_v5_scheduler u_arithmetic (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_kind(cfg_kind), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_epoch(start_epoch), .done_valid(child_done_valid),
        .done_ready(done_ready), .done_epoch(child_done_epoch),
        .out_valid(child_out_valid), .out_ready(child_out_ready),
        .out_index(child_out_index), .out_data(child_out_data),
        .busy(child_busy), .scratch0_state(child_scratch0_state),
        .scratch1_state(child_scratch1_state), .active_epoch(child_active_epoch),
        .cycle_count(child_cycle_count), .pw_mac_count(child_pw_mac_count),
        .dw_mac_count(child_dw_mac_count), .overlap_cycles(child_overlap_cycles),
        .protocol_errors(child_protocol_errors),
        .scratch_read_ready(scratch_read_ready),
        .word_out_valid(child_word_valid), .word_out_ready(child_word_ready),
        .word_out_data(child_word_data), .word_out_index(child_word_index),
        .word_out_epoch(child_word_epoch)
    );

    wire sink_fire = sink_valid && sink_ready;

    /* v5 receives complete words from the two-bank scheduler.  The ready
     * signal is passed through unchanged, so a stalled final word also stalls
     * completion at the arithmetic boundary. */
    assign child_out_ready = 1'b1;
    assign child_word_ready = rst_n && sink_ready;
    assign sink_valid = child_word_valid;
    assign sink_addr = {14'd0, child_word_index, 2'b00};
    assign sink_data = child_word_data;
    assign sink_byte_enable = 4'b1111;
    assign sink_index = child_word_index;
    assign sink_epoch = child_word_epoch;

    assign done_valid = child_done_valid;
    assign done_epoch = child_done_epoch;
    assign out_valid = child_out_valid;
    assign out_index = child_out_index;
    assign out_data = child_out_data;
    assign busy = child_busy;
    assign scratch0_state = child_scratch0_state;
    assign scratch1_state = child_scratch1_state;
    assign active_epoch = child_active_epoch;
    assign cycle_count = child_cycle_count;
    assign pw_mac_count = child_pw_mac_count;
    assign dw_mac_count = child_dw_mac_count;
    assign overlap_cycles = child_overlap_cycles;
    assign protocol_errors = child_protocol_errors;

    always @(posedge clk) begin
        if (!rst_n) begin
            word_sink_fire_count <= 32'd0;
            byte_commit_count <= 32'd0;
            sink_stall_count <= 32'd0;
            sink_protocol_errors <= 32'd0;
        end else begin
            if (sink_valid && !sink_ready)
                sink_stall_count <= sink_stall_count + 1'b1;
            if (sink_fire)
                begin
                    word_sink_fire_count <= word_sink_fire_count + 1'b1;
                    byte_commit_count <= byte_commit_count + 4;
                end

            if (sink_fire && (sink_addr[1:0] !== 2'd0 || sink_byte_enable !== 4'hf))
                sink_protocol_errors <= sink_protocol_errors + 1'b1;
        end
    end
endmodule
`default_nettype wire
