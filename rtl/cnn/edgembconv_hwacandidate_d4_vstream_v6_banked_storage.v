`timescale 1ns/1ps
`default_nettype none

/*
 * Synchronous activation storage for the D4 vstream v6 candidate.
 *
 * This module is the physical boundary for the three activation stores used
 * by the v6 scheduler.  Every read is an accepted request followed by one
 * registered response cycle.  A response is held until resp_ready, and a
 * response-consuming edge may accept the next request (II=1).  The payload
 * arrays are deliberately not reset; only valid state is reset.
 *
 *   input   : eight 2048 x 8 banks, bank = byte address[6:4]
 *   scratch0: sixteen 2048 x 8 channel banks, common row address
 *   scratch1: eight 256 x 32 spatial banks, bank = pixel x[2:0]
 *
 * The XPM instances are kept explicit in synthesis so the hierarchy and
 * inferred RAMB resources are visible in the fresh v6 synthesis report.  The
 * non-synthesis model has the same synchronous response contract; it does not
 * expose asynchronous array reads to the scheduler.
 */
module edgembconv_hwacandidate_d4_vstream_v6_banked_storage (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cfg_valid,
    input  wire [2:0]  cfg_kind,
    input  wire [15:0] cfg_addr,
    input  wire [31:0] cfg_data,

    input  wire [7:0]  input_rd_valid,
    input  wire [87:0] input_rd_addr_vec,
    input  wire [15:0] input_rd_desc,
    output wire        input_rd_ready,
    input  wire        input_rd_resp_ready,
    output wire [63:0] input_rd_data_vec,
    output wire [15:0] input_rd_resp_desc,
    output wire        input_rd_resp_valid,

    input  wire        scratch0_rd_valid,
    input  wire [10:0] scratch0_rd_addr,
    output wire        scratch0_rd_ready,
    input  wire        scratch0_rd_resp_ready,
    output wire [127:0] scratch0_rd_data,
    output wire        scratch0_rd_resp_valid,

    input  wire [15:0] scratch0_wr_valid_vec,
    input  wire [10:0] scratch0_wr_addr,
    input  wire [127:0] scratch0_wr_data_vec,

    input  wire [7:0]  scratch1_rd_valid,
    input  wire [63:0] scratch1_rd_addr_vec,
    input  wire [15:0] scratch1_rd_desc,
    output wire        scratch1_rd_ready,
    input  wire        scratch1_rd_resp_ready,
    output wire [255:0] scratch1_rd_data_vec,
    output wire [15:0] scratch1_rd_resp_desc,
    output wire        scratch1_rd_resp_valid,

    /* Project position 7 is a separate physical consumer.  It gets its own
     * response handshake so an RQ burst cannot stall the dedicated positions
     * 0..6, which continue to run at II=1. */
    input  wire        scratch1_pool_rd_valid,
    input  wire [7:0]  scratch1_pool_rd_addr,
    input  wire [15:0] scratch1_pool_rd_desc,
    output wire        scratch1_pool_rd_ready,
    input  wire        scratch1_pool_rd_resp_ready,
    output wire [31:0] scratch1_pool_rd_data,
    output wire [15:0] scratch1_pool_rd_resp_desc,
    output wire        scratch1_pool_rd_resp_valid,

    input  wire        scratch1_wr_valid,
    input  wire [2:0]  scratch1_wr_bank,
    input  wire [7:0]  scratch1_wr_addr,
    input  wire [31:0] scratch1_wr_data
);
    localparam [2:0] CFG_INPUT = 3'd0;

    wire input_cfg_fire = cfg_valid && (cfg_kind == CFG_INPUT);
    wire [2:0] input_cfg_bank = cfg_addr[6:4];
    wire [10:0] input_cfg_row = {cfg_addr[15:7], 4'd0} + cfg_addr[3:0];

    reg input_resp_q, scratch0_resp_q, scratch1_resp_q, scratch1_pool_resp_q;
    reg [15:0] input_resp_desc_q, scratch1_resp_desc_q,
               scratch1_pool_resp_desc_q;
    wire input_rd_any = |input_rd_valid;
    wire scratch1_rd_any = |scratch1_rd_valid;
    wire input_rd_fire = input_rd_any && input_rd_ready;
    wire scratch0_rd_fire = scratch0_rd_valid && scratch0_rd_ready;
    wire scratch1_rd_fire = scratch1_rd_any && scratch1_rd_ready;
    wire scratch1_pool_rd_fire = scratch1_pool_rd_valid && scratch1_pool_rd_ready;

    assign input_rd_ready = rst_n && (!input_resp_q || input_rd_resp_ready);
    assign scratch0_rd_ready = rst_n && (!scratch0_resp_q || scratch0_rd_resp_ready);
    assign scratch1_rd_ready = rst_n && (!scratch1_resp_q || scratch1_rd_resp_ready);
    assign scratch1_pool_rd_ready = rst_n &&
                                    (!scratch1_pool_resp_q ||
                                     scratch1_pool_rd_resp_ready);
    assign input_rd_resp_valid = input_resp_q;
    assign scratch0_rd_resp_valid = scratch0_resp_q;
    assign scratch1_rd_resp_valid = scratch1_resp_q;
    assign scratch1_pool_rd_resp_valid = scratch1_pool_resp_q;

`ifndef SYNTHESIS
    (* ram_style = "block" *) reg signed [7:0] input_mem [0:7][0:2047];
    (* ram_style = "block" *) reg signed [7:0] scratch0_mem [0:15][0:2047];
    (* ram_style = "block" *) reg [31:0] scratch1_mem [0:7][0:255];
    reg [63:0] input_data_q;
    reg [127:0] scratch0_data_q;
    reg [255:0] scratch1_data_q;
    reg [31:0] scratch1_pool_data_q;
    integer b;

    /* The behavioral model exposes an explicit same-address write-first
     * bypass.  XPM simple-dual-port block RAM requires read-first mode on
     * port B, so the synthesis instances use that legal primitive setting;
     * the scheduler does not depend on a physical same-edge collision. */
    always @(posedge clk) begin
        if (!rst_n) begin
            input_resp_q <= 1'b0;
            scratch0_resp_q <= 1'b0;
            scratch1_resp_q <= 1'b0;
            scratch1_pool_resp_q <= 1'b0;
            input_resp_desc_q <= 16'd0;
            scratch1_resp_desc_q <= 16'd0;
            scratch1_pool_resp_desc_q <= 16'd0;
        end else begin
            if (input_resp_q && input_rd_resp_ready)
                input_resp_q <= 1'b0;
            if (scratch0_resp_q && scratch0_rd_resp_ready)
                scratch0_resp_q <= 1'b0;
            if (scratch1_resp_q && scratch1_rd_resp_ready)
                scratch1_resp_q <= 1'b0;
            if (scratch1_pool_resp_q && scratch1_pool_rd_resp_ready)
                scratch1_pool_resp_q <= 1'b0;

            if (input_rd_fire) begin
                input_resp_q <= 1'b1;
                input_resp_desc_q <= input_rd_desc;
                for (b = 0; b < 8; b = b + 1) begin
                    if (input_rd_valid[b]) begin
                        if (input_cfg_fire && input_cfg_bank == b[2:0] &&
                            input_cfg_row == input_rd_addr_vec[b*11 +: 11])
                            input_data_q[b*8 +: 8] <= cfg_data[7:0];
                        else
                            input_data_q[b*8 +: 8] <=
                                input_mem[b][input_rd_addr_vec[b*11 +: 11]];
                    end
                end
            end
            if (scratch0_rd_fire) begin
                scratch0_resp_q <= 1'b1;
                for (b = 0; b < 16; b = b + 1) begin
                    if (scratch0_wr_valid_vec[b] &&
                        scratch0_wr_addr == scratch0_rd_addr)
                        scratch0_data_q[b*8 +: 8] <=
                            scratch0_wr_data_vec[b*8 +: 8];
                    else
                        scratch0_data_q[b*8 +: 8] <=
                            scratch0_mem[b][scratch0_rd_addr];
                end
            end
            if (scratch1_rd_fire) begin
                scratch1_resp_q <= 1'b1;
                scratch1_resp_desc_q <= scratch1_rd_desc;
                for (b = 0; b < 7; b = b + 1) begin
                    if (scratch1_rd_valid[b]) begin
                        if (scratch1_wr_valid &&
                            scratch1_wr_bank == b[2:0] &&
                            scratch1_wr_addr == scratch1_rd_addr_vec[b*8 +: 8])
                            scratch1_data_q[b*32 +: 32] <= scratch1_wr_data;
                        else
                            scratch1_data_q[b*32 +: 32] <=
                                scratch1_mem[b][scratch1_rd_addr_vec[b*8 +: 8]];
                    end
                end
            end
            if (scratch1_pool_rd_fire) begin
                scratch1_pool_resp_q <= 1'b1;
                scratch1_pool_resp_desc_q <= scratch1_pool_rd_desc;
                if (scratch1_wr_valid && scratch1_wr_bank == 3'd7 &&
                    scratch1_wr_addr == scratch1_pool_rd_addr)
                    scratch1_pool_data_q <= scratch1_wr_data;
                else
                    scratch1_pool_data_q <= scratch1_mem[7][scratch1_pool_rd_addr];
            end

            if (input_cfg_fire)
                input_mem[input_cfg_bank][input_cfg_row] <= cfg_data[7:0];
            for (b = 0; b < 16; b = b + 1)
                if (scratch0_wr_valid_vec[b])
                    scratch0_mem[b][scratch0_wr_addr] <=
                        scratch0_wr_data_vec[b*8 +: 8];
            if (scratch1_wr_valid)
                scratch1_mem[scratch1_wr_bank][scratch1_wr_addr] <=
                    scratch1_wr_data;
        end
    end

    assign input_rd_data_vec = input_data_q;
    assign input_rd_resp_desc = input_resp_desc_q;
    assign scratch0_rd_data = scratch0_data_q;
    assign scratch1_rd_data_vec = scratch1_data_q;
    assign scratch1_rd_resp_desc = scratch1_resp_desc_q;
    assign scratch1_pool_rd_data = scratch1_pool_data_q;
    assign scratch1_pool_rd_resp_desc = scratch1_pool_resp_desc_q;
`else
    wire signed [7:0] input_dout [0:7];
    wire signed [7:0] scratch0_dout [0:15];
    wire [31:0] scratch1_dout [0:7];
    wire [31:0] scratch1_pool_dout;
    genvar ib;
    generate
      for (ib = 0; ib < 8; ib = ib + 1) begin : gen_input_xpm
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(2048*8),
          .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(8), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(8),
          .WRITE_MODE_B("read_first")
        ) u_mem (
          .clka(clk),
          .ena(input_cfg_fire && input_cfg_bank == ib[2:0]),
          .wea(input_cfg_fire && input_cfg_bank == ib[2:0]),
          .addra(input_cfg_row), .dina(cfg_data[7:0]),
          .clkb(clk), .enb(input_rd_fire && input_rd_valid[ib]),
          .addrb(input_rd_addr_vec[ib*11 +: 11]), .doutb(input_dout[ib]),
          .regceb(1'b1), .rstb(1'b0), .sleep(1'b0),
          .injectsbiterra(1'b0), .injectdbiterra(1'b0),
          .sbiterrb(), .dbiterrb()
        );
      end
      for (ib = 0; ib < 16; ib = ib + 1) begin : gen_scratch0_xpm
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(2048*8),
          .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(8), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(8),
          .WRITE_MODE_B("read_first")
        ) u_mem (
          .clka(clk), .ena(scratch0_wr_valid_vec[ib]),
          .wea(scratch0_wr_valid_vec[ib]), .addra(scratch0_wr_addr),
          .dina(scratch0_wr_data_vec[ib*8 +: 8]), .clkb(clk),
          .enb(scratch0_rd_fire), .addrb(scratch0_rd_addr),
          .doutb(scratch0_dout[ib]), .regceb(1'b1), .rstb(1'b0),
          .sleep(1'b0), .injectsbiterra(1'b0), .injectdbiterra(1'b0),
          .sbiterrb(), .dbiterrb()
        );
      end
      for (ib = 0; ib < 7; ib = ib + 1) begin : gen_scratch1_xpm
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(8), .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(256*32),
          .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(32),
          .WRITE_MODE_B("read_first")
        ) u_mem (
          .clka(clk),
          .ena(scratch1_wr_valid && scratch1_wr_bank == ib[2:0]),
          .wea(scratch1_wr_valid && scratch1_wr_bank == ib[2:0]),
          .addra(scratch1_wr_addr), .dina(scratch1_wr_data),
          .clkb(clk), .enb(scratch1_rd_fire && scratch1_rd_valid[ib]),
          .addrb(scratch1_rd_addr_vec[ib*8 +: 8]),
          .doutb(scratch1_dout[ib]), .regceb(1'b1), .rstb(1'b0),
          .sleep(1'b0), .injectsbiterra(1'b0), .injectdbiterra(1'b0),
          .sbiterrb(), .dbiterrb()
        );
      end
      xpm_memory_sdpram #(
        .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(8), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(256*32),
        .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(32),
        .WRITE_MODE_B("read_first")
      ) u_scratch1_pool_mem (
        .clka(clk), .ena(scratch1_wr_valid && scratch1_wr_bank == 3'd7),
        .wea(scratch1_wr_valid && scratch1_wr_bank == 3'd7),
        .addra(scratch1_wr_addr), .dina(scratch1_wr_data),
        .clkb(clk), .enb(scratch1_pool_rd_fire),
        .addrb(scratch1_pool_rd_addr), .doutb(scratch1_pool_dout),
        .regceb(1'b1), .rstb(1'b0), .sleep(1'b0),
        .injectsbiterra(1'b0), .injectdbiterra(1'b0),
        .sbiterrb(), .dbiterrb()
      );
    endgenerate

    always @(posedge clk) begin
      if (!rst_n) begin
        input_resp_q <= 1'b0;
        scratch0_resp_q <= 1'b0;
        scratch1_resp_q <= 1'b0;
        scratch1_pool_resp_q <= 1'b0;
        input_resp_desc_q <= 16'd0;
        scratch1_resp_desc_q <= 16'd0;
        scratch1_pool_resp_desc_q <= 16'd0;
      end else begin
        if (input_resp_q && input_rd_resp_ready)
          input_resp_q <= 1'b0;
        if (scratch0_resp_q && scratch0_rd_resp_ready)
          scratch0_resp_q <= 1'b0;
        if (scratch1_resp_q && scratch1_rd_resp_ready)
          scratch1_resp_q <= 1'b0;
        if (scratch1_pool_resp_q && scratch1_pool_rd_resp_ready)
          scratch1_pool_resp_q <= 1'b0;
        if (input_rd_fire) begin
          input_resp_q <= 1'b1;
          input_resp_desc_q <= input_rd_desc;
        end
        if (scratch0_rd_fire) scratch0_resp_q <= 1'b1;
        if (scratch1_rd_fire) begin
          scratch1_resp_q <= 1'b1;
          scratch1_resp_desc_q <= scratch1_rd_desc;
        end
        if (scratch1_pool_rd_fire) begin
          scratch1_pool_resp_q <= 1'b1;
          scratch1_pool_resp_desc_q <= scratch1_pool_rd_desc;
        end
      end
    end

    genvar od;
    generate
      for (od = 0; od < 8; od = od + 1) begin : gen_input_out
        assign input_rd_data_vec[od*8 +: 8] = input_dout[od];
        if (od < 7)
          assign scratch1_rd_data_vec[od*32 +: 32] = scratch1_dout[od];
        else
          assign scratch1_rd_data_vec[od*32 +: 32] = 32'd0;
      end
      for (od = 0; od < 16; od = od + 1)
        assign scratch0_rd_data[od*8 +: 8] = scratch0_dout[od];
      assign scratch1_pool_rd_data = scratch1_pool_dout;
      assign input_rd_resp_desc = input_resp_desc_q;
      assign scratch1_rd_resp_desc = scratch1_resp_desc_q;
      assign scratch1_pool_rd_resp_desc = scratch1_pool_resp_desc_q;
    endgenerate
`endif
endmodule

`default_nettype wire
