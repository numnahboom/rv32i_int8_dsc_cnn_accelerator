`timescale 1ns/1ps
`default_nettype none

/*
 * Retained-bank PW replay controller for one DS1 2x8 microgroup.
 *
 * The data bank is deliberately outside this module.  A caller presents a
 * committed-bank descriptor, the controller acquires that bank once, and it
 * then serialises the complete eight-job PW replay:
 *
 *       row 0: Cout groups 0,1,2,3
 *       row 1: Cout groups 0,1,2,3
 *
 * Each job reads K=0..15 from the same bank.  The bank response is one
 * 8-pixel activation vector and is consumed by the existing 8x8 systolic
 * array.  k_count is intentionally eight on every token; the two K groups
 * are partial-K metadata only and do not publish an intermediate result.
 *
 * `start_*` is a ready/valid acceptance of an already committed external
 * scratch descriptor.  No bank implementation is instantiated here.  The
 * matching acquire/release channels are the tagless bank ABI used by
 * ds_pw_spatial_tile_bank_tagless.
 *
 * The weight input is a narrow lookup boundary.  It must be held/derived
 * from weight_k_index and weight_cout_group while weight_valid is asserted;
 * it is sampled only when the corresponding bank read is accepted.  This
 * keeps weight lookup outside the controller and makes the retained replay
 * primitive usable with either registers or a BRAM-backed weight store.
 */
module ds1_pw_replay_controller #(
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH  = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,

    /* Descriptor of a bank that has already reached COMMITTED. */
    input  wire                         start_valid,
    output wire                         start_ready,
    input  wire                         start_bank,
    input  wire [EPOCH_WIDTH-1:0]       start_epoch,
    input  wire [TILE_WIDTH-1:0]        start_tile,
    input  wire [5:0]                   start_row0_pixel_base,
    input  wire [5:0]                   start_row1_pixel_base,

    /* One acquire for all eight row/Cout jobs. */
    output wire                         pw_acquire_valid,
    input  wire                         pw_acquire_ready,
    output wire                         pw_acquire_bank,
    output wire [EPOCH_WIDTH-1:0]       pw_acquire_epoch,
    output wire [TILE_WIDTH-1:0]        pw_acquire_tile,

    /* Tagless retained-bank read request. */
    output wire                         pw_read_valid,
    input  wire                         pw_read_ready,
    output wire [6:0]                   pw_read_channel_idx,
    output wire [5:0]                   pw_read_pixel_base,

    /* Tagless retained-bank response. */
    input  wire                         pw_out_valid,
    output wire                         pw_out_ready,
    input  wire [63:0]                  pw_out_data,
    input  wire [7:0]                   pw_out_lane_mask,

    /* External weight lookup boundary, sampled on each accepted read. */
    output wire                         weight_valid,
    output wire [3:0]                   weight_k_index,
    output wire [1:0]                   weight_cout_group,
    input  wire signed [63:0]           weight_vec,

    /* One exact 8x8 psum transaction per row/Cout group. */
    output wire                         out_valid,
    input  wire                         out_ready,
    output wire                         out_row_idx,
    output wire [1:0]                   out_cout_group,
    output wire signed [2047:0]         out_psum,

    /* One release after all eight output handshakes. */
    output wire                         pw_release_valid,
    input  wire                         pw_release_ready,
    output wire                         pw_release_bank,
    output wire [EPOCH_WIDTH-1:0]       pw_release_epoch,
    output wire [TILE_WIDTH-1:0]        pw_release_tile,

    output wire                         busy,
    output reg                          done
);
    localparam [3:0] ST_IDLE    = 4'd0;
    localparam [3:0] ST_ACQUIRE = 4'd1;
    localparam [3:0] ST_READ    = 4'd2;
    localparam [3:0] ST_WAITOUT = 4'd3;
    localparam [3:0] ST_RELEASE = 4'd4;

    reg [3:0] state;
    reg       bank_q;
    reg [EPOCH_WIDTH-1:0] epoch_q;
    reg [TILE_WIDTH-1:0] tile_q;
    reg [5:0] row0_base_q;
    reg [5:0] row1_base_q;
    reg [2:0] job_q;          /* {row, Cout-group}; eight jobs total. */
    reg [3:0] read_k_q;
    reg       final_read_issued_q;

    /* Metadata and weights paired with the one outstanding bank response. */
    reg [3:0] response_k_q;
    reg signed [63:0] response_weight_q;

    wire start_fire = start_valid && start_ready;
    wire acquire_fire = pw_acquire_valid && pw_acquire_ready;
    wire read_fire = pw_read_valid && pw_read_ready;
    wire array_valid_in;
    wire array_ready_in;
    wire array_valid_out;
    wire signed [2047:0] array_psum_out;
    wire response_fire = pw_out_valid && pw_out_ready;
    wire output_fire = out_valid && out_ready;
    wire release_fire = pw_release_valid && pw_release_ready;

    assign start_ready = rst_n && (state == ST_IDLE);
    assign pw_acquire_valid = (state == ST_ACQUIRE);
    assign pw_acquire_bank = bank_q;
    assign pw_acquire_epoch = epoch_q;
    assign pw_acquire_tile = tile_q;

    /* A request remains stable until the bank accepts it.  The bank ABI
     * accepts one channel at a time, and its own ready signal fences the
     * registered response before another request can be issued. */
    /* Once K=15 has been accepted, wait for its registered bank response
     * before leaving the read phase.  Without this fence a bank may legally
     * assert read_ready in the same cycle that K=14's response is consumed,
     * causing a duplicate K=15 request while the controller is transitioning
     * to output. */
    assign pw_read_valid = (state == ST_READ) && !final_read_issued_q;
    assign pw_read_channel_idx = {3'd0, read_k_q};
    assign pw_read_pixel_base = job_q[2] ? row1_base_q : row0_base_q;

    assign weight_valid = (state == ST_READ);
    assign weight_k_index = read_k_q;
    assign weight_cout_group = job_q[1:0];

    /* The systolic array is the response consumer.  It is elastic at its
     * input, so the bank response remains held whenever the array stalls. */
    assign array_valid_in = (state == ST_READ) && pw_out_valid;
    assign pw_out_ready = (state == ST_READ) && array_ready_in;

    pw_systolic_array_8x8 u_pw_array (
        .clk(clk), .rst_n(rst_n),
        .valid_in(array_valid_in), .ready_in(array_ready_in),
        .first_k(response_k_q == 4'd0),
        .last_k(response_k_q == 4'd15),
        .k_group({7'd0, response_k_q[3]}),
        .k_count(8'd8),
        .clear_acc(1'b0), .k_last(1'b0),
        .act_vec($signed(pw_out_data)),
        .wgt_vec(response_weight_q),
        .ready_out(out_ready),
        .valid_out(array_valid_out), .psum_out(array_psum_out)
    );

    /* The array emits exactly one transaction after each 16-token job.  The
     * job tag is held in job_q for the complete output stall interval. */
    assign out_valid = (state == ST_WAITOUT) && array_valid_out;
    assign out_row_idx = job_q[2];
    assign out_cout_group = job_q[1:0];
    assign out_psum = array_psum_out;

    /* A response cannot remain pending when array_valid_out is asserted, but
     * explicitly fence both signals before exposing release.  This makes the
     * ownership transition robust against a future bank with a deeper output
     * queue and documents the required completion condition. */
    assign pw_release_valid = (state == ST_RELEASE) &&
                              !pw_out_valid && !array_valid_out;
    assign pw_release_bank = bank_q;
    assign pw_release_epoch = epoch_q;
    assign pw_release_tile = tile_q;
    assign busy = (state != ST_IDLE);

`ifndef SYNTHESIS
    integer sim_acquire_count;
    integer sim_release_count;
    integer sim_output_count;
    integer sim_read_count;
    integer sim_protocol_errors;
    reg sim_hold_valid;
    reg [2:0] sim_hold_job;
    reg signed [2047:0] sim_hold_psum;
`endif

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            bank_q <= 1'b0;
            epoch_q <= {EPOCH_WIDTH{1'b0}};
            tile_q <= {TILE_WIDTH{1'b0}};
            row0_base_q <= 6'd0;
            row1_base_q <= 6'd8;
            job_q <= 3'd0;
            read_k_q <= 4'd0;
            final_read_issued_q <= 1'b0;
            response_k_q <= 4'd0;
            response_weight_q <= 64'sd0;
            done <= 1'b0;
`ifndef SYNTHESIS
            sim_acquire_count <= 0;
            sim_release_count <= 0;
            sim_output_count <= 0;
            sim_read_count <= 0;
            sim_protocol_errors <= 0;
            sim_hold_valid <= 1'b0;
            sim_hold_job <= 3'd0;
            sim_hold_psum <= 2048'sd0;
`endif
        end else begin
            done <= 1'b0;

`ifndef SYNTHESIS
            /* ready/valid stability at both externally visible boundaries. */
            if (sim_hold_valid) begin
                if (!out_valid || out_row_idx !== sim_hold_job[2] ||
                    out_cout_group !== sim_hold_job[1:0] ||
                    out_psum !== sim_hold_psum) begin
                    $display("DS1_PW_ASSERT output_changed_under_stall");
                    sim_protocol_errors <= sim_protocol_errors + 1;
                end
            end
            if (out_valid && !out_ready) begin
                sim_hold_valid <= 1'b1;
                sim_hold_job <= job_q;
                sim_hold_psum <= array_psum_out;
            end else begin
                sim_hold_valid <= 1'b0;
            end
            if (read_fire) sim_read_count <= sim_read_count + 1;
            if (acquire_fire) sim_acquire_count <= sim_acquire_count + 1;
            if (output_fire) sim_output_count <= sim_output_count + 1;
            /* A retained controller is intentionally reusable without reset;
             * the simulation fence counter is per acquired session, just as
             * the eight-job protocol itself is. */
            if (start_fire) sim_output_count <= 0;
            if (release_fire) sim_release_count <= sim_release_count + 1;
            if (release_fire && (sim_output_count != 8)) begin
                $display("DS1_PW_ASSERT release_before_eight_outputs count=%0d",
                         sim_output_count);
                sim_protocol_errors <= sim_protocol_errors + 1;
            end
`endif

            case (state)
                ST_IDLE: begin
                    if (start_fire) begin
                        bank_q <= start_bank;
                        epoch_q <= start_epoch;
                        tile_q <= start_tile;
                        row0_base_q <= start_row0_pixel_base;
                        row1_base_q <= start_row1_pixel_base;
                        job_q <= 3'd0;
                        read_k_q <= 4'd0;
                        final_read_issued_q <= 1'b0;
                        state <= ST_ACQUIRE;
                    end
                end

                ST_ACQUIRE: begin
                    if (acquire_fire) begin
                        read_k_q <= 4'd0;
                        final_read_issued_q <= 1'b0;
                        state <= ST_READ;
                    end
                end

                ST_READ: begin
                    /* Capture both sides of the read/response pairing on
                     * request acceptance.  If a response and a new request
                     * share an edge, nonblocking assignments ensure the
                     * array still sees the old (matching) response metadata. */
                    if (read_fire) begin
                        response_k_q <= read_k_q;
                        response_weight_q <= weight_vec;
                        if (read_k_q == 4'd15)
                            final_read_issued_q <= 1'b1;
                        else
                            read_k_q <= read_k_q + 1'b1;
                    end
                    if (response_fire && (response_k_q == 4'd15))
                        state <= ST_WAITOUT;
                end

                ST_WAITOUT: begin
                    if (output_fire) begin
                        if (job_q == 3'd7) begin
                            state <= ST_RELEASE;
                        end else begin
                            job_q <= job_q + 1'b1;
                            read_k_q <= 4'd0;
                            final_read_issued_q <= 1'b0;
                            state <= ST_READ;
                        end
                    end
                end

                ST_RELEASE: begin
                    if (release_fire) begin
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
