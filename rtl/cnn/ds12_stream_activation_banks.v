`timescale 1ns/1ps
`default_nettype none

// Independent DS1/DS2 activation ping-pong store.
//
// The address on both request channels is a byte address.  Each bank has
// BANK_WORDS little-endian 32-bit words (the default is 32 KiB).  A layer is
// opened explicitly on a FREE bank, writes are accepted only for that bank
// and epoch, and a commit fence atomically changes the old READ bank to FREE
// and the new bank to READ.  The one-entry write response and read response
// registers are deliberately held under backpressure.
module ds12_stream_activation_banks #(
    parameter integer BANK_WORDS = 8192
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        layer_start_valid,
    output wire        layer_start_ready,
    input  wire        layer_start_bank,
    input  wire [31:0] layer_start_epoch,
    input  wire [31:0] layer_start_expected_bytes,

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

    input  wire        commit_valid,
    output wire        commit_ready,
    input  wire        commit_bank,
    input  wire [31:0] commit_epoch,
    output reg         commit_done,

    input  wire        read_req_valid,
    output wire        read_req_ready,
    input  wire        read_req_bank,
    input  wire [31:0] read_req_epoch,
    input  wire [31:0] read_req_addr,
    output reg         read_resp_valid,
    input  wire        read_resp_ready,
    output reg  [31:0] read_resp_data,
    output reg         read_resp_bank,
    output reg  [31:0] read_resp_epoch,
    output reg  [31:0] read_resp_addr,

    output reg  [1:0]  bank0_state,
    output reg  [1:0]  bank1_state,
    output reg  [31:0] bank0_epoch,
    output reg  [31:0] bank1_epoch,
    output reg  [31:0] write_epoch_active,
    output reg  [31:0] write_count,
    output reg  [31:0] write_expected_bytes,
    output reg         write_last_seen,
    output reg         error,
    output reg  [7:0]  error_code
);
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

    reg [31:0] bank0_mem [0:BANK_WORDS-1];
    reg [31:0] bank1_mem [0:BANK_WORDS-1];
    reg        active_write;
    reg        active_bank;
    reg        commit_pending;
    reg        read_pending;
    integer    b;
    integer    word_index;
    integer    byte_count;

    function automatic integer be_count;
        input [3:0] be;
        begin
            be_count = {31'd0, be[0]} + {31'd0, be[1]} +
                       {31'd0, be[2]} + {31'd0, be[3]};
        end
    endfunction

    wire write_ack_slot = (!write_resp_valid) || write_resp_ready;
    // A second start is intentionally handshakable so that a dual-owner
    // attempt is reported as an error instead of silently deadlocking.
    assign layer_start_ready = rst_n && !commit_pending;
    assign write_ready = rst_n && active_write && write_ack_slot;
    assign commit_ready = rst_n && active_write;
    assign read_req_ready = rst_n && !read_pending && !commit_pending;

    always @(posedge clk) begin
        if (!rst_n) begin
            bank0_state         <= OWNER_READ;
            bank1_state         <= OWNER_FREE;
            bank0_epoch        <= 32'd0;
            bank1_epoch        <= 32'd0;
            active_write       <= 1'b0;
            active_bank        <= 1'b0;
            commit_pending     <= 1'b0;
            write_epoch_active <= 32'd0;
            write_count        <= 32'd0;
            write_expected_bytes <= 32'd0;
            write_last_seen    <= 1'b0;
            write_resp_valid   <= 1'b0;
            write_resp_bank    <= 1'b0;
            write_resp_epoch   <= 32'd0;
            write_resp_addr    <= 32'd0;
            commit_done        <= 1'b0;
            read_pending       <= 1'b0;
            read_resp_valid    <= 1'b0;
            read_resp_data     <= 32'd0;
            read_resp_bank     <= 1'b0;
            read_resp_epoch    <= 32'd0;
            read_resp_addr     <= 32'd0;
            error              <= 1'b0;
            error_code         <= 8'd0;
        end else begin
            commit_done <= 1'b0;

            // Keep COMMITTED observable for one cycle, then publish READ.
            // No request channel is ready during this fence transition.
            if (commit_pending) begin
                commit_pending <= 1'b0;
                if (bank0_state == OWNER_COMMITTED)
                    bank0_state <= OWNER_READ;
                if (bank1_state == OWNER_COMMITTED)
                    bank1_state <= OWNER_READ;
            end

            if (write_resp_valid && write_resp_ready)
                write_resp_valid <= 1'b0;
            if (read_resp_valid && read_resp_ready) begin
                read_resp_valid <= 1'b0;
                read_pending <= 1'b0;
            end

            if (layer_start_valid && layer_start_ready) begin
                if (active_write ||
                    (layer_start_bank == 1'b0 && bank0_state != OWNER_FREE) ||
                    (layer_start_bank == 1'b1 && bank1_state != OWNER_FREE) ||
                    (layer_start_expected_bytes > BANK_WORDS*4)) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_START;
                    if (active_write)
                        error_code <= error_code | ERR_START | ERR_DUAL;
                end else begin
                    active_write <= 1'b1;
                    active_bank <= layer_start_bank;
                    write_epoch_active <= layer_start_epoch;
                    write_count <= 32'd0;
                    write_expected_bytes <= layer_start_expected_bytes;
                    write_last_seen <= 1'b0;
                    if (layer_start_bank == 1'b0) begin
                        bank0_state <= OWNER_WRITE;
                        bank0_epoch <= layer_start_epoch;
                    end else begin
                        bank1_state <= OWNER_WRITE;
                        bank1_epoch <= layer_start_epoch;
                    end
                end
            end

            if (write_valid && write_ready) begin
                // The response is an acknowledgement of every accepted
                // command, including a rejected command, so the producer can
                // always drain the command stream deterministically.
                write_resp_valid <= 1'b1;
                write_resp_bank <= write_bank;
                write_resp_epoch <= write_epoch;
                write_resp_addr <= write_addr;
                if (!active_write || write_bank != active_bank ||
                    write_epoch != write_epoch_active) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_STALE | ERR_DUAL;
                    if (active_write && write_bank == active_bank)
                        error_code <= error_code | ERR_STALE | ERR_SAME_BANK;
                end else if (write_addr[1:0] != 2'b00) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_ALIGN;
                end else if (write_addr >= BANK_WORDS*4) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_RANGE;
                end else begin
                    word_index = write_addr >> 2;
                    byte_count = be_count(write_be);
                    write_count <= write_count + byte_count;
                    if (write_last)
                        write_last_seen <= 1'b1;
                    if (write_bank == 1'b0) begin
                        for (b = 0; b < 4; b = b + 1)
                            if (write_be[b]) bank0_mem[word_index][b*8 +: 8] <= write_data[b*8 +: 8];
                    end else begin
                        for (b = 0; b < 4; b = b + 1)
                            if (write_be[b]) bank1_mem[word_index][b*8 +: 8] <= write_data[b*8 +: 8];
                    end
                end
            end

            if (commit_valid && commit_ready) begin
                if (!active_write || commit_bank != active_bank ||
                    commit_epoch != write_epoch_active || !write_last_seen ||
                    write_count != write_expected_bytes ||
                    (write_resp_valid && !write_resp_ready)) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_EARLY | ERR_COMMIT;
                end else begin
                    // This is the commit fence: the old READ bank is freed
                    // and the new bank is marked COMMITTED on this same
                    // edge.  COMMITTED changes to READ on the next edge.
                    active_write <= 1'b0;
                    commit_pending <= 1'b1;
                    commit_done <= 1'b1;
                    if (active_bank == 1'b0) begin
                        bank0_state <= OWNER_COMMITTED;
                        bank1_state <= OWNER_FREE;
                        bank0_epoch <= write_epoch_active;
                    end else begin
                        bank1_state <= OWNER_COMMITTED;
                        bank0_state <= OWNER_FREE;
                        bank1_epoch <= write_epoch_active;
                    end
                end
            end

            if (read_req_valid && read_req_ready) begin
                if ((read_req_bank == 1'b0 && bank0_state != OWNER_READ) ||
                    (read_req_bank == 1'b1 && bank1_state != OWNER_READ)) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_SAME_BANK;
                    if (active_write && read_req_bank == active_bank)
                        error_code <= error_code | ERR_SAME_BANK | ERR_DUAL;
                end else if ((read_req_bank == 1'b0 && read_req_epoch != bank0_epoch) ||
                             (read_req_bank == 1'b1 && read_req_epoch != bank1_epoch)) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_STALE;
                end else if (read_req_addr[1:0] != 2'b00) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_ALIGN;
                end else if (read_req_addr >= BANK_WORDS*4) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_RANGE;
                end else begin
                    word_index = read_req_addr >> 2;
                    if (read_req_bank == 1'b0)
                        read_resp_data <= bank0_mem[word_index];
                    else
                        read_resp_data <= bank1_mem[word_index];
                    read_resp_bank <= read_req_bank;
                    read_resp_epoch <= read_req_epoch;
                    read_resp_addr <= read_req_addr;
                    read_resp_valid <= 1'b1;
                    read_pending <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
