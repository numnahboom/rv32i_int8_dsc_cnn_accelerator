`timescale 1ns/1ps
`default_nettype none

// DS2 adapter.  The reusable window reader and DW endpoint consume the
// committed DS1 activation bank.  Their 32-channel DW vectors are transcribed
// into one bounded four-context staging ledger, then emitted as the same
// 8-activation/8-weight PW tokens used by DS1.  No PW MAC/accumulator/result
// array is present here.
module ds12_shared_pw_ds2_adapter (
    input wire clk,
    input wire rst_n,

    input wire cfg_word_valid,
    output wire cfg_word_ready,
    input wire [1:0] cfg_word_layer,
    input wire [9:0] cfg_word_index,
    input wire [31:0] cfg_word_data,

    input wire start,
    output wire ready,
    output wire done,

    input wire active_bank,
    input wire [31:0] active_epoch,
    output wire activation_rd_valid,
    input wire activation_rd_ready,
    output wire activation_rd_bank,
    output wire [31:0] activation_rd_epoch,
    output wire [31:0] activation_rd_addr,
    input wire activation_rd_resp_valid,
    input wire [127:0] activation_rd_resp_data,
    input wire activation_rd_resp_bank,
    input wire [31:0] activation_rd_resp_epoch,
    input wire [31:0] activation_rd_resp_addr,

    output wire token_valid,
    input wire token_ready,
    output wire [1:0] token_layer,
    output wire [1:0] token_context,
    output wire token_owner,
    output wire [31:0] token_epoch,
    output wire [2:0] token_cout_tile,
    output wire [5:0] token_k,
    output reg [63:0] token_activation,
    input wire [63:0] token_weight,
    output wire token_last_k,
    output wire token_last_tile,
    output wire weight_query_valid,
    output wire [1:0] weight_query_layer,
    output wire [2:0] weight_query_tile,
    output wire [5:0] weight_query_k,

    output wire [31:0] dw_mac_count,
    output wire error
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_RUN = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;

    reg [1:0] state;
    reg cfg_loaded;
    (* ram_style = "block" *) reg [31:0] dw_cfg_mem [0:167];
    reg cfg_resp_valid;
    reg [31:0] cfg_resp_data;
    wire cfg_rd_en;
    wire [15:0] cfg_rd_addr;

    wire reader_start_valid;
    wire reader_start_ready;
    reg [8:0] window_issue;
    wire reader_window_valid;
    wire reader_window_ready;
    wire [127:0] reader_window_data;
    wire [5:0] reader_window_row, reader_window_col;
    wire [1:0] reader_tap_row, reader_tap_col;
    wire reader_slice;
    wire [1:0] reader_context;
    wire reader_owner;
    wire [31:0] reader_epoch;
    wire reader_window_last;
    wire reader_error;
    wire [7:0] reader_error_code;
    wire [31:0] reader_window_count;
    wire reader_req_valid;
    wire reader_req_ready;
    wire reader_req_bank;
    wire [31:0] reader_req_epoch;
    wire [31:0] reader_req_addr;
    wire reader_resp_ready;

    wire dw_start = start && ready;
    wire dw_ready_unused;
    wire dw_valid;
    wire dw_ready;
    wire [127:0] dw_data;
    wire [5:0] dw_row;
    wire [7:0] dw_pixel;
    wire dw_group;
    wire [1:0] dw_context;
    wire dw_owner;
    wire [31:0] dw_epoch;
    wire dw_last;
    wire dw_done;
    wire dw_error;
    wire [7:0] dw_error_code;
    wire [31:0] dw_vector_count;
    wire [31:0] dw_mac_count_i;
    wire [31:0] dw_cfg_count;
    wire [3:0] dw_context_peak;

    reg ctx_active [0:3];
    reg ctx_ready [0:3];
    reg [4:0] ctx_ordinal [0:3];
    reg [15:0] ctx_seen [0:3];
    reg signed [7:0] ctx_activation [0:3][0:7][0:31];
    reg token_active;
    reg [1:0] token_slot;
    reg [2:0] cout_tile;
    reg [5:0] k_index;
    reg done_r;
    reg error_r;
    integer i;
    integer p;
    integer c;
    integer scan;
    integer slot_i;
    integer ordinal_i;
    integer bit_i;
    reg ready_found;
    reg [1:0] ready_sel;

    assign cfg_word_ready = rst_n && !cfg_loaded &&
                            (cfg_word_layer == 2'd2) &&
                            (cfg_word_index < 10'd168);
    wire cfg_fire = cfg_word_valid && cfg_word_ready;
    assign ready = rst_n && cfg_loaded && (state == ST_IDLE);
    assign done = done_r;
    assign dw_mac_count = dw_mac_count_i;

    assign reader_start_valid = (state == ST_RUN) && (window_issue < 9'd256);
    assign activation_rd_valid = reader_req_valid;
    assign activation_rd_bank = reader_req_bank;
    assign activation_rd_epoch = reader_req_epoch;
    assign activation_rd_addr = reader_req_addr;

    // The reader's tags are checked by the reader/store boundary.  The
    // global DS2 owner/epoch for the PW token is derived from its pixel-group
    // ordinal (128..159), avoiding any second tag ledger in this adapter.
    ds12_stream_ds2_window_vector_reader reader (
        .clk(clk), .rst_n(rst_n),
        .window_start_valid(reader_start_valid), .window_start_ready(reader_start_ready),
        .window_start_row({2'd0, window_issue[7:4]}),
        .window_start_col({2'd0, window_issue[3:0]}),
        .window_start_bank(active_bank), .window_start_epoch(active_epoch),
        .window_start_last(window_issue == 9'd255),
        .window_valid(reader_window_valid), .window_ready(reader_window_ready),
        .window_data(reader_window_data), .window_row(reader_window_row),
        .window_col(reader_window_col), .window_tap_row(reader_tap_row),
        .window_tap_col(reader_tap_col), .window_channel_slice(reader_slice),
        .window_context(reader_context), .window_owner(reader_owner),
        .window_epoch(reader_epoch), .window_last(reader_window_last),
        .read_req_valid(reader_req_valid), .read_req_ready(activation_rd_ready),
        .read_req_bank(reader_req_bank), .read_req_epoch(reader_req_epoch),
        .read_req_addr(reader_req_addr), .read_resp_valid(activation_rd_resp_valid),
        .read_resp_ready(reader_resp_ready), .read_resp_data(activation_rd_resp_data),
        .read_resp_bank(activation_rd_resp_bank), .read_resp_epoch(activation_rd_resp_epoch),
        .read_resp_addr(activation_rd_resp_addr), .busy(), .context_active(),
        .context_peak(), .read_count(), .window_count(reader_window_count),
        .error(reader_error), .error_code(reader_error_code)
    );

    assign reader_resp_ready = 1'b1;

    // Local synchronous configuration response for the reusable DS2 DW
    // endpoint.  It is only 168 packed words and is not PW state.
    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_resp_valid <= 1'b0;
            cfg_resp_data <= 0;
        end else begin
            cfg_resp_valid <= cfg_rd_en;
            if (cfg_rd_en)
                cfg_resp_data <= dw_cfg_mem[cfg_rd_addr];
        end
    end

    ds12_stream_ds2_dw_compute dw_endpoint (
        .clk(clk), .rst_n(rst_n), .start(dw_start), .ready(dw_ready_unused),
        .cfg_rd_en(cfg_rd_en), .cfg_rd_bank(), .cfg_rd_addr(cfg_rd_addr),
        .cfg_rd_data(cfg_resp_data), .cfg_rd_valid(cfg_resp_valid),
        .cfg_active_valid(cfg_loaded), .cfg_active_layer(2'd2),
        .cfg_active_bank(1'b0), .cfg_active_epoch(active_epoch),
        .config_index(), .config_payload(),
        .window_valid(reader_window_valid), .window_ready(reader_window_ready),
        .window_data(reader_window_data), .window_row(reader_window_row),
        .window_col(reader_window_col), .window_tap_row(reader_tap_row),
        .window_tap_col(reader_tap_col), .window_channel_slice(reader_slice),
        .window_context(reader_context), .window_owner(reader_owner),
        .window_epoch(reader_epoch), .window_last(reader_window_last),
        .dw_valid(dw_valid), .dw_ready(dw_ready), .dw_data(dw_data),
        .dw_row(dw_row), .dw_pixel(dw_pixel), .dw_group(dw_group),
        .dw_context(dw_context), .dw_owner(dw_owner), .dw_epoch(dw_epoch),
        .dw_last(dw_last), .done(dw_done), .error(dw_error),
        .error_code(dw_error_code), .window_vector_count(),
        .dw_vector_count(dw_vector_count), .dw_mac_count(dw_mac_count_i),
        .padding_tap_count(), .context_peak(dw_context_peak),
        .config_read_count(dw_cfg_count)
    );

    assign dw_ready = (state == ST_RUN) &&
                      (!ctx_active[(dw_pixel >> 3) & 2'd3] ||
                       ctx_ordinal[(dw_pixel >> 3) & 2'd3] == (dw_pixel >> 3));

    always @* begin
        ready_found = 1'b0;
        ready_sel = 0;
        for (scan = 0; scan < 4; scan = scan + 1) begin
            if (!ready_found && ctx_ready[scan] && !token_active) begin
                ready_found = 1'b1;
                ready_sel = scan[1:0];
            end
        end
    end

    assign token_valid = token_active;
    wire [31:0] token_ordinal = 32'd128 + {27'd0, ctx_ordinal[token_slot]};
    assign token_layer = 2'd2;
    assign token_context = token_ordinal[1:0];
    assign token_owner = token_ordinal[0];
    assign token_epoch = token_ordinal >> 1;
    assign token_cout_tile = cout_tile;
    assign token_k = k_index;
    assign token_last_k = (k_index == 6'd31);
    assign token_last_tile = (cout_tile == 3'd7) && (k_index == 6'd31);
    assign weight_query_valid = token_active;
    assign weight_query_layer = 2'd2;
    assign weight_query_tile = cout_tile;
    assign weight_query_k = k_index;

    always @* begin
        token_activation = 64'd0;
        for (p = 0; p < 8; p = p + 1)
            token_activation[p*8 +: 8] = ctx_activation[token_slot][p][k_index];
    end

    wire dw_fire = dw_valid && dw_ready;
    wire token_fire = token_valid && token_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            cfg_loaded <= 1'b0;
            window_issue <= 0;
            token_active <= 0;
            token_slot <= 0;
            cout_tile <= 0;
            k_index <= 0;
            done_r <= 0;
            error_r <= 0;
            for (i = 0; i < 4; i = i + 1) begin
                ctx_active[i] <= 0;
                ctx_ready[i] <= 0;
                ctx_ordinal[i] <= 0;
                ctx_seen[i] <= 0;
            end
        end else begin
            if (cfg_fire) begin
                dw_cfg_mem[cfg_word_index] <= cfg_word_data;
                if (cfg_word_index == 10'd167)
                    cfg_loaded <= 1'b1;
            end
            if (start && ready) begin
                state <= ST_RUN;
                window_issue <= 0;
                token_active <= 0;
                cout_tile <= 0;
                k_index <= 0;
                done_r <= 0;
                for (i = 0; i < 4; i = i + 1) begin
                    ctx_active[i] <= 0;
                    ctx_ready[i] <= 0;
                    ctx_seen[i] <= 0;
                end
            end
            if (reader_start_valid && reader_start_ready)
                window_issue <= window_issue + 1'b1;

            if (dw_fire) begin
                slot_i = (dw_pixel >> 3) & 3;
                ordinal_i = (dw_pixel >> 3);
                bit_i = (dw_pixel[2:0] * 2) + (dw_group ? 1 : 0);
                if (!ctx_active[slot_i]) begin
                    ctx_active[slot_i] <= 1'b1;
                    ctx_ready[slot_i] <= 1'b0;
                    ctx_ordinal[slot_i] <= ordinal_i[4:0];
                    ctx_seen[slot_i] <= 0;
                end
                for (c = 0; c < 16; c = c + 1)
                    ctx_activation[slot_i][dw_pixel[2:0]][(dw_group ? 16 : 0)+c] <=
                        $signed(dw_data[c*8 +: 8]);
                ctx_seen[slot_i] <= ctx_seen[slot_i] | (16'b1 << bit_i);
                if ((ctx_seen[slot_i] | (16'b1 << bit_i)) == 16'hffff)
                    ctx_ready[slot_i] <= 1'b1;
            end

            if (!token_active && ready_found) begin
                token_active <= 1'b1;
                token_slot <= ready_sel;
                cout_tile <= 0;
                k_index <= 0;
            end

            if (token_fire) begin
                if (k_index == 6'd31) begin
                    k_index <= 0;
                    if (cout_tile == 3'd7) begin
                        cout_tile <= 0;
                        ctx_active[token_slot] <= 1'b0;
                        ctx_ready[token_slot] <= 1'b0;
                        ctx_seen[token_slot] <= 0;
                        token_active <= 1'b0;
                        if (ctx_ordinal[token_slot] == 5'd31) begin
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

            if (dw_error || reader_error)
                error_r <= 1'b1;
        end
    end

    assign error = error_r | dw_error | reader_error;
endmodule

`default_nettype wire
