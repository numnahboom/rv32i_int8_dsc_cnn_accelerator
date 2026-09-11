`timescale 1ns/1ps
`default_nettype none

/*
 * Scalar-write / eight-output-channel-read pointwise weight buffer.
 *
 * Linear loader layout is [Cout][MAX_CIN].  A compute read returns the eight
 * weights for one output-channel tile at one input channel.
 */
module pw_weight_buffer_bram #(
    parameter MAX_CIN = 128,
    parameter MAX_COUT = 256,
    parameter LANES = 8,
    parameter LINEAR_ADDR_WIDTH = 15
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         wr_en,
    input  wire [LINEAR_ADDR_WIDTH-1:0] wr_linear_idx,
    input  wire signed [7:0]            wr_data_int8,
    // Packed loader entry.  The four bytes are consecutive entries in the
    // software's [Cout][Cin] linear layout; the buffer unpacks them before
    // presenting the existing eight-Cout read vector.
    input  wire                         wr_word_en,
    input  wire [LINEAR_ADDR_WIDTH-1:0] wr_word_index,
    input  wire [31:0]                  wr_word_data_int8,
    input  wire [3:0]                   wr_word_be,
    output wire                         wr_word_ready,

    input  wire                         rd_en,
    input  wire [8:0]                   rd_cout_base,
    input  wire [7:0]                   rd_channel_idx,
    output reg                          rd_valid,
    output wire signed [(LANES*8)-1:0]  rd_data_vector
);
    localparam COUT_TILES = MAX_COUT / LANES;
    localparam DEPTH = COUT_TILES * MAX_CIN;
    localparam ADDR_WIDTH = $clog2(DEPTH);
    localparam DATA_WIDTH = LANES * 8;
    localparam CIN_SHIFT = $clog2(MAX_CIN);
    localparam LANE_SHIFT = $clog2(LANES);

    wire [ADDR_WIDTH-1:0] rd_addr;
    wire [DATA_WIDTH-1:0] rd_data_raw;

    assign rd_addr = ((rd_cout_base >> LANE_SHIFT) * MAX_CIN) + rd_channel_idx;
    // A packed external word is accepted once, then retired as four scalar
    // canonical-store writes.  The runner uses wr_word_ready to hold the
    // corresponding response until this tiny unpack queue is available.
    reg packed_pending;
    reg [LINEAR_ADDR_WIDTH-1:0] packed_pending_word_index;
    reg [31:0] packed_pending_data;
    reg [3:0] packed_pending_be;
    reg [1:0] packed_pending_byte;
    wire packed_pending_byte_valid = packed_pending_be[packed_pending_byte];
    wire [LINEAR_ADDR_WIDTH-1:0] packed_pending_linear =
        (packed_pending_word_index << 2) + packed_pending_byte;
    wire canonical_wr_from_packed = packed_pending && packed_pending_byte_valid;
    wire canonical_wr_en = wr_en || canonical_wr_from_packed;
    wire [LINEAR_ADDR_WIDTH-1:0] canonical_wr_linear_idx =
        canonical_wr_from_packed ? packed_pending_linear : wr_linear_idx;
    wire signed [7:0] canonical_wr_data_int8 = canonical_wr_from_packed ?
        packed_pending_data[(packed_pending_byte * 8) +: 8] : wr_data_int8;
    wire [$clog2(MAX_COUT)-1:0] canonical_wr_cout_idx =
        canonical_wr_linear_idx >> CIN_SHIFT;
    wire [$clog2(MAX_CIN)-1:0] canonical_wr_channel_idx =
        canonical_wr_linear_idx[$clog2(MAX_CIN)-1:0];
    wire [$clog2(COUT_TILES)-1:0] canonical_wr_cout_tile =
        canonical_wr_cout_idx >> LANE_SHIFT;
    wire [LANE_SHIFT-1:0] canonical_wr_lane_idx =
        canonical_wr_cout_idx[LANE_SHIFT-1:0];
    wire [ADDR_WIDTH-1:0] canonical_wr_addr =
        (canonical_wr_cout_tile * MAX_CIN) + canonical_wr_channel_idx;
    assign wr_word_ready = !packed_pending;
    // Packed and scalar loaders converge on the same canonical compute
    // memory; only the write address/data/byte lane are selected here.
    assign rd_data_vector = rd_data_raw;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
            packed_pending <= 1'b0;
            packed_pending_word_index <= {LINEAR_ADDR_WIDTH{1'b0}};
            packed_pending_data <= 32'd0;
            packed_pending_be <= 4'd0;
            packed_pending_byte <= 2'd0;
        end else begin
            rd_valid <= rd_en;
            if (packed_pending) begin
                if (packed_pending_byte == 2'd3) begin
                    packed_pending <= 1'b0;
                    packed_pending_byte <= 2'd0;
                end else begin
                    packed_pending_byte <= packed_pending_byte + 2'd1;
                end
            end else if (wr_word_en) begin
                packed_pending <= 1'b1;
                packed_pending_word_index <= wr_word_index;
                packed_pending_data <= wr_word_data_int8;
                packed_pending_be <= wr_word_be;
                packed_pending_byte <= 2'd0;
            end
        end
    end

`ifdef SYNTHESIS
    localparam MEMORY_SIZE_BITS = DEPTH * DATA_WIDTH;
    wire [LANES-1:0] wr_byte_enable;
    wire [DATA_WIDTH-1:0] wr_data_replicated;

    assign wr_byte_enable = {{(LANES-1){1'b0}}, 1'b1} << canonical_wr_lane_idx;
    assign wr_data_replicated = {LANES{canonical_wr_data_int8}};

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8),
        .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(MEMORY_SIZE_BITS),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(DATA_WIDTH),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(DATA_WIDTH),
        .WRITE_MODE_B("read_first")
    ) u_weight_memory (
        .clka(clk),
        .clkb(clk),
        .ena(canonical_wr_en),
        .enb(rd_en),
        .addra(canonical_wr_addr),
        .addrb(rd_addr),
        .dina(wr_data_replicated),
        .wea(wr_byte_enable),
        .doutb(rd_data_raw),
        .rstb(!rst_n),
        .regceb(1'b1),
        .sleep(1'b0),
        .injectdbiterra(1'b0),
        .injectsbiterra(1'b0),
        .dbiterrb(),
        .sbiterrb()
    );
`else
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [DATA_WIDTH-1:0] rd_data_reg;

    assign rd_data_raw = rd_data_reg;

    always @(posedge clk) begin
        if (canonical_wr_en) begin
            mem[canonical_wr_addr][(canonical_wr_lane_idx*8) +: 8] <=
                canonical_wr_data_int8;
        end

        if (!rst_n) begin
            rd_data_reg <= {DATA_WIDTH{1'b0}};
        end else if (rd_en) begin
            rd_data_reg <= mem[rd_addr];
        end
    end
`endif

`ifndef SYNTHESIS
    initial begin
        if ((MAX_CIN % LANES) != 0 || (MAX_COUT % LANES) != 0) begin
            $error("pw_weight_buffer_bram dimensions must be multiples of LANES");
        end
        if ((1 << CIN_SHIFT) != MAX_CIN) begin
            $error("pw_weight_buffer_bram MAX_CIN must be a power of two");
        end
    end
`endif
endmodule

`default_nettype wire
