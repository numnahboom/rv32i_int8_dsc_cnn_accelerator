`timescale 1ns/1ps
`default_nettype none

// The only pointwise engine used by the DS1 -> DS2 shared slice.
//
// A token represents one 8-pixel x 8-output tile for one K value.  The
// activation and weight vectors are deliberately kept at the boundary: the
// adapters do not contain pointwise accumulators or a MAC array.  This block
// owns the active packed PW weight/RQ view, one 64-lane accumulator island,
// and two result lifecycle banks.  A result bank is filled by the MAC island
// and drained independently, so a sink stall never changes a valid result.
module ds12_shared_pw_mac_lane (
    input  wire clk,
    input  wire reset_p,
    input  wire ce,
    input  wire signed [7:0] a_in,
    input  wire signed [7:0] b_in,
    output wire signed [31:0] p_out
);
    reg signed [31:0] p_reg;
    always @(posedge clk) begin
        if (reset_p)
            p_reg <= 32'sd0;
        else if (ce)
            p_reg <= p_reg + ($signed(a_in) * $signed(b_in));
    end
    assign p_out = p_reg;
endmodule

module ds12_shared_pw_service #(
    parameter [31:0] DS1_SINK_BASE = 32'h0010_0000,
    parameter [31:0] DS2_SINK_BASE = 32'h0020_0000
) (
    input wire clk,
    input wire rst_n,

    // Broadcast configuration stream.  The config port serializes external
    // traffic; this block captures only PW words and keeps one active view.
    input wire cfg_word_valid,
    output wire cfg_word_ready,
    input wire [1:0] cfg_word_layer,
    input wire [9:0] cfg_word_index,
    input wire [31:0] cfg_word_data,

    // Non-preemptive layer fence from the scheduler.
    input wire layer_start_valid,
    output wire layer_start_ready,
    input wire [1:0] layer_start_layer,
    output wire layer_done,

    // Unified pointwise token boundary.
    input wire token_valid,
    output wire token_ready,
    input wire [1:0] token_layer,
    input wire [1:0] token_context,
    input wire token_owner,
    input wire [31:0] token_epoch,
    input wire [2:0] token_cout_tile,
    input wire [5:0] token_k,
    input wire [63:0] token_activation,
    input wire [63:0] token_weight,
    input wire token_last_k,
    input wire token_last_tile,

    // Weight lookup is owned by this block.  Adapters use it to put the
    // weight half of the token on the same boundary as the activation half.
    input wire weight_query_valid,
    input wire [1:0] weight_query_layer,
    input wire [2:0] weight_query_tile,
    input wire [5:0] weight_query_k,
    output reg [63:0] weight_query_data,

    // One shared result sink.  The top-level adapter selects DS1/DS2 ready.
    output wire sink_valid,
    input wire sink_ready,
    output wire sink_layer,
    output wire [31:0] sink_addr,
    output wire [31:0] sink_data,
    output wire [3:0] sink_be,
    output wire sink_last,

    output reg error,
    output reg [7:0] error_code,
    output reg [31:0] pw_token_count,
    output reg [31:0] pw_mac_count,
    output reg [31:0] output_word_count,
    output reg [31:0] ds1_pw_token_count,
    output reg [31:0] ds2_pw_token_count,
    output reg [31:0] ds1_pw_mac_count,
    output reg [31:0] ds2_pw_mac_count,
    output reg [31:0] ds1_output_word_count,
    output reg [31:0] ds2_output_word_count
);
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_RUN = 3'd1;
    localparam [2:0] ST_PREP = 3'd2;
    localparam [2:0] ST_MAC = 3'd3;
    localparam [2:0] ST_WAIT_TOKEN = 3'd4;
    localparam [2:0] ST_CAPTURE = 3'd5;

    localparam [1:0] BANK_FREE = 2'd0;
    localparam [1:0] BANK_COMPUTE = 2'd1;
    localparam [1:0] BANK_READY = 2'd2;
    localparam [1:0] BANK_DRAIN = 2'd3;

    reg [2:0] state;
    reg [1:0] active_layer;
    reg layer_done_r;

    // 512 packed words is the largest PW matrix (DS2: 32 x 64 INT8).  The
    // array is intentionally a single block-RAM-shaped object.  DS1 uses
    // the first 128 words; the next layer load replaces the active view.
    (* ram_style = "block" *) reg [31:0] pw_weight_mem [0:511];
    reg signed [31:0] rq_bias [0:63];
    reg signed [31:0] rq_multiplier [0:63];
    reg [5:0] rq_shift [0:63];

    // One physical 64-lane MAC island.  The two lifecycle banks below hold
    // only completed 8x8 result tiles, not a layer-sized accumulator store.
    wire signed [31:0] mac_p [0:63];
    reg signed [7:0] cur_activation [0:7];
    reg signed [7:0] cur_weight [0:7];
    reg mac_reset_p;
    wire mac_ce = (state == ST_MAC);

    genvar gp, go;
    generate
        for (gp = 0; gp < 8; gp = gp + 1) begin : GEN_MAC_PIXEL
            for (go = 0; go < 8; go = go + 1) begin : GEN_MAC_COUT
                ds12_shared_pw_mac_lane u_mac (
                    .clk(clk), .reset_p(mac_reset_p), .ce(mac_ce),
                    .a_in(cur_activation[gp]), .b_in(cur_weight[go]),
                    .p_out(mac_p[gp*8+go])
                );
            end
        end
    endgenerate

    reg [1:0] result_state [0:1];
    reg signed [31:0] result_bank0 [0:63];
    reg signed [31:0] result_bank1 [0:63];
    reg [1:0] result_layer [0:1];
    reg [1:0] result_context [0:1];
    reg result_owner [0:1];
    reg [31:0] result_epoch [0:1];
    reg [2:0] result_tile [0:1];
    reg result_last_tile [0:1];

    reg compute_bank;
    reg cur_last_k;
    reg cur_last_tile;
    reg [1:0] cur_layer;
    reg [1:0] cur_context;
    reg cur_owner;
    reg [31:0] cur_epoch;
    reg [2:0] cur_tile;
    reg [5:0] cur_k;
    reg have_cur_token;
    reg mac_ready;

    reg drain_active;
    reg drain_bank;
    reg [3:0] drain_word;

    integer i;
    integer lane;
    integer cfg_word;
    integer weight_byte;
    integer weight_word;
    integer weight_lane;
    integer output_lane;
    integer output_index;
    reg free_found;
    reg free_sel;
    reg ready_found;
    reg ready_sel;
    reg signed [31:0] acc_word [0:3];
    reg [7:0] qbyte [0:3];

    wire cfg_fire = cfg_word_valid && cfg_word_ready;
    wire start_fire = layer_start_valid && layer_start_ready;
    wire token_fire = token_valid && token_ready;
    wire sink_fire = sink_valid && sink_ready;

    assign cfg_word_ready = rst_n;
    // After the final sink word the service is quiescent but remains in the
    // run state so layer_done is observable.  That quiescent fence is also a
    // legal point to accept the next non-preemptive layer descriptor.
    assign layer_start_ready = rst_n &&
        ((state == ST_IDLE) ||
         (state == ST_RUN && layer_done_r && !drain_active && !have_cur_token));
    assign layer_done = layer_done_r;

    // A first token claims a free result bank.  Once claimed, the one shared
    // MAC island consumes the tile's K stream; a missing token is handled by
    // ST_WAIT_TOKEN, so valid payload stability is preserved under BP.
    always @* begin
        free_found = 1'b0;
        free_sel = 1'b0;
        ready_found = 1'b0;
        ready_sel = 1'b0;
        for (i = 0; i < 2; i = i + 1) begin
            if (!free_found && result_state[i] == BANK_FREE) begin
                free_found = 1'b1;
                free_sel = i[0:0];
            end
            if (!ready_found && result_state[i] == BANK_READY) begin
                ready_found = 1'b1;
                ready_sel = i[0:0];
            end
        end
    end

    assign token_ready = rst_n && (active_layer == token_layer) &&
                         ((state == ST_RUN && free_found) ||
                          (state == ST_MAC && !cur_last_k) ||
                          (state == ST_WAIT_TOKEN));

    // Central PW lookup.  The adapter's token carries this result unchanged;
    // the service also retains the matrix so the ownership is visible in the
    // elaborated hierarchy and on the synth RAM inference path.
    always @* begin
        weight_query_data = 64'd0;
        weight_byte = 0;
        weight_word = 0;
        weight_lane = 0;
        if (weight_query_valid) begin
            for (lane = 0; lane < 8; lane = lane + 1) begin
                weight_byte = ((weight_query_tile * 8) + lane) *
                              ((weight_query_layer == 2'd1) ? 16 : 32) +
                              weight_query_k;
                weight_word = weight_byte >> 2;
                weight_lane = weight_byte & 3;
                weight_query_data[lane*8 +: 8] =
                    pw_weight_mem[weight_word][weight_lane*8 +: 8];
            end
        end
    end

    // Result sink combinational view.  The bank arrays are read only while a
    // bank is in DRAIN, making all fields stable for an arbitrarily long
    // ready-low interval.
    wire [1:0] drain_layer = result_layer[drain_bank];
    wire [1:0] drain_context_tag = result_context[drain_bank];
    wire drain_owner_tag = result_owner[drain_bank];
    wire [31:0] drain_epoch_tag = result_epoch[drain_bank];
    wire [2:0] drain_tile_tag = result_tile[drain_bank];
    wire [31:0] drain_ordinal = (drain_epoch_tag << 1) +
                                 {{31{1'b0}}, drain_owner_tag};
    wire [31:0] drain_pixel = (drain_ordinal * 32'd8) +
                              {{29{1'b0}}, drain_word[3:1]};
    wire [31:0] drain_words_per_pixel = (drain_layer == 2'd1) ? 32'd8 : 32'd16;
    wire [31:0] drain_word_local = {29'd0, drain_word};
    wire [31:0] drain_word_index = (drain_pixel * drain_words_per_pixel) +
                                    (drain_tile_tag * 32'd2) +
                                    (drain_word_local[0]);
    wire [31:0] drain_addr = ((drain_layer == 2'd1) ? DS1_SINK_BASE : DS2_SINK_BASE) +
                              (drain_word_index * 32'd4);

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
            // C0 PW output zero point is zero and activation range is
            // 0..127 for both layers.
            if (q < 0) q = 0;
            if (q > 127) q = 127;
            requant = q[7:0];
        end
    endfunction

    always @* begin
        for (output_lane = 0; output_lane < 4; output_lane = output_lane + 1) begin
            output_index = (drain_word[3:1] * 8) + output_lane +
                           (drain_word[0] * 8);
            if (!drain_bank)
                acc_word[output_lane] = result_bank0[(drain_word[3:1] * 8) + output_lane +
                                                     (drain_word[0] * 8)];
            else
                acc_word[output_lane] = result_bank1[(drain_word[3:1] * 8) + output_lane +
                                                     (drain_word[0] * 8)];
            qbyte[output_lane] = requant(acc_word[output_lane],
                                         rq_bias[(drain_tile_tag * 8) +
                                                 (drain_word[0] * 4) + output_lane],
                                         rq_multiplier[(drain_tile_tag * 8) +
                                                       (drain_word[0] * 4) + output_lane],
                                         rq_shift[(drain_tile_tag * 8) +
                                                  (drain_word[0] * 4) + output_lane]);
        end
    end

    assign sink_valid = drain_active;
    assign sink_layer = (drain_layer == 2'd2);
    assign sink_addr = drain_addr;
    assign sink_data = {qbyte[3], qbyte[2], qbyte[1], qbyte[0]};
    assign sink_be = 4'hf;
    assign sink_last = drain_active &&
        ((drain_layer == 2'd1 && drain_ordinal == 32'd127 &&
          drain_tile_tag == 3'd3 && drain_word == 4'd15) ||
         (drain_layer == 2'd2 && drain_ordinal == 32'd159 &&
          drain_tile_tag == 3'd7 && drain_word == 4'd15));

    // Store configuration words and service state.  DS1 PW begins at packed
    // index 84; DS2 PW begins at packed index 168.
    always @(posedge clk) begin
        mac_reset_p <= 1'b0;
        if (!rst_n) begin
            state <= ST_IDLE;
            active_layer <= 2'd0;
            layer_done_r <= 1'b0;
            error <= 1'b0;
            error_code <= 8'd0;
            pw_token_count <= 0;
            pw_mac_count <= 0;
            output_word_count <= 0;
            ds1_pw_token_count <= 0;
            ds2_pw_token_count <= 0;
            ds1_pw_mac_count <= 0;
            ds2_pw_mac_count <= 0;
            ds1_output_word_count <= 0;
            ds2_output_word_count <= 0;
            compute_bank <= 0;
            cur_last_k <= 0;
            cur_last_tile <= 0;
            cur_layer <= 0;
            cur_context <= 0;
            cur_owner <= 0;
            cur_epoch <= 0;
            cur_tile <= 0;
            cur_k <= 0;
            have_cur_token <= 0;
            mac_ready <= 1'b0;
            drain_active <= 0;
            drain_bank <= 0;
            drain_word <= 0;
            for (i = 0; i < 2; i = i + 1) begin
                result_state[i] <= BANK_FREE;
                result_layer[i] <= 0;
                result_context[i] <= 0;
                result_owner[i] <= 0;
                result_epoch[i] <= 0;
                result_tile[i] <= 0;
                result_last_tile[i] <= 0;
            end
            for (i = 0; i < 64; i = i + 1) begin
                rq_bias[i] <= 0;
                rq_multiplier[i] <= 0;
                rq_shift[i] <= 0;
            end
        end else begin
            // Config is accepted even while idle only.  The scheduler fences
            // layer loads, so replacing the active PW view cannot race a MAC.
            if (cfg_fire) begin
                if (cfg_word_layer == 2'd1 && cfg_word_index >= 10'd84) begin
                    cfg_word = cfg_word_index - 84;
                    if (cfg_word < 128)
                        pw_weight_mem[cfg_word] <= cfg_word_data;
                    else if (cfg_word < 160)
                        rq_bias[cfg_word-128] <= $signed(cfg_word_data);
                    else if (cfg_word < 192)
                        rq_multiplier[cfg_word-160] <= $signed(cfg_word_data);
                    else if (cfg_word < 224)
                        rq_shift[cfg_word-192] <= cfg_word_data[5:0];
                end else if (cfg_word_layer == 2'd2 && cfg_word_index >= 10'd168) begin
                    cfg_word = cfg_word_index - 168;
                    if (cfg_word < 512)
                        pw_weight_mem[cfg_word] <= cfg_word_data;
                    else if (cfg_word < 576)
                        rq_bias[cfg_word-512] <= $signed(cfg_word_data);
                    else if (cfg_word < 640)
                        rq_multiplier[cfg_word-576] <= $signed(cfg_word_data);
                    else if (cfg_word < 704)
                        rq_shift[cfg_word-640] <= cfg_word_data[5:0];
                end
            end

            if (start_fire) begin
                active_layer <= layer_start_layer;
                layer_done_r <= 1'b0;
                state <= ST_RUN;
                have_cur_token <= 1'b0;
                mac_ready <= 1'b0;
                drain_active <= 1'b0;
                drain_word <= 0;
                for (i = 0; i < 2; i = i + 1)
                    result_state[i] <= BANK_FREE;
            end

            // Launch a result drain whenever a ready bank is available.  The
            // sink valid/data registers are entirely bank-derived and hence
            // remain stable while sink_ready is low.
            if (!drain_active && ready_found) begin
                drain_active <= 1'b1;
                drain_bank <= ready_sel;
                drain_word <= 0;
                result_state[ready_sel] <= BANK_DRAIN;
            end

            if (state == ST_RUN && !have_cur_token && token_fire) begin
                // Claim a bank with the descriptor carried by K=0.  A token
                // that starts in the middle of a K stream is reported but is
                // still consumed, avoiding a protocol deadlock.
                compute_bank <= free_sel;
                result_state[free_sel] <= BANK_COMPUTE;
                result_layer[free_sel] <= token_layer;
                result_context[free_sel] <= token_context;
                result_owner[free_sel] <= token_owner;
                result_epoch[free_sel] <= token_epoch;
                result_tile[free_sel] <= token_cout_tile;
                result_last_tile[free_sel] <= token_last_tile;
                cur_layer <= token_layer;
                cur_context <= token_context;
                cur_owner <= token_owner;
                cur_epoch <= token_epoch;
                cur_tile <= token_cout_tile;
                cur_k <= token_k;
                cur_last_k <= token_last_k;
                cur_last_tile <= token_last_tile;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    cur_activation[lane] <= $signed(token_activation[lane*8 +: 8]);
                    cur_weight[lane] <= $signed(token_weight[lane*8 +: 8]);
                end
                if (token_k != 0)
                    error_code <= error_code | 8'h01;
                state <= mac_ready ? ST_MAC : ST_PREP;
                have_cur_token <= 1'b1;
            end else if (state == ST_PREP) begin
                mac_reset_p <= 1'b1;
                mac_ready <= 1'b1;
                state <= ST_MAC;
            end else if (state == ST_MAC && have_cur_token) begin
                pw_token_count <= pw_token_count + 1'b1;
                pw_mac_count <= pw_mac_count + 32'd64;
                if (active_layer == 2'd1) begin
                    ds1_pw_token_count <= ds1_pw_token_count + 1'b1;
                    ds1_pw_mac_count <= ds1_pw_mac_count + 32'd64;
                end else if (active_layer == 2'd2) begin
                    ds2_pw_token_count <= ds2_pw_token_count + 1'b1;
                    ds2_pw_mac_count <= ds2_pw_mac_count + 32'd64;
                end
                if (cur_last_k) begin
                    // The MAC lane outputs still contain the K-1 sum at this
                    // edge.  Include the final product explicitly, publish
                    // the result bank immediately, and reset the same DSP
                    // registers for the next tile.  This removes a separate
                    // capture/reset bubble from every tile after the first.
                    for (lane = 0; lane < 64; lane = lane + 1) begin
                        if (!compute_bank)
                            result_bank0[lane] <= mac_p[lane] +
                                ($signed(cur_activation[lane/8]) * $signed(cur_weight[lane%8]));
                        else
                            result_bank1[lane] <= mac_p[lane] +
                                ($signed(cur_activation[lane/8]) * $signed(cur_weight[lane%8]));
                    end
                    result_state[compute_bank] <= BANK_READY;
                    mac_reset_p <= 1'b1;
                    mac_ready <= 1'b1;
                    have_cur_token <= 1'b0;
                    state <= ST_RUN;
                end else if (token_fire) begin
                    if (token_layer != cur_layer || token_context != cur_context ||
                        token_owner != cur_owner || token_epoch != cur_epoch ||
                        token_cout_tile != cur_tile || token_k != (cur_k + 1'b1))
                        error_code <= error_code | 8'h02;
                    cur_layer <= token_layer;
                    cur_context <= token_context;
                    cur_owner <= token_owner;
                    cur_epoch <= token_epoch;
                    cur_tile <= token_cout_tile;
                    cur_k <= token_k;
                    cur_last_k <= token_last_k;
                    cur_last_tile <= token_last_tile;
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        cur_activation[lane] <= $signed(token_activation[lane*8 +: 8]);
                        cur_weight[lane] <= $signed(token_weight[lane*8 +: 8]);
                    end
                end else begin
                    have_cur_token <= 1'b0;
                    state <= ST_WAIT_TOKEN;
                end
            end else if (state == ST_WAIT_TOKEN && token_fire) begin
                cur_layer <= token_layer;
                cur_context <= token_context;
                cur_owner <= token_owner;
                cur_epoch <= token_epoch;
                cur_tile <= token_cout_tile;
                cur_k <= token_k;
                cur_last_k <= token_last_k;
                cur_last_tile <= token_last_tile;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    cur_activation[lane] <= $signed(token_activation[lane*8 +: 8]);
                    cur_weight[lane] <= $signed(token_weight[lane*8 +: 8]);
                end
                have_cur_token <= 1'b1;
                state <= ST_MAC;
            end

            if (sink_fire) begin
                output_word_count <= output_word_count + 1'b1;
                if (drain_layer == 2'd1)
                    ds1_output_word_count <= ds1_output_word_count + 1'b1;
                else if (drain_layer == 2'd2)
                    ds2_output_word_count <= ds2_output_word_count + 1'b1;
                if (drain_word == 4'd15) begin
                    result_state[drain_bank] <= BANK_FREE;
                    drain_active <= 1'b0;
                    if (sink_last)
                        layer_done_r <= 1'b1;
                end else begin
                    drain_word <= drain_word + 1'b1;
                end
            end

            if (error_code != 0)
                error <= 1'b1;
        end
    end
endmodule

`default_nettype wire
