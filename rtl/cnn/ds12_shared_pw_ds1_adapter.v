`timescale 1ns/1ps
`default_nettype none

// DS1 DW-to-PW adapter. Four bounded context slots let the depthwise
// endpoint continue while the single shared PW service drains another
// context. No PW accumulation, result bank, or MAC array is present here.
module ds12_shared_pw_ds1_adapter #(
    parameter [31:0] INPUT_BASE = 32'd0,
    parameter integer CONTEXTS = 4
) (
    input wire clk, input wire rst_n,
    input wire cfg_word_valid, output wire cfg_word_ready,
    input wire [1:0] cfg_word_layer, input wire [9:0] cfg_word_index,
    input wire [31:0] cfg_word_data,
    input wire start, output wire ready, output wire done,
    output wire input_mem_req_valid, input wire input_mem_req_ready,
    output wire input_mem_req_write, output wire [31:0] input_mem_req_addr,
    output wire [127:0] input_mem_req_wdata, output wire [15:0] input_mem_req_strb,
    output wire [1:0] input_mem_req_context, output wire input_mem_req_owner,
    output wire [31:0] input_mem_req_epoch, input wire input_mem_resp_valid,
    input wire [127:0] input_mem_resp_data,
    output wire token_valid, input wire token_ready,
    output wire [1:0] token_layer, output wire [1:0] token_context,
    output wire token_owner, output wire [31:0] token_epoch,
    output wire [2:0] token_cout_tile, output wire [5:0] token_k,
    output reg [63:0] token_activation, input wire [63:0] token_weight,
    output wire token_last_k, output wire token_last_tile,
    output wire weight_query_valid, output wire [1:0] weight_query_layer,
    output wire [2:0] weight_query_tile, output wire [5:0] weight_query_k,
    output wire [31:0] dw_mac_count, output wire error
);
    localparam [1:0] ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_DONE = 2'd2;
    reg [1:0] state;
    reg cfg_loaded;
    reg signed [7:0] activation_context [0:CONTEXTS-1][0:7][0:15];
    reg ctx_active [0:CONTEXTS-1];
    reg ctx_ready [0:CONTEXTS-1];
    reg [6:0] ctx_ordinal [0:CONTEXTS-1];
    reg [7:0] ctx_seen [0:CONTEXTS-1];
    reg token_active;
    reg [1:0] token_slot;
    reg [2:0] cout_tile;
    reg [3:0] k_index;
    reg done_r;

    wire endpoint_cfg_ready;
    wire endpoint_cfg_valid = cfg_word_valid && cfg_word_ready;
    wire endpoint_start = start && ready;
    wire endpoint_dw_valid, endpoint_dw_ready;
    wire [127:0] endpoint_dw_data;
    wire [5:0] endpoint_dw_row;
    wire [9:0] endpoint_dw_pixel;
    wire [1:0] endpoint_dw_context;
    wire endpoint_dw_owner;
    wire [31:0] endpoint_dw_epoch;
    wire endpoint_dw_last, endpoint_done, endpoint_error;
    integer i, p, s, slot_i, ordinal_i;
    reg ready_found;
    reg [1:0] ready_sel;
    integer best_ordinal;

    assign cfg_word_ready = rst_n && !cfg_loaded && cfg_word_layer == 2'd1 &&
                            cfg_word_index < 10'd84 && endpoint_cfg_ready;
    assign ready = rst_n && cfg_loaded && state == ST_IDLE;
    assign done = done_r;

    ds12_shared_pw_ds1_dw_bram_endpoint #(.INPUT_BASE(INPUT_BASE)) dw_endpoint (
        .clk(clk), .rst_n(rst_n), .start(endpoint_start), .ready(),
        .cfg_valid(endpoint_cfg_valid), .cfg_ready(endpoint_cfg_ready),
        .cfg_data(cfg_word_data), .cfg_last(cfg_word_index == 10'd83),
        .mem_req_valid(input_mem_req_valid), .mem_req_ready(input_mem_req_ready),
        .mem_req_write(input_mem_req_write), .mem_req_addr(input_mem_req_addr),
        .mem_req_wdata(input_mem_req_wdata), .mem_req_strb(input_mem_req_strb),
        .mem_req_context(input_mem_req_context), .mem_req_owner(input_mem_req_owner),
        .mem_req_epoch(input_mem_req_epoch), .mem_resp_valid(input_mem_resp_valid),
        .mem_resp_rdata(input_mem_resp_data), .dw_valid(endpoint_dw_valid),
        .dw_ready(endpoint_dw_ready), .dw_data(endpoint_dw_data),
        .dw_row(endpoint_dw_row), .dw_pixel(endpoint_dw_pixel),
        .dw_context(endpoint_dw_context), .dw_owner(endpoint_dw_owner),
        .dw_epoch(endpoint_dw_epoch), .dw_last(endpoint_dw_last), .done(endpoint_done),
        .error(endpoint_error), .input_read_count(), .padding_tap_count(),
        .dw_mac_count(dw_mac_count), .context_peak()
    );

    assign endpoint_dw_ready = (state == ST_RUN) &&
        (!ctx_active[(endpoint_dw_pixel >> 3) & 2'd3] ||
         ctx_ordinal[(endpoint_dw_pixel >> 3) & 2'd3] == (endpoint_dw_pixel >> 3));

    always @* begin
        ready_found = 1'b0;
        ready_sel = 0;
        best_ordinal = 1000000;
        for (s = 0; s < CONTEXTS; s = s + 1) begin
            if (ctx_ready[s] && !token_active && (ctx_ordinal[s] < best_ordinal)) begin
                ready_found = 1'b1;
                ready_sel = s[1:0];
                best_ordinal = ctx_ordinal[s];
            end
        end
    end

    wire [31:0] token_ordinal = {25'd0, ctx_ordinal[token_slot]};
    assign token_valid = token_active;
    assign token_layer = 2'd1;
    assign token_context = token_ordinal[1:0];
    assign token_owner = token_ordinal[0];
    assign token_epoch = token_ordinal >> 1;
    assign token_cout_tile = cout_tile;
    assign token_k = {2'd0, k_index};
    assign token_last_k = (k_index == 4'd15);
    assign token_last_tile = (cout_tile == 3'd3) && (k_index == 4'd15);
    assign weight_query_valid = token_active;
    assign weight_query_layer = 2'd1;
    assign weight_query_tile = cout_tile;
    assign weight_query_k = {2'd0, k_index};

    always @* begin
        token_activation = 64'd0;
        for (p = 0; p < 8; p = p + 1)
            token_activation[p*8 +: 8] = activation_context[token_slot][p][k_index];
    end

    wire cfg_fire = cfg_word_valid && cfg_word_ready;
    wire dw_fire = endpoint_dw_valid && endpoint_dw_ready;
    wire token_fire = token_valid && token_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            cfg_loaded <= 1'b0;
            token_active <= 1'b0;
            token_slot <= 0;
            cout_tile <= 0;
            k_index <= 0;
            done_r <= 1'b0;
            for (i = 0; i < CONTEXTS; i = i + 1) begin
                ctx_active[i] <= 1'b0;
                ctx_ready[i] <= 1'b0;
                ctx_ordinal[i] <= 0;
                ctx_seen[i] <= 0;
            end
        end else begin
            if (cfg_fire && cfg_word_index == 10'd83)
                cfg_loaded <= 1'b1;
            if (start && ready) begin
                state <= ST_RUN;
                token_active <= 1'b0;
                cout_tile <= 0;
                k_index <= 0;
                done_r <= 1'b0;
                for (i = 0; i < CONTEXTS; i = i + 1) begin
                    ctx_active[i] <= 1'b0;
                    ctx_ready[i] <= 1'b0;
                    ctx_seen[i] <= 0;
                end
            end
            if (dw_fire) begin
                slot_i = (endpoint_dw_pixel >> 3) & 3;
                ordinal_i = endpoint_dw_pixel >> 3;
                if (!ctx_active[slot_i]) begin
                    ctx_active[slot_i] <= 1'b1;
                    ctx_ready[slot_i] <= 1'b0;
                    ctx_ordinal[slot_i] <= ordinal_i[6:0];
                    ctx_seen[slot_i] <= 0;
                end
                for (i = 0; i < 16; i = i + 1)
                    activation_context[slot_i][endpoint_dw_pixel[2:0]][i] <=
                        $signed(endpoint_dw_data[i*8 +: 8]);
                ctx_seen[slot_i] <= ctx_seen[slot_i] |
                                    (8'b1 << endpoint_dw_pixel[2:0]);
                if ((ctx_seen[slot_i] | (8'b1 << endpoint_dw_pixel[2:0])) == 8'hff)
                    ctx_ready[slot_i] <= 1'b1;
            end
            if (!token_active && ready_found) begin
                token_active <= 1'b1;
                token_slot <= ready_sel;
                cout_tile <= 0;
                k_index <= 0;
            end
            if (token_fire) begin
                if (k_index == 4'd15) begin
                    k_index <= 0;
                    if (cout_tile == 3'd3) begin
                        cout_tile <= 0;
                        ctx_active[token_slot] <= 1'b0;
                        ctx_ready[token_slot] <= 1'b0;
                        ctx_seen[token_slot] <= 0;
                        token_active <= 1'b0;
                        if (ctx_ordinal[token_slot] == 7'd127) begin
                            done_r <= 1'b1;
                            state <= ST_DONE;
                        end
                    end else begin
                        cout_tile <= cout_tile + 1'b1;
                    end
                end else begin
                    k_index <= k_index + 1'b1;
                end
            end
        end
    end

    assign error = endpoint_error;
endmodule
`default_nettype wire
