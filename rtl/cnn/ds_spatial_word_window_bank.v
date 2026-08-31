`timescale 1ns/1ps
`default_nettype none

/*
 * Passive spatial window store for a producer/consumer island boundary.
 *
 * A logical vector contains sixteen signed int8 channels.  It is stored as
 * four independent 32-bit planes; a write command updates exactly one plane
 * and a synchronous read gathers all four planes into one registered vector.
 * The address is intentionally already linearized by the caller.  The
 * default depth (17*17*3 vectors) covers a 17x17 footprint for three channel
 * groups while keeping the interface free of a divider or a spatial
 * scheduler.
 *
 * Both transaction payloads are registered at the island boundary.  A write
 * accepted on cycle N reaches the RAM on cycle N+1.  A read accepted on N
 * returns on N+2 (one RAM cycle plus the explicit vector register).  The
 * accepted write is forwarded on a same-address/same-plane collision, making
 * the externally visible behavior deterministic and write-first independent
 * of inferred RAM primitive collision mode.
 */
module ds_spatial_word_window_bank #(
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer MAX_CHANNEL_GROUPS = 3,
    parameter integer DEPTH = MAX_IN_H * MAX_IN_W * MAX_CHANNEL_GROUPS,
    parameter integer ADDR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TAG_WIDTH = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         wr_valid,
    output wire                         wr_ready,
    input  wire [ADDR_WIDTH-1:0]        wr_vector_addr,
    input  wire [1:0]                   wr_quarter,
    input  wire [31:0]                  wr_data,
    input  wire [EPOCH_WIDTH-1:0]       wr_epoch,
    output reg  [EPOCH_WIDTH-1:0]       wr_epoch_seen,

    input  wire                         rd_req_valid,
    output wire                         rd_req_ready,
    input  wire [ADDR_WIDTH-1:0]        rd_vector_addr,
    input  wire [15:0]                  rd_lane_mask,
    input  wire [TAG_WIDTH-1:0]         rd_tag,
    input  wire [EPOCH_WIDTH-1:0]       rd_epoch,

    output wire                         rd_resp_valid,
    input  wire                         rd_resp_ready,
    output wire [127:0]                 rd_data_vector,
    output wire [15:0]                  rd_resp_lane_mask,
    output wire [TAG_WIDTH-1:0]         rd_resp_tag,
    output wire [EPOCH_WIDTH-1:0]       rd_resp_epoch
);
    /* Explicit four-plane memories are preferred over a 128-bit RAM: this
     * keeps the gather boundary local and maps predictably to RAMB18/RAMB36.
     * The synthesis implementation below uses XPM to make that mapping
     * explicit; the simulation implementation is an equivalent synchronous
     * read model. */
    wire [31:0] plane_dout [0:3];

    reg                         wr_q_valid;
    reg [ADDR_WIDTH-1:0]        wr_q_addr;
    reg [1:0]                   wr_q_quarter;
    reg [31:0]                  wr_q_data;
    reg [EPOCH_WIDTH-1:0]       wr_q_epoch;

    reg                         rd_pending;
    reg [ADDR_WIDTH-1:0]        rd_q_addr;
    reg [15:0]                  rd_q_mask;
    reg [TAG_WIDTH-1:0]         rd_q_tag;
    reg [EPOCH_WIDTH-1:0]       rd_q_epoch;
    reg                         rd_data_pending;
    reg                         rd_collision0;
    reg                         rd_collision1;
    reg                         rd_collision2;
    reg                         rd_collision3;
    reg [31:0]                  rd_collision_data0;
    reg [31:0]                  rd_collision_data1;
    reg [31:0]                  rd_collision_data2;
    reg [31:0]                  rd_collision_data3;

    reg                         resp_valid_q;
    reg [127:0]                 resp_data_q;
    reg [15:0]                  resp_mask_q;
    reg [TAG_WIDTH-1:0]         resp_tag_q;
    reg [EPOCH_WIDTH-1:0]       resp_epoch_q;

    /* There is one registered write command and one registered read.  The
     * write command retires to RAM every cycle, so writes can be accepted at
     * one per clock after reset.  Read admission is deliberately stopped
     * while either read pipeline stage is occupied; this gives unambiguous
     * metadata alignment under arbitrary response backpressure. */
    wire wr_fire = wr_valid && wr_ready;
    wire rd_fire = rd_req_valid && rd_req_ready;
    assign wr_ready = rst_n;
    assign rd_req_ready = rst_n && !rd_pending && !rd_data_pending &&
                          (!resp_valid_q || rd_resp_ready);
    assign rd_resp_valid = resp_valid_q;
    assign rd_data_vector = resp_data_q;
    assign rd_resp_lane_mask = resp_mask_q;
    assign rd_resp_tag = resp_tag_q;
    assign rd_resp_epoch = resp_epoch_q;

    function automatic [127:0] mask_vector;
        input [127:0] value;
        input [15:0]  lane_mask;
        integer lane;
        begin
            mask_vector = value;
            for (lane = 0; lane < 16; lane = lane + 1)
                if (!lane_mask[lane])
                    mask_vector[(lane*8) +: 8] = 8'd0;
        end
    endfunction

    genvar plane;
    generate
        for (plane = 0; plane < 4; plane = plane + 1) begin : gen_plane
`ifdef SYNTHESIS
            xpm_memory_sdpram #(
                .ADDR_WIDTH_A(ADDR_WIDTH), .ADDR_WIDTH_B(ADDR_WIDTH),
                .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8),
                .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
                .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
                .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
                .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(DEPTH*32),
                .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(32),
                .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
                .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
                .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
                .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
                .WRITE_DATA_WIDTH_A(32), .WRITE_MODE_B("read_first")
            ) u_mem (
                .clka(clk), .clkb(clk),
                .ena(wr_q_valid && (wr_q_quarter == plane[1:0])),
                /* BYTE_WRITE_WIDTH_A=8 makes wea four bits wide.  Replicate
                 * the command bit so a quarter write updates all four bytes,
                 * rather than only byte zero after scalar extension. */
                .wea({4{wr_q_valid && (wr_q_quarter == plane[1:0])}}),
                .addra(wr_q_addr), .dina(wr_q_data),
                .addrb(rd_q_addr), .enb(rd_pending),
                .doutb(plane_dout[plane]),
                .regceb(1'b1), .rstb(!rst_n), .sleep(1'b0),
                .injectdbiterra(1'b0), .injectsbiterra(1'b0),
                .dbiterrb(), .sbiterrb()
            );
`else
            (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];
            reg [31:0] plane_dout_reg;
            assign plane_dout[plane] = plane_dout_reg;
            always @(posedge clk) begin
                if (wr_q_valid && (wr_q_quarter == plane[1:0]))
                    mem[wr_q_addr] <= wr_q_data;
                if (rd_pending)
                    plane_dout_reg <= mem[rd_q_addr];
            end
`endif
        end
    endgenerate

    /* The memory arrays use a conventional synchronous-read process.  The
     * collision test is intentionally in the read expression: wr_q_valid is
     * the command that is simultaneously retiring into the RAM on this
     * edge, so a read of the same vector/plane observes the new data. */
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_q_valid <= 1'b0;
            wr_q_addr <= {ADDR_WIDTH{1'b0}};
            wr_q_quarter <= 2'd0;
            wr_q_data <= 32'd0;
            wr_q_epoch <= {EPOCH_WIDTH{1'b0}};
            wr_epoch_seen <= {EPOCH_WIDTH{1'b0}};
            rd_pending <= 1'b0;
            rd_q_addr <= {ADDR_WIDTH{1'b0}};
            rd_q_mask <= 16'd0;
            rd_q_tag <= {TAG_WIDTH{1'b0}};
            rd_q_epoch <= {EPOCH_WIDTH{1'b0}};
            rd_data_pending <= 1'b0;
            rd_collision0 <= 1'b0;
            rd_collision1 <= 1'b0;
            rd_collision2 <= 1'b0;
            rd_collision3 <= 1'b0;
            rd_collision_data0 <= 32'd0;
            rd_collision_data1 <= 32'd0;
            rd_collision_data2 <= 32'd0;
            rd_collision_data3 <= 32'd0;
            resp_valid_q <= 1'b0;
            resp_data_q <= 128'd0;
            resp_mask_q <= 16'd0;
            resp_tag_q <= {TAG_WIDTH{1'b0}};
            resp_epoch_q <= {EPOCH_WIDTH{1'b0}};
        end else begin
            /* The per-plane RAM processes retire the prior registered write
             * command.  Keep the epoch observable at that same boundary. */
            if (wr_q_valid) begin
                /* The observed epoch denotes the command that has actually
                 * reached the RAM, rather than a merely presented command. */
                wr_epoch_seen <= wr_q_epoch;
            end

            /* Capture the next write command and its epoch independently of
             * the RAM write.  This is the narrow registered island boundary. */
            wr_q_valid <= wr_fire;
            if (wr_fire) begin
                wr_q_addr <= wr_vector_addr;
                wr_q_quarter <= wr_quarter;
                wr_q_data <= wr_data;
                wr_q_epoch <= wr_epoch;
            end

            /* First read stage: four 32-bit synchronous RAM reads. */
            rd_pending <= rd_fire;
            if (rd_fire) begin
                rd_q_addr <= rd_vector_addr;
                rd_q_mask <= rd_lane_mask;
                rd_q_tag <= rd_tag;
                rd_q_epoch <= rd_epoch;
            end
            rd_data_pending <= rd_pending;
            if (rd_pending) begin
                rd_collision0 <= wr_q_valid && (wr_q_quarter == 2'd0) &&
                                 (wr_q_addr == rd_q_addr);
                rd_collision1 <= wr_q_valid && (wr_q_quarter == 2'd1) &&
                                 (wr_q_addr == rd_q_addr);
                rd_collision2 <= wr_q_valid && (wr_q_quarter == 2'd2) &&
                                 (wr_q_addr == rd_q_addr);
                rd_collision3 <= wr_q_valid && (wr_q_quarter == 2'd3) &&
                                 (wr_q_addr == rd_q_addr);
                rd_collision_data0 <= wr_q_data;
                rd_collision_data1 <= wr_q_data;
                rd_collision_data2 <= wr_q_data;
                rd_collision_data3 <= wr_q_data;
            end

            /* Second stage: gather and mask only at the registered output.
             * This makes padding/tail lanes deterministic zeros while the
             * response mask retains the caller's exact validity information. */
            if (rd_data_pending) begin
                resp_valid_q <= 1'b1;
                resp_data_q <= mask_vector({rd_collision3 ? rd_collision_data3 : plane_dout[3],
                                             rd_collision2 ? rd_collision_data2 : plane_dout[2],
                                             rd_collision1 ? rd_collision_data1 : plane_dout[1],
                                             rd_collision0 ? rd_collision_data0 : plane_dout[0]},
                                            rd_q_mask);
                resp_mask_q <= rd_q_mask;
                resp_tag_q <= rd_q_tag;
                resp_epoch_q <= rd_q_epoch;
            end else if (resp_valid_q && rd_resp_ready) begin
                resp_valid_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_IN_H < 1 || MAX_IN_H > 17 || MAX_IN_W < 1 || MAX_IN_W > 17)
            $error("window footprint must be in the range 1..17");
        if (MAX_CHANNEL_GROUPS < 1)
            $error("MAX_CHANNEL_GROUPS must be positive");
        if (DEPTH < MAX_IN_H * MAX_IN_W * MAX_CHANNEL_GROUPS)
            $error("DEPTH does not cover the configured footprint/groups");
    end
`endif
endmodule

`default_nettype wire
