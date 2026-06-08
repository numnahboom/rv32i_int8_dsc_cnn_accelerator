`timescale 1ns/1ps
`default_nettype none

module feature_sram_pingpong #(
    parameter ADDR_WIDTH = 15,
    parameter DATA_WIDTH = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         reset_to_a,
    input  wire                         layer_done,
    output wire                         input_bank_sel,
    output wire                         output_bank_sel,

    input  wire                         input_rd_en,
    input  wire [ADDR_WIDTH-1:0]        input_rd_addr,
    output wire                         input_rd_valid,
    output wire signed [DATA_WIDTH-1:0] input_rd_data,

    input  wire                         output_wr_en,
    input  wire [ADDR_WIDTH-1:0]        output_wr_addr,
    input  wire signed [DATA_WIDTH-1:0] output_wr_data,

    input  wire                         host_wr_en,
    input  wire                         host_bank_sel,
    input  wire [ADDR_WIDTH-1:0]        host_addr,
    input  wire signed [DATA_WIDTH-1:0] host_wdata,
    input  wire                         host_rd_en,
    output wire                         host_rd_valid,
    output wire signed [DATA_WIDTH-1:0] host_rdata
);
    reg active_input_bank;
    reg input_rd_bank_d;
    reg host_rd_bank_d;
    reg input_rd_active_d;
    reg host_rd_active_d;

    wire bank0_wr_en;
    wire [ADDR_WIDTH-1:0] bank0_wr_addr;
    wire signed [DATA_WIDTH-1:0] bank0_wr_data;
    wire bank0_rd_en;
    wire [ADDR_WIDTH-1:0] bank0_rd_addr;
    wire bank0_rd_valid;
    wire signed [DATA_WIDTH-1:0] bank0_rd_data;

    wire bank1_wr_en;
    wire [ADDR_WIDTH-1:0] bank1_wr_addr;
    wire signed [DATA_WIDTH-1:0] bank1_wr_data;
    wire bank1_rd_en;
    wire [ADDR_WIDTH-1:0] bank1_rd_addr;
    wire bank1_rd_valid;
    wire signed [DATA_WIDTH-1:0] bank1_rd_data;

    wire logical_wr_bank;
    wire logical_rd_bank;

    assign input_bank_sel = active_input_bank;
    assign output_bank_sel = ~active_input_bank;
    assign logical_wr_bank = output_bank_sel;
    assign logical_rd_bank = input_bank_sel;
    assign input_rd_valid = input_rd_active_d &&
                            ((input_rd_bank_d == 1'b0) ? bank0_rd_valid : bank1_rd_valid);
    assign input_rd_data = (input_rd_bank_d == 1'b0) ? bank0_rd_data : bank1_rd_data;
    assign host_rd_valid = host_rd_active_d &&
                           ((host_rd_bank_d == 1'b0) ? bank0_rd_valid : bank1_rd_valid);
    assign host_rdata = (host_rd_bank_d == 1'b0) ? bank0_rd_data : bank1_rd_data;

    assign bank0_wr_en = (host_wr_en && !host_bank_sel) ||
                         (output_wr_en && !logical_wr_bank && !(host_wr_en && !host_bank_sel));
    assign bank0_wr_addr = (host_wr_en && !host_bank_sel) ? host_addr : output_wr_addr;
    assign bank0_wr_data = (host_wr_en && !host_bank_sel) ? host_wdata : output_wr_data;
    assign bank1_wr_en = (host_wr_en && host_bank_sel) ||
                         (output_wr_en && logical_wr_bank && !(host_wr_en && host_bank_sel));
    assign bank1_wr_addr = (host_wr_en && host_bank_sel) ? host_addr : output_wr_addr;
    assign bank1_wr_data = (host_wr_en && host_bank_sel) ? host_wdata : output_wr_data;

    assign bank0_rd_en = (host_rd_en && !host_bank_sel) ||
                         (input_rd_en && !logical_rd_bank && !(host_rd_en && !host_bank_sel));
    assign bank0_rd_addr = (host_rd_en && !host_bank_sel) ? host_addr : input_rd_addr;
    assign bank1_rd_en = (host_rd_en && host_bank_sel) ||
                         (input_rd_en && logical_rd_bank && !(host_rd_en && host_bank_sel));
    assign bank1_rd_addr = (host_rd_en && host_bank_sel) ? host_addr : input_rd_addr;

    feature_sram_bank #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_bank0 (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(bank0_wr_en),
        .wr_addr(bank0_wr_addr),
        .wr_data(bank0_wr_data),
        .rd_en(bank0_rd_en),
        .rd_addr(bank0_rd_addr),
        .rd_valid(bank0_rd_valid),
        .rd_data(bank0_rd_data)
    );

    feature_sram_bank #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_bank1 (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(bank1_wr_en),
        .wr_addr(bank1_wr_addr),
        .wr_data(bank1_wr_data),
        .rd_en(bank1_rd_en),
        .rd_addr(bank1_rd_addr),
        .rd_valid(bank1_rd_valid),
        .rd_data(bank1_rd_data)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            active_input_bank <= 1'b0;
            input_rd_bank_d <= 1'b0;
            host_rd_bank_d <= 1'b0;
            input_rd_active_d <= 1'b0;
            host_rd_active_d <= 1'b0;
        end else begin
            if (reset_to_a) begin
                active_input_bank <= 1'b0;
            end else if (layer_done) begin
                active_input_bank <= ~active_input_bank;
            end

            input_rd_bank_d <= logical_rd_bank;
            host_rd_bank_d <= host_bank_sel;
            input_rd_active_d <= input_rd_en;
            host_rd_active_d <= host_rd_en;
        end
    end
endmodule

`default_nettype wire
