`timescale 1ns/1ps
`default_nettype none

/* One 64-MAC PW tile and two result-lifecycle banks for M1.1-A. */
module m11a_pw_mac_cell (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,
    input  wire               clear_acc,
    input  wire signed [7:0]  act_in,
    input  wire signed [7:0]  weight_in,
    output wire signed [47:0] sum_next
);
    m11a_dsp48e1_int8_accum u_dsp48e1 (
        .clk(clk), .rst_p(!rst_n), .ce(en), .clear_acc(clear_acc),
        .a_in(act_in), .b_in(weight_in), .p_out(sum_next)
    );
endmodule

module m11a_pw64_shared_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start_valid,
    output wire         start_ready,
    input  wire [1:0]   desc_layer,
    input  wire [5:0]   desc_cin,
    input  wire [6:0]   desc_cout,
    input  wire [31:0]  desc_sink_base,
    input  wire [31:0]  desc_pw_output_zero_point,
    input  wire [31:0]  desc_pw_activation_min,
    input  wire [31:0]  desc_pw_activation_max,

    input  wire [2047:0] pw_bias_bus,
    input  wire [2047:0] pw_multiplier_bus,
    input  wire [383:0]  pw_shift_bus,
    output wire         pw_row_rd_en,
    output wire [8:0]   pw_row_rd_addr,
    input  wire         pw_row_valid,
    input  wire [63:0]  pw_row_rd_data,

    input  wire         token_valid,
    output wire         token_ready,
    input  wire [63:0]  token_activation,
    input  wire [8:0]   token_weight_row,
    input  wire [2:0]   token_cout_tile,
    input  wire [5:0]   token_k,
    input  wire         token_first_k,
    input  wire         token_last_k,
    input  wire         token_last_tile,
    input  wire         token_last_layer,
    input  wire [1:0]   token_context,
    input  wire         token_owner,
    input  wire [31:0]  token_epoch,
    input  wire [31:0]  token_context_ordinal,

    output wire         out_valid,
    input  wire         out_ready,
    output wire [31:0]  out_addr,
    output wire [31:0]  out_data,
    output wire [3:0]   out_be,
    output wire [1:0]   out_context,
    output wire         out_owner,
    output wire [31:0]  out_epoch,
    output wire         out_last,

    output wire         done,
    output wire         error,
    output wire [31:0]  pw_token_count,
    output wire [31:0]  pw_mac_count,
    output wire [31:0]  out_word_count
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_RUN  = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;
    localparam [1:0] BANK_FREE = 2'd0;
    localparam [1:0] BANK_FILL = 2'd1;
    localparam [1:0] BANK_READY = 2'd2;
    localparam [1:0] BANK_DRAIN = 2'd3;

    reg [1:0] state;
    reg [1:0] layer_r;
    reg [5:0] cin_r;
    reg [6:0] cout_r;
    reg [31:0] sink_base_r;
    reg signed [31:0] pw_zp_r, pw_min_r, pw_max_r;
    reg [1:0] bank_state [0:1];
    reg bank_select_r;
    reg current_active;
    reg current_bank;
    reg current_last_tile;
    reg pending;
    reg pending_first, pending_last_k, pending_last_tile, pending_last_layer;
    reg [63:0] pending_activation;
    reg [2:0] pending_tile;
    reg [8:0] pending_row;
    reg [1:0] pending_context;
    reg pending_owner;
    reg [31:0] pending_epoch, pending_context_ordinal;
    reg final_token_done;
    /* The last K product becomes visible after the DSP PREG edge. */
    reg dsp_drain;
    reg dsp_drain_bank;

    reg signed [31:0] result_bank0 [0:63];
    reg signed [31:0] result_bank1 [0:63];
    reg [1:0] result_context [0:1];
    reg result_owner [0:1];
    reg [31:0] result_epoch [0:1];
    reg [31:0] result_context_ordinal [0:1];
    reg [2:0] result_tile [0:1];
    reg result_last_tile [0:1];
    reg result_last_layer [0:1];

    reg drain_active;
    reg drain_bank;
    reg [3:0] drain_word;
    reg [31:0] drain_addr_r;
    reg done_r, error_r;
    reg [31:0] token_count_r, mac_count_r, out_count_r;

    reg [127:0] rq_acc_bus, rq_bias_bus, rq_multiplier_bus;
    reg [23:0] rq_shift_bus;
    integer rq_lane;
    integer rq_chan;
    integer rq_idx;
    wire rq_bank = drain_bank;
    wire [3:0] rq_word_sel = (output_fire && (drain_word != 4'd15)) ?
                              (drain_word + 1'b1) : drain_word;
    wire rq_in_valid;
    wire rq_in_ready;
    wire rq_out_valid;
    wire [31:0] rq_out_data;

    wire token_fire = token_valid && token_ready;
    wire process_fire = pending && pw_row_valid;
    wire output_fire = out_valid && out_ready;
    wire bank0_free = (bank_state[0] == BANK_FREE);
    wire bank1_free = (bank_state[1] == BANK_FREE);
    wire free_any = bank0_free || bank1_free;
    wire alloc_bank = bank0_free ? 1'b0 : 1'b1;
    wire drain_start = !drain_active &&
                       ((bank_state[0] == BANK_READY) || (bank_state[1] == BANK_READY));

    assign start_ready = rst_n && state == ST_IDLE;
    assign token_ready = rst_n && state == ST_RUN && !pending &&
                         (current_active || free_any);
    assign pw_row_rd_en = token_fire;
    assign pw_row_rd_addr = token_weight_row;
    /* The RQ4 pipeline is the valid/data boundary.  It only accepts a new
     * word when the current word is absent or is being consumed, which gives
     * one-cycle startup latency and one-word-per-cycle steady-state drain. */
    /* Word 15 always terminates the current result bank.  A following bank
     * is launched by drain_start on the next edge, so never replay word 15
     * into the RQ pipeline at a bank boundary (that would present the old
     * tile's data under the new tile's metadata). */
    /* RQ4 now has an explicit multi-cycle pipeline and cannot accept the
     * next word on the same edge as an output.  Feed word 15 on the cycle
     * after word 14 is consumed; drain_active remains asserted until that
     * final word is emitted. */
    assign rq_in_valid = drain_active && rq_in_ready;
    assign out_valid = drain_active && rq_out_valid;
    assign out_addr = drain_addr_r;
    assign out_be = 4'hf;
    assign out_context = result_context[drain_bank];
    assign out_owner = result_owner[drain_bank];
    assign out_epoch = result_epoch[drain_bank];
    assign out_data = rq_out_data;
    assign out_last = drain_active && rq_out_valid &&
                      result_last_layer[drain_bank] && (drain_word == 4'd15);
    assign done = done_r;
    assign error = error_r;
    assign pw_token_count = token_count_r;
    assign pw_mac_count = mac_count_r;
    assign out_word_count = out_count_r;

    /* Select the four accumulators and quantization parameters for the
     * current drain word.  On a simultaneous output/input handshake the
     * next word is selected before the edge, so the RQ4 pipeline can sustain
     * one accepted word per cycle after its initial PREG latency. */
    always @* begin
        rq_acc_bus = 128'd0;
        rq_bias_bus = 128'd0;
        rq_multiplier_bus = 128'd0;
        rq_shift_bus = 24'd0;
        for (rq_lane = 0; rq_lane < 4; rq_lane = rq_lane + 1) begin
            rq_idx = {rq_word_sel[3:1],3'b000} +
                     {rq_word_sel[0],2'b0} + rq_lane;
            rq_chan = {result_tile[rq_bank],3'b000} +
                      {rq_word_sel[0],2'b0} + rq_lane;
            if (rq_bank)
                rq_acc_bus[rq_lane*32 +: 32] = result_bank1[rq_idx];
            else
                rq_acc_bus[rq_lane*32 +: 32] = result_bank0[rq_idx];
            rq_bias_bus[rq_lane*32 +: 32] = pw_bias_bus[rq_chan*32 +: 32];
            rq_multiplier_bus[rq_lane*32 +: 32] =
                pw_multiplier_bus[rq_chan*32 +: 32];
            rq_shift_bus[rq_lane*6 +: 6] = pw_shift_bus[rq_chan*6 +: 6];
        end
    end

    m11a_rq4 pwrq4 (
        .clk(clk), .rst_p(!rst_n), .in_valid(rq_in_valid),
        .in_ready(rq_in_ready), .acc_bus(rq_acc_bus), .bias_bus(rq_bias_bus),
        .multiplier_bus(rq_multiplier_bus), .shift_bus(rq_shift_bus),
        .zero_point(pw_zp_r), .activation_min(pw_min_r),
        .activation_max(pw_max_r), .out_valid(rq_out_valid),
        .out_ready(out_ready && drain_active), .out_data(rq_out_data)
    );

    wire signed [47:0] mac_sum_next [0:63];
    wire mac_en = process_fire;
    wire mac_clear = pending_first;
    genvar gp;
    generate
        for (gp = 0; gp < 64; gp = gp + 1) begin : GEN_PW64_MAC
            m11a_pw_mac_cell u_mac (
                .clk(clk), .rst_n(rst_n), .en(mac_en), .clear_acc(mac_clear),
                .act_in(pending_activation[(gp/8)*8 +: 8]),
                .weight_in(pw_row_rd_data[(gp%8)*8 +: 8]),
                .sum_next(mac_sum_next[gp])
            );
        end
    endgenerate

    integer i;
    reg [31:0] context_base_addr;
    reg [31:0] tile_base_addr;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            layer_r <= 0; cin_r <= 0; cout_r <= 0; sink_base_r <= 0;
            pw_zp_r <= 0; pw_min_r <= 0; pw_max_r <= 127;
            bank_state[0] <= BANK_FREE; bank_state[1] <= BANK_FREE;
            bank_select_r <= 0; current_active <= 0; current_bank <= 0;
            current_last_tile <= 0; pending <= 0; pending_first <= 0;
            pending_last_k <= 0; pending_last_tile <= 0; pending_activation <= 0;
            pending_last_layer <= 0;
            pending_tile <= 0; pending_row <= 0; pending_context <= 0;
            pending_owner <= 0; pending_epoch <= 0; pending_context_ordinal <= 0;
            dsp_drain <= 1'b0;
            dsp_drain_bank <= 1'b0;
            final_token_done <= 0; drain_active <= 0; drain_bank <= 0;
            drain_word <= 0; drain_addr_r <= 0; done_r <= 0; error_r <= 0;
            token_count_r <= 0; mac_count_r <= 0; out_count_r <= 0;
            for (i = 0; i < 64; i = i + 1) begin
                result_bank0[i] <= 0;
                result_bank1[i] <= 0;
            end
            for (i = 0; i < 2; i = i + 1) begin
                result_context[i] <= 0;
                result_owner[i] <= 0;
                result_epoch[i] <= 0;
                result_context_ordinal[i] <= 0;
                result_tile[i] <= 0;
                result_last_tile[i] <= 0;
                result_last_layer[i] <= 0;
            end
        end else begin
            if (start_valid && start_ready) begin
                state <= ST_RUN;
                layer_r <= desc_layer;
                cin_r <= desc_cin;
                cout_r <= desc_cout;
                sink_base_r <= desc_sink_base;
                pw_zp_r <= $signed(desc_pw_output_zero_point);
                pw_min_r <= $signed(desc_pw_activation_min);
                pw_max_r <= $signed(desc_pw_activation_max);
                bank_state[0] <= BANK_FREE;
                bank_state[1] <= BANK_FREE;
                current_active <= 0;
                pending <= 0;
                dsp_drain <= 1'b0;
                dsp_drain_bank <= 1'b0;
                drain_active <= 0;
                final_token_done <= 0;
                done_r <= 0;
                error_r <= 0;
                token_count_r <= 0;
                mac_count_r <= 0;
                out_count_r <= 0;
            end

            if (token_fire) begin
                pending <= 1'b1;
                pending_first <= token_first_k;
                pending_last_k <= token_last_k;
                pending_last_tile <= token_last_tile;
                pending_last_layer <= token_last_layer;
                pending_activation <= token_activation;
                pending_tile <= token_cout_tile;
                pending_row <= token_weight_row;
                pending_context <= token_context;
                pending_owner <= token_owner;
                pending_epoch <= token_epoch;
                pending_context_ordinal <= token_context_ordinal;
                token_count_r <= token_count_r + 1'b1;
                if (token_first_k) begin
                    if (free_any) begin
                        current_bank <= alloc_bank;
                        current_active <= 1'b1;
                        bank_state[alloc_bank] <= BANK_FILL;
                    end else begin
                        error_r <= 1'b1;
                    end
                end
            end

            if (process_fire) begin
                pending <= 1'b0;
                mac_count_r <= mac_count_r + 32'd64;
                if (pending_last_k) begin
                    /* The PREG output contains the final product only after
                     * this edge.  Commit it on the following edge, while a
                     * new K token may already be accepted into the same
                     * 64-lane physical array. */
                    dsp_drain <= 1'b1;
                    dsp_drain_bank <= current_bank;
                    current_active <= 1'b0;
                end
            end

            if (dsp_drain) begin
                dsp_drain <= 1'b0;
                if (dsp_drain_bank)
                    for (i = 0; i < 64; i = i + 1) result_bank1[i] <= mac_sum_next[i][31:0];
                else
                    for (i = 0; i < 64; i = i + 1) result_bank0[i] <= mac_sum_next[i][31:0];
                result_context[dsp_drain_bank] <= pending_context;
                result_owner[dsp_drain_bank] <= pending_owner;
                result_epoch[dsp_drain_bank] <= pending_epoch;
                result_context_ordinal[dsp_drain_bank] <= pending_context_ordinal;
                result_tile[dsp_drain_bank] <= pending_tile;
                result_last_tile[dsp_drain_bank] <= pending_last_tile;
                result_last_layer[dsp_drain_bank] <= pending_last_layer;
                bank_state[dsp_drain_bank] <= BANK_READY;
                if (pending_last_layer)
                    final_token_done <= 1'b1;
            end

            if (drain_start) begin
                drain_active <= 1'b1;
                drain_bank <= (bank_state[0] == BANK_READY) ? 1'b0 : 1'b1;
                drain_word <= 0;
                bank_state[(bank_state[0] == BANK_READY) ? 1'b0 : 1'b1] <= BANK_DRAIN;
                if (bank_state[0] == BANK_READY) begin
                    context_base_addr <= sink_base_r +
                        (result_context_ordinal[0] << ((layer_r == 2'd1) ? 8 : 9));
                    drain_addr_r <= sink_base_r +
                        (result_context_ordinal[0] << ((layer_r == 2'd1) ? 8 : 9)) +
                        /* Each eight-output tile drains 8 pixels x 8 bytes =
                         * 64 bytes (16 four-byte sink words). */
                        (result_tile[0] << 6);
                end else begin
                    context_base_addr <= sink_base_r +
                        (result_context_ordinal[1] << ((layer_r == 2'd1) ? 8 : 9));
                    drain_addr_r <= sink_base_r +
                        (result_context_ordinal[1] << ((layer_r == 2'd1) ? 8 : 9)) +
                        (result_tile[1] << 6);
                end
            end

            if (output_fire) begin
                out_count_r <= out_count_r + 1'b1;
                if (drain_word == 4'd15) begin
                    bank_state[drain_bank] <= BANK_FREE;
                    drain_active <= 1'b0;
                    if (result_last_layer[drain_bank] && final_token_done) begin
                        done_r <= 1'b1;
                        state <= ST_DONE;
                    end
                end else begin
                    drain_word <= drain_word + 1'b1;
                    drain_addr_r <= drain_addr_r + 32'd4;
                end
            end
        end
    end
endmodule

`default_nettype wire
