`timescale 1ns/1ps
`default_nettype none

/*
 * Registered source-request boundary for the v6 DW16 tile.
 *
 * The legacy DW primitive deliberately keeps a one-outstanding source
 * protocol, but its request address/valid are combinational from the tile
 * cursors.  Driving a synchronous BRAM directly from that interface exposes
 * the whole tap-in-bounds arithmetic cone to the BRAM enable pin.  This
 * adapter captures the request in a small elastic register and drives the
 * physical read port only from registered state.
 *
 * For the steady-state interior of the fixed v6 32x32/stride-2 deployment,
 * the following in-bounds tap is known when the current request is accepted.
 * Its address is precomputed into next_addr_q.  When the current response is
 * consumed, the registered look-ahead address can be issued on the same edge
 * as the tile's next request, preserving one accepted source word per cycle.
 * If the following tap is halo (or the current tap is the final tap), the
 * look-ahead is disabled and the normal elastic path accepts the next actual
 * request after the tile has advanced through its local zero taps/output.
 *
 * The look-ahead is an optimization, not a new source protocol: the adapter
 * still permits only one source response in flight and checks that the tile's
 * same-edge next request agrees with the registered prediction.
 */
module edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter #(
    parameter integer IN_W = 32,
    parameter integer IN_H = 32
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         enable,
    input  wire         command_start,

    input  wire         in_req_valid,
    output wire         in_req_ready,
    input  wire [31:0]  in_req_addr,
    input  wire [7:0]   in_req_pixel_idx,
    input  wire [3:0]   in_req_tap_idx,
    input  wire [31:0]  in_req_metadata,

    output wire         in_resp_valid,
    input  wire         in_resp_ready,
    output wire [127:0] in_resp_data,

    output wire         mem_req_valid,
    input  wire         mem_req_ready,
    output wire [10:0]  mem_req_addr,
    input  wire         service_ready,
    input  wire         mem_resp_valid,
    output wire         mem_resp_ready,
    input  wire [127:0] mem_resp_data,

    output reg          protocol_error
);
    localparam [10:0] ROW_TAP_DELTA = IN_W - 2;
    reg        request_valid_q;
    reg        request_sent_q;
    reg [31:0] request_addr_q;
    reg [31:0] next_addr_q;
    reg        next_valid_q;

    reg       next_valid_comb;
    reg [10:0] next_addr_comb;
    reg [10:0] tap_delta_comb;

    /*
     * The v6 scheduler instantiates the DW primitive with stride 2.  The tile
     * now owns a registered row/column cursor and presents the current word
     * address directly on in_req_addr.  Forming the following address from a
     * narrow fixed delta keeps the adapter out of the deep absolute
     * (output_x, output_y, bounds, multiply-by-width) cone that used to feed
     * next_addr_q.  The delta table is the row-major 3x3 tap walk for the
     * fixed v6 input width: +1, +1, +IN_W-2, +1, +1, +IN_W-2, +1, +1.
     *
     * next_valid_comb need not re-evaluate bounds.  If the following tap is a
     * halo, the tile's registered cursor deasserts in_req_valid and the
     * same-edge look-ahead window is therefore closed.  A valid source
     * request always carries an in-bounds current address.
     */
    always @* begin
        next_valid_comb = (in_req_tap_idx < 4'd8);
        case (in_req_tap_idx)
            4'd0, 4'd1, 4'd3, 4'd4, 4'd6, 4'd7:
                tap_delta_comb = 11'd1;
            4'd2, 4'd5:
                tap_delta_comb = ROW_TAP_DELTA;
            default:
                tap_delta_comb = 11'd0;
        endcase
        next_addr_comb = in_req_addr[10:0] + tap_delta_comb;
    end

    wire response_available = request_valid_q && request_sent_q &&
                               mem_resp_valid;
    /* A predicted replacement is consumed together with the current response.
     * service_ready is the external source-service throttle; using it here
     * avoids a ready/ready combinational loop through the BRAM response slot. */
    /* A replacement is only a true same-edge transfer when the physical
     * read port can accept it.  If mem_req_ready is low, consume the current
     * response and let the tile present the next request on the following
     * cycle; marking the replacement sent without this guard would drop it
     * at a ready stall and strand the tile behind an empty slot. */
    wire lookahead_window = response_available && next_valid_q &&
                            in_req_valid && in_resp_ready && service_ready &&
                            mem_req_ready;
    wire response_fire = response_available && mem_resp_ready;
    wire request_fire = in_req_valid && in_req_ready;
    wire mem_request_fire = mem_req_valid && mem_req_ready;

    assign in_req_ready = enable &&
                          ((!request_valid_q) || lookahead_window);
    assign in_resp_valid = response_available;
    assign in_resp_data = mem_resp_data;

    /* The first request is launched after request_addr_q is captured.  A
     * predicted replacement is launched from next_addr_q, both of which are
     * flops at the physical BRAM boundary. */
    assign mem_req_valid = (request_valid_q && !request_sent_q) ||
                           lookahead_window;
    assign mem_req_addr = (request_valid_q && !request_sent_q)
                        ? request_addr_q[10:0] : next_addr_q[10:0];

    /* The physical response must be consumed whenever the tile accepts it.
     * ``service_ready`` only throttles a replacement memory request; using it
     * to hold this response would let the tile observe/consume the adapter's
     * valid while the physical response remained queued, losing request/data
     * alignment under randomized service stalls.  When replacement service is
     * unavailable, lookahead_window is false and the tile naturally inserts a
     * one-cycle bubble before issuing the next request. */
    assign mem_resp_ready = response_available && in_resp_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            request_valid_q <= 1'b0;
            request_sent_q <= 1'b0;
            request_addr_q <= 32'd0;
            next_addr_q <= 32'd0;
            next_valid_q <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            protocol_error <= 1'b0;

            /* A DW command starts only after the previous tile has drained.
             * Clear the elastic state at that explicit boundary rather than
             * tying it to a transient FIFO-full condition. */
            if (command_start) begin
                request_valid_q <= 1'b0;
                request_sent_q <= 1'b0;
                request_addr_q <= 32'd0;
                next_addr_q <= 32'd0;
                next_valid_q <= 1'b0;
            end else begin
                if (request_fire && !request_valid_q) begin
                    request_valid_q <= 1'b1;
                    request_sent_q <= 1'b0;
                    request_addr_q <= in_req_addr;
                    next_addr_q <= {21'd0, next_addr_comb};
                    next_valid_q <= next_valid_comb;
                end

                if (mem_request_fire)
                    request_sent_q <= 1'b1;

                if (response_fire) begin
                    /* Only retain the slot for a same-edge replacement when
                     * the replacement window was actually open.  In
                     * particular, next_valid_q may be set for the following
                     * in-bounds tap while service_ready is low; the current
                     * response is still consumed, but the tile must then
                     * present that tap again on the next cycle.  Preserving
                     * the old slot in that case strands the tile behind a
                     * request that has already been consumed. */
                    if (lookahead_window && request_fire) begin
                        /* The predicted request is issued on this response
                         * edge.  The tile's next request is deterministic for
                         * the v6 one-outstanding primitive; flag any mismatch
                         * without changing the accepted data stream. */
                        if (in_req_addr != {21'd0, next_addr_q[10:0]})
                            protocol_error <= 1'b1;
                        request_valid_q <= 1'b1;
                        request_sent_q <= 1'b1;
                        request_addr_q <= in_req_addr;
                        next_addr_q <= {21'd0, next_addr_comb};
                        next_valid_q <= next_valid_comb;
                    end else begin
                        if (lookahead_window && !request_fire)
                            protocol_error <= 1'b1;
                        request_valid_q <= 1'b0;
                        request_sent_q <= 1'b0;
                        request_addr_q <= 32'd0;
                        next_addr_q <= 32'd0;
                        next_valid_q <= 1'b0;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
