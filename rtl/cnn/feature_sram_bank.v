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
    output wire signed [DATA_WIDTH-1:0] rd_data
);
    localparam DEPTH = (1 << ADDR_WIDTH);

`ifdef SYNTHESIS
    wire [DATA_WIDTH-1:0] memory_rd_data;
    reg bypass_valid;
    reg signed [DATA_WIDTH-1:0] bypass_data;

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(DATA_WIDTH),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(DEPTH * DATA_WIDTH),
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
    ) u_feature_memory (
        .clka(clk),
        .ena(wr_en),
        .wea(wr_en),
        .addra(wr_addr),
        .dina(wr_data),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .sleep(1'b0),
        .clkb(clk),
        .rstb(!rst_n),
        .enb(rd_en),
        .regceb(1'b1),
        .addrb(rd_addr),
        .doutb(memory_rd_data),
        .sbiterrb(),
        .dbiterrb()
    );

    assign rd_data = bypass_valid ? bypass_data : memory_rd_data;
`else
    reg signed [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg signed [DATA_WIDTH-1:0] behavioral_rd_data;

    assign rd_data = behavioral_rd_data;
`endif

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
`ifdef SYNTHESIS
            bypass_valid <= 1'b0;
            bypass_data <= {DATA_WIDTH{1'b0}};
`endif
`ifndef SYNTHESIS
            behavioral_rd_data <= {DATA_WIDTH{1'b0}};
`endif
        end else begin
            rd_valid <= rd_en;
`ifdef SYNTHESIS
            bypass_valid <= rd_en && wr_en && (wr_addr == rd_addr);
            if (rd_en && wr_en && (wr_addr == rd_addr)) begin
                bypass_data <= wr_data;
            end
`endif
`ifndef SYNTHESIS
            if (wr_en) begin
                mem[wr_addr] <= wr_data;
            end
            if (rd_en) begin
                if (wr_en && (wr_addr == rd_addr)) begin
                    behavioral_rd_data <= wr_data;
                end else begin
                    behavioral_rd_data <= mem[rd_addr];
                end
            end
`endif
        end
    end
endmodule

`default_nettype wire
