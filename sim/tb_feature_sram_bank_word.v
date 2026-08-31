`timescale 1ns/1ps
`default_nettype none

// Deterministic randomized semantic check for the widened feature SRAM.
// Scalar reads must observe the selected byte of the 32-bit word, including
// partial byte-enable writes and a same-cycle read/write to the same byte.
module tb_feature_sram_bank_word;
    localparam ADDR_WIDTH = 6;
    localparam BYTE_COUNT = (1 << ADDR_WIDTH);

    reg clk;
    reg rst_n;
    reg wr_en;
    reg [ADDR_WIDTH-1:0] wr_addr;
    reg signed [7:0] wr_data;
    reg wr_word_en;
    reg [ADDR_WIDTH-1:0] wr_word_addr;
    reg [31:0] wr_word_data;
    reg [3:0] wr_word_be;
    reg rd_en;
    reg [ADDR_WIDTH-1:0] rd_addr;
    wire rd_valid;
    wire signed [7:0] rd_data;

    reg [7:0] model [0:BYTE_COUNT-1];
    integer i;
    integer errors;
    integer checks;
    reg [31:0] seed;
    integer addr_i;
    integer word_i;
    reg [31:0] data_i;
    reg [3:0] be_i;
    reg [7:0] expected_i;

    feature_sram_bank #(.ADDR_WIDTH(ADDR_WIDTH)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .wr_word_en(wr_word_en),
        .wr_word_addr(wr_word_addr),
        .wr_word_data(wr_word_data),
        .wr_word_be(wr_word_be),
        .rd_en(rd_en),
        .rd_addr(rd_addr),
        .rd_valid(rd_valid),
        .rd_data(rd_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task scalar_write;
        input [ADDR_WIDTH-1:0] addr;
        input [7:0] data;
        begin
            @(negedge clk);
            wr_en = 1'b1;
            wr_addr = addr;
            wr_data = data;
            @(posedge clk);
            #1;
            wr_en = 1'b0;
            model[addr] = data;
        end
    endtask

    task word_write;
        input [ADDR_WIDTH-1:0] addr;
        input [31:0] data;
        input [3:0] be;
        integer lane;
        begin
            @(negedge clk);
            wr_word_en = 1'b1;
            wr_word_addr = {addr[ADDR_WIDTH-1:2], 2'b00};
            wr_word_data = data;
            wr_word_be = be;
            @(posedge clk);
            #1;
            wr_word_en = 1'b0;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (be[lane]) model[{addr[ADDR_WIDTH-1:2], 2'b00} + lane] = data[(lane*8) +: 8];
        end
    endtask

    task read_check;
        input [ADDR_WIDTH-1:0] addr;
        begin
            @(negedge clk);
            rd_en = 1'b1;
            rd_addr = addr;
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (!rd_valid || rd_data[7:0] !== model[addr]) begin
                $display("MISMATCH read addr=%0d expected=%02x valid=%b actual=%02x",
                         addr, model[addr], rd_valid, rd_data[7:0]);
                errors = errors + 1;
            end
            rd_en = 1'b0;
        end
    endtask

    task same_cycle_scalar_check;
        input [ADDR_WIDTH-1:0] addr;
        input [7:0] data;
        begin
            @(negedge clk);
            wr_en = 1'b1;
            wr_addr = addr;
            wr_data = data;
            rd_en = 1'b1;
            rd_addr = addr;
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (!rd_valid || rd_data[7:0] !== data) begin
                $display("MISMATCH same-cycle addr=%0d expected=%02x valid=%b actual=%02x",
                         addr, data, rd_valid, rd_data[7:0]);
                errors = errors + 1;
            end
            wr_en = 1'b0;
            rd_en = 1'b0;
            model[addr] = data;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        wr_en = 1'b0;
        wr_addr = '0;
        wr_data = '0;
        wr_word_en = 1'b0;
        wr_word_addr = '0;
        wr_word_data = '0;
        wr_word_be = '0;
        rd_en = 1'b0;
        rd_addr = '0;
        errors = 0;
        checks = 0;
        seed = 32'h1a2b3c4d;
        for (i = 0; i < BYTE_COUNT; i = i + 1) model[i] = 8'h00;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // Exercise all lane offsets and exact read-after-write behavior.
        for (i = 0; i < 32; i = i + 1) begin
            scalar_write(i[ADDR_WIDTH-1:0], (8'h31 + i));
            read_check(i[ADDR_WIDTH-1:0]);
            addr_i = BYTE_COUNT - 1 - i;
            same_cycle_scalar_check(addr_i[ADDR_WIDTH-1:0], (8'he0 - i));
        end

        // Random partial word writes followed by random scalar reads.  The
        // model deliberately retains disabled lanes from the prior word.
        for (i = 0; i < 250; i = i + 1) begin
            data_i = $urandom(seed);
            be_i = $urandom(seed);
            if (be_i == 4'b0000) be_i = 4'b0101;
            word_i = $urandom(seed) % (BYTE_COUNT / 4);
            word_write(word_i * 4, data_i, be_i);
            addr_i = $urandom(seed) % BYTE_COUNT;
            read_check(addr_i[ADDR_WIDTH-1:0]);
            if ((i % 7) == 0) begin
                addr_i = $urandom(seed) % BYTE_COUNT;
                read_check(addr_i[ADDR_WIDTH-1:0]);
            end
        end

        // Scalar writes have priority if both write ports are asserted.
        @(negedge clk);
        wr_en = 1'b1;
        wr_addr = 6'd9;
        wr_data = 8'h5a;
        wr_word_en = 1'b1;
        wr_word_addr = 6'd8;
        wr_word_data = 32'h11223344;
        wr_word_be = 4'b1111;
        @(posedge clk);
        #1;
        wr_en = 1'b0;
        wr_word_en = 1'b0;
        model[9] = 8'h5a;
        read_check(6'd8);
        read_check(6'd9);
        read_check(6'd10);
        read_check(6'd11);

        if (errors == 0) begin
            $display("PASS tb_feature_sram_bank_word checks=%0d", checks);
            $finish;
        end else begin
            $display("FAIL tb_feature_sram_bank_word checks=%0d errors=%0d", checks, errors);
            $fatal;
        end
    end
endmodule

`default_nettype wire
