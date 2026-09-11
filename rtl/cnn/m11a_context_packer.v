`timescale 1ns/1ps
`default_nettype none

/*
 * M1.1-A eight-pixel context packer.
 *
 * DW-RQ emits one 16-byte vector at a time.  The packer stores only the
 * current eight-pixel context in a transposed byte matrix, then walks
 * {Cout-tile,K} and emits one 8-activation token per cycle when the shared
 * PW64 core is ready.  There is no layer-sized activation store and no
 * asynchronous eight-read service path: the context is filled serially and
 * the token payload is held stable while downstream valid/ready is stalled.
 */
module m11a_context_packer (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start_valid,
    output wire         start_ready,
    input  wire [1:0]   desc_layer,
    input  wire [5:0]   desc_cin,
    input  wire [6:0]   desc_cout,

    input  wire         dw_valid,
    output wire         dw_ready,
    input  wire [127:0] dw_data,
    input  wire [9:0]   dw_pixel,
    input  wire [1:0]   dw_group,
    input  wire [1:0]   dw_context,
    input  wire         dw_owner,
    input  wire [31:0]  dw_epoch,
    input  wire [31:0]  dw_context_ordinal,
    input  wire         dw_last,

    output wire         token_valid,
    input  wire         token_ready,
    output reg  [63:0]  token_activation,
    output wire [8:0]   token_weight_row,
    output wire [2:0]   token_cout_tile,
    output wire [5:0]   token_k,
    output wire         token_first_k,
    output wire         token_last_k,
    output wire         token_last_tile,
    output wire         token_last_layer,
    output wire [1:0]   token_context,
    output wire         token_owner,
    output wire [31:0]  token_epoch,
    output wire [31:0]  token_context_ordinal,

    output wire         done,
    output wire         error,
    output wire [31:0]  token_count
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_RECV = 2'd1;
    localparam [1:0] ST_EMIT = 2'd2;
    localparam [1:0] ST_DONE = 2'd3;

    reg [1:0] state;
    reg [1:0] layer_r;
    reg [5:0] cin_r;
    reg [6:0] cout_r;
    reg [1:0] group_count_r;
    reg [3:0] tile_count_r;
    reg [2:0] recv_pixel;
    reg recv_group;
    reg [1:0] ctx_tag_r;
    reg ctx_owner_r;
    reg [31:0] ctx_epoch_r, ctx_ordinal_r;
    reg ctx_last_r;
    reg [2:0] emit_tile;
    reg emit_group;
    reg [3:0] emit_k_local;
    reg [8:0] emit_row_addr;
    reg done_r, error_r;
    reg [31:0] token_count_r;

    /* [group][channel][pixel] is a small transposed shift/context store.
     * Channel is fixed by token emission, so the consumer never needs a
     * runtime modulo/division address expression. */
    reg [7:0] context_byte [0:1][0:31][0:7];

    wire start_fire = start_valid && start_ready;
    wire dw_fire = dw_valid && dw_ready;
    wire token_fire = token_valid && token_ready;
    assign start_ready = rst_n && (state == ST_IDLE);
    assign dw_ready = rst_n && (state == ST_RECV);
    assign token_valid = (state == ST_EMIT);
    assign token_cout_tile = emit_tile;
    assign token_k = {1'b0, emit_group, emit_k_local};
    assign token_weight_row = emit_row_addr;
    assign token_first_k = (emit_group == 1'b0) && (emit_k_local == 0);
    assign token_last_k = (emit_group == group_count_r - 1'b1) &&
                          (emit_k_local == 4'd15);
    assign token_last_tile = token_last_k && (emit_tile == tile_count_r - 1'b1);
    assign token_last_layer = token_last_tile && ctx_last_r;
    assign token_context = ctx_tag_r;
    assign token_owner = ctx_owner_r;
    assign token_epoch = ctx_epoch_r;
    assign token_context_ordinal = ctx_ordinal_r;
    assign done = done_r;
    assign error = error_r;
    assign token_count = token_count_r;

    integer p;
    always @* begin
        for (p = 0; p < 8; p = p + 1) begin
            if (emit_group == 1'b0)
                token_activation[p*8 +: 8] = context_byte[0][{1'b0,emit_k_local}][p];
            else
                token_activation[p*8 +: 8] = context_byte[1][{1'b0,emit_k_local}][p];
        end
    end

    integer i, g, c;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            layer_r <= 0; cin_r <= 0; cout_r <= 0; group_count_r <= 0; tile_count_r <= 0;
            recv_pixel <= 0; recv_group <= 0;
            ctx_tag_r <= 0; ctx_owner_r <= 0; ctx_epoch_r <= 0; ctx_ordinal_r <= 0;
            ctx_last_r <= 1'b0;
            emit_tile <= 0; emit_group <= 0; emit_k_local <= 0; emit_row_addr <= 0;
            done_r <= 0; error_r <= 0; token_count_r <= 0;
            for (g = 0; g < 2; g = g + 1)
                for (c = 0; c < 32; c = c + 1)
                    for (p = 0; p < 8; p = p + 1)
                        context_byte[g][c][p] <= 0;
        end else begin
            if (start_fire) begin
                layer_r <= desc_layer;
                cin_r <= desc_cin;
                cout_r <= desc_cout;
                group_count_r <= (desc_cin == 32) ? 2 : 1;
                tile_count_r <= desc_cout >> 3;
                recv_pixel <= 0;
                recv_group <= 0;
                ctx_tag_r <= 0;
                ctx_owner_r <= 0;
                ctx_epoch_r <= 0;
                ctx_ordinal_r <= 0;
                ctx_last_r <= 1'b0;
                emit_tile <= 0;
                emit_group <= 0;
                emit_k_local <= 0;
                emit_row_addr <= 0;
                done_r <= 0;
                error_r <= 0;
                token_count_r <= 0;
                state <= ST_RECV;
            end

            if (state == ST_RECV && dw_fire) begin
                if (dw_pixel[2:0] != recv_pixel || dw_group != recv_group ||
                    (dw_context_ordinal != ctx_ordinal_r && recv_pixel != 0)) begin
                    error_r <= 1'b1;
                end
                if (recv_pixel == 0 && recv_group == 0) begin
                    ctx_tag_r <= dw_context;
                    ctx_owner_r <= dw_owner;
                    ctx_epoch_r <= dw_epoch;
                    ctx_ordinal_r <= dw_context_ordinal;
                end
                for (i = 0; i < 16; i = i + 1)
                    context_byte[recv_group][i][recv_pixel] <= dw_data[i*8 +: 8];

                if (recv_group == group_count_r - 1'b1) begin
                    recv_group <= 0;
                    if (recv_pixel == 3'd7) begin
                        ctx_last_r <= dw_last;
                        emit_tile <= 0;
                        emit_group <= 0;
                        emit_k_local <= 0;
                        emit_row_addr <= 0;
                        state <= ST_EMIT;
                    end else begin
                        recv_pixel <= recv_pixel + 1'b1;
                    end
                end else begin
                    recv_group <= recv_group + 1'b1;
                end
            end

            if (state == ST_EMIT && token_fire) begin
                token_count_r <= token_count_r + 1'b1;
                /* K walks one byte row at a time.  For DS2 the first
                 * 16-channel group is followed by the second group at the
                 * same local K sequence; only the final group/K pair closes
                 * a Cout tile. */
                if (emit_k_local != 4'd15) begin
                    emit_k_local <= emit_k_local + 1'b1;
                    emit_row_addr <= emit_row_addr + 1'b1;
                end else if (emit_group != group_count_r - 1'b1) begin
                    emit_group <= emit_group + 1'b1;
                    emit_k_local <= 0;
                    emit_row_addr <= emit_row_addr + 1'b1;
                end else if (token_last_tile) begin
                    if (ctx_last_r) begin
                        done_r <= 1'b1;
                        state <= ST_DONE;
                    end else begin
                        recv_pixel <= 0;
                        recv_group <= 0;
                        ctx_ordinal_r <= ctx_ordinal_r + 1'b1;
                        ctx_tag_r <= ctx_tag_r + 1'b1;
                        ctx_owner_r <= ~ctx_owner_r;
                        if (ctx_owner_r)
                            ctx_epoch_r <= ctx_epoch_r + 1'b1;
                        state <= ST_RECV;
                    end
                end else begin
                    emit_tile <= emit_tile + 1'b1;
                    emit_group <= 0;
                    emit_k_local <= 0;
                    emit_row_addr <= emit_row_addr + 1'b1;
                end
            end

            /* The packed-stream endpoint is reused by the next layer; make
             * done a one-cycle pulse and return to the idle handshake. */
            if (state == ST_DONE) begin
                done_r <= 1'b0;
                state <= ST_IDLE;
            end
        end
    end
endmodule

`default_nettype wire
