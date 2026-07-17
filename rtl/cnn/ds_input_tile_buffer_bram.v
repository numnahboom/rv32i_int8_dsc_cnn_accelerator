`timescale 1ns/1ps
`default_nettype none

/*
 * Scalar-write / 16-channel-read input tile buffer.
 *
 * The loader writes the same MAX_IN_H x MAX_IN_W x MAX_CIN linear layout used
 * by the original packed DSBlock interface.  The streaming DW controller reads
 * one 16-channel vector for a spatial pixel and channel tile.
 */
module ds_input_tile_buffer_bram #(
    parameter MAX_CIN = 128,
    parameter MAX_IN_H = 17,
    parameter MAX_IN_W = 17,
    parameter LANES = 16,
    parameter LINEAR_ADDR_WIDTH = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         wr_en,
    input  wire [LINEAR_ADDR_WIDTH-1:0] wr_linear_idx,
    input  wire signed [7:0]            wr_data_int8,

    input  wire                         rd_en,
    input  wire [8:0]                   rd_pixel_idx,
    input  wire [$clog2(MAX_CIN/LANES)-1:0] rd_channel_tile,
    output reg                          rd_valid,
    output wire signed [(LANES*8)-1:0]  rd_data_vector
);
    localparam CHANNEL_TILES = MAX_CIN / LANES;
    localparam DEPTH = MAX_IN_H * MAX_IN_W * CHANNEL_TILES;
    localparam ADDR_WIDTH = $clog2(DEPTH);
    localparam DATA_WIDTH = LANES * 8;
    localparam CIN_SHIFT = $clog2(MAX_CIN);
    localparam LANE_SHIFT = $clog2(LANES);

    wire [8:0] wr_pixel_idx;
    wire [$clog2(MAX_CIN)-1:0] wr_channel_idx;
    wire [$clog2(CHANNEL_TILES)-1:0] wr_channel_tile;
    wire [LANE_SHIFT-1:0] wr_lane_idx;
    wire [ADDR_WIDTH-1:0] wr_addr;
    wire [ADDR_WIDTH-1:0] rd_addr;
    wire [DATA_WIDTH-1:0] rd_data_raw;

    assign wr_pixel_idx = wr_linear_idx >> CIN_SHIFT;
    assign wr_channel_idx = wr_linear_idx[$clog2(MAX_CIN)-1:0];
    assign wr_channel_tile = wr_channel_idx >> LANE_SHIFT;
    assign wr_lane_idx = wr_channel_idx[LANE_SHIFT-1:0];
    assign wr_addr = (wr_pixel_idx * CHANNEL_TILES) + wr_channel_tile;
    assign rd_addr = (rd_pixel_idx * CHANNEL_TILES) + rd_channel_tile;
    assign rd_data_vector = rd_data_raw;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
        end else begin
            rd_valid <= rd_en;
        end
    end

`ifdef SYNTHESIS
    localparam MEMORY_SIZE_BITS = DEPTH * DATA_WIDTH;
    wire [LANES-1:0] wr_byte_enable;
    wire [DATA_WIDTH-1:0] wr_data_replicated;

    assign wr_byte_enable = {{(LANES-1){1'b0}}, 1'b1} << wr_lane_idx;
    assign wr_data_replicated = {LANES{wr_data_int8}};

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
    ) u_input_memory (
        .clka(clk),
        .clkb(clk),
        .ena(wr_en),
        .enb(rd_en),
        .addra(wr_addr),
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
        if (wr_en) begin
            mem[wr_addr][(wr_lane_idx*8) +: 8] <= wr_data_int8;
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
        if ((MAX_CIN % LANES) != 0) begin
            $error("ds_input_tile_buffer_bram MAX_CIN must be a multiple of LANES");
        end
        if ((1 << CIN_SHIFT) != MAX_CIN) begin
            $error("ds_input_tile_buffer_bram MAX_CIN must be a power of two");
        end
        if ((1 << LANE_SHIFT) != LANES) begin
            $error("ds_input_tile_buffer_bram LANES must be a power of two");
        end
    end
`endif
endmodule

`default_nettype wire
