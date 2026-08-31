`timescale 1ns/1ps
`default_nettype none

/*
 * Two-bank ownership/fence controller for feature tiles.
 *
 * The controller deliberately contains no RAM or datapath.  A bank follows
 * the one-way protocol FREE -> FILLING -> READY -> ACTIVE -> CONSUMED ->
 * FREE.  The descriptor captured by fill_start is the bank's identity until
 * release.  All command ready signals and all event descriptors are
 * registered; there is no combinational ready path between command sources,
 * the two banks, and event sinks.  The two banks are independent, so a fill
 * may proceed on one bank while the other is ACTIVE.
 *
 * A command always receives exactly one response.  Invalid commands are
 * acknowledged with ok=0 and leave ownership unchanged.  The one-entry
 * response queues intentionally insert a bubble after an accepted command;
 * this is control logic, where the explicit fence and bounded fanout are
 * more important than command issue rate.
 */
module feature_tile_pingpong_ctrl #(
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TAG_WIDTH = 8,
    parameter integer EXTENT_WIDTH = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         fill_start_valid,
    output reg                          fill_start_ready,
    input  wire                         fill_start_bank,
    input  wire [EPOCH_WIDTH-1:0]       fill_start_epoch,
    input  wire [TAG_WIDTH-1:0]         fill_start_tag,
    input  wire [EXTENT_WIDTH-1:0]      fill_start_extent,
    output reg                          fill_start_resp_valid,
    input  wire                         fill_start_resp_ready,
    output reg                          fill_start_resp_ok,
    output reg [2:0]                    fill_start_resp_error,

    input  wire                         fill_done_valid,
    output reg                          fill_done_ready,
    input  wire                         fill_done_bank,
    input  wire [EPOCH_WIDTH-1:0]       fill_done_epoch,
    input  wire [TAG_WIDTH-1:0]         fill_done_tag,
    input  wire [EXTENT_WIDTH-1:0]      fill_done_extent,
    output reg                          fill_done_desc_valid,
    input  wire                         fill_done_desc_ready,
    output reg                          fill_done_desc_bank,
    output reg [EPOCH_WIDTH-1:0]         fill_done_desc_epoch,
    output reg [TAG_WIDTH-1:0]           fill_done_desc_tag,
    output reg [EXTENT_WIDTH-1:0]        fill_done_desc_extent,
    output reg                          fill_done_ok,
    output reg [2:0]                    fill_done_error,

    input  wire                         acquire_valid,
    output reg                          acquire_ready,
    input  wire                         acquire_bank,
    input  wire [EPOCH_WIDTH-1:0]       acquire_epoch,
    input  wire [TAG_WIDTH-1:0]         acquire_tag,
    input  wire [EXTENT_WIDTH-1:0]      acquire_extent,
    output reg                          active_desc_valid,
    input  wire                         active_desc_ready,
    output reg                          active_desc_bank,
    output reg [EPOCH_WIDTH-1:0]         active_desc_epoch,
    output reg [TAG_WIDTH-1:0]           active_desc_tag,
    output reg [EXTENT_WIDTH-1:0]        active_desc_extent,
    output reg                          acquire_ok,
    output reg [2:0]                    acquire_error,

    input  wire                         consume_done_valid,
    output reg                          consume_done_ready,
    input  wire                         consume_done_bank,
    input  wire [EPOCH_WIDTH-1:0]       consume_done_epoch,
    input  wire [TAG_WIDTH-1:0]         consume_done_tag,
    input  wire [EXTENT_WIDTH-1:0]      consume_done_extent,
    output reg                          consume_done_resp_valid,
    input  wire                         consume_done_resp_ready,
    output reg                          consume_done_ok,
    output reg [2:0]                    consume_done_error,

    input  wire                         release_valid,
    output reg                          release_ready,
    input  wire                         release_bank,
    input  wire [EPOCH_WIDTH-1:0]       release_epoch,
    input  wire [TAG_WIDTH-1:0]         release_tag,
    input  wire [EXTENT_WIDTH-1:0]      release_extent,
    output reg                          release_resp_valid,
    input  wire                         release_resp_ready,
    output reg                          release_ok,
    output reg [2:0]                    release_error,

    output reg [2:0]                    bank0_state,
    output reg [2:0]                    bank1_state
);
    localparam [2:0] S_FREE = 3'd0;
    localparam [2:0] S_FILL = 3'd1;
    localparam [2:0] S_READY = 3'd2;
    localparam [2:0] S_ACTIVE = 3'd3;
    localparam [2:0] S_DONE = 3'd4;

    /* Error values are stable ABI for scoreboards and future users. */
    localparam [2:0] ERR_NONE = 3'd0;
    localparam [2:0] ERR_STATE = 3'd1;
    localparam [2:0] ERR_DESCRIPTOR = 3'd2;

    reg [EPOCH_WIDTH-1:0] bank_epoch [0:1];
    reg [TAG_WIDTH-1:0] bank_tag [0:1];
    reg [EXTENT_WIDTH-1:0] bank_extent [0:1];

    wire fill_start_fire = fill_start_valid && fill_start_ready;
    wire fill_done_fire = fill_done_valid && fill_done_ready;
    wire acquire_fire = acquire_valid && acquire_ready;
    wire consume_done_fire = consume_done_valid && consume_done_ready;
    wire release_fire = release_valid && release_ready;

    wire fill_start_state_ok = fill_start_bank ?
        (bank1_state == S_FREE) : (bank0_state == S_FREE);
    wire fill_done_state_ok = fill_done_bank ?
        (bank1_state == S_FILL) : (bank0_state == S_FILL);
    wire fill_done_desc_ok = fill_done_bank ?
        ((fill_done_epoch == bank_epoch[1]) &&
         (fill_done_tag == bank_tag[1]) &&
         (fill_done_extent == bank_extent[1])) :
        ((fill_done_epoch == bank_epoch[0]) &&
         (fill_done_tag == bank_tag[0]) &&
         (fill_done_extent == bank_extent[0]));
    wire acquire_state_ok = acquire_bank ?
        (bank1_state == S_READY) : (bank0_state == S_READY);
    wire acquire_desc_ok = acquire_bank ?
        ((acquire_epoch == bank_epoch[1]) &&
         (acquire_tag == bank_tag[1]) &&
         (acquire_extent == bank_extent[1])) :
        ((acquire_epoch == bank_epoch[0]) &&
         (acquire_tag == bank_tag[0]) &&
         (acquire_extent == bank_extent[0]));
    wire consume_state_ok = consume_done_bank ?
        (bank1_state == S_ACTIVE) : (bank0_state == S_ACTIVE);
    wire consume_desc_ok = consume_done_bank ?
        ((consume_done_epoch == bank_epoch[1]) &&
         (consume_done_tag == bank_tag[1]) &&
         (consume_done_extent == bank_extent[1])) :
        ((consume_done_epoch == bank_epoch[0]) &&
         (consume_done_tag == bank_tag[0]) &&
         (consume_done_extent == bank_extent[0]));
    wire release_state_ok = release_bank ?
        (bank1_state == S_DONE) : (bank0_state == S_DONE);
    wire release_desc_ok = release_bank ?
        ((release_epoch == bank_epoch[1]) &&
         (release_tag == bank_tag[1]) &&
         (release_extent == bank_extent[1])) :
        ((release_epoch == bank_epoch[0]) &&
         (release_tag == bank_tag[0]) &&
         (release_extent == bank_extent[0]));

    wire fill_start_ok = fill_start_fire && fill_start_state_ok;
    wire fill_done_ok_w = fill_done_fire && fill_done_state_ok && fill_done_desc_ok;
    wire acquire_ok_w = acquire_fire && acquire_state_ok && acquire_desc_ok;
    wire consume_done_ok_w = consume_done_fire && consume_state_ok && consume_desc_ok;
    wire release_ok_w = release_fire && release_state_ok && release_desc_ok;

    /* Keep command ready outputs registered.  A response queue is never
     * overwritten: after a command fire, ready is held low until the old or
     * newly generated response has been observed by its sink. */
    always @(posedge clk) begin
        if (!rst_n) begin
            fill_start_ready <= 1'b0;
            fill_done_ready <= 1'b0;
            acquire_ready <= 1'b0;
            consume_done_ready <= 1'b0;
            release_ready <= 1'b0;
        end else begin
            if (fill_start_fire)
                fill_start_ready <= 1'b0;
            else if (!fill_start_resp_valid || fill_start_resp_ready)
                fill_start_ready <= 1'b1;
            else
                fill_start_ready <= 1'b0;

            if (fill_done_fire)
                fill_done_ready <= 1'b0;
            else if (!fill_done_desc_valid || fill_done_desc_ready)
                fill_done_ready <= 1'b1;
            else
                fill_done_ready <= 1'b0;

            if (acquire_fire)
                acquire_ready <= 1'b0;
            else if (!active_desc_valid || active_desc_ready)
                acquire_ready <= 1'b1;
            else
                acquire_ready <= 1'b0;

            if (consume_done_fire)
                consume_done_ready <= 1'b0;
            else if (!consume_done_resp_valid || consume_done_resp_ready)
                consume_done_ready <= 1'b1;
            else
                consume_done_ready <= 1'b0;

            if (release_fire)
                release_ready <= 1'b0;
            else if (!release_resp_valid || release_resp_ready)
                release_ready <= 1'b1;
            else
                release_ready <= 1'b0;
        end
    end

    integer bi;
    always @(posedge clk) begin
        if (!rst_n) begin
            bank0_state <= S_FREE;
            bank1_state <= S_FREE;
            for (bi = 0; bi < 2; bi = bi + 1) begin
                bank_epoch[bi] <= {EPOCH_WIDTH{1'b0}};
                bank_tag[bi] <= {TAG_WIDTH{1'b0}};
                bank_extent[bi] <= {EXTENT_WIDTH{1'b0}};
            end

            fill_start_resp_valid <= 1'b0;
            fill_start_resp_ok <= 1'b0;
            fill_start_resp_error <= ERR_NONE;
            fill_done_desc_valid <= 1'b0;
            fill_done_desc_bank <= 1'b0;
            fill_done_desc_epoch <= {EPOCH_WIDTH{1'b0}};
            fill_done_desc_tag <= {TAG_WIDTH{1'b0}};
            fill_done_desc_extent <= {EXTENT_WIDTH{1'b0}};
            fill_done_ok <= 1'b0;
            fill_done_error <= ERR_NONE;
            active_desc_valid <= 1'b0;
            active_desc_bank <= 1'b0;
            active_desc_epoch <= {EPOCH_WIDTH{1'b0}};
            active_desc_tag <= {TAG_WIDTH{1'b0}};
            active_desc_extent <= {EXTENT_WIDTH{1'b0}};
            acquire_ok <= 1'b0;
            acquire_error <= ERR_NONE;
            consume_done_resp_valid <= 1'b0;
            consume_done_ok <= 1'b0;
            consume_done_error <= ERR_NONE;
            release_resp_valid <= 1'b0;
            release_ok <= 1'b0;
            release_error <= ERR_NONE;
        end else begin
            /* Every response is held until its point-to-point ready. */
            if (fill_start_resp_valid && fill_start_resp_ready)
                fill_start_resp_valid <= 1'b0;
            if (fill_done_desc_valid && fill_done_desc_ready)
                fill_done_desc_valid <= 1'b0;
            if (active_desc_valid && active_desc_ready)
                active_desc_valid <= 1'b0;
            if (consume_done_resp_valid && consume_done_resp_ready)
                consume_done_resp_valid <= 1'b0;
            if (release_resp_valid && release_resp_ready)
                release_resp_valid <= 1'b0;

            if (fill_start_fire) begin
                fill_start_resp_valid <= 1'b1;
                fill_start_resp_ok <= fill_start_state_ok;
                fill_start_resp_error <= fill_start_state_ok ? ERR_NONE : ERR_STATE;
            end
            if (fill_done_fire) begin
                fill_done_desc_valid <= 1'b1;
                fill_done_desc_bank <= fill_done_bank;
                fill_done_desc_epoch <= fill_done_epoch;
                fill_done_desc_tag <= fill_done_tag;
                fill_done_desc_extent <= fill_done_extent;
                fill_done_ok <= fill_done_state_ok && fill_done_desc_ok;
                if (!fill_done_state_ok)
                    fill_done_error <= ERR_STATE;
                else if (!fill_done_desc_ok)
                    fill_done_error <= ERR_DESCRIPTOR;
                else
                    fill_done_error <= ERR_NONE;
            end
            if (acquire_fire) begin
                active_desc_valid <= 1'b1;
                active_desc_bank <= acquire_bank;
                active_desc_epoch <= acquire_epoch;
                active_desc_tag <= acquire_tag;
                active_desc_extent <= acquire_extent;
                acquire_ok <= acquire_state_ok && acquire_desc_ok;
                if (!acquire_state_ok)
                    acquire_error <= ERR_STATE;
                else if (!acquire_desc_ok)
                    acquire_error <= ERR_DESCRIPTOR;
                else
                    acquire_error <= ERR_NONE;
            end
            if (consume_done_fire) begin
                consume_done_resp_valid <= 1'b1;
                consume_done_ok <= consume_state_ok && consume_desc_ok;
                if (!consume_state_ok)
                    consume_done_error <= ERR_STATE;
                else if (!consume_desc_ok)
                    consume_done_error <= ERR_DESCRIPTOR;
                else
                    consume_done_error <= ERR_NONE;
            end
            if (release_fire) begin
                release_resp_valid <= 1'b1;
                release_ok <= release_state_ok && release_desc_ok;
                if (!release_state_ok)
                    release_error <= ERR_STATE;
                else if (!release_desc_ok)
                    release_error <= ERR_DESCRIPTOR;
                else
                    release_error <= ERR_NONE;
            end

            /* State updates are disjoint by protocol state, allowing both
             * banks to advance on the same edge. */
            if (fill_start_ok) begin
                if (fill_start_bank) begin
                    bank1_state <= S_FILL;
                    bank_epoch[1] <= fill_start_epoch;
                    bank_tag[1] <= fill_start_tag;
                    bank_extent[1] <= fill_start_extent;
                end else begin
                    bank0_state <= S_FILL;
                    bank_epoch[0] <= fill_start_epoch;
                    bank_tag[0] <= fill_start_tag;
                    bank_extent[0] <= fill_start_extent;
                end
            end
            if (fill_done_ok_w) begin
                if (fill_done_bank) bank1_state <= S_READY;
                else bank0_state <= S_READY;
            end
            if (acquire_ok_w) begin
                if (acquire_bank) bank1_state <= S_ACTIVE;
                else bank0_state <= S_ACTIVE;
            end
            if (consume_done_ok_w) begin
                if (consume_done_bank) bank1_state <= S_DONE;
                else bank0_state <= S_DONE;
            end
            if (release_ok_w) begin
                if (release_bank) begin
                    bank1_state <= S_FREE;
                    bank_epoch[1] <= {EPOCH_WIDTH{1'b0}};
                    bank_tag[1] <= {TAG_WIDTH{1'b0}};
                    bank_extent[1] <= {EXTENT_WIDTH{1'b0}};
                end else begin
                    bank0_state <= S_FREE;
                    bank_epoch[0] <= {EPOCH_WIDTH{1'b0}};
                    bank_tag[0] <= {TAG_WIDTH{1'b0}};
                    bank_extent[0] <= {EXTENT_WIDTH{1'b0}};
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (EPOCH_WIDTH < 1 || TAG_WIDTH < 1 || EXTENT_WIDTH < 1)
            $error("descriptor widths must be positive");
    end
`endif
endmodule

`default_nettype wire
