`timescale 1ns/1ps
`default_nettype none

module tb_feature_sram_bank_word_read;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg wr_en = 1'b0;
    reg [7:0] wr_addr = 8'd0;
    reg signed [7:0] wr_data = 8'sd0;
    reg wr_word_en = 1'b0;
    reg [7:0] wr_word_addr = 8'd0;
    reg [31:0] wr_word_data = 32'd0;
    reg [3:0] wr_word_be = 4'd0;
    reg rd_en = 1'b0;
    reg [7:0] rd_addr = 8'd0;
    wire rd_valid;
    wire signed [7:0] rd_data;
    reg rd_word_en = 1'b0;
    reg [7:0] rd_word_addr = 8'd0;
    wire rd_word_valid;
    wire [31:0] rd_word_data;
    integer errors = 0;
    integer checks = 0;

    always #5 clk = ~clk;

    feature_sram_bank #(.ADDR_WIDTH(8)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data),
        .wr_word_en(wr_word_en), .wr_word_addr(wr_word_addr),
        .wr_word_data(wr_word_data), .wr_word_be(wr_word_be),
        .rd_word_en(rd_word_en), .rd_word_addr(rd_word_addr),
        .rd_word_valid(rd_word_valid), .rd_word_data(rd_word_data)
    );

    task check_word;
        input [31:0] expected;
        begin
            @(posedge clk);
            #1;
            if (!rd_word_valid || rd_word_data !== expected) begin
                $display("MISMATCH word valid=%b data=%08x expected=%08x",
                         rd_word_valid, rd_word_data, expected);
                errors = errors + 1;
            end
            checks = checks + 1;
            rd_word_en <= 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        // Full word write, then a scalar lane overwrite.
        @(posedge clk);
        wr_word_en <= 1'b1;
        wr_word_addr <= 8'd4;
        wr_word_data <= 32'h44332211;
        wr_word_be <= 4'b1111;
        @(posedge clk);
        wr_word_en <= 1'b0;
        wr_word_be <= 4'd0;
        wr_en <= 1'b1;
        wr_addr <= 8'd5;
        wr_data <= -8'sd7;
        @(posedge clk);
        wr_en <= 1'b0;
        rd_word_en <= 1'b1;
        rd_word_addr <= 8'd4;
        check_word(32'h4433f911);

        // Partial write preserves the untouched byte lanes.
        @(posedge clk);
        wr_word_en <= 1'b1;
        wr_word_addr <= 8'd4;
        wr_word_data <= 32'haabbccdd;
        wr_word_be <= 4'b0101;
        @(posedge clk);
        wr_word_en <= 1'b0;
        wr_word_be <= 4'd0;
        rd_word_en <= 1'b1;
        rd_word_addr <= 8'd4;
        check_word(32'h44bbf9dd);

        if (errors == 0) begin
            $display("PASS tb_feature_sram_bank_word_read checks=%0d", checks);
            $finish;
        end else begin
            $display("FAIL tb_feature_sram_bank_word_read checks=%0d errors=%0d", checks, errors);
            $fatal;
        end
    end
endmodule

`default_nettype wire
