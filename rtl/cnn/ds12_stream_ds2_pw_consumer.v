`timescale 1ns/1ps
`default_nettype none

/*
 * Stand-alone DS2 pointwise consumer.
 *
 * The DW endpoint presents two 16-byte activation slices for each pixel.
 * Eight adjacent pixels form one PW context, so the input side keeps only
 * the bounded activation scratch and its sixteen slice-valid bits.  The PW
 * engine itself is an 8x8 output-stationary array: one accepted K token
 * performs 8*8 = 64 signed INT8 MACs and K=0..31 is issued on consecutive
 * cycles.  The 64 local INT32 sums are reused for each Cout tile; at K=31
 * their *next* values are written to the selected result bank.  Consequently
 * the final product is present before a bank can become drainable.
 *
 * Two result banks provide the compute/drain ownership fence.  Each lifecycle
 * bank is 64 independent shallow depth-8 x 32-bit lane memories (not a
 * layer-sized accumulator array): one completed context can remain stable
 * under sink backpressure while the other bank accepts the next context.  A
 * bank is released only by the final accepted sink word, and contexts are
 * drained in group order so sink_last cannot be asserted early by an
 * out-of-order DW arrival.
 */
module ds12_stream_ds2_pw_consumer #(
    parameter integer PIXELS = 256,
    parameter integer CONTEXTS = 32,
    parameter integer CONTEXT_PIXELS = 8,
    parameter [31:0] SINK_BASE = 32'h00200000
) (
    input wire clk, input wire rst_n,
    input wire start, output wire ready,

    // Synchronous read port of the real packed DS2 configuration bank.
    // Local indices 0..703 map to packed bank words 168..871.
    output wire cfg_rd_en, output wire cfg_rd_bank,
    output wire [15:0] cfg_rd_addr, input wire [31:0] cfg_rd_data,
    input wire cfg_rd_valid, input wire cfg_active_valid,
    input wire [1:0] cfg_active_layer, input wire cfg_active_bank,
    input wire [31:0] cfg_active_epoch,
    output wire [15:0] config_index, output wire [31:0] config_payload,

    input wire dw_valid, output wire dw_ready,
    input wire [127:0] dw_data, input wire [5:0] dw_row,
    input wire [7:0] dw_pixel, input wire dw_group,
    input wire [1:0] dw_context, input wire dw_owner,
    input wire [31:0] dw_epoch, input wire dw_last,

    output wire sink_valid, input wire sink_ready,
    output wire [31:0] sink_addr, output wire [31:0] sink_data,
    output wire [3:0] sink_strb, output wire [5:0] sink_row,
    output wire [7:0] sink_pixel, output wire [3:0] sink_word_in_pixel,
    output wire [1:0] sink_context, output wire sink_owner,
    output wire [31:0] sink_epoch, output wire sink_last,

    output wire busy, output wire done, output wire error,
    output wire [7:0] error_code,
    output wire [31:0] cfg_read_count, output wire [31:0] cfg_weight_read_count,
    output wire [31:0] dw_vector_count, output wire [31:0] pw_token_count,
    output wire [31:0] pw_mac_count, output wire [31:0] output_word_count,
    output wire [3:0] partial_context_peak
);
    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_CFG_ISSUE = 3'd1;
    localparam [2:0] ST_CFG_WAIT  = 3'd2;
    localparam [2:0] ST_RUN       = 3'd3;

    localparam [2:0] SLOT_IDLE     = 3'd0;
    localparam [2:0] SLOT_FILL     = 3'd1;
    localparam [2:0] SLOT_READY    = 3'd2;
    localparam [2:0] SLOT_COMPUTE  = 3'd3;
    localparam [2:0] SLOT_WAIT_OUT = 3'd4;

    localparam [1:0] BANK_FREE    = 2'd0;
    localparam [1:0] BANK_COMPUTE = 2'd1;
    localparam [1:0] BANK_READY   = 2'd2;
    localparam [1:0] BANK_DRAIN   = 2'd3;

    localparam integer EXPECTED_OUTPUTS = PIXELS * 16;
    localparam [15:0] CFG_BASE_WORD = 16'd168;
    localparam [9:0] CFG_LAST_INDEX = 10'd703;
    localparam [6:0] LAST_OUTPUT_WORD = 7'd127;
    localparam [8:0] PIXELS_LIMIT = 9'd256;
    localparam [5:0] CONTEXTS_LIMIT = 6'd32;
    localparam [7:0] LAST_PIXEL = 8'd255;

    reg [2:0] state;
    reg [9:0] cfg_index_r;
    reg cfg_bank_r;
    reg [31:0] cfg_epoch_r;
    reg cfg_done_r, done_r, error_r;
    reg [7:0] error_code_r;

    reg signed [31:0] bias [0:63];
    reg signed [31:0] multiplier [0:63];
    reg [5:0] shift [0:63];

    // Input activation ledger.  The payload itself lives in eight independent
    // synchronous BRAM read/write banks below: one 64 x 128-bit bank per
    // pixel lane.  The six-bit row address is {pixel-group[4:0],slice}, so a
    // DW fire writes one complete 128-bit slice without any byte enables.
    //
    // The 32-context tag ledger is deliberately partitioned into four local
    // 8-context banks.  Each bank owns its state/context/owner/epoch/seen
    // arrays and performs its own selected-entry compare/update.  The top
    // level only decodes input_group[4:3] (and the ordered target group) to
    // select one bank; it never indexes one global 32-entry ledger.
    wire [2:0] ledger_input_state [0:3];
    wire [1:0] ledger_input_context [0:3];
    wire ledger_input_owner [0:3];
    wire [31:0] ledger_input_epoch [0:3];
    wire [15:0] ledger_input_seen [0:3];
    wire ledger_input_slot_existing [0:3];
    wire ledger_input_tag_match [0:3];
    wire ledger_input_slice_available [0:3];
    wire ledger_input_ready [0:3];
    // The ingress selector is one-hot.  Gating DW valid before it enters a
    // local bank keeps non-selected banks out of the input handshake/update
    // cone; their slot/seen/tag state cannot observe another bank's fire.
    wire [3:0] input_bank_selected;
    wire [3:0] bank_dw_valid;
    wire [3:0] bank_dw_fire;
    wire [2:0] ledger_target_state [0:3];
    wire [1:0] ledger_target_context [0:3];
    wire ledger_target_owner [0:3];
    wire [31:0] ledger_target_epoch [0:3];
    wire [3:0] ledger_active_count [0:3];

    // Each generated memory has one write port (DW slice) and one independent
    // synchronous read port (compute prefetch).  A 64 x 128-bit logical bank
    // maps to four RAMB18 primitives (or two RAMB36 primitives) on the
    // XC7Z020; eight lane banks therefore account for 32 RAMB18/16 RAMB36.
    // The memory array is intentionally not reset, preserving block-RAM
    // inference.  A compute claim always issues the first read before any
    // prefetched byte is consumed.
    reg [127:0] activation_prefetch [0:CONTEXT_PIXELS-1];

    // Eight Cout-lane weight memories hold one 32-bit word for each
    // {Cout-tile,K-byte-group}.  The packed configuration stream is ordered
    // by Cout first and four K bytes per word: cfg index bits [8:3] are the
    // original Cout, so [5:3] selects the lane and [8:6] plus [2:0] form the
    // tile/K-group depth address.  Keeping the memories as separate 64 x 32
    // block-RAM candidates avoids rebuilding 16,384 weight bits as registers
    // while preserving the original word-write interface.
    wire [255:0] weight_prefetch_bus;

    // The DW boundary is intentionally a one-entry ingress/commit pipeline.
    // A vector is accepted into these registers on one edge and committed to
    // activation BRAM on the next edge.  Because the old entry is committed
    // on the same edge that a new entry is captured, the external DW stream
    // still has II=1.  Keeping the BRAM write enable registered removes the
    // slot tag/epoch compare from the RAMB WEBWE timing cone.
    reg dw_ingress_pending;
    reg [127:0] dw_ingress_data;
    reg [5:0] dw_ingress_row;
    reg [7:0] dw_ingress_pixel;
    reg [4:0] dw_ingress_group;
    reg [2:0] dw_ingress_local_pixel;
    reg dw_ingress_slice;
    reg [1:0] dw_ingress_context;
    reg dw_ingress_owner;
    reg [31:0] dw_ingress_epoch;
    reg dw_ingress_last;
    reg dw_ingress_final;

    // The 64 lane accumulators are the P registers of explicit DSP48E1
    // wrappers.  There is no ordinary external register in the K feedback
    // loop: each DSP receives its own P output on PCIN and has PREG=1.
    // Results are committed through one controlled two-edge pending drain
    // after K=31 so the final product can cross the DSP A/B input registers
    // and PREG before the result BRAM write.
    wire signed [47:0] dsp_accum [0:63];
    reg [1:0] bank_state [0:1];
    reg [4:0] bank_group [0:1];
    reg [1:0] bank_context [0:1];
    reg bank_owner [0:1];
    reg [31:0] bank_epoch [0:1];

    reg compute_active;
    reg [4:0] compute_slot;
    reg compute_bank;
    reg [7:0] compute_step;
    reg last_pending;
    reg result_pending;
    reg output_active;
    reg output_bank;
    reg [6:0] output_word;
    reg [5:0] next_output_group;

    reg [31:0] cfg_read_count_r, cfg_weight_read_count_r;
    reg [31:0] dw_vector_count_r, pw_token_count_r, pw_mac_count_r;
    reg [31:0] output_word_count_r;
    reg [3:0] partial_context_peak_r;

    integer i, j;

    wire [4:0] input_group = dw_pixel[7:3];
    wire [2:0] input_local_pixel = dw_pixel[2:0];
    wire [3:0] input_bit_index = {input_local_pixel, 1'b0} +
                                  {{3{1'b0}}, dw_group};
    wire input_group_valid = ({1'b0, dw_pixel} < PIXELS_LIMIT) &&
                             ({1'b0, input_group} < CONTEXTS_LIMIT);
    wire [5:0] target_group = output_active ?
        (next_output_group + 6'd1) : next_output_group;
    reg input_slot_existing;
    reg input_tag_match;
    reg input_slice_available;
    reg [2:0] input_state;
    reg [15:0] input_seen;
    reg [5:0] active_context_count;

    wire target_group_valid = (target_group < CONTEXTS_LIMIT);
    reg target_ready;
    reg [2:0] target_state;
    reg [1:0] target_context;
    reg target_owner;
    reg [31:0] target_epoch;
    reg compute_pick_valid;
    reg compute_pick_bank;
    reg [4:0] compute_pick_slot;
    reg output_pick_valid;
    reg output_pick_bank;

    wire run_active = (state == ST_RUN);
    wire [31:0] expected_outputs = EXPECTED_OUTPUTS;
    wire [5:0] expected_dw_row = {2'd0, dw_pixel[7:4]};
    wire dw_fire;
    wire dw_commit_fire = dw_ingress_pending;
    wire sink_fire;
    wire prefetch_req;
    wire [5:0] prefetch_addr;
    wire weight_prefetch_req;
    wire [5:0] weight_prefetch_addr;

    // Decode the 32-entry global context index into exactly one of the four
    // local 8-slot ledger banks.  An invalid pixel selects no bank and is
    // still handled by the sticky protocol-error checks below.
    assign input_bank_selected[0] = input_group_valid &&
                                    (input_group[4:3] == 2'd0);
    assign input_bank_selected[1] = input_group_valid &&
                                    (input_group[4:3] == 2'd1);
    assign input_bank_selected[2] = input_group_valid &&
                                    (input_group[4:3] == 2'd2);
    assign input_bank_selected[3] = input_group_valid &&
                                    (input_group[4:3] == 2'd3);
    assign bank_dw_valid[0] = dw_valid && input_bank_selected[0];
    assign bank_dw_valid[1] = dw_valid && input_bank_selected[1];
    assign bank_dw_valid[2] = dw_valid && input_bank_selected[2];
    assign bank_dw_valid[3] = dw_valid && input_bank_selected[3];

    wire run_start = (state == ST_IDLE) && start && cfg_done_r &&
                     cfg_active_valid && (cfg_active_layer == 2'd2) &&
                     (cfg_active_epoch == cfg_epoch_r);

    // Decode the group before selecting one local ledger bank.  This keeps
    // malformed pixels out of the local indices and gives a single handshake
    // source without a global 32-entry tag/seen mux.
    always @* begin
        input_slot_existing = 1'b0;
        input_tag_match = 1'b0;
        input_slice_available = 1'b0;
        input_state = SLOT_IDLE;
        input_seen = 16'd0;
        if (input_group_valid) begin
            case (input_group[4:3])
                2'd0: begin
                    input_state = ledger_input_state[0];
                    input_seen = ledger_input_seen[0];
                    input_slot_existing = ledger_input_slot_existing[0];
                    input_tag_match = ledger_input_tag_match[0];
                    input_slice_available = ledger_input_slice_available[0];
                end
                2'd1: begin
                    input_state = ledger_input_state[1];
                    input_seen = ledger_input_seen[1];
                    input_slot_existing = ledger_input_slot_existing[1];
                    input_tag_match = ledger_input_tag_match[1];
                    input_slice_available = ledger_input_slice_available[1];
                end
                2'd2: begin
                    input_state = ledger_input_state[2];
                    input_seen = ledger_input_seen[2];
                    input_slot_existing = ledger_input_slot_existing[2];
                    input_tag_match = ledger_input_tag_match[2];
                    input_slice_available = ledger_input_slice_available[2];
                end
                default: begin
                    input_state = ledger_input_state[3];
                    input_seen = ledger_input_seen[3];
                    input_slot_existing = ledger_input_slot_existing[3];
                    input_tag_match = ledger_input_tag_match[3];
                    input_slice_available = ledger_input_slice_available[3];
                end
            endcase
        end
    end

    genvar lb;
    generate
        for (lb = 0; lb < 4; lb = lb + 1) begin : gen_slot_ledger_bank
            localparam [1:0] LEDGER_BANK = lb[1:0];
            ds12_stream_ds2_slot_ledger_bank u_ledger (
            .clk(clk),
            .rst_n(rst_n),
            .clear_slots(run_start),
                .input_query_valid(input_bank_selected[lb]),
                .input_query_slot(input_group[2:0]),
                .input_query_context(dw_context),
                .input_query_owner(dw_owner),
                .input_query_epoch(dw_epoch),
                .input_query_bit(input_bit_index),
                .input_state(ledger_input_state[lb]),
                .input_context(ledger_input_context[lb]),
                .input_owner(ledger_input_owner[lb]),
                .input_epoch(ledger_input_epoch[lb]),
                .input_seen(ledger_input_seen[lb]),
                .input_slot_existing(ledger_input_slot_existing[lb]),
                .input_tag_match(ledger_input_tag_match[lb]),
                .input_slice_available(ledger_input_slice_available[lb]),
                .stream_active(run_active),
                .ingress_available(!dw_ingress_pending || dw_commit_fire),
                .dw_valid(bank_dw_valid[lb]),
                .input_ready(ledger_input_ready[lb]),
                .input_fire(bank_dw_fire[lb]),
                .target_query_valid(target_group_valid &&
                                    (target_group[4:3] == LEDGER_BANK)),
                .target_query_slot(target_group[2:0]),
                .target_state(ledger_target_state[lb]),
                .target_context(ledger_target_context[lb]),
                .target_owner(ledger_target_owner[lb]),
                .target_epoch(ledger_target_epoch[lb]),
                .active_count(ledger_active_count[lb]),
                .set_ready_valid(dw_commit_fire && dw_ingress_final &&
                                  (dw_ingress_group[4:3] == LEDGER_BANK)),
                .set_ready_slot(dw_ingress_group[2:0]),
                .set_compute_valid(compute_pick_valid &&
                                   (compute_pick_slot[4:3] == LEDGER_BANK)),
                .set_compute_slot(compute_pick_slot[2:0]),
                .set_wait_valid(compute_active &&
                                (compute_step == 8'd255) &&
                                (compute_slot[4:3] == LEDGER_BANK)),
                .set_wait_slot(compute_slot[2:0]),
                .release_valid(sink_fire &&
                               (output_word == LAST_OUTPUT_WORD) &&
                               (bank_group[output_bank][4:3] == LEDGER_BANK)),
                .release_slot(bank_group[output_bank][2:0])
            );
        end
    endgenerate

    assign ready = rst_n && (state == ST_IDLE) &&
                   cfg_active_valid && (cfg_active_layer == 2'd2);
    assign busy = (state != ST_IDLE) || compute_active || last_pending ||
                  result_pending || output_active;
    assign done = done_r;
    assign error = error_r;
    assign error_code = error_code_r;
    assign cfg_read_count = cfg_read_count_r;
    assign cfg_weight_read_count = cfg_weight_read_count_r;
    assign dw_vector_count = dw_vector_count_r;
    assign pw_token_count = pw_token_count_r;
    assign pw_mac_count = pw_mac_count_r;
    assign output_word_count = output_word_count_r;
    assign partial_context_peak = partial_context_peak_r;

    assign cfg_rd_en = (state == ST_CFG_ISSUE);
    assign cfg_rd_bank = cfg_bank_r;
    assign cfg_rd_addr = CFG_BASE_WORD + {{6{1'b0}}, cfg_index_r};
    assign config_index = CFG_BASE_WORD + {{6{1'b0}}, cfg_index_r};
    assign config_payload = cfg_rd_data;

    // The selected local ledger bank owns the tag compare, duplicate-slice
    // filter, and ingress-availability check.  ORing the one-hot bank results
    // keeps the accept/update path in that bank instead of routing it back
    // through a parent-wide 32-slot write decoder; exactly one bank can fire
    // for a legal input_group.
    // Only the selected bank contributes to the external ready/fire.  The
    // one-hot bank_dw_fire signals are the local valid/ready handshakes and
    // are mutually exclusive for every legal input_group.
    assign dw_ready = rst_n &&
        ((input_bank_selected[0] && ledger_input_ready[0]) ||
         (input_bank_selected[1] && ledger_input_ready[1]) ||
         (input_bank_selected[2] && ledger_input_ready[2]) ||
         (input_bank_selected[3] && ledger_input_ready[3]));
    assign dw_fire = bank_dw_fire[0] || bank_dw_fire[1] ||
                     bank_dw_fire[2] || bank_dw_fire[3];

    function automatic signed [7:0] requant;
        input signed [31:0] acc_value, bias_value, mult_value;
        input [5:0] shift_value;
        reg signed [32:0] x;
        reg signed [64:0] product, rounded, shifted, q;
        begin
            x = acc_value + bias_value;
            product = x * mult_value;
            if (product < 0)
                rounded = -(((-product) + 65'sd1073741824) >>> 31);
            else
                rounded = (product + 65'sd1073741824) >>> 31;
            shifted = rounded >>> shift_value;
            q = shifted;                         // DS2 output zero point = 0
            if (q < 0) q = 0;                     // activation clamp [0,127]
            else if (q > 127) q = 127;
            requant = q[7:0];
        end
    endfunction

    // The target is deliberately ordered.  While group N drains, only N+1
    // may compute; otherwise two later ready banks could starve an incomplete
    // earlier group and deadlock the ordered sink.
    wire bank0_free = (bank_state[0] == BANK_FREE);
    wire bank1_free = (bank_state[1] == BANK_FREE);
    wire free_bank_available = bank0_free || bank1_free;

    always @* begin
        target_state = SLOT_IDLE;
        target_context = 2'd0;
        target_owner = 1'b0;
        target_epoch = 32'd0;
        target_ready = 1'b0;
        if (target_group_valid) begin
            case (target_group[4:3])
                2'd0: begin
                    target_state = ledger_target_state[0];
                    target_context = ledger_target_context[0];
                    target_owner = ledger_target_owner[0];
                    target_epoch = ledger_target_epoch[0];
                end
                2'd1: begin
                    target_state = ledger_target_state[1];
                    target_context = ledger_target_context[1];
                    target_owner = ledger_target_owner[1];
                    target_epoch = ledger_target_epoch[1];
                end
                2'd2: begin
                    target_state = ledger_target_state[2];
                    target_context = ledger_target_context[2];
                    target_owner = ledger_target_owner[2];
                    target_epoch = ledger_target_epoch[2];
                end
                default: begin
                    target_state = ledger_target_state[3];
                    target_context = ledger_target_context[3];
                    target_owner = ledger_target_owner[3];
                    target_epoch = ledger_target_epoch[3];
                end
            endcase
            target_ready = (target_state == SLOT_READY);
        end

        // Use bank zero first, then bank one.  The result bank is selected at
        // the same edge that claims the context, so no later context can alias
        // it while the 256-token reduction is in flight.
        compute_pick_valid = run_active && !compute_active &&
                             free_bank_available && target_ready;
        compute_pick_slot = target_group[4:0];
        if (bank0_free) compute_pick_bank = 1'b0;
        else compute_pick_bank = 1'b1;

        output_pick_valid = !output_active &&
            ((bank_state[0] == BANK_READY && bank_group[0] == next_output_group[4:0]) ||
             (bank_state[1] == BANK_READY && bank_group[1] == next_output_group[4:0]));
        if (bank_state[0] == BANK_READY && bank_group[0] == next_output_group[4:0])
            output_pick_bank = 1'b0;
        else
            output_pick_bank = 1'b1;

        active_context_count = {2'd0, ledger_active_count[0]} +
                               {2'd0, ledger_active_count[1]} +
                               {2'd0, ledger_active_count[2]} +
                               {2'd0, ledger_active_count[3]};
    end

    wire [2:0] compute_cout_tile = compute_step[7:5];
    wire [4:0] compute_k = compute_step[4:0];

    // A synchronous memory read issued at the claim edge supplies K=0 for
    // the following edge.  During a segment each active edge issues the row
    // for the next K token; this permits the row transition at K=16 without
    // inserting a bubble.  The lower nibble selects the byte for the current
    // K from the registered 128-bit row.
    wire [4:0] prefetch_next_k = compute_k + 5'd1;
    assign prefetch_req = compute_pick_valid ||
                          (compute_active && (compute_step != 8'd255));
    assign prefetch_addr = compute_pick_valid ?
                           {compute_pick_slot, 1'b0} :
                           {compute_slot, prefetch_next_k[4]};

    // The weight word has a second address dimension at the Cout-tile
    // boundary.  Compute step + 1 is used rather than only the wrapped K
    // counter so that the edge for K=31 fetches tile N+1/K=0 with no bubble.
    wire [7:0] prefetch_next_step = compute_step + 8'd1;
    assign weight_prefetch_req = compute_pick_valid ||
                                 (compute_active && (compute_step != 8'd255));
    assign weight_prefetch_addr = compute_pick_valid ? 6'd0 :
                                  {prefetch_next_step[7:5],
                                   prefetch_next_step[4:2]};

    genvar ab;
    generate
        for (ab = 0; ab < CONTEXT_PIXELS; ab = ab + 1) begin : gen_activation_lane_bank
            (* ram_style = "block" *)
            reg [127:0] activation_mem [0:63];

            always @(posedge clk) begin
                if (dw_commit_fire && (dw_ingress_local_pixel == ab[2:0]))
                    activation_mem[{dw_ingress_group, dw_ingress_slice}] <= dw_ingress_data;
                if (prefetch_req)
                    activation_prefetch[ab] <= activation_mem[prefetch_addr];
            end
        end
    endgenerate

    genvar wl;
    generate
        for (wl = 0; wl < 8; wl = wl + 1) begin : gen_weight_lane_bank
            localparam integer WEIGHT_LANE = wl;
            (* ram_style = "block" *)
            reg [31:0] weight_mem [0:63];
            reg [31:0] weight_prefetch_lane;

            assign weight_prefetch_bus[(WEIGHT_LANE * 32) +: 32] =
                weight_prefetch_lane;

            // Configuration writes are mutually exclusive with compute reads
            // because the consumer first drains all 704 packed words and only
            // then enters ST_RUN.  This single write/read process therefore
            // maps naturally to one synchronous block-RAM lane.
            always @(posedge clk) begin
                if ((state == ST_CFG_WAIT) && cfg_rd_valid &&
                    (cfg_index_r < 10'd512) &&
                    (cfg_index_r[5:3] == WEIGHT_LANE[2:0]))
                    weight_mem[{cfg_index_r[8:6], cfg_index_r[2:0]}] <= cfg_rd_data;
                if (weight_prefetch_req)
                    weight_prefetch_lane <= weight_mem[weight_prefetch_addr];
            end
        end
    endgenerate

    genvar gm;
    generate
        for (gm = 0; gm < 64; gm = gm + 1) begin : gen_mac_accum
            localparam integer MAC_PIXEL = gm / 8;
            localparam integer MAC_COUT = gm % 8;
            wire signed [7:0] mac_activation =
                $signed(activation_prefetch[MAC_PIXEL][{compute_k[3:0], 3'b000} +: 8]);
            wire signed [7:0] mac_weight =
                $signed(weight_prefetch_bus[(MAC_COUT * 32) +
                                            {{27{1'b0}}, compute_k[1:0],
                                             3'b000} +: 8]);

            ds12_stream_ds2_pw_dsp_accum u_dsp_accum (
                .clk(clk),
                .reset_p(!rst_n || compute_pick_valid),
                .ce(compute_active || last_pending),
                .a_in(mac_activation),
                .b_in(mac_weight),
                .p_out(dsp_accum[gm])
            );
        end
    endgenerate

    wire [2:0] output_local_pixel = output_word[6:4];
    wire [3:0] output_word_local = output_word[3:0];
    wire [5:0] output_channel_base = {output_word_local, 2'b00};
    wire [7:0] output_global_pixel =
        ({3'd0, bank_group[output_bank]} << 3) +
        {5'd0, output_local_pixel};
    wire [2:0] output_result_tile = output_channel_base[5:3];
    wire [5:0] output_result_lane_base =
        {output_local_pixel, 3'b000} + {3'd0, output_channel_base[2:0]};

    // Each lifecycle bank owns 64 independent 8-deep x 32-bit distributed
    // memories.  Lane p*8+c stores pixel p and the within-tile Cout lane c;
    // the depth address is the Cout tile.  This preserves 64 same-edge writes
    // at K=31 while giving the sink four asynchronous channel reads.
    wire signed [31:0] result_psum_read [0:1][0:63];
    genvar rb, rl;
    generate
        for (rb = 0; rb < 2; rb = rb + 1) begin : gen_result_lifecycle_bank
            for (rl = 0; rl < 64; rl = rl + 1) begin : gen_result_lane_bank
                (* ram_style = "distributed" *)
                reg signed [31:0] result_mem [0:7];
                wire result_write_enable = result_pending &&
                    (compute_bank == rb[0:0]);
                always @(posedge clk) begin
                    if (result_write_enable)
                        result_mem[compute_cout_tile] <= dsp_accum[rl][31:0];
                end
                assign result_psum_read[rb][rl] =
                    result_mem[output_result_tile];
            end
        end
    endgenerate

    wire signed [31:0] output_acc0 =
        result_psum_read[output_bank][output_result_lane_base];
    wire signed [31:0] output_acc1 =
        result_psum_read[output_bank][output_result_lane_base + 6'd1];
    wire signed [31:0] output_acc2 =
        result_psum_read[output_bank][output_result_lane_base + 6'd2];
    wire signed [31:0] output_acc3 =
        result_psum_read[output_bank][output_result_lane_base + 6'd3];
    wire [31:0] output_word_data = {
        requant(output_acc3, bias[output_channel_base + 6'd3], multiplier[output_channel_base + 6'd3], shift[output_channel_base + 6'd3]),
        requant(output_acc2, bias[output_channel_base + 6'd2], multiplier[output_channel_base + 6'd2], shift[output_channel_base + 6'd2]),
        requant(output_acc1, bias[output_channel_base + 6'd1], multiplier[output_channel_base + 6'd1], shift[output_channel_base + 6'd1]),
        requant(output_acc0, bias[output_channel_base], multiplier[output_channel_base], shift[output_channel_base])
    };

    assign sink_valid = output_active;
    assign sink_addr = SINK_BASE +
        ((({24'd0, output_global_pixel} << 4) +
          {{28{1'b0}}, output_word_local}) << 2);
    assign sink_data = output_word_data;
    assign sink_strb = 4'hf;
    assign sink_row = {2'd0, output_global_pixel[7:4]};
    assign sink_pixel = output_global_pixel;
    assign sink_word_in_pixel = output_word_local;
    assign sink_context = bank_context[output_bank];
    assign sink_owner = bank_owner[output_bank];
    assign sink_epoch = bank_epoch[output_bank];
    assign sink_last = output_active &&
        (output_global_pixel == LAST_PIXEL) &&
        (output_word == LAST_OUTPUT_WORD);
    assign sink_fire = sink_valid && sink_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            cfg_index_r <= 10'd0;
            cfg_bank_r <= 1'b0;
            cfg_epoch_r <= 32'd0;
            cfg_done_r <= 1'b0;
            done_r <= 1'b0;
            error_r <= 1'b0;
            error_code_r <= 8'd0;
            compute_active <= 1'b0;
            compute_slot <= 5'd0;
            compute_bank <= 1'b0;
            compute_step <= 8'd0;
            last_pending <= 1'b0;
            result_pending <= 1'b0;
            dw_ingress_pending <= 1'b0;
            dw_ingress_data <= 128'd0;
            dw_ingress_row <= 6'd0;
            dw_ingress_pixel <= 8'd0;
            dw_ingress_group <= 5'd0;
            dw_ingress_local_pixel <= 3'd0;
            dw_ingress_slice <= 1'b0;
            dw_ingress_context <= 2'd0;
            dw_ingress_owner <= 1'b0;
            dw_ingress_epoch <= 32'd0;
            dw_ingress_last <= 1'b0;
            dw_ingress_final <= 1'b0;
            output_active <= 1'b0;
            output_bank <= 1'b0;
            output_word <= 7'd0;
            next_output_group <= 6'd0;
            cfg_read_count_r <= 32'd0;
            cfg_weight_read_count_r <= 32'd0;
            dw_vector_count_r <= 32'd0;
            pw_token_count_r <= 32'd0;
            pw_mac_count_r <= 32'd0;
            output_word_count_r <= 32'd0;
            partial_context_peak_r <= 4'd0;
            for (i = 0; i < 64; i = i + 1) begin
                bias[i] <= 32'sd0;
                multiplier[i] <= 32'sd0;
                shift[i] <= 6'd0;
            end
            for (i = 0; i < 2; i = i + 1) begin
                bank_state[i] <= BANK_FREE;
                bank_group[i] <= 5'd0;
                bank_context[i] <= 2'd0;
                bank_owner[i] <= 1'b0;
                bank_epoch[i] <= 32'd0;
            end
        end else begin
            if (active_context_count > {2'd0, partial_context_peak_r}) begin
                if (active_context_count >= 6'd15)
                    partial_context_peak_r <= 4'hf;
                else
                    partial_context_peak_r <= active_context_count[3:0];
            end

            if (state == ST_IDLE && start) begin
                if (!cfg_active_valid || cfg_active_layer != 2'd2) begin
                    error_r <= 1'b1;
                    error_code_r <= error_code_r | 8'h01;
                end else if (!cfg_done_r) begin
                    cfg_bank_r <= cfg_active_bank;
                    cfg_epoch_r <= cfg_active_epoch;
                    cfg_index_r <= 10'd0;
                    cfg_done_r <= 1'b0;
                    done_r <= 1'b0;
                    error_r <= 1'b0;
                    error_code_r <= 8'd0;
                    cfg_read_count_r <= 32'd0;
                    cfg_weight_read_count_r <= 32'd0;
                    state <= ST_CFG_ISSUE;
                end else if (cfg_active_epoch != cfg_epoch_r) begin
                    error_r <= 1'b1;
                    error_code_r <= error_code_r | 8'h20;
                end else begin
                    // A second start is the run fence after the packed PW
                    // view has been loaded.
                    state <= ST_RUN;
                    done_r <= 1'b0;
                    error_r <= 1'b0;
                    error_code_r <= 8'd0;
                    dw_vector_count_r <= 32'd0;
                    pw_token_count_r <= 32'd0;
                    pw_mac_count_r <= 32'd0;
                    output_word_count_r <= 32'd0;
                    compute_active <= 1'b0;
                    last_pending <= 1'b0;
                    result_pending <= 1'b0;
                    dw_ingress_pending <= 1'b0;
                    output_active <= 1'b0;
                    next_output_group <= 6'd0;
                    for (i = 0; i < 2; i = i + 1)
                        bank_state[i] <= BANK_FREE;
                end
            end

            if (state == ST_CFG_ISSUE) begin
                state <= ST_CFG_WAIT;
            end else if (state == ST_CFG_WAIT && cfg_rd_valid) begin
                cfg_read_count_r <= cfg_read_count_r + 32'd1;
                if (cfg_index_r < 10'd512) begin
                    cfg_weight_read_count_r <= cfg_weight_read_count_r + 32'd1;
                end else if (cfg_index_r < 10'd576) begin
                    bias[cfg_index_r[5:0]] <= $signed(cfg_rd_data);
                end else if (cfg_index_r < 10'd640) begin
                    multiplier[cfg_index_r[5:0]] <= $signed(cfg_rd_data);
                end else begin
                    shift[cfg_index_r[5:0]] <= cfg_rd_data[5:0];
                end
                if (cfg_index_r == CFG_LAST_INDEX) begin
                    cfg_done_r <= 1'b1;
                    state <= ST_IDLE;
                end else begin
                    cfg_index_r <= cfg_index_r + 10'd1;
                    state <= ST_CFG_ISSUE;
                end
            end

            // Protocol faults are sticky, but do not disturb the valid/ready
            // data path.  A stalled producer therefore cannot be duplicated.
            if (dw_valid && run_active && !input_group_valid) begin
                error_r <= 1'b1;
                error_code_r <= error_code_r | 8'h02;
            end
            if (dw_valid && run_active && input_group_valid &&
                input_slot_existing && !input_tag_match) begin
                error_r <= 1'b1;
                error_code_r <= error_code_r | 8'h04;
            end
            if (dw_valid && run_active && (dw_row != expected_dw_row)) begin
                error_r <= 1'b1;
                error_code_r <= error_code_r | 8'h10;
            end
            if (dw_valid && run_active &&
                (dw_last != ((dw_pixel == LAST_PIXEL) && dw_group))) begin
                error_r <= 1'b1;
                error_code_r <= error_code_r | 8'h08;
            end
            // Retire the previous ingress entry first.  A full slot is not
            // exposed as READY until this commit edge, which is the explicit
            // one-cycle write/claim fence for the final DW slice.
            if (dw_commit_fire) begin
                dw_ingress_pending <= 1'b0;
            end

            // Capture the next DW vector at the same edge that commits the
            // old one.  Updating slot_seen at capture prevents duplicate
            // acceptance while the payload is in flight; activation BRAM
            // itself is written only by the registered commit entry.
            if (dw_fire) begin
                dw_ingress_pending <= 1'b1;
                dw_ingress_data <= dw_data;
                dw_ingress_row <= dw_row;
                dw_ingress_pixel <= dw_pixel;
                dw_ingress_group <= input_group;
                dw_ingress_local_pixel <= input_local_pixel;
                dw_ingress_slice <= dw_group;
                dw_ingress_context <= dw_context;
                dw_ingress_owner <= dw_owner;
                dw_ingress_epoch <= dw_epoch;
                dw_ingress_last <= dw_last;
                dw_ingress_final <=
                    ((input_seen | (16'h0001 << input_bit_index)) == 16'hffff);
                dw_vector_count_r <= dw_vector_count_r + 32'd1;
            end

            // Admit only the ordered target context, and only when a result
            // bank is free.  DSP PREG is reset at this claim edge; K=0 is
            // therefore the first product of a fresh 32-bit-equivalent sum.
            if (compute_pick_valid) begin
                compute_active <= 1'b1;
                compute_slot <= compute_pick_slot;
                compute_bank <= compute_pick_bank;
                compute_step <= 8'd0;
                bank_state[compute_pick_bank] <= BANK_COMPUTE;
                bank_group[compute_pick_bank] <= compute_pick_slot;
                bank_context[compute_pick_bank] <= target_context;
                bank_owner[compute_pick_bank] <= target_owner;
                bank_epoch[compute_pick_bank] <= target_epoch;
            end

            if (compute_active) begin
                pw_token_count_r <= pw_token_count_r + 32'd1;
                pw_mac_count_r <= pw_mac_count_r + 32'd64;
                // DSP PREG captures this token every cycle.  K=31 is held in
                // the DSP for one pending-drain edge; the following result
                // commit edge writes the now-stable P output to the bank.
                if (compute_step == 8'd255) begin
                    compute_active <= 1'b0;
                    last_pending <= 1'b1;
                end else begin
                    compute_step <= compute_step + 8'd1;
                end
            end

            if (last_pending) begin
                last_pending <= 1'b0;
                result_pending <= 1'b1;
            end

            if (result_pending) begin
                result_pending <= 1'b0;
                bank_state[compute_bank] <= BANK_READY;
            end

            // Start a drain only after the bank has reached READY.  The sink
            // remains a held valid transaction until its external handshake.
            if (output_pick_valid) begin
                output_active <= 1'b1;
                output_bank <= output_pick_bank;
                output_word <= 7'd0;
                bank_state[output_pick_bank] <= BANK_DRAIN;
            end

            if (sink_fire) begin
                output_word_count_r <= output_word_count_r + 32'd1;
                if (output_word == LAST_OUTPUT_WORD) begin
                    bank_state[output_bank] <= BANK_FREE;
                    output_active <= 1'b0;
                    if (output_word_count_r == expected_outputs - 32'd1) begin
                        done_r <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        next_output_group <= next_output_group + 6'd1;
                    end
                end else begin
                    output_word <= output_word + 7'd1;
                end
            end
        end
    end
endmodule

/*
 * One fixed local partition of the DS2 context ledger.
 *
 * There are four instances, each owning eight adjacent context groups.  The
 * selected-entry compares and all state/tag/seen updates stay inside the
 * instance.  The parent decodes group[4:3] only to select an instance; this
 * prevents Vivado from building one 32-entry dynamic array mux and keeps the
 * route-critical epoch/seen control local to an 8-entry bank.
 */
module ds12_stream_ds2_slot_ledger_bank #(
    parameter integer SLOTS = 8
) (
    input wire clk,
    input wire rst_n,
    input wire clear_slots,

    input wire input_query_valid,
    input wire [2:0] input_query_slot,
    input wire [1:0] input_query_context,
    input wire input_query_owner,
    input wire [31:0] input_query_epoch,
    input wire [3:0] input_query_bit,
    output reg [2:0] input_state,
    output reg [1:0] input_context,
    output reg input_owner,
    output reg [31:0] input_epoch,
    output reg [15:0] input_seen,
    output reg input_slot_existing,
    output reg input_tag_match,
    output reg input_slice_available,
    input wire stream_active,
    input wire ingress_available,
    input wire dw_valid,
    output wire input_ready,
    output wire input_fire,

    input wire target_query_valid,
    input wire [2:0] target_query_slot,
    output reg [2:0] target_state,
    output reg [1:0] target_context,
    output reg target_owner,
    output reg [31:0] target_epoch,
    output reg [3:0] active_count,

    input wire set_ready_valid,
    input wire [2:0] set_ready_slot,
    input wire set_compute_valid,
    input wire [2:0] set_compute_slot,
    input wire set_wait_valid,
    input wire [2:0] set_wait_slot,
    input wire release_valid,
    input wire [2:0] release_slot
);
    localparam [2:0] SLOT_IDLE = 3'd0;
    localparam [2:0] SLOT_FILL = 3'd1;
    localparam [2:0] SLOT_READY = 3'd2;
    localparam [2:0] SLOT_COMPUTE = 3'd3;
    localparam [2:0] SLOT_WAIT_OUT = 3'd4;

    reg [2:0] slot_state [0:SLOTS-1];
    reg [1:0] slot_context [0:SLOTS-1];
    reg slot_owner [0:SLOTS-1];
    reg [31:0] slot_epoch [0:SLOTS-1];
    reg [15:0] slot_seen [0:SLOTS-1];
    integer i;

    // Both query ports are local 8-entry muxes.  No parent-visible compare
    // fans out across all 32 contexts.
    always @* begin
        input_state = SLOT_IDLE;
        input_context = 2'd0;
        input_owner = 1'b0;
        input_epoch = 32'd0;
        input_seen = 16'd0;
        input_slot_existing = 1'b0;
        input_tag_match = 1'b0;
        input_slice_available = 1'b0;
        if (input_query_valid) begin
            input_state = slot_state[input_query_slot];
            input_context = slot_context[input_query_slot];
            input_owner = slot_owner[input_query_slot];
            input_epoch = slot_epoch[input_query_slot];
            input_seen = slot_seen[input_query_slot];
            input_slot_existing = (input_state != SLOT_IDLE);
            input_tag_match = !input_slot_existing ||
                ((input_context == input_query_context) &&
                 (input_owner == input_query_owner) &&
                 (input_epoch == input_query_epoch));
            input_slice_available = !input_seen[input_query_bit];
        end

        target_state = SLOT_IDLE;
        target_context = 2'd0;
        target_owner = 1'b0;
        target_epoch = 32'd0;
        if (target_query_valid) begin
            target_state = slot_state[target_query_slot];
            target_context = slot_context[target_query_slot];
            target_owner = slot_owner[target_query_slot];
            target_epoch = slot_epoch[target_query_slot];
        end

        active_count = 4'd0;
        for (i = 0; i < SLOTS; i = i + 1)
            if (slot_state[i] != SLOT_IDLE)
                active_count = active_count + 4'd1;
    end

    // Keep the handshake and its state update in this local bank.  The parent
    // only ORs the four one-hot results, so the epoch/tag/seen control cone
    // does not make a round trip through a global fill decoder.
    assign input_ready = stream_active && input_query_valid &&
                         ingress_available && input_tag_match &&
                         ((!input_slot_existing && input_state == SLOT_IDLE) ||
                          (input_slot_existing && input_state == SLOT_FILL &&
                           input_slice_available));
    assign input_fire = dw_valid && input_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < SLOTS; i = i + 1) begin
                slot_state[i] <= SLOT_IDLE;
                slot_context[i] <= 2'd0;
                slot_owner[i] <= 1'b0;
                slot_epoch[i] <= 32'd0;
                slot_seen[i] <= 16'd0;
            end
        end else begin
            // A run start is the only non-reset clear.  Tags intentionally
            // survive this fence exactly as in the original ledger; IDLE
            // entries ignore stale tags until their first slice establishes a
            // new owner/context/epoch tuple.
            if (clear_slots) begin
                for (i = 0; i < SLOTS; i = i + 1) begin
                    slot_state[i] <= SLOT_IDLE;
                    slot_seen[i] <= 16'd0;
                end
            end

            // These controls are mutually exclusive for a given entry in the
            // normal protocol.  Their order mirrors the old parent ledger's
            // nonblocking assignment order for the rare cross-entry overlap.
            if (set_ready_valid)
                slot_state[set_ready_slot] <= SLOT_READY;
            if (input_fire) begin
                if (!input_slot_existing) begin
                    slot_context[input_query_slot] <= input_query_context;
                    slot_owner[input_query_slot] <= input_query_owner;
                    slot_epoch[input_query_slot] <= input_query_epoch;
                    slot_state[input_query_slot] <= SLOT_FILL;
                end
                slot_seen[input_query_slot][input_query_bit] <= 1'b1;
            end
            if (set_compute_valid)
                slot_state[set_compute_slot] <= SLOT_COMPUTE;
            if (set_wait_valid)
                slot_state[set_wait_slot] <= SLOT_WAIT_OUT;
            if (release_valid) begin
                slot_state[release_slot] <= SLOT_IDLE;
                slot_seen[release_slot] <= 16'd0;
            end
        end
    end
endmodule

/*
 * One signed INT8 product plus A/B-input-registered PREG accumulator.  The synthesis branch is
 * intentionally an explicit DSP48E1 so the K feedback is the DSP's own P
 * register (internal P feedback), not an ordinary fabric register around a
 * multiplier.
 * The behavioral branch keeps the direct Verilator/XSim test independent of
 * the Vivado UNISIM library while matching the one-edge PREG update exactly.
 *
 * OPMODE=7'b0100001 selects X=M, Y=0, Z=P, hence P <= M + P using the
 * DSP's internal P feedback mux.  No PCIN cascade route is needed for the
 * self-accumulating lane.
 * The largest possible 32-term INT8 sum is 32*128*128=524288, well inside signed
 * 32 bits; truncating the signed 48-bit DSP P output to [31:0] is therefore
 * numerically equivalent for every legal activation/weight sequence.
 */
module ds12_stream_ds2_pw_dsp_accum (
    input wire clk,
    input wire reset_p,
    input wire ce,
    input wire signed [7:0] a_in,
    input wire signed [7:0] b_in,
    output wire signed [47:0] p_out
);
`ifdef SYNTHESIS
    wire signed [29:0] a_dsp = {{22{a_in[7]}}, a_in};
    wire signed [17:0] b_dsp = {{10{b_in[7]}}, b_in};
    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .USE_DPORT("FALSE"),
        .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .ACASCREG(1), .ADREG(0), .ALUMODEREG(0), .AREG(1), .BREG(1),
        .BCASCREG(1), .CARRYINREG(0), .CREG(0), .DREG(0),
        .INMODEREG(0), .MREG(0), .OPMODEREG(0), .PREG(1)
    ) u_dsp48e1_accum (
        .A(a_dsp), .B(b_dsp), .C(48'd0), .D(25'd0),
        .INMODE(5'b00000), .OPMODE(7'b0100001), .ALUMODE(4'b0000),
        .CARRYIN(1'b0), .CARRYINSEL(3'b000), .CLK(clk),
        .CEA1(ce), .CEA2(ce), .CEAD(1'b0), .CEALUMODE(1'b0),
        .CEB1(ce), .CEB2(ce), .CEC(1'b0), .CECARRYIN(1'b0),
        .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0),
        .CEP(ce), .RSTA(reset_p), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
        .RSTB(reset_p), .RSTC(1'b0), .RSTCTRL(1'b0), .RSTD(1'b0),
        .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(reset_p),
        .PCIN(48'd0), .P(p_out), .ACOUT(), .BCOUT(),
        .CARRYCASCIN(1'b0), .CARRYCASCOUT(), .CARRYOUT(),
        .MULTSIGNIN(1'b0), .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(),
        .PATTERNDETECT(), .PCOUT(), .UNDERFLOW()
    );
`else
    reg signed [47:0] p_reg;
    always @(posedge clk) begin
        if (reset_p)
            p_reg <= 48'sd0;
        else if (ce)
            p_reg <= p_reg + ($signed(a_in) * $signed(b_in));
    end
    assign p_out = p_reg;
`endif
endmodule

`default_nettype wire
