`timescale 1ns/1ps
`default_nettype none

// Isolated DS2 input-window reader.
//
// A start describes one DS2 output pixel.  The reader walks its 3x3 SAME
// window in tap-major order and emits eighteen contiguous 16-channel vectors
// (tap 0..8, channel slice 0..1).  Input storage is the committed
// ds12_stream_activation_banks byte-addressed NHWC image: four little-endian
// 32-bit reads make one 16-channel vector.  Padding never issues a memory
// request and emits a zero vector instead.
//
// Four independent context slots allow callers to queue windows while the
// single synchronous bank port is occupied.  Requests and responses are
// explicit ready/valid transactions; all response and output metadata is
// registered/held while stalled.  This block is intentionally not connected
// to cnn_layer_runner, cnn_top, or any existing DS1 component.
module ds12_stream_ds2_window_reader #(
    parameter integer IMAGE_H = 32,
    parameter integer IMAGE_W = 32,
    parameter integer CHANNELS = 32,
    parameter integer OUT_H = 16,
    parameter integer OUT_W = 16,
    parameter integer CONTEXTS = 4
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         window_start_valid,
    output wire                         window_start_ready,
    input  wire [5:0]                   window_start_row,
    input  wire [5:0]                   window_start_col,
    input  wire                         window_start_bank,
    input  wire [31:0]                  window_start_epoch,
    input  wire                         window_start_last,

    output wire                         window_valid,
    input  wire                         window_ready,
    output wire [127:0]                 window_data,
    output wire [5:0]                   window_row,
    output wire [5:0]                   window_col,
    output wire [1:0]                   window_tap_row,
    output wire [1:0]                   window_tap_col,
    output wire                         window_channel_slice,
    output wire [1:0]                   window_context,
    output wire                         window_owner,
    output wire [31:0]                  window_epoch,
    output wire                         window_last,

    output wire                         read_req_valid,
    input  wire                         read_req_ready,
    output wire                         read_req_bank,
    output wire [31:0]                  read_req_epoch,
    output wire [31:0]                  read_req_addr,
    input  wire                         read_resp_valid,
    output wire                         read_resp_ready,
    input  wire [31:0]                  read_resp_data,
    input  wire                         read_resp_bank,
    input  wire [31:0]                  read_resp_epoch,
    input  wire [31:0]                  read_resp_addr,

    output wire                         busy,
    output wire [3:0]                   context_active,
    output wire [3:0]                   context_peak,
    output wire [31:0]                  read_count,
    output wire [31:0]                  window_count,
    output wire                         error,
    output wire [7:0]                   error_code
);
    localparam [2:0] CTX_IDLE  = 3'd0;
    localparam [2:0] CTX_ISSUE = 3'd1;
    localparam [2:0] CTX_WAIT  = 3'd2;
    localparam [2:0] CTX_OUT   = 3'd3;

    localparam [7:0] ERR_RESP_BANK  = 8'h01;
    localparam [7:0] ERR_RESP_EPOCH = 8'h02;
    localparam [7:0] ERR_RESP_ADDR  = 8'h04;
    localparam [7:0] ERR_RESP_OWNER = 8'h08;
    localparam [7:0] ERR_START_RANGE = 8'h10;
    localparam [7:0] ERR_CTX = 8'h20;

    reg [2:0] ctx_state [0:CONTEXTS-1];
    reg [5:0] ctx_row [0:CONTEXTS-1];
    reg [5:0] ctx_col [0:CONTEXTS-1];
    reg       ctx_bank [0:CONTEXTS-1];
    reg [31:0] ctx_epoch [0:CONTEXTS-1];
    reg       ctx_last [0:CONTEXTS-1];
    reg [3:0] ctx_tap [0:CONTEXTS-1];
    reg       ctx_slice [0:CONTEXTS-1];
    reg [2:0] ctx_word [0:CONTEXTS-1];
    reg [127:0] ctx_data [0:CONTEXTS-1];

    reg [1:0] rr_issue;
    reg [1:0] rr_output;
    reg       outstanding;
    reg [1:0] outstanding_ctx;
    reg [31:0] outstanding_addr;
    reg [31:0] read_count_r;
    reg [31:0] window_count_r;
    reg [3:0] context_peak_r;
    reg       error_r;
    reg [7:0] error_code_r;

    integer i;
    integer s;
    integer issue_sel;
    integer out_sel;
    integer active_tmp;
    integer issue_k;
    integer out_k;
    integer start_k;
    integer start_sel;
    integer iy_tmp;
    integer ix_tmp;
    integer tap_row_tmp;
    integer tap_col_tmp;
    integer addr_tmp;
    reg issue_found;
    reg out_found;
    reg start_found;

    // A free slot is immediately available for a new descriptor.  The
    // descriptor itself is checked at acceptance, not by the bank.
    always @* begin
        issue_found = 1'b0;
        issue_sel = 0;
        out_found = 1'b0;
        out_sel = 0;
        start_found = 1'b0;
        start_sel = 0;
        active_tmp = 0;
        for (issue_k = 0; issue_k < CONTEXTS; issue_k = issue_k + 1) begin
            if (!issue_found && ctx_state[(rr_issue + issue_k) % CONTEXTS] == CTX_ISSUE) begin
                issue_found = 1'b1;
                issue_sel = (rr_issue + issue_k) % CONTEXTS;
            end
        end
        for (out_k = 0; out_k < CONTEXTS; out_k = out_k + 1) begin
            if (!out_found && ctx_state[(rr_output + out_k) % CONTEXTS] == CTX_OUT) begin
                out_found = 1'b1;
                out_sel = (rr_output + out_k) % CONTEXTS;
            end
        end
        for (start_k = 0; start_k < CONTEXTS; start_k = start_k + 1) begin
            if (!start_found && ctx_state[start_k] == CTX_IDLE) begin
                start_found = 1'b1;
                start_sel = start_k;
            end
        end
        for (i = 0; i < CONTEXTS; i = i + 1)
            if (ctx_state[i] != CTX_IDLE) active_tmp = active_tmp + 1;
    end

    assign window_start_ready = rst_n && start_found;
    assign window_valid = out_found;
    assign window_data = out_found ? ctx_data[out_sel] : 128'd0;
    assign window_row = out_found ? ctx_row[out_sel] : 6'd0;
    assign window_col = out_found ? ctx_col[out_sel] : 6'd0;
    assign window_tap_row = out_found ? ctx_tap[out_sel] / 3 : 2'd0;
    assign window_tap_col = out_found ? ctx_tap[out_sel] % 3 : 2'd0;
    assign window_channel_slice = out_found ? ctx_slice[out_sel] : 1'b0;
    assign window_context = out_found ? out_sel[1:0] : 2'd0;
    // The bank has no separate owner field; its committed bank is the owner
    // tag.  It is consequently checked against the response bank below.
    assign window_owner = out_found ? ctx_bank[out_sel] : 1'b0;
    assign window_epoch = out_found ? ctx_epoch[out_sel] : 32'd0;
    assign window_last = out_found && ctx_last[out_sel] &&
                         (ctx_tap[out_sel] == 4'd8) && ctx_slice[out_sel];

    assign read_req_valid = issue_found && !outstanding &&
                            (ctx_state[issue_sel] == CTX_ISSUE) &&
                            (iy_tmp >= 0 && iy_tmp < IMAGE_H &&
                             ix_tmp >= 0 && ix_tmp < IMAGE_W);
    assign read_req_bank = issue_found ? ctx_bank[issue_sel] : 1'b0;
    assign read_req_epoch = issue_found ? ctx_epoch[issue_sel] : 32'd0;

    // SAME coordinates are intentionally evaluated from the output pixel
    // and tap counters, never from a prepacked window memory.
    always @* begin
        tap_row_tmp = issue_found ? (ctx_tap[issue_sel] / 3) : 0;
        tap_col_tmp = issue_found ? (ctx_tap[issue_sel] % 3) : 0;
        iy_tmp = issue_found ? (ctx_row[issue_sel] * 2 + tap_row_tmp - 1) : 0;
        ix_tmp = issue_found ? (ctx_col[issue_sel] * 2 + tap_col_tmp - 1) : 0;
        addr_tmp = (iy_tmp * IMAGE_W + ix_tmp) * CHANNELS +
                   (ctx_slice[issue_sel] * 16) + (ctx_word[issue_sel] * 4);
    end
    assign read_req_addr = (issue_found && iy_tmp >= 0 && iy_tmp < IMAGE_H &&
                            ix_tmp >= 0 && ix_tmp < IMAGE_W)
                           ? addr_tmp[31:0] : 32'd0;
    assign read_resp_ready = outstanding;
    assign busy = (active_tmp != 0) || outstanding;
    assign context_active = active_tmp[3:0];
    assign context_peak = context_peak_r;
    assign read_count = read_count_r;
    assign window_count = window_count_r;
    assign error = error_r;
    assign error_code = error_code_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            rr_issue <= 2'd0;
            rr_output <= 2'd0;
            outstanding <= 1'b0;
            outstanding_ctx <= 2'd0;
            outstanding_addr <= 32'd0;
            read_count_r <= 32'd0;
            window_count_r <= 32'd0;
            context_peak_r <= 4'd0;
            error_r <= 1'b0;
            error_code_r <= 8'd0;
            for (i = 0; i < CONTEXTS; i = i + 1) begin
                ctx_state[i] <= CTX_IDLE;
                ctx_row[i] <= 6'd0;
                ctx_col[i] <= 6'd0;
                ctx_bank[i] <= 1'b0;
                ctx_epoch[i] <= 32'd0;
                ctx_last[i] <= 1'b0;
                ctx_tap[i] <= 4'd0;
                ctx_slice[i] <= 1'b0;
                ctx_word[i] <= 3'd0;
                ctx_data[i] <= 128'd0;
            end
        end else begin
            if (window_start_valid && window_start_ready) begin
                // The allocator selects the lowest free slot.  Context tags
                // are observable and stable, while scheduling remains RR.
                if (start_found && window_start_row < OUT_H && window_start_col < OUT_W) begin
                    ctx_state[start_sel] <= CTX_ISSUE;
                    ctx_row[start_sel] <= window_start_row;
                    ctx_col[start_sel] <= window_start_col;
                    ctx_bank[start_sel] <= window_start_bank;
                    ctx_epoch[start_sel] <= window_start_epoch;
                    ctx_last[start_sel] <= window_start_last;
                    ctx_tap[start_sel] <= 4'd0;
                    ctx_slice[start_sel] <= 1'b0;
                    ctx_word[start_sel] <= 3'd0;
                    ctx_data[start_sel] <= 128'd0;
                end
                if (window_start_row >= OUT_H || window_start_col >= OUT_W) begin
                    error_r <= 1'b1;
                    error_code_r <= error_code_r | ERR_START_RANGE;
                end
            end

            // Handle requests before padding.  Address arithmetic is
            // combinational, so this ordering also avoids a delta-cycle
            // classifying an address-zero request as padding.
            if (read_req_valid && read_req_ready && !outstanding) begin
                // The bank port is dedicated to this reader.  The request is
                // held in CTX_ISSUE until the normal ready/valid handshake.
                outstanding <= 1'b1;
                outstanding_ctx <= issue_sel[1:0];
                outstanding_addr <= read_req_addr;
                ctx_state[issue_sel] <= CTX_WAIT;
                rr_issue <= (issue_sel + 1) % CONTEXTS;
                read_count_r <= read_count_r + 1;
            // A padding vector is produced without touching the bank.
            end else if (issue_found && !outstanding && ctx_state[issue_sel] == CTX_ISSUE &&
                         !(iy_tmp >= 0 && iy_tmp < IMAGE_H && ix_tmp >= 0 && ix_tmp < IMAGE_W)) begin
                ctx_data[issue_sel] <= 128'd0;
                ctx_state[issue_sel] <= CTX_OUT;
            end

            if (outstanding && read_resp_valid && read_resp_ready) begin
                if (read_resp_bank != ctx_bank[outstanding_ctx]) begin
                    error_r <= 1'b1;
                    error_code_r <= error_code_r | ERR_RESP_BANK | ERR_RESP_OWNER;
                end
                if (read_resp_epoch != ctx_epoch[outstanding_ctx]) begin
                    error_r <= 1'b1;
                    error_code_r <= error_code_r | ERR_RESP_EPOCH;
                end
                if (read_resp_addr != outstanding_addr) begin
                    $display("reader addr mismatch t=%0t ctx=%0d got=%h exp=%h", $time, outstanding_ctx, read_resp_addr, outstanding_addr);
                    error_r <= 1'b1;
                    error_code_r <= error_code_r | ERR_RESP_ADDR;
                end
                ctx_data[outstanding_ctx][ctx_word[outstanding_ctx]*32 +: 32] <= read_resp_data;
                outstanding <= 1'b0;
                if (ctx_word[outstanding_ctx] == 3) begin
                    ctx_word[outstanding_ctx] <= 3'd0;
                    ctx_state[outstanding_ctx] <= CTX_OUT;
                end else begin
                    ctx_word[outstanding_ctx] <= ctx_word[outstanding_ctx] + 1'b1;
                    ctx_state[outstanding_ctx] <= CTX_ISSUE;
                end
            end

            if (window_valid && window_ready) begin
                window_count_r <= window_count_r + 1;
                rr_output <= (out_sel + 1) % CONTEXTS;
                if (ctx_slice[out_sel]) begin
                    ctx_slice[out_sel] <= 1'b0;
                    if (ctx_tap[out_sel] == 4'd8)
                        ctx_state[out_sel] <= CTX_IDLE;
                    else begin
                        ctx_tap[out_sel] <= ctx_tap[out_sel] + 1'b1;
                        ctx_state[out_sel] <= CTX_ISSUE;
                    end
                end else begin
                    ctx_slice[out_sel] <= 1'b1;
                    ctx_state[out_sel] <= CTX_ISSUE;
                end
                ctx_data[out_sel] <= 128'd0;
            end

            if (active_tmp > context_peak_r)
                context_peak_r <= active_tmp[3:0];
        end
    end
endmodule

`default_nettype wire
