`timescale 1ns/1ps
`default_nettype none

// Candidate DS2 input-window reader for ds12_stream_dual_vector_activation_store.
// One accepted store request is one complete 16-byte channel slice; there is
// no 32-bit-word reconstruction or pre-packed window storage in this block.
module ds12_stream_ds2_window_vector_reader #(
    parameter integer IMAGE_H = 32,
    parameter integer IMAGE_W = 32,
    parameter integer CHANNELS = 32,
    parameter integer OUT_H = 16,
    parameter integer OUT_W = 16,
    parameter integer CONTEXTS = 4
) (
    input  wire clk,
    input  wire rst_n,
    input  wire window_start_valid,
    output wire window_start_ready,
    input  wire [5:0] window_start_row,
    input  wire [5:0] window_start_col,
    input  wire window_start_bank,
    input  wire [31:0] window_start_epoch,
    input  wire window_start_last,
    output wire window_valid,
    input  wire window_ready,
    output wire [127:0] window_data,
    output wire [5:0] window_row,
    output wire [5:0] window_col,
    output wire [1:0] window_tap_row,
    output wire [1:0] window_tap_col,
    output wire window_channel_slice,
    output wire [1:0] window_context,
    output wire window_owner,
    output wire [31:0] window_epoch,
    output wire window_last,
    output wire read_req_valid,
    input wire read_req_ready,
    output wire read_req_bank,
    output wire [31:0] read_req_epoch,
    output wire [31:0] read_req_addr,
    input wire read_resp_valid,
    output wire read_resp_ready,
    input wire [127:0] read_resp_data,
    input wire read_resp_bank,
    input wire [31:0] read_resp_epoch,
    input wire [31:0] read_resp_addr,
    output wire busy,
    output wire [3:0] context_active,
    output wire [3:0] context_peak,
    output wire [31:0] read_count,
    output wire [31:0] window_count,
    output wire error,
    output wire [7:0] error_code
);
    localparam [2:0] CTX_IDLE = 3'd0;
    localparam [2:0] CTX_ISSUE = 3'd1;
    localparam [2:0] CTX_WAIT = 3'd2;
    localparam [2:0] CTX_OUT = 3'd3;
    localparam [7:0] ERR_RESP_BANK = 8'h01;
    localparam [7:0] ERR_RESP_EPOCH = 8'h02;
    localparam [7:0] ERR_RESP_ADDR = 8'h04;
    localparam [7:0] ERR_RESP_OWNER = 8'h08;
    localparam [7:0] ERR_START_RANGE = 8'h10;

    reg [2:0] ctx_state [0:CONTEXTS-1];
    reg [5:0] ctx_row [0:CONTEXTS-1];
    reg [5:0] ctx_col [0:CONTEXTS-1];
    reg ctx_bank [0:CONTEXTS-1];
    reg [31:0] ctx_epoch [0:CONTEXTS-1];
    reg ctx_last [0:CONTEXTS-1];
    reg [3:0] ctx_tap [0:CONTEXTS-1];
    reg ctx_slice [0:CONTEXTS-1];
    reg [127:0] ctx_data [0:CONTEXTS-1];

    reg [1:0] rr_issue, rr_output;
    reg outstanding;
    reg [1:0] outstanding_ctx;
    reg [31:0] outstanding_addr;
    reg [31:0] read_count_r, window_count_r;
    reg [3:0] context_peak_r;
    reg error_r;
    reg [7:0] error_code_r;

    integer i, k, issue_sel, out_sel, start_sel, active_tmp;
    integer tap_row_tmp, tap_col_tmp, iy_tmp, ix_tmp, addr_tmp;
    reg issue_found, out_found, start_found;

    always @* begin
        issue_found = 1'b0; issue_sel = 0;
        out_found = 1'b0; out_sel = 0;
        start_found = 1'b0; start_sel = 0; active_tmp = 0;
        for (k = 0; k < CONTEXTS; k = k + 1) begin
            if (!issue_found && ctx_state[(rr_issue + k) % CONTEXTS] == CTX_ISSUE) begin
                issue_found = 1'b1;
                issue_sel = (rr_issue + k) % CONTEXTS;
            end
            if (!out_found && ctx_state[(rr_output + k) % CONTEXTS] == CTX_OUT) begin
                out_found = 1'b1;
                out_sel = (rr_output + k) % CONTEXTS;
            end
        end
        for (k = 0; k < CONTEXTS; k = k + 1)
            if (!start_found && ctx_state[k] == CTX_IDLE) begin
                start_found = 1'b1; start_sel = k;
            end
        for (i = 0; i < CONTEXTS; i = i + 1)
            if (ctx_state[i] != CTX_IDLE) active_tmp = active_tmp + 1;
    end

    always @* begin
        tap_row_tmp = issue_found ? (ctx_tap[issue_sel] / 3) : 0;
        tap_col_tmp = issue_found ? (ctx_tap[issue_sel] % 3) : 0;
        iy_tmp = issue_found ? (ctx_row[issue_sel] * 2 + tap_row_tmp - 1) : 0;
        ix_tmp = issue_found ? (ctx_col[issue_sel] * 2 + tap_col_tmp - 1) : 0;
        addr_tmp = (iy_tmp * IMAGE_W + ix_tmp) * CHANNELS +
                   (ctx_slice[issue_sel] * 16);
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
    assign window_owner = out_found ? ctx_bank[out_sel] : 1'b0;
    assign window_epoch = out_found ? ctx_epoch[out_sel] : 32'd0;
    assign window_last = out_found && ctx_last[out_sel] &&
                         (ctx_tap[out_sel] == 4'd8) && ctx_slice[out_sel];

    // A padding tap is a logical vector but deliberately does not touch the
    // store.  read_count is the logical 4,608-vector ledger; the store-side
    // request handshake is the physical valid-vector ledger.
    // The store has one elastic response slot and explicitly allows a new
    // request on the same edge that the previous vector is consumed.  Keep
    // the request channel open for that replacement edge; this is what lets
    // four contexts hide the one-cycle registered store response.
    assign read_req_valid = issue_found &&
                            (!outstanding || (read_resp_valid && read_resp_ready)) &&
                            (ctx_state[issue_sel] == CTX_ISSUE) &&
                            (iy_tmp >= 0 && iy_tmp < IMAGE_H &&
                             ix_tmp >= 0 && ix_tmp < IMAGE_W);
    assign read_req_bank = issue_found ? ctx_bank[issue_sel] : 1'b0;
    assign read_req_epoch = issue_found ? ctx_epoch[issue_sel] : 32'd0;
    assign read_req_addr = (issue_found && iy_tmp >= 0 && iy_tmp < IMAGE_H &&
                            ix_tmp >= 0 && ix_tmp < IMAGE_W) ? addr_tmp[31:0] : 32'd0;
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
            rr_issue <= 2'd0; rr_output <= 2'd0; outstanding <= 1'b0;
            outstanding_ctx <= 2'd0; outstanding_addr <= 32'd0;
            read_count_r <= 32'd0; window_count_r <= 32'd0;
            context_peak_r <= 4'd0; error_r <= 1'b0; error_code_r <= 8'd0;
            for (i = 0; i < CONTEXTS; i = i + 1) begin
                ctx_state[i] <= CTX_IDLE; ctx_row[i] <= 0; ctx_col[i] <= 0;
                ctx_bank[i] <= 0; ctx_epoch[i] <= 0; ctx_last[i] <= 0;
                ctx_tap[i] <= 0; ctx_slice[i] <= 0; ctx_data[i] <= 0;
            end
        end else begin
            if (window_start_valid && window_start_ready) begin
                if (window_start_row < OUT_H && window_start_col < OUT_W) begin
                    ctx_state[start_sel] <= CTX_ISSUE;
                    ctx_row[start_sel] <= window_start_row;
                    ctx_col[start_sel] <= window_start_col;
                    ctx_bank[start_sel] <= window_start_bank;
                    ctx_epoch[start_sel] <= window_start_epoch;
                    ctx_last[start_sel] <= window_start_last;
                    ctx_tap[start_sel] <= 0; ctx_slice[start_sel] <= 0;
                    ctx_data[start_sel] <= 0;
                end else begin
                    error_r <= 1'b1; error_code_r <= error_code_r | ERR_START_RANGE;
                end
            end

            // Consume the old registered response first.  A replacement
            // request below intentionally wins the outstanding register on
            // the same edge, sustaining one vector request per cycle.
            if (outstanding && read_resp_valid && read_resp_ready) begin
                if (read_resp_bank != ctx_bank[outstanding_ctx]) begin
                    error_r <= 1'b1; error_code_r <= error_code_r | ERR_RESP_BANK | ERR_RESP_OWNER;
                end
                if (read_resp_epoch != ctx_epoch[outstanding_ctx]) begin
                    error_r <= 1'b1; error_code_r <= error_code_r | ERR_RESP_EPOCH;
                end
                if (read_resp_addr != outstanding_addr) begin
                    error_r <= 1'b1;
                    error_code_r <= error_code_r | ERR_RESP_ADDR;
                end
                ctx_data[outstanding_ctx] <= read_resp_data;
                outstanding <= 1'b0;
                ctx_state[outstanding_ctx] <= CTX_OUT;
            end

            if (read_req_valid && read_req_ready) begin
                outstanding <= 1'b1;
                outstanding_ctx <= issue_sel[1:0];
                outstanding_addr <= read_req_addr;
                ctx_state[issue_sel] <= CTX_WAIT;
                rr_issue <= (issue_sel + 1) % CONTEXTS;
                read_count_r <= read_count_r + 1'b1;
            end else if (issue_found && (!outstanding || (read_resp_valid && read_resp_ready)) &&
                         ctx_state[issue_sel] == CTX_ISSUE &&
                         !(iy_tmp >= 0 && iy_tmp < IMAGE_H && ix_tmp >= 0 && ix_tmp < IMAGE_W)) begin
                ctx_data[issue_sel] <= 128'd0;
                ctx_state[issue_sel] <= CTX_OUT;
                read_count_r <= read_count_r + 1'b1;
            end

            if (window_valid && window_ready) begin
                window_count_r <= window_count_r + 1'b1;
                rr_output <= (out_sel + 1) % CONTEXTS;
                ctx_data[out_sel] <= 0;
                if (ctx_slice[out_sel]) begin
                    ctx_slice[out_sel] <= 0;
                    if (ctx_tap[out_sel] == 8) begin
                        ctx_state[out_sel] <= CTX_IDLE;
                    end else begin
                        ctx_tap[out_sel] <= ctx_tap[out_sel] + 1'b1;
                        ctx_state[out_sel] <= CTX_ISSUE;
                    end
                end else begin
                    ctx_slice[out_sel] <= 1'b1;
                    ctx_state[out_sel] <= CTX_ISSUE;
                end
            end
            if (active_tmp > context_peak_r) context_peak_r <= active_tmp[3:0];
        end
    end
endmodule

`default_nettype wire
