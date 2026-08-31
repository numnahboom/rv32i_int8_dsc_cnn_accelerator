`timescale 1ns/1ps
`default_nettype none

module feature_sram_bank #(
    parameter ADDR_WIDTH = 15,
    parameter DATA_WIDTH = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         wr_en,
    input  wire [ADDR_WIDTH-1:0]        wr_addr,
    input  wire signed [DATA_WIDTH-1:0] wr_data,

    input  wire                         rd_en,
    input  wire [ADDR_WIDTH-1:0]        rd_addr,
    output reg                          rd_valid,
    output wire signed [DATA_WIDTH-1:0] rd_data,

    // Optional aligned 32-bit read. Byte lane zero is bits [7:0].
    input  wire                         rd_word_en,
    input  wire [ADDR_WIDTH-1:0]        rd_word_addr,
    output reg                          rd_word_valid,
    output wire [31:0]                  rd_word_data,

    // Optional byte-enabled 32-bit write path.  Addresses remain byte
    // addresses, matching the scalar interface and the descriptor SRAM
    // contract; the low two bits select the byte lane.  Keeping this port
    // optional preserves the original scalar directed benches and host ABI.
    input  wire                         wr_word_en,
    input  wire [ADDR_WIDTH-1:0]         wr_word_addr,
    input  wire [31:0]                  wr_word_data,
    input  wire [3:0]                   wr_word_be
);
    localparam DEPTH = (1 << ADDR_WIDTH);
    localparam WORD_ADDR_WIDTH = (ADDR_WIDTH > 2) ? (ADDR_WIDTH - 2) : 1;

    // Normalize the legacy scalar write to the same 32-bit/byte-enable
    // transaction used by the new internal store4 path.  A scalar host write
    // has priority over the accelerator write, as before.
    wire scalar_write = wr_en;
    // Unconnected optional ports in legacy scalar benches are Z.  Treat only
    // a definite one as an enabled word transaction so the old interface is
    // deterministic in four-state simulation as well as in hardware.
    wire wr_word_en_i = (wr_word_en === 1'b1);
    wire word_write = wr_word_en_i || scalar_write;
    wire [ADDR_WIDTH-1:0] word_write_byte_addr = scalar_write ?
                                                  wr_addr : wr_word_addr;
    wire [WORD_ADDR_WIDTH-1:0] word_write_addr =
        word_write_byte_addr[ADDR_WIDTH-1:2];
    wire [31:0] scalar_write_data =
        ({24'd0, wr_data} << (word_write_byte_addr[1:0] * 8));
    wire [31:0] word_write_data_i = scalar_write ? scalar_write_data : wr_word_data;
    wire [3:0] word_write_be_i = scalar_write ?
                                  (4'b0001 << word_write_byte_addr[1:0]) : wr_word_be;
    wire [WORD_ADDR_WIDTH-1:0] read_word_addr = rd_addr[ADDR_WIDTH-1:2];
    wire read_word_en_i = (rd_word_en === 1'b1);
    wire [WORD_ADDR_WIDTH-1:0] read_word_addr_i =
        read_word_en_i ? rd_word_addr[ADDR_WIDTH-1:2] : read_word_addr;

`ifdef SYNTHESIS
    wire [31:0] memory_rd_data;
    reg bypass_valid;
    reg signed [DATA_WIDTH-1:0] bypass_data;
    reg [1:0] rd_lane_d;
    reg [31:0] word_bypass_data;
    reg [3:0] word_bypass_mask;

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(WORD_ADDR_WIDTH),
        .ADDR_WIDTH_B(WORD_ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(DEPTH * DATA_WIDTH),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(32),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(32),
        .WRITE_MODE_B("read_first")
    ) u_feature_memory (
        .clka(clk),
        .ena(word_write),
        .wea(word_write ? word_write_be_i : 4'b0000),
        .addra(word_write_addr),
        .dina(word_write_data_i),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .sleep(1'b0),
        .clkb(clk),
        .rstb(!rst_n),
        .enb(rd_en || read_word_en_i),
        .regceb(1'b1),
        .addrb(read_word_addr_i),
        .doutb(memory_rd_data),
        .sbiterrb(),
        .dbiterrb()
    );

    assign rd_data = bypass_valid ? bypass_data :
                     $signed(memory_rd_data[(rd_lane_d * 8) +: 8]);
    assign rd_word_data =
        (word_bypass_mask[0] ? word_bypass_data[7:0] : memory_rd_data[7:0]) |
        ((word_bypass_mask[1] ? word_bypass_data[15:8] : memory_rd_data[15:8]) << 8) |
        ((word_bypass_mask[2] ? word_bypass_data[23:16] : memory_rd_data[23:16]) << 16) |
        ((word_bypass_mask[3] ? word_bypass_data[31:24] : memory_rd_data[31:24]) << 24);
`else
    localparam WORD_DEPTH = (1 << WORD_ADDR_WIDTH);
    reg [31:0] mem [0:WORD_DEPTH-1];
    reg signed [DATA_WIDTH-1:0] behavioral_rd_data;
    reg [31:0] behavioral_rd_word_data;

    assign rd_data = behavioral_rd_data;
    assign rd_word_data = behavioral_rd_word_data;
`endif

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
            rd_word_valid <= 1'b0;
`ifdef SYNTHESIS
            bypass_valid <= 1'b0;
            bypass_data <= {DATA_WIDTH{1'b0}};
            rd_lane_d <= 2'd0;
            word_bypass_data <= 32'd0;
            word_bypass_mask <= 4'd0;
`endif
`ifndef SYNTHESIS
            behavioral_rd_data <= {DATA_WIDTH{1'b0}};
            behavioral_rd_word_data <= 32'd0;
`endif
        end else begin
            rd_valid <= rd_en;
            rd_word_valid <= read_word_en_i;
`ifdef SYNTHESIS
            rd_lane_d <= rd_addr[1:0];
            bypass_valid <= rd_en && word_write &&
                            (word_write_addr == read_word_addr) &&
                            word_write_be_i[rd_addr[1:0]];
            if (rd_en && word_write &&
                (word_write_addr == read_word_addr) &&
                word_write_be_i[rd_addr[1:0]]) begin
                bypass_data <= $signed(word_write_data_i[(rd_addr[1:0] * 8) +: 8]);
            end
            word_bypass_mask <= 4'd0;
            if (read_word_en_i && word_write &&
                (word_write_addr == read_word_addr_i)) begin
                word_bypass_mask <= word_write_be_i;
                word_bypass_data <= word_write_data_i;
            end
`endif
`ifndef SYNTHESIS
            if (word_write) begin
                if (word_write_be_i[0]) mem[word_write_addr][7:0] <= word_write_data_i[7:0];
                if (word_write_be_i[1]) mem[word_write_addr][15:8] <= word_write_data_i[15:8];
                if (word_write_be_i[2]) mem[word_write_addr][23:16] <= word_write_data_i[23:16];
                if (word_write_be_i[3]) mem[word_write_addr][31:24] <= word_write_data_i[31:24];
            end
            if (rd_en) begin
                if (word_write && (word_write_addr == read_word_addr) &&
                    word_write_be_i[rd_addr[1:0]]) begin
                    behavioral_rd_data <= $signed(word_write_data_i[(rd_addr[1:0] * 8) +: 8]);
                end else begin
                    behavioral_rd_data <= $signed(mem[read_word_addr][(rd_addr[1:0] * 8) +: 8]);
                end
            end
            if (rd_word_en) begin
                behavioral_rd_word_data <= mem[read_word_addr_i];
                if (word_write && (word_write_addr == read_word_addr_i)) begin
                    if (word_write_be_i[0]) behavioral_rd_word_data[7:0] <= word_write_data_i[7:0];
                    if (word_write_be_i[1]) behavioral_rd_word_data[15:8] <= word_write_data_i[15:8];
                    if (word_write_be_i[2]) behavioral_rd_word_data[23:16] <= word_write_data_i[23:16];
                    if (word_write_be_i[3]) behavioral_rd_word_data[31:24] <= word_write_data_i[31:24];
                end
            end
`endif
        end
    end
endmodule

`default_nettype wire
