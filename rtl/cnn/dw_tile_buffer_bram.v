`timescale 1ns/1ps
`default_nettype none

module dw_tile_buffer_bram (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               wr_en,
    input  wire [5:0]         wr_pixel_idx,
    input  wire [6:0]         wr_channel_idx,
    input  wire signed [7:0]  wr_data_int8,

    input  wire               rd_en,
    input  wire [5:0]         rd_pixel_base,
    input  wire [6:0]         rd_channel_idx,
    output reg                rd_valid,
    output wire signed [63:0] rd_data_vector
);
    localparam ADDR_WIDTH = 10;
    localparam DATA_WIDTH = 64;

    wire [ADDR_WIDTH-1:0] wr_addr;
    wire [ADDR_WIDTH-1:0] rd_addr;
    wire [DATA_WIDTH-1:0] rd_data_raw;

    assign wr_addr = {wr_pixel_idx[5:3], wr_channel_idx};
    assign rd_addr = {rd_pixel_base[5:3], rd_channel_idx};
    assign rd_data_vector = rd_data_raw;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
        end else begin
            rd_valid <= rd_en;
        end
    end

`ifdef SYNTHESIS
    localparam MEMORY_SIZE_BITS = 65536;
    wire [7:0] wr_byte_enable;
    wire [DATA_WIDTH-1:0] wr_data_replicated;

    assign wr_byte_enable = 8'b0000_0001 << wr_pixel_idx[2:0];
    assign wr_data_replicated = {8{wr_data_int8}};

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
    ) u_tile_memory (
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
    reg [DATA_WIDTH-1:0] mem [0:1023];
    reg [DATA_WIDTH-1:0] rd_data_reg;

    assign rd_data_raw = rd_data_reg;

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr][(wr_pixel_idx[2:0]*8) +: 8] <= wr_data_int8;
        end

        if (!rst_n) begin
            rd_data_reg <= {DATA_WIDTH{1'b0}};
        end else if (rd_en) begin
            rd_data_reg <= mem[rd_addr];
        end
    end

    always @(posedge clk) begin
        if (rst_n && rd_en && (rd_pixel_base[2:0] != 3'b000)) begin
            $error(
                "dw_tile_buffer_bram rd_pixel_base must be 8-aligned: %0d",
                rd_pixel_base
            );
        end
    end
`endif
endmodule

`default_nettype wire
