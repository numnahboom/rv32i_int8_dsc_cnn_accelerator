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
    output wire signed [31:0] sum_next
);
    reg signed [31:0] acc_reg;
    wire signed [15:0] product = act_in * weight_in;
    assign sum_next = clear_acc ? {{16{product[15]}}, product} :
                      (acc_reg + {{16{product[15]}}, product});
    always @(posedge clk) begin
        if (!rst_n)
            acc_reg <= 32'sd0;
        else if (en)
            acc_reg <= sum_next;
    end
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
    assign out_valid = drain_active;
    assign out_addr = drain_addr_r;
    assign out_be = 4'hf;
    assign out_context = result_context[drain_bank];
    assign out_owner = result_owner[drain_bank];
    assign out_epoch = result_epoch[drain_bank];
    assign out_last = drain_active && result_last_layer[drain_bank] && (drain_word == 4'd15);
    assign done = done_r;
    assign error = error_r;
    assign pw_token_count = token_count_r;
    assign pw_mac_count = mac_count_r;
    assign out_word_count = out_count_r;

    function automatic signed [7:0] requant_pw;
        input signed [31:0] acc_value;
        input signed [31:0] bias_value;
        input signed [31:0] multiplier_value;
        input [5:0] shift_value;
        reg signed [32:0] x;
        reg signed [64:0] product;
        reg signed [64:0] magnitude;
        reg signed [64:0] rounded;
        reg signed [64:0] shifted;
        reg signed [64:0] q;
        begin
            x = acc_value + bias_value;
            product = x * multiplier_value;
            if (product < 0) begin
                magnitude = -product;
                rounded = -((magnitude + 65'sd1073741824) >>> 31);
            end else begin
                rounded = (product + 65'sd1073741824) >>> 31;
            end
            shifted = rounded >>> shift_value;
            q = shifted + pw_zp_r;
            if (q > 65'sd127) q = 65'sd127;
            if (q < -65'sd128) q = -65'sd128;
            if (q < pw_min_r) q = pw_min_r;
            if (q > pw_max_r) q = pw_max_r;
            requant_pw = q[7:0];
        end
    endfunction

    reg [31:0] rq_word;
    integer rq_lane;
    integer rq_chan;
    integer rq_idx;
    reg signed [31:0] rq_acc_i, rq_bias_i, rq_mul_i;
    reg [5:0] rq_shift_i;
    always @* begin
        rq_word = 32'd0;
        for (rq_lane = 0; rq_lane < 4; rq_lane = rq_lane + 1) begin
            rq_idx = {drain_word[3:1],3'b000} + {drain_word[0],2'b0} + rq_lane;
            rq_chan = {result_tile[drain_bank],3'b000} + {drain_word[0],2'b0} + rq_lane;
                /* Each result word carries four lanes.  The low/high word
                 * of a pixel pair selects lanes 0..3/4..7; the bit-0 term
                 * is therefore a four-entry stride, not an eight-entry
                 * stride.  The old 3'b000 concatenation skipped the upper
                 * half of every eight-lane pixel and made Vivado remove 32
                 * of the 64 PW MAC cells as unobserved. */
                if (drain_bank)
                    rq_acc_i = result_bank1[{drain_word[3:1],3'b000} + rq_lane +
                                       {drain_word[0],2'b0}];
                else
                    rq_acc_i = result_bank0[{drain_word[3:1],3'b000} + rq_lane +
                                       {drain_word[0],2'b0}];
            rq_bias_i = pw_bias_bus[rq_chan*32 +: 32];
            rq_mul_i = pw_multiplier_bus[rq_chan*32 +: 32];
            rq_shift_i = pw_shift_bus[rq_chan*6 +: 6];
            rq_word[rq_lane*8 +: 8] = requant_pw(rq_acc_i, rq_bias_i, rq_mul_i, rq_shift_i);
        end
    end
    assign out_data = rq_word;

    wire signed [31:0] mac_sum_next [0:63];
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
                    if (current_bank)
                        for (i = 0; i < 64; i = i + 1) result_bank1[i] <= mac_sum_next[i];
                    else
                        for (i = 0; i < 64; i = i + 1) result_bank0[i] <= mac_sum_next[i];
                    result_context[current_bank] <= pending_context;
                    result_owner[current_bank] <= pending_owner;
                    result_epoch[current_bank] <= pending_epoch;
                    result_context_ordinal[current_bank] <= pending_context_ordinal;
                    result_tile[current_bank] <= pending_tile;
                    result_last_tile[current_bank] <= pending_last_tile;
                    result_last_layer[current_bank] <= pending_last_layer;
                    bank_state[current_bank] <= BANK_READY;
                    current_active <= 1'b0;
                    if (pending_last_layer)
                        final_token_done <= 1'b1;
                end
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
