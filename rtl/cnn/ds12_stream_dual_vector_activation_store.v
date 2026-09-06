`timescale 1ns/1ps
`default_nettype none

// Two-bank activation store built from the vector lane-bank primitive.
//
// A layer claims one FREE bank for 32-bit writes.  The other bank remains the
// published READ bank until a checked commit fence atomically swaps ownership.
// The lane banks are deliberately separate instances: a write and a 16-byte
// vector read can therefore proceed on different banks in the same cycle.
module ds12_stream_dual_vector_activation_store #(
    parameter integer LINE_WORDS = 2048
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        layer_start_valid,
    output wire        layer_start_ready,
    input  wire        layer_start_bank,
    input  wire [31:0] layer_start_epoch,
    input  wire [31:0] layer_start_expected_words,

    input  wire        write_valid,
    output wire        write_ready,
    input  wire        write_bank,
    input  wire [31:0] write_epoch,
    input  wire [31:0] write_addr,
    input  wire [31:0] write_data,
    input  wire [3:0]  write_be,
    input  wire        write_last,
    output reg         write_resp_valid,
    input  wire        write_resp_ready,
    output reg         write_resp_bank,
    output reg  [31:0] write_resp_epoch,
    output reg  [31:0] write_resp_addr,

    // Both spellings are provided for integration convenience.  They are one
    // command channel; if both valids are asserted, layer_end wins.
    input  wire        layer_end_valid,
    output wire        layer_end_ready,
    input  wire        layer_end_bank,
    input  wire [31:0] layer_end_epoch,
    input  wire        commit_valid,
    output wire        commit_ready,
    input  wire        commit_bank,
    input  wire [31:0] commit_epoch,
    output reg         commit_done,
    output reg         layer_end_done,
    output reg         atomic_swap,

    // Bank/epoch are optional on the read request.  When left unconnected the
    // request targets the currently published READ bank and its epoch.  When
    // driven, they make stale/same-bank negative cases directly testable.
    input  wire        read_req_valid,
    output wire        read_req_ready,
    input  wire        read_req_bank,
    input  wire [31:0] read_req_epoch,
    input  wire [31:0] read_req_addr,
    output wire        read_resp_valid,
    input  wire        read_resp_ready,
    output wire [127:0] read_resp_data,
    output reg         read_resp_bank,
    output reg  [31:0] read_resp_epoch,
    output wire [31:0] read_resp_addr,

    output reg  [1:0]  bank0_state,
    output reg  [1:0]  bank1_state,
    output reg  [31:0] bank0_epoch,
    output reg  [31:0] bank1_epoch,
    output reg         active_read_bank,
    output reg  [31:0] active_read_epoch,
    output reg         active_write,
    output reg         active_write_bank,
    output reg  [31:0] write_epoch_active,
    output reg  [31:0] write_count,
    output reg  [31:0] write_expected_words,
    output reg         write_last_seen,
    output reg         error,
    output reg  [7:0]  error_code
);
    localparam integer BANK_BYTES = LINE_WORDS * 16;
    localparam [1:0] OWNER_FREE      = 2'd0;
    localparam [1:0] OWNER_READ      = 2'd1;
    localparam [1:0] OWNER_WRITE     = 2'd2;
    localparam [1:0] OWNER_COMMITTED = 2'd3;
    localparam [7:0] ERR_START       = 8'h01;
    localparam [7:0] ERR_STALE       = 8'h02;
    localparam [7:0] ERR_DUAL        = 8'h04;
    localparam [7:0] ERR_SAME_BANK   = 8'h08;
    localparam [7:0] ERR_RANGE       = 8'h10;
    localparam [7:0] ERR_EARLY       = 8'h20;
    localparam [7:0] ERR_ALIGN       = 8'h40;
    localparam [7:0] ERR_COMMIT      = 8'h80;

    reg        commit_pending;
    reg        read_pending;
    reg        read_pending_bank;

    wire write_slot = !write_resp_valid || write_resp_ready;
    // A second start is handshakable and reported as a dual-owner error.
    // Blocking it only while the commit fence is in flight keeps invalid
    // command behavior equivalent to ds12_stream_activation_banks.
    wire commit_cmd_layer = (layer_end_valid === 1'b1);
    wire commit_cmd_legacy = (commit_valid === 1'b1);
    wire commit_cmd_valid = commit_cmd_layer || commit_cmd_legacy;
    wire commit_cmd_bank = commit_cmd_layer ? layer_end_bank : commit_bank;
    wire [31:0] commit_cmd_epoch = commit_cmd_layer ? layer_end_epoch : commit_epoch;

    assign layer_start_ready = rst_n && !commit_pending && !commit_cmd_valid;
    assign write_ready = rst_n && active_write && write_slot;
    assign layer_end_ready = rst_n && active_write;
    assign commit_ready = rst_n && active_write;

    wire read_bank_known = (read_req_bank === 1'b0) || (read_req_bank === 1'b1);
    wire read_epoch_known = (^read_req_epoch !== 1'bx);
    wire selected_read_bank = read_bank_known ? read_req_bank : active_read_bank;
    wire [31:0] selected_read_epoch = read_epoch_known ? read_req_epoch :
                                      (selected_read_bank ? bank1_epoch : bank0_epoch);
    wire read_response_fire = read_resp_valid && read_resp_ready;
    wire selected_lane_ready = selected_read_bank ? bank1_req_ready : bank0_req_ready;
    // The vector lane bank has an elastic registered response, so consume and
    // replace it on one edge to sustain one accepted vector per cycle.
    assign read_req_ready = rst_n && !commit_pending &&
                            ((!read_pending) || read_response_fire) &&
                            ((!read_command_ok) || selected_lane_ready);
    wire read_accept = read_req_valid && read_req_ready;
    wire read_addr_ok = (read_req_addr[3:0] == 4'h0) &&
                        (read_req_addr <= (BANK_BYTES - 16));
    wire selected_bank_read = selected_read_bank ?
                              (bank1_state == OWNER_READ) :
                              (bank0_state == OWNER_READ);
    wire selected_epoch_ok = selected_read_bank ?
                             (selected_read_epoch == bank1_epoch) :
                             (selected_read_epoch == bank0_epoch);
    wire read_command_ok = selected_bank_read && selected_epoch_ok && read_addr_ok;

    wire write_meta_ok = active_write &&
                         (write_bank == active_write_bank) &&
                         (write_epoch == write_epoch_active);
    wire write_addr_aligned = (write_addr[1:0] == 2'b00);
    wire write_addr_in_range = (write_addr < BANK_BYTES);
    wire write_command_ok = write_meta_ok && write_addr_aligned && write_addr_in_range;
    wire write_accept = write_valid && write_ready;

    // The two physical vector banks.  No packed/duplicated wrapper memory is
    // present; each instance owns sixteen explicit byte lane memories.
    wire bank0_write_valid = write_accept && write_command_ok && !write_bank;
    wire bank1_write_valid = write_accept && write_command_ok &&  write_bank;
    wire bank0_req_valid = read_accept && read_command_ok && !selected_read_bank;
    wire bank1_req_valid = read_accept && read_command_ok &&  selected_read_bank;
    wire bank0_req_ready, bank1_req_ready;
    wire bank0_resp_valid, bank1_resp_valid;
    wire [127:0] bank0_resp_data, bank1_resp_data;
    wire [31:0] bank0_resp_addr, bank1_resp_addr;

    ds12_stream_vector_lane_bank #(.LINE_WORDS(LINE_WORDS)) bank0_lane (
        .clk(clk), .rst_n(rst_n),
        .write_valid(bank0_write_valid), .write_ready(),
        .write_addr(write_addr), .write_data(write_data), .write_be(write_be),
        .vector_req_valid(bank0_req_valid), .vector_req_ready(bank0_req_ready),
        .vector_req_addr(read_req_addr), .vector_resp_valid(bank0_resp_valid),
        .vector_resp_ready(read_resp_ready && read_pending && !read_pending_bank),
        .vector_resp_data(bank0_resp_data), .vector_resp_addr(bank0_resp_addr),
        .error(), .error_code()
    );
    ds12_stream_vector_lane_bank #(.LINE_WORDS(LINE_WORDS)) bank1_lane (
        .clk(clk), .rst_n(rst_n),
        .write_valid(bank1_write_valid), .write_ready(),
        .write_addr(write_addr), .write_data(write_data), .write_be(write_be),
        .vector_req_valid(bank1_req_valid), .vector_req_ready(bank1_req_ready),
        .vector_req_addr(read_req_addr), .vector_resp_valid(bank1_resp_valid),
        .vector_resp_ready(read_resp_ready && read_pending && read_pending_bank),
        .vector_resp_data(bank1_resp_data), .vector_resp_addr(bank1_resp_addr),
        .error(), .error_code()
    );

    // A response is already registered inside the selected lane-bank.  The
    // wrapper only adds the owner/epoch tag and routes ready to that bank.
    assign read_resp_valid = read_pending &&
                             (read_pending_bank ? bank1_resp_valid : bank0_resp_valid);
    assign read_resp_data = read_pending_bank ? bank1_resp_data : bank0_resp_data;
    assign read_resp_addr = read_pending_bank ? bank1_resp_addr : bank0_resp_addr;

    always @(posedge clk) begin
        if (!rst_n) begin
            bank0_state          <= OWNER_READ;
            bank1_state          <= OWNER_FREE;
            bank0_epoch         <= 32'd0;
            bank1_epoch         <= 32'd0;
            active_read_bank    <= 1'b0;
            active_read_epoch   <= 32'd0;
            active_write        <= 1'b0;
            active_write_bank   <= 1'b0;
            commit_pending      <= 1'b0;
            read_pending        <= 1'b0;
            read_pending_bank   <= 1'b0;
            write_epoch_active  <= 32'd0;
            write_count         <= 32'd0;
            write_expected_words <= 32'd0;
            write_last_seen     <= 1'b0;
            write_resp_valid    <= 1'b0;
            write_resp_bank     <= 1'b0;
            write_resp_epoch    <= 32'd0;
            write_resp_addr     <= 32'd0;
            commit_done         <= 1'b0;
            layer_end_done      <= 1'b0;
            atomic_swap         <= 1'b0;
            read_resp_bank      <= 1'b0;
            read_resp_epoch     <= 32'd0;
            error               <= 1'b0;
            error_code          <= 8'd0;
        end else begin
            commit_done    <= 1'b0;
            layer_end_done <= 1'b0;
            atomic_swap    <= 1'b0;

            if (commit_pending) begin
                commit_pending <= 1'b0;
                if (bank0_state == OWNER_COMMITTED)
                    bank0_state <= OWNER_READ;
                if (bank1_state == OWNER_COMMITTED)
                    bank1_state <= OWNER_READ;
            end

            if (write_resp_valid && write_resp_ready)
                write_resp_valid <= 1'b0;
            if (read_response_fire)
                read_pending <= 1'b0;

            if (layer_start_valid && layer_start_ready) begin
                if (active_write ||
                    (layer_start_bank == 1'b0 && bank0_state != OWNER_FREE) ||
                    (layer_start_bank == 1'b1 && bank1_state != OWNER_FREE) ||
                    (layer_start_expected_words > LINE_WORDS*4)) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_START |
                                  (active_write ? ERR_DUAL : 8'h00);
                end else begin
                    active_write         <= 1'b1;
                    active_write_bank    <= layer_start_bank;
                    write_epoch_active   <= layer_start_epoch;
                    write_count          <= 32'd0;
                    write_expected_words <= layer_start_expected_words;
                    write_last_seen      <= 1'b0;
                    if (!layer_start_bank) begin
                        bank0_state <= OWNER_WRITE;
                        bank0_epoch <= layer_start_epoch;
                    end else begin
                        bank1_state <= OWNER_WRITE;
                        bank1_epoch <= layer_start_epoch;
                    end
                end
            end

            if (write_accept) begin
                write_resp_valid <= 1'b1;
                write_resp_bank  <= write_bank;
                write_resp_epoch <= write_epoch;
                write_resp_addr  <= write_addr;
                if (!write_meta_ok) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_STALE | ERR_DUAL |
                                  ((active_write && write_bank == active_write_bank) ? ERR_SAME_BANK : 8'h00);
                end else if (!write_addr_aligned) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_ALIGN;
                end else if (!write_addr_in_range) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_RANGE;
                end else begin
                    write_count <= write_count + 1'b1;
                    if (write_last)
                        write_last_seen <= 1'b1;
                end
            end

            if (commit_cmd_valid && (layer_end_ready || commit_ready)) begin
                if (!active_write || commit_cmd_bank != active_write_bank ||
                    commit_cmd_epoch != write_epoch_active || !write_last_seen ||
                    write_count != write_expected_words ||
                    (write_resp_valid && !write_resp_ready)) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_EARLY | ERR_COMMIT;
                end else begin
                    active_write   <= 1'b0;
                    commit_pending <= 1'b1;
                    commit_done    <= 1'b1;
                    layer_end_done <= 1'b1;
                    atomic_swap    <= 1'b1;
                    if (!active_write_bank) begin
                        bank0_state       <= OWNER_COMMITTED;
                        bank1_state       <= OWNER_FREE;
                        bank0_epoch       <= write_epoch_active;
                        active_read_bank  <= 1'b0;
                        active_read_epoch <= write_epoch_active;
                    end else begin
                        bank1_state       <= OWNER_COMMITTED;
                        bank0_state       <= OWNER_FREE;
                        bank1_epoch       <= write_epoch_active;
                        active_read_bank  <= 1'b1;
                        active_read_epoch <= write_epoch_active;
                    end
                end
            end

            if (read_accept) begin
                if (!selected_bank_read) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_SAME_BANK |
                                  ((active_write && selected_read_bank == active_write_bank) ? ERR_DUAL : 8'h00);
                end else if (!selected_epoch_ok) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_STALE;
                end else if (read_req_addr[3:0] != 4'h0) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_ALIGN;
                end else if (read_req_addr > (BANK_BYTES - 16)) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_RANGE;
                end else begin
                    read_pending       <= 1'b1;
                    read_pending_bank  <= selected_read_bank;
                    read_resp_bank    <= selected_read_bank;
                    read_resp_epoch   <= selected_read_epoch;
                end
            end
        end
    end
endmodule

`default_nettype wire
