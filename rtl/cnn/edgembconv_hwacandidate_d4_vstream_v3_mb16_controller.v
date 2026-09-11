`timescale 1ns/1ps
`default_nettype none

/*
 * D4 vstream v3 integration candidate.
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
module edgembconv_hwacandidate_d4_vstream_v3_mb16_controller #(
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

    /* The arithmetic/dataflow child is an existing, independently verified
     * D4 primitive.  No old file is modified and no additional DSP island is
     * instantiated by this shell. */
    edgembconv_hwacandidate_d4_vstream_v3_scheduler u_arithmetic (
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
        .scratch_read_ready(scratch_read_ready)
    );

    reg [31:0] pack_reg;
    reg [1:0] pack_count;
    reg pack_valid;
    reg [15:0] pack_index_reg;
    reg [3:0] pack_epoch_reg;
    /* Child completion can arrive on the same cycle as the final packed
     * word.  Keep a local completion token until that word has actually
     * drained, otherwise a stalled sink can leave the wrapper in an idle
     * state with no clock-progressing source to release the last word. */
    reg done_pending;
    reg [3:0] done_pending_epoch;
    wire pack_last_byte = (child_out_index[1:0] == 2'd3);
    wire sink_fire = sink_valid && sink_ready;

    /* A source byte can be accepted when the current word is not pending, or
     * when the pending word is consumed in this same cycle.  This is a
     * registered one-entry service queue: sink backpressure cannot perturb
     * the child's byte index or address. */
    assign child_out_ready = rst_n && (!pack_valid || sink_ready);
    assign sink_valid = pack_valid;
    assign sink_addr = {14'd0, pack_index_reg, 2'b00};
    assign sink_data = pack_reg;
    assign sink_byte_enable = 4'b1111;
    assign sink_index = pack_index_reg;
    assign sink_epoch = pack_epoch_reg;

    assign done_valid = done_pending && !pack_valid;
    assign done_epoch = done_pending_epoch;
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
            pack_reg <= 32'd0;
            pack_count <= 2'd0;
            pack_valid <= 1'b0;
            pack_index_reg <= 16'd0;
            pack_epoch_reg <= 4'd0;
            done_pending <= 1'b0;
            done_pending_epoch <= 4'd0;
            word_sink_fire_count <= 32'd0;
            byte_commit_count <= 32'd0;
            sink_stall_count <= 32'd0;
            sink_protocol_errors <= 32'd0;
        end else begin
            if (child_done_valid) begin
                done_pending <= 1'b1;
                done_pending_epoch <= child_done_epoch;
            end
            if (done_valid && done_ready)
                done_pending <= 1'b0;
            if (sink_valid && !sink_ready)
                sink_stall_count <= sink_stall_count + 1'b1;
            if (sink_fire)
                begin
                    word_sink_fire_count <= word_sink_fire_count + 1'b1;
                    byte_commit_count <= byte_commit_count + 4;
                end

            if (child_out_valid && child_out_ready) begin
                if (child_out_index[1:0] != pack_count)
                    sink_protocol_errors <= sink_protocol_errors + 1'b1;
                pack_reg[(pack_count*8) +: 8] <= child_out_data;
                pack_epoch_reg <= child_active_epoch;
                if (pack_count == 2'd0)
                    pack_index_reg <= child_out_index >> 2;
                pack_count <= pack_count + 1'b1;
                if (pack_last_byte) begin
                    pack_valid <= 1'b1;
                    pack_count <= 2'd0;
                end
            end

            /* A consumed word clears the registered queue unless a new final
             * byte replaces it on the same edge. */
            if (sink_fire && !(child_out_valid && child_out_ready && pack_last_byte))
                pack_valid <= 1'b0;
        end
    end
endmodule
`default_nettype wire
