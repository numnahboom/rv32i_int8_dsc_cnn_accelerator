`timescale 1ns/1ps
`default_nettype none

/*
 * Two-bank packed Stem weight store.
 *
 * Public configuration remains the legacy cout-major byte index
 *   cfg_index = cout * 27 + k, cout in [0,15], k in [0,26].
 * Physically, each bank is one 64-bit row per k and contains eight adjacent
 * output-channel bytes.  Consequently the compute side has exactly two
 * synchronous 64-bit reads per k group, rather than sixteen scalar reads.
 * Configuration and compute are mutually exclusive at the parent interface,
 * so one sequential process owns each memory's write and read state.
 */
module stem_weight_store_packed64 #(
    parameter integer MAX_K = 27,
    parameter integer ROWS = 32
) (
    input wire clk,
    input wire rst_n,
    input wire cfg_valid,
    input wire [8:0] cfg_index,
    input wire [31:0] cfg_data,
    input wire read_enable,
    input wire [4:0] read_addr,
    output wire [63:0] read_data0,
    output wire [63:0] read_data1
);
    wire cfg_bank = (cfg_index >= 9'd216);
    wire [8:0] cfg_local_index = cfg_bank ?
                                  (cfg_index - 9'd216) : cfg_index;
    wire [4:0] cfg_k = cfg_local_index % MAX_K;
    wire [2:0] cfg_lane = cfg_local_index / MAX_K;
    wire [7:0] cfg_byte_addr = {3'b000, cfg_k, 3'b000} +
                                {5'b00000, cfg_lane};

`ifndef SYNTHESIS
    /* Simulation reference model of the same true-dual-width SDP geometry.
     * Configuration and compute are mutually exclusive at the parent, so
     * this single process is also the collision model for the XPM instance
     * below.  The registered output is intentional: XPM READ_LATENCY_B=1. */
    (* ram_style = "block" *) reg [63:0] bank0_mem [0:ROWS-1];
    (* ram_style = "block" *) reg [63:0] bank1_mem [0:ROWS-1];
    reg [63:0] read_data0_reg, read_data1_reg;
    assign read_data0 = read_data0_reg;
    assign read_data1 = read_data1_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            read_data0_reg <= 64'd0;
            read_data1_reg <= 64'd0;
        end else begin
            if (cfg_valid && (cfg_index < 9'd432)) begin
                if (!cfg_bank) begin
                    case (cfg_lane)
                        3'd0: bank0_mem[cfg_k][7:0]   <= cfg_data[7:0];
                        3'd1: bank0_mem[cfg_k][15:8]  <= cfg_data[7:0];
                        3'd2: bank0_mem[cfg_k][23:16] <= cfg_data[7:0];
                        3'd3: bank0_mem[cfg_k][31:24] <= cfg_data[7:0];
                        3'd4: bank0_mem[cfg_k][39:32] <= cfg_data[7:0];
                        3'd5: bank0_mem[cfg_k][47:40] <= cfg_data[7:0];
                        3'd6: bank0_mem[cfg_k][55:48] <= cfg_data[7:0];
                        default: bank0_mem[cfg_k][63:56] <= cfg_data[7:0];
                    endcase
                end else begin
                    case (cfg_lane)
                        3'd0: bank1_mem[cfg_k][7:0]   <= cfg_data[7:0];
                        3'd1: bank1_mem[cfg_k][15:8]  <= cfg_data[7:0];
                        3'd2: bank1_mem[cfg_k][23:16] <= cfg_data[7:0];
                        3'd3: bank1_mem[cfg_k][31:24] <= cfg_data[7:0];
                        3'd4: bank1_mem[cfg_k][39:32] <= cfg_data[7:0];
                        3'd5: bank1_mem[cfg_k][47:40] <= cfg_data[7:0];
                        3'd6: bank1_mem[cfg_k][55:48] <= cfg_data[7:0];
                        default: bank1_mem[cfg_k][63:56] <= cfg_data[7:0];
                    endcase
                end
            end
            if (read_enable) begin
                read_data0_reg <= bank0_mem[read_addr];
                read_data1_reg <= bank1_mem[read_addr];
            end
        end
    end
`else
    /* Production implementation: one 8-bit write / 64-bit read XPM per
     * eight-output-channel bank.  The public cfg_index remains cout-major;
     * cfg_k/cfg_lane map it to the packed physical row and byte lane. */
    wire [63:0] read_data0_xpm, read_data1_xpm;
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(5), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(2048), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(64), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(8),
        .WRITE_MODE_B("read_first")
    ) u_stem_weight_bank0 (
        .clka(clk), .clkb(clk),
        .ena(cfg_valid && !cfg_bank && (cfg_index < 9'd432)),
        .enb(read_enable), .addra(cfg_byte_addr),
        .addrb(read_addr), .dina(cfg_data[7:0]), .wea(1'b1),
        .doutb(read_data0_xpm), .rstb(!rst_n), .regceb(1'b1),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(5), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(2048), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(64), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(8),
        .WRITE_MODE_B("read_first")
    ) u_stem_weight_bank1 (
        .clka(clk), .clkb(clk),
        .ena(cfg_valid && cfg_bank && (cfg_index < 9'd432)),
        .enb(read_enable), .addra(cfg_byte_addr),
        .addrb(read_addr), .dina(cfg_data[7:0]), .wea(1'b1),
        .doutb(read_data1_xpm), .rstb(!rst_n), .regceb(1'b1),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
    assign read_data0 = read_data0_xpm;
    assign read_data1 = read_data1_xpm;
`endif
endmodule

`default_nettype wire
