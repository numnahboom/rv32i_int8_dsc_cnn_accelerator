`timescale 1ns/1ps
`default_nettype none

module tb_cnn_top;
    localparam DESC_BASE = 32'h0000_1000;
    localparam LAYERS = 4;
    localparam DESC_WORDS = 32;

    reg clk;
    reg rst_n;
    reg cmd_valid;
    wire cmd_ready;
    reg [1:0] cmd_type;
    reg [31:0] desc_base_addr;
    reg [31:0] layer_num;
    wire [31:0] status;
    wire mem_req_valid;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    reg mem_req_ready;
    reg mem_resp_valid;
    reg [31:0] mem_resp_rdata;

    reg [31:0] desc_mem [0:(LAYERS*DESC_WORDS)-1];
    integer i;
    integer req_count;
    integer error_count;
    integer timeout;
    reg [31:0] expected_addr;
    reg [31:0] read_index;

    cnn_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_type(cmd_type),
        .desc_base_addr(desc_base_addr),
        .layer_num(layer_num),
        .status(status),
        .mem_req_valid(mem_req_valid),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    /* verilator lint_off BLKSEQ */
    function [31:0] read_desc_word;
        input [31:0] addr;
        reg [31:0] idx;
        begin
            if (addr < DESC_BASE) begin
                read_desc_word = 32'hdead_0000;
            end else begin
                idx = (addr - DESC_BASE) >> 2;
                if (idx < (LAYERS * DESC_WORDS)) begin
                    read_desc_word = desc_mem[idx];
                end else begin
                    read_desc_word = 32'hdead_ffff;
                end
            end
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
        end else begin
            mem_resp_valid <= mem_req_valid && mem_req_ready && !mem_req_write;
            if (mem_req_valid && mem_req_ready && !mem_req_write) begin
                mem_resp_rdata <= read_desc_word(mem_req_addr);
            end
        end
    end

    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        if (rst_n && mem_req_valid && mem_req_ready) begin
            expected_addr = DESC_BASE + (req_count * 4);
            if (mem_req_write) begin
                $display("MISMATCH unexpected write addr=%08x data=%08x", mem_req_addr, mem_req_wdata);
                error_count = error_count + 1;
            end
            if (mem_req_addr !== expected_addr) begin
                $display("MISMATCH req=%0d expected_addr=%08x actual_addr=%08x", req_count, expected_addr, mem_req_addr);
                error_count = error_count + 1;
            end
            req_count = req_count + 1;
        end
    end
    /* verilator lint_on BLKSEQ */

    initial begin
        rst_n = 1'b0;
        cmd_valid = 1'b0;
        cmd_type = 2'd0;
        desc_base_addr = DESC_BASE;
        layer_num = LAYERS;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        req_count = 0;
        error_count = 0;
        timeout = 0;

        for (i = 0; i < (LAYERS * DESC_WORDS); i = i + 1) begin
            desc_mem[i] = 32'hcafe_0000 + i[31:0];
        end
        desc_mem[0 * DESC_WORDS + 0] = 32'd0;
        desc_mem[1 * DESC_WORDS + 0] = 32'd1;
        desc_mem[2 * DESC_WORDS + 0] = 32'd2;
        desc_mem[3 * DESC_WORDS + 0] = 32'd3;
        desc_mem[0 * DESC_WORDS + 18] = 32'd1;
        desc_mem[1 * DESC_WORDS + 18] = 32'd1;
        desc_mem[2 * DESC_WORDS + 18] = 32'd1;
        desc_mem[3 * DESC_WORDS + 18] = 32'd1;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        @(posedge clk);
        while (!cmd_ready) begin
            @(posedge clk);
        end
        cmd_valid = 1'b1;
        cmd_type = 2'd0;
        desc_base_addr = DESC_BASE;
        layer_num = LAYERS;
        @(posedge clk);
        cmd_valid = 1'b0;

        while (!status[1] && timeout < 5000) begin
            timeout = timeout + 1;
            @(posedge clk);
        end

        if (timeout >= 5000) begin
            $display("FAIL tb_cnn_top timeout status=%08x", status);
            $fatal;
        end

        if (status[0] !== 1'b0) begin
            $display("MISMATCH busy should be 0 at done status=%08x", status);
            error_count = error_count + 1;
        end
        if (status[2] !== 1'b0) begin
            $display("MISMATCH error should be 0 status=%08x", status);
            error_count = error_count + 1;
        end
        if (status[7:4] !== 4'd3) begin
            $display("MISMATCH current_layer expected=3 actual=%0d status=%08x", status[7:4], status);
            error_count = error_count + 1;
        end
        if (req_count != (LAYERS * DESC_WORDS)) begin
            $display("MISMATCH descriptor request count expected=%0d actual=%0d", (LAYERS * DESC_WORDS), req_count);
            error_count = error_count + 1;
        end

        repeat (5) @(posedge clk);
        if (error_count == 0) begin
            $display("PASS tb_cnn_top layers=%0d desc_reads=%0d status=%08x", LAYERS, req_count, status);
            $finish;
        end else begin
            $display("FAIL tb_cnn_top errors=%0d status=%08x", error_count, status);
            $fatal;
        end
    end
endmodule

`default_nettype wire
