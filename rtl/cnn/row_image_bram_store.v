`timescale 1ns/1ps
`default_nettype none

/*
 * Eight-plane row image store.
 *
 * An address names one {row, group, half}: {row[2:0], group[3:0], half}.
 * Each address contains eight 36-bit words.  A word is {mask[3:0], data[31:0]}
 * and therefore represents four pixels for one 8-channel slice.  The write
 * port updates one plane per cycle.  The read port is a one-cycle synchronous
 * request/response interface with an elastic output register.  There is no
 * memory reset or initialization; reset only drops protocol valid state.
 *
 * Same-cycle read/write collisions are deliberately READ_FIRST: a read
 * accepted in the same cycle as a write to the same plane/address returns the
 * pre-write word.  This is both the simulation model and the XPM mode below.
 * Ownership/fence ordering is intentionally an external protocol concern;
 * this primitive accepts writes whenever wr_ready is asserted.
 */
module row_image_bram_store (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         wr_valid,
    output wire         wr_ready,
    input  wire [7:0]   wr_addr,
    input  wire [2:0]   wr_word_sel,
    input  wire [35:0]  wr_data36,

    input  wire         rd_req_valid,
    output wire         rd_req_ready,
    input  wire [7:0]   rd_addr,
    output reg          rd_valid,
    input  wire         rd_ready,
    output wire [255:0] rd_data,
    output wire [31:0]  rd_mask
);
    localparam integer DEPTH = 256;
    localparam integer DATA_WIDTH = 36;

    wire wr_fire;
    wire rd_fire;
    wire [DATA_WIDTH-1:0] bank_rd_data [0:7];

    assign wr_ready = 1'b1;
    assign wr_fire = wr_valid && wr_ready;
    /* One output slot: consume it, or accept a replacement in the same edge. */
    assign rd_req_ready = !rd_valid || rd_ready;
    assign rd_fire = rd_req_valid && rd_req_ready;

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : gen_plane
            wire bank_wr_en = wr_fire && (wr_word_sel == b[2:0]);

`ifdef SYNTHESIS
            RAMB36E1 #(
                /* Explicit primitive keeps each logical plane as one BRAM36
                 * placement boundary; XPM otherwise packs two planes/tile. */
                .DOA_REG(0),
                .DOB_REG(1),
                .EN_ECC_READ("FALSE"),
                .EN_ECC_WRITE("FALSE"),
                .RAM_MODE("SDP"),
                .RDADDR_COLLISION_HWCONFIG("DELAYED_WRITE"),
                .READ_WIDTH_A(0),
                .READ_WIDTH_B(36),
                .RSTREG_PRIORITY_A("RSTREG"),
                .RSTREG_PRIORITY_B("RSTREG"),
                .SIM_COLLISION_CHECK("ALL"),
                .SIM_DEVICE("7SERIES"),
                .SRVAL_A(36'h0),
                .SRVAL_B(36'h0),
                .WRITE_MODE_A("READ_FIRST"),
                .WRITE_MODE_B("READ_FIRST"),
                .WRITE_WIDTH_A(36),
                .WRITE_WIDTH_B(0)
            ) u_memory (
                .CLKARDCLK(clk), .CLKBWRCLK(clk),
                .ENARDEN(bank_wr_en), .ENBWREN(rd_fire),
                .ADDRARDADDR({2'b00, wr_addr, 6'b0}),
                .ADDRBWRADDR({2'b00, rd_addr, 6'b0}),
                .DIADI(wr_data36[31:0]), .DIPADIP(wr_data36[35:32]),
                .DIBDI(32'b0), .DIPBDIP(4'b0),
                .WEA(4'b1111), .WEBWE(8'b0),
                .DOADO(), .DOPADOP(), .DOBDO(bank_rd_data[b][31:0]),
                .DOPBDOP(bank_rd_data[b][35:32]),
                .REGCEAREGCE(1'b0), .REGCEB(1'b1),
                .RSTRAMARSTRAM(!rst_n), .RSTRAMB(!rst_n),
                .RSTREGARSTREG(!rst_n), .RSTREGB(!rst_n),
                .CASCADEINA(1'b0), .CASCADEINB(1'b0),
                .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
                .CASCADEOUTA(), .CASCADEOUTB(), .DBITERR(),
                .ECCPARITY(), .RDADDRECC(), .SBITERR()
            );
`else
            reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
            reg [DATA_WIDTH-1:0] bank_rd_data_reg;

            /* Nonblocking assignments model XPM READ_FIRST on collisions. */
            always @(posedge clk) begin
                if (bank_wr_en)
                    mem[wr_addr] <= wr_data36;
                if (rd_fire)
                    bank_rd_data_reg <= mem[rd_addr];
            end
            assign bank_rd_data[b] = bank_rd_data_reg;
`endif
        end
    endgenerate

    /* Static concatenation: no variable-address array mux on the read path. */
    generate
        for (b = 0; b < 8; b = b + 1) begin : gen_unpack
            assign rd_data[(b*32) +: 32] = bank_rd_data[b][31:0];
            assign rd_mask[(b*4) +: 4] = bank_rd_data[b][35:32];
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n)
            rd_valid <= 1'b0;
        else if (rd_req_ready)
            rd_valid <= rd_req_valid;
    end

`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH != 36 || DEPTH != 256)
            $error("row_image_bram_store geometry changed unexpectedly");
    end
`endif
endmodule

`default_nettype wire
