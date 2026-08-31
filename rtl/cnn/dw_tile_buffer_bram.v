`timescale 1ns/1ps
`default_nettype none

/* Four channel-interleaved banks.  Each bank stores the eight pixels for one
 * channel at an address; the PW reader retains its one-channel/8-pixel ABI. */
module dw_tile_buffer_bram (
    input wire clk, input wire rst_n,
    input wire wr_en, input wire [5:0] wr_pixel_idx,
    input wire [6:0] wr_channel_idx, input wire signed [7:0] wr_data_int8,
    input wire wr_vec4_en, input wire [5:0] wr_vec4_pixel_idx,
    input wire [6:0] wr_vec4_channel_idx, input wire [31:0] wr_vec4_data_int8,
    input wire [3:0] wr_vec4_byte_en,
    input wire rd_en, input wire [5:0] rd_pixel_base,
    input wire [6:0] rd_channel_idx, output reg rd_valid,
    output wire signed [63:0] rd_data_vector
);
    localparam ADDR_WIDTH = 8;
    localparam DATA_WIDTH = 64;
    localparam MEMORY_SIZE_BITS = 16384;
    wire [ADDR_WIDTH-1:0] rd_addr = {rd_pixel_base[5:3], rd_channel_idx[6:2]};
    wire [1:0] rd_bank = rd_channel_idx[1:0];
    reg [1:0] rd_bank_reg;
    wire [DATA_WIDTH-1:0] bank_rd_data [0:3];
    reg [DATA_WIDTH-1:0] bank_rd_data_sim [0:3];
    genvar b;
    generate for (b = 0; b < 4; b = b + 1) begin : gen_bank
        wire bank_scalar = wr_en && (wr_channel_idx[1:0] == b[1:0]);
        // DW fusion emits channel quartets aligned to a four-bank boundary;
        // lane b therefore maps directly to physical bank b.
        wire bank_vector = wr_vec4_en && wr_vec4_byte_en[b] &&
                           (wr_vec4_channel_idx[1:0] == 2'd0);
        wire [ADDR_WIDTH-1:0] wr_addr = bank_vector
            ? {wr_vec4_pixel_idx[5:3], wr_vec4_channel_idx[6:2]}
            : {wr_pixel_idx[5:3], wr_channel_idx[6:2]};
        wire [7:0] wr_byte_enable = bank_vector
            ? (8'b0000_0001 << wr_vec4_pixel_idx[2:0])
            : (8'b0000_0001 << wr_pixel_idx[2:0]);
        wire [DATA_WIDTH-1:0] wr_data = bank_vector
            ? {8{wr_vec4_data_int8[(b*8) +: 8]}}
            : {8{wr_data_int8}};
`ifdef SYNTHESIS
        xpm_memory_sdpram #(
            .ADDR_WIDTH_A(ADDR_WIDTH), .ADDR_WIDTH_B(ADDR_WIDTH),
            .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8),
            .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
            .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
            .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
            .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(MEMORY_SIZE_BITS),
            .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(DATA_WIDTH),
            .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
            .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
            .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
            .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(DATA_WIDTH),
            .WRITE_MODE_B("read_first")
        ) u_memory (
            .clka(clk), .clkb(clk), .ena(bank_scalar || bank_vector),
            .enb(rd_en), .addra(wr_addr), .addrb(rd_addr), .dina(wr_data),
            .wea(wr_byte_enable), .doutb(bank_rd_data[b]), .rstb(!rst_n),
            .regceb(1'b1), .sleep(1'b0), .injectdbiterra(1'b0),
            .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb()
        );
`else
        reg [DATA_WIDTH-1:0] mem [0:255];
        always @(posedge clk) begin
            if (bank_scalar)
                mem[{wr_pixel_idx[5:3], wr_channel_idx[6:2]}]
                    [(wr_pixel_idx[2:0]*8) +: 8] <= wr_data_int8;
            if (bank_vector)
                mem[{wr_vec4_pixel_idx[5:3], wr_vec4_channel_idx[6:2]}]
                    [(wr_vec4_pixel_idx[2:0]*8) +: 8] <= wr_vec4_data_int8[(b*8) +: 8];
            if (!rst_n) bank_rd_data_sim[b] <= {DATA_WIDTH{1'b0}};
            else if (rd_en) bank_rd_data_sim[b] <= mem[rd_addr];
        end
        assign bank_rd_data[b] = bank_rd_data_sim[b];
`endif
    end endgenerate
    assign rd_data_vector = bank_rd_data[rd_bank_reg];
    always @(posedge clk) begin
        if (!rst_n) begin rd_valid <= 1'b0; rd_bank_reg <= 2'd0; end
        else begin rd_valid <= rd_en; if (rd_en) rd_bank_reg <= rd_bank; end
    end
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && rd_en && (rd_pixel_base[2:0] != 3'b000))
            $error("dw_tile_buffer_bram rd_pixel_base must be 8-aligned: %0d", rd_pixel_base);
    end
`endif
endmodule
`default_nettype wire
