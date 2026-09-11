`timescale 1ns/1ps
`default_nettype none

/*
 * D4 vstream v6 DW raw-result FIFO.
 *
 * A captured DW vector is one 512-bit transaction: sixteen 32-bit lanes are
 * written to the same circular slot on one push handshake.  The read side is
 * a synchronous, one-entry response channel.  A response remains valid until
 * it is consumed, and a consumed response can be replaced by the next head
 * read on the same edge.  FIFO occupancy and pointers are kept here so a
 * full/empty boundary cannot overwrite a live raw result.
 *
 * In synthesis each lane is an explicit 64x32 XPM simple-dual-port RAM.  The
 * behavioral model deliberately has the same one-cycle response and uses
 * read-first semantics for a simultaneous read/write of one slot.
 */
module edgembconv_hwacandidate_d4_vstream_v6_raw_fifo #(
    parameter integer DEPTH = 64,
    parameter integer ADDR_WIDTH = 6
) (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 push_valid,
    output wire                 push_ready,
    input  wire [511:0]         push_data,

    input  wire                 read_valid,
    output wire                 read_ready,
    output wire                 resp_valid,
    input  wire                 resp_ready,
    output wire [511:0]         resp_data,

    input  wire                 pop_valid,
    output wire                 pop_ready,

    output wire [ADDR_WIDTH:0]  fifo_count,
    output wire [ADDR_WIDTH-1:0] fifo_head,
    output wire [ADDR_WIDTH-1:0] fifo_tail
);
    reg [ADDR_WIDTH:0] count_q;
    reg [ADDR_WIDTH-1:0] head_q, tail_q;
    reg resp_q;

    wire pop_fire = pop_valid && pop_ready;
    wire push_fire = push_valid && push_ready;
    wire read_fire = read_valid && read_ready;

    assign fifo_count = count_q;
    assign fifo_head = head_q;
    assign fifo_tail = tail_q;
    assign resp_valid = resp_q;

    /* A full FIFO can accept a replacement only when the current head is
     * retiring on this edge.  A read response is never discarded while
     * stalled. */
    assign pop_ready = rst_n && (count_q != 0) && (!resp_q || resp_ready);
    assign push_ready = rst_n && ((count_q < DEPTH) || pop_fire);
    assign read_ready = rst_n && (count_q != 0) && (!resp_q || resp_ready);

`ifndef SYNTHESIS
    (* ram_style = "block" *) reg [31:0] raw_mem [0:15][0:DEPTH-1];
    reg [511:0] resp_data_q;
    integer lane;

    always @(posedge clk) begin
        if (!rst_n) begin
            count_q <= 0;
            head_q <= 0;
            tail_q <= 0;
            resp_q <= 1'b0;
        end else begin
            if (resp_q && resp_ready)
                resp_q <= 1'b0;

            /* The old value is intentionally selected before the write in a
             * same-slot collision, matching XPM WRITE_MODE_B=read_first. */
            if (read_fire) begin
                resp_q <= 1'b1;
                for (lane = 0; lane < 16; lane = lane + 1)
                    resp_data_q[lane*32 +: 32] <= raw_mem[lane][head_q];
            end
            if (push_fire) begin
                for (lane = 0; lane < 16; lane = lane + 1)
                    raw_mem[lane][tail_q] <= push_data[lane*32 +: 32];
                tail_q <= tail_q + 1'b1;
            end
            if (pop_fire)
                head_q <= head_q + 1'b1;

            case ({push_fire, pop_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

    assign resp_data = resp_data_q;
`else
    wire [31:0] raw_dout [0:15];
    wire [511:0] raw_dout_vec;
    genvar lane_g;
    generate
      for (lane_g = 0; lane_g < 16; lane_g = lane_g + 1) begin : gen_raw_lane
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(ADDR_WIDTH), .ADDR_WIDTH_B(ADDR_WIDTH),
          .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(32),
          .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
          .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
          .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
          .MEMORY_SIZE(DEPTH*32), .MESSAGE_CONTROL(0),
          .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
          .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
          .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(32),
          .WRITE_MODE_B("read_first")
        ) u_mem (
          .clka(clk), .ena(push_fire), .wea(push_fire), .addra(tail_q),
          .dina(push_data[lane_g*32 +: 32]), .clkb(clk),
          .enb(read_fire), .addrb(head_q), .doutb(raw_dout[lane_g]),
          .regceb(1'b1), .rstb(1'b0), .sleep(1'b0),
          .injectsbiterra(1'b0), .injectdbiterra(1'b0),
          .sbiterrb(), .dbiterrb()
        );
        assign raw_dout_vec[lane_g*32 +: 32] = raw_dout[lane_g];
      end
    endgenerate

    /* XPM already supplies the registered read data.  Keeping this vector
     * directly on the response channel also permits a same-edge response
     * consume and next-read replacement without an extra bubble. */
    assign resp_data = raw_dout_vec;

    always @(posedge clk) begin
        if (!rst_n) begin
            count_q <= 0;
            head_q <= 0;
            tail_q <= 0;
            resp_q <= 1'b0;
        end else begin
            if (resp_q && resp_ready)
                resp_q <= 1'b0;
            if (read_fire)
                resp_q <= 1'b1;
            if (push_fire)
                tail_q <= tail_q + 1'b1;
            if (pop_fire)
                head_q <= head_q + 1'b1;
            case ({push_fire, pop_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end
`endif
endmodule

`default_nettype wire
