`timescale 1ns/1ps
`default_nettype none

// DS1 pointwise streaming consumer.
//
// This is an isolated DS12 prototype.  It consumes the 16-lane DW endpoint
// directly; there is no layer-sized DW replay store.  Sixteen bounded context
// slots hold
// at most eight 16-byte vectors each while a slot is being reduced or drained.
// A context is selected by its endpoint context tag and its owner/epoch pair,
// so vectors may arrive in any order.
//
// One compute cycle is one 8-pixel x 8-output-channel x 1-input-channel tile
// (64 signed MACs).  Sixteen K cycles are continuous for each of the four
// Cout groups.  Thus one context takes 64 PW tokens and the complete DS1
// ledger is 8192 tokens / 524288 MACs.  Compute and the 32-bit sink run in
// parallel on different context slots.
module ds12_stream_ds1_pw_consumer #(
    parameter integer PIXELS = 1024,
    parameter integer CONTEXTS = 16,
    parameter integer CONTEXT_PIXELS = 8,
    parameter [31:0] PW_WEIGHT_BASE = 32'h00003200,
    parameter [31:0] PW_BIAS_BASE = 32'h00003400,
    parameter [31:0] PW_MULT_BASE = 32'h00003480,
    parameter [31:0] PW_SHIFT_BASE = 32'h00003500,
    parameter [31:0] SINK_BASE = 32'h00100000
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    output wire ready,

    // Packed PW configuration memory transaction boundary.  The consumer
    // performs exactly 128 weight-word reads plus 32 bias, 32 multiplier and
    // 32 shift reads.  A response may be delayed arbitrarily, but only one
    // request is outstanding and request fields remain stable until accepted.
    output wire cfg_req_valid,
    input wire cfg_req_ready,
    output wire [31:0] cfg_req_addr,
    output wire [7:0] cfg_req_index,
    output wire [1:0] cfg_req_kind, // 0=weight, 1=bias, 2=multiplier, 3=shift
    output wire cfg_req_last,
    input wire cfg_resp_valid,
    output wire cfg_resp_ready,
    input wire [31:0] cfg_resp_data,

    // Direct DS1 DW vector boundary (the endpoint's 16-lane tagged vector).
    input wire dw_valid,
    output wire dw_ready,
    input wire [127:0] dw_data,
    input wire [5:0] dw_row,
    input wire [9:0] dw_pixel,
    input wire [1:0] dw_context,
    input wire dw_owner,
    input wire [31:0] dw_epoch,
    input wire dw_last,

    // 32-bit little-endian output words.
    output wire sink_valid,
    input wire sink_ready,
    output wire [31:0] sink_addr,
    output wire [31:0] sink_data,
    output wire [3:0] sink_strb,
    output wire [5:0] sink_row,
    output wire [9:0] sink_pixel,
    output wire [2:0] sink_word_in_pixel,
    output wire [1:0] sink_context,
    output wire sink_owner,
    output wire [31:0] sink_epoch,
    output wire sink_last,

    output wire busy,
    output wire done,
    output wire error,
    output wire [31:0] cfg_read_count,
    output wire [31:0] cfg_weight_read_count,
    output wire [31:0] dw_vector_count,
    output wire [31:0] pw_token_count,
    output wire [31:0] pw_mac_count,
    output wire [31:0] output_word_count,
    output wire [4:0] partial_context_peak
);
    localparam [2:0] ST_CFG_REQ = 3'd0;
    localparam [2:0] ST_CFG_WAIT = 3'd1;
    localparam [2:0] ST_IDLE = 3'd2;
    localparam [2:0] ST_RUN = 3'd3;
    localparam [1:0] SLOT_IDLE = 2'd0;
    localparam [1:0] SLOT_FILL = 2'd1;
    localparam [1:0] SLOT_READY = 2'd2;
    localparam [1:0] SLOT_COMPUTE = 2'd3;
    // SLOT_COMPUTE is also used until the final MAC; output ownership is
    // represented by output_active while the slot remains non-idle.

    reg [2:0] state;
    reg [7:0] cfg_index_r;
    reg cfg_done_r;
    reg done_r, error_r;

    reg signed [7:0] weight [0:31][0:15];
    reg signed [31:0] bias [0:31];
    reg signed [31:0] multiplier [0:31];
    reg [5:0] shift [0:31];

    reg [1:0] slot_state [0:CONTEXTS-1];
    reg [1:0] slot_context [0:CONTEXTS-1];
    reg slot_owner [0:CONTEXTS-1];
    reg [31:0] slot_epoch [0:CONTEXTS-1];
    reg [7:0] slot_seen [0:CONTEXTS-1];
    reg signed [7:0] activation [0:CONTEXTS-1][0:7][0:15];
    reg signed [31:0] accum [0:CONTEXTS-1][0:7][0:31];

    reg compute_active;
    reg [3:0] compute_slot;
    reg [5:0] compute_step;
    reg output_active;
    reg [3:0] output_slot;
    reg [5:0] output_word;

    reg [31:0] cfg_read_count_r, cfg_weight_read_count_r;
    reg [31:0] dw_vector_count_r, pw_token_count_r, pw_mac_count_r;
    reg [31:0] output_word_count_r;
    reg [4:0] partial_context_peak_r;

    integer i, j, p, c;

    reg [3:0] input_slot;
    reg input_slot_found, input_slot_free;
    wire [2:0] input_local_pixel = dw_pixel[2:0];
    wire input_context_ok = (dw_pixel < PIXELS) &&
                            (dw_pixel[4:3] == dw_context) &&
                            (dw_pixel[3] == dw_owner) &&
                            ({26'd0, dw_pixel[9:4]} == dw_epoch);
    wire input_slot_can_start = input_slot_free;
    wire input_slot_can_fill = input_slot_found && (slot_state[input_slot] == SLOT_FILL) &&
                               (slot_context[input_slot] == dw_context) &&
                               (slot_owner[input_slot] == dw_owner) &&
                               (slot_epoch[input_slot] == dw_epoch);
    wire input_pixel_new = input_slot_found && !slot_seen[input_slot][input_local_pixel];
    wire run_active = (state == ST_RUN);
    assign dw_ready = rst_n && run_active && input_context_ok &&
                      (input_slot_can_start || (input_slot_can_fill && input_pixel_new));
    wire dw_fire = dw_valid && dw_ready;

    assign ready = rst_n && (state == ST_IDLE) && cfg_done_r;
    assign busy = (state != ST_IDLE) || compute_active || output_active;
    assign done = done_r;
    assign error = error_r;
    assign cfg_read_count = cfg_read_count_r;
    assign cfg_weight_read_count = cfg_weight_read_count_r;
    assign dw_vector_count = dw_vector_count_r;
    assign pw_token_count = pw_token_count_r;
    assign pw_mac_count = pw_mac_count_r;
    assign output_word_count = output_word_count_r;
    assign partial_context_peak = partial_context_peak_r;

    assign cfg_req_valid = (state == ST_CFG_REQ);
    assign cfg_resp_ready = (state == ST_CFG_WAIT);
    assign cfg_req_index = cfg_index_r;
    assign cfg_req_kind = (cfg_index_r < 8'd128) ? 2'd0 :
                          (cfg_index_r < 8'd160) ? 2'd1 :
                          (cfg_index_r < 8'd192) ? 2'd2 : 2'd3;
    assign cfg_req_addr = (cfg_index_r < 8'd128) ?
                          (PW_WEIGHT_BASE + ({24'd0, cfg_index_r} << 2)) :
                          (cfg_index_r < 8'd160) ?
                          (PW_BIAS_BASE + ({24'd0, (cfg_index_r - 8'd128)} << 2)) :
                          (cfg_index_r < 8'd192) ?
                          (PW_MULT_BASE + ({24'd0, (cfg_index_r - 8'd160)} << 2)) :
                          (PW_SHIFT_BASE + ({24'd0, (cfg_index_r - 8'd192)} << 2));
    assign cfg_req_last = (cfg_index_r == 8'd223);

    // Q31 half-away-from-zero, arithmetic post-shift, zero point, INT8
    // saturation and activation clamp.  DS1 C0 config uses 0..127, but the
    // parameters remain explicit in this local function for auditability.
    function automatic signed [7:0] requant;
        input signed [31:0] acc_value;
        input signed [31:0] bias_value;
        input signed [31:0] mult_value;
        input [5:0] shift_value;
        reg signed [32:0] x;
        reg signed [64:0] product;
        reg signed [64:0] rounded;
        reg signed [64:0] shifted;
        reg signed [64:0] q;
        begin
            x = acc_value + bias_value;
            product = x * mult_value;
            if (product < 0)
                rounded = -(((-product) + 65'sd1073741824) >>> 31);
            else
                rounded = (product + 65'sd1073741824) >>> 31;
            shifted = rounded >>> shift_value;
            q = shifted;
            if (q > 65'sd127) q = 65'sd127;
            if (q < -65'sd128) q = -65'sd128;
            q = q; // output zero point is the C0 DS1 value (zero)
            if (q < 0) q = 0;
            if (q > 127) q = 127;
            requant = q[7:0];
        end
    endfunction

    wire [2:0] output_local_pixel = output_word[5:3];
    wire [2:0] output_word_local = output_word[2:0];
    wire [4:0] output_channel_base = {output_word_local, 2'b00};
    wire [31:0] output_global_pixel_w = (slot_epoch[output_slot] << 4) +
                                         ({31'd0, slot_owner[output_slot]} << 3) + output_local_pixel;
    wire [9:0] output_global_pixel = output_global_pixel_w[9:0];
    wire [31:0] output_word_data = {
        requant(accum[output_slot][output_local_pixel][output_channel_base + 5'd3], bias[output_channel_base + 5'd3], multiplier[output_channel_base + 5'd3], shift[output_channel_base + 5'd3]),
        requant(accum[output_slot][output_local_pixel][output_channel_base + 5'd2], bias[output_channel_base + 5'd2], multiplier[output_channel_base + 5'd2], shift[output_channel_base + 5'd2]),
        requant(accum[output_slot][output_local_pixel][output_channel_base + 5'd1], bias[output_channel_base + 5'd1], multiplier[output_channel_base + 5'd1], shift[output_channel_base + 5'd1]),
        requant(accum[output_slot][output_local_pixel][output_channel_base], bias[output_channel_base], multiplier[output_channel_base], shift[output_channel_base])
    };
    assign sink_valid = output_active;
    assign sink_addr = SINK_BASE + ((output_global_pixel * 32'd8) + output_word_local) * 32'd4;
    assign sink_data = output_word_data;
    assign sink_strb = 4'hf;
    assign sink_row = output_global_pixel / 32;
    assign sink_pixel = output_global_pixel;
    assign sink_word_in_pixel = output_word_local;
    assign sink_context = slot_context[output_slot];
    assign sink_owner = slot_owner[output_slot];
    assign sink_epoch = slot_epoch[output_slot];
    assign sink_last = output_active && (output_global_pixel == PIXELS-1) && (output_word == 6'd63);
    wire sink_fire = sink_valid && sink_ready;

    // Number of contexts that are no longer empty, used to expose the small
    // partial-context footprint to the TB/report without implying a full DW
    // layer buffer.
    reg [4:0] active_context_count;
    reg compute_pick_valid, output_pick_valid;
    reg [3:0] compute_pick_slot, output_pick_slot;
    always @* begin
        active_context_count = 0;
        input_slot = 0;
        input_slot_found = 0;
        input_slot_free = 0;
        compute_pick_valid = 0;
        compute_pick_slot = 0;
        output_pick_valid = 0;
        output_pick_slot = 0;
        for (i = 0; i < CONTEXTS; i = i + 1) begin
            if (slot_state[i] != SLOT_IDLE) active_context_count = active_context_count + 1'b1;
            if (!input_slot_found && slot_state[i] != SLOT_IDLE && slot_context[i] == dw_context &&
                slot_owner[i] == dw_owner && slot_epoch[i] == dw_epoch) begin
                input_slot = i[3:0]; input_slot_found = 1'b1;
            end
            if (!input_slot_free && !input_slot_found && slot_state[i] == SLOT_IDLE) begin
                input_slot = i[3:0]; input_slot_free = 1'b1;
            end
            if (!compute_pick_valid && slot_state[i] == SLOT_READY) begin
                compute_pick_valid = 1'b1; compute_pick_slot = i[3:0];
            end
            if (!output_pick_valid && slot_state[i] == SLOT_COMPUTE) begin
                output_pick_valid = 1'b1; output_pick_slot = i[3:0];
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_CFG_REQ;
            cfg_index_r <= 0;
            cfg_done_r <= 0;
            done_r <= 0;
            error_r <= 0;
            compute_active <= 0;
            compute_slot <= 0;
            compute_step <= 0;
            output_active <= 0;
            output_slot <= 0;
            output_word <= 0;
            cfg_read_count_r <= 0;
            cfg_weight_read_count_r <= 0;
            dw_vector_count_r <= 0;
            pw_token_count_r <= 0;
            pw_mac_count_r <= 0;
            output_word_count_r <= 0;
            partial_context_peak_r <= 0;
            for (i = 0; i < CONTEXTS; i = i + 1) begin
                slot_state[i] <= SLOT_IDLE;
                slot_context[i] <= 0;
                slot_owner[i] <= 0;
                slot_epoch[i] <= 0;
                slot_seen[i] <= 0;
            end
            for (i = 0; i < 32; i = i + 1) begin
                bias[i] <= 0;
                multiplier[i] <= 0;
                shift[i] <= 0;
                for (j = 0; j < 16; j = j + 1) weight[i][j] <= 0;
            end
        end else begin
            if (active_context_count > partial_context_peak_r)
                partial_context_peak_r <= active_context_count;

            if (state == ST_CFG_REQ && cfg_req_ready)
                state <= ST_CFG_WAIT;
            if (state == ST_CFG_WAIT && cfg_resp_valid && cfg_resp_ready) begin
                cfg_read_count_r <= cfg_read_count_r + 1'b1;
                if (cfg_index_r < 8'd128) begin
                    for (j = 0; j < 4; j = j + 1)
                        weight[(cfg_index_r * 4 + j) / 16][(cfg_index_r * 4 + j) % 16] <= $signed(cfg_resp_data[j*8 +: 8]);
                    cfg_weight_read_count_r <= cfg_weight_read_count_r + 1'b1;
                end else if (cfg_index_r < 8'd160)
                    bias[cfg_index_r[4:0]] <= $signed(cfg_resp_data);
                else if (cfg_index_r < 8'd192)
                    multiplier[cfg_index_r[4:0]] <= $signed(cfg_resp_data);
                else
                    shift[cfg_index_r[4:0]] <= cfg_resp_data[5:0];
                if (cfg_index_r == 8'd223) begin
                    cfg_done_r <= 1'b1;
                    state <= ST_IDLE;
                end else begin
                    cfg_index_r <= cfg_index_r + 1'b1;
                    state <= ST_CFG_REQ;
                end
            end

            if (state == ST_IDLE && start && cfg_done_r) begin
                state <= ST_RUN;
                done_r <= 0;
            end

            if (dw_valid && run_active && !input_context_ok)
                error_r <= 1'b1;
            if (dw_fire) begin
                // A free slot may be selected speculatively while the scan is
                // still looking for a matching tagged context.  Starting a
                // slot must therefore require that no matching slot was
                // found; otherwise a lower idle slot resets slot_seen on
                // every later pixel of a higher-index context.
                if (input_slot_can_start && !input_slot_found) begin
                    slot_context[input_slot] <= dw_context;
                    slot_owner[input_slot] <= dw_owner;
                    slot_epoch[input_slot] <= dw_epoch;
                    slot_seen[input_slot] <= (8'b1 << input_local_pixel);
                    slot_state[input_slot] <= SLOT_FILL;
                end else begin
                    slot_seen[input_slot] <= slot_seen[input_slot] | (8'b1 << input_local_pixel);
                end
                for (j = 0; j < 16; j = j + 1)
                    activation[input_slot][input_local_pixel][j] <= $signed(dw_data[j*8 +: 8]);
                if (slot_seen[input_slot] == 8'h7f ||
                    (slot_seen[input_slot] | (8'b1 << input_local_pixel)) == 8'hff)
                    slot_state[input_slot] <= SLOT_READY;
                dw_vector_count_r <= dw_vector_count_r + 1'b1;
            end

            // Start one ready context and clear its 8x32 accumulator bank.
            if (run_active && !compute_active && compute_pick_valid) begin
                compute_active <= 1'b1;
                compute_slot <= compute_pick_slot;
                compute_step <= 0;
                slot_state[compute_pick_slot] <= SLOT_COMPUTE;
                for (p = 0; p < 8; p = p + 1)
                    for (c = 0; c < 32; c = c + 1)
                        accum[compute_pick_slot][p][c] <= 0;
            end

            if (compute_active) begin
                // step = cout_group*16 + K.  The two K groups are deliberately
                // only a tagging/ledger boundary; accumulation never clears
                // at K=8.
                for (p = 0; p < 8; p = p + 1)
                    for (c = 0; c < 8; c = c + 1)
                        accum[compute_slot][p][compute_step[5:4] * 8 + c] <=
                            accum[compute_slot][p][compute_step[5:4] * 8 + c] +
                            activation[compute_slot][p][compute_step[3:0]] *
                            weight[compute_step[5:4] * 8 + c][compute_step[3:0]];
                pw_token_count_r <= pw_token_count_r + 1'b1;
                pw_mac_count_r <= pw_mac_count_r + 32'd64;
                if (compute_step == 6'd63) begin
                    compute_active <= 1'b0;
                    if (!output_active) begin
                        output_active <= 1'b1;
                        output_slot <= compute_slot;
                        output_word <= 0;
                    end
                end else compute_step <= compute_step + 1'b1;
            end

            // If the compute completion could not claim the output port, pick
            // an already-computed slot on the following cycle.
            if (run_active && !output_active && !compute_active && output_pick_valid) begin
                output_active <= 1'b1;
                output_slot <= output_pick_slot;
                output_word <= 0;
            end

            if (sink_fire) begin
                output_word_count_r <= output_word_count_r + 1'b1;
                if (output_word == 6'd63) begin
                    slot_state[output_slot] <= SLOT_IDLE;
                    slot_seen[output_slot] <= 0;
                    output_active <= 1'b0;
                    // The final global tag may arrive early when the DW
                    // producer is intentionally out of order.  Completion is
                    // therefore fenced by the output ledger, not sink_last.
                    if (output_word_count_r == (PIXELS*8-1)) begin done_r <= 1'b1; state <= ST_IDLE; end
                end else output_word <= output_word + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
