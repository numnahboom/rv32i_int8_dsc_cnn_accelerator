`timescale 1ns/1ps
`default_nettype none

/* Focused runner integration check for the strict DS1 retained predicate.
 * All parameter words are zero, so the complete layer must write 32'h07070707
 * for every output word (PW output zero point is seven).  Source reads use the
 * existing synchronous feature-SRAM word contract. */
module tb_cnn_layer_runner_ds1_retained;
    localparam integer SRAM_ADDR_WIDTH = 15;
    localparam integer SRAM_BYTES = (1 << SRAM_ADDR_WIDTH);

    reg clk = 1'b0;
    always #1 clk = ~clk;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [1023:0] desc_words = 1024'd0;

    wire busy, done, error;
    wire mem_req_valid, mem_req_write;
    wire [31:0] mem_req_addr, mem_req_wdata;
    reg mem_req_ready = 1'b1;
    reg mem_resp_valid = 1'b0;
    reg [31:0] mem_resp_rdata = 32'd0;

    wire sram_input_rd_en;
    wire [SRAM_ADDR_WIDTH-1:0] sram_input_rd_addr;
    reg sram_input_rd_valid = 1'b0;
    reg signed [7:0] sram_input_rd_data = 8'sd0;
    wire sram_input_rd_word_en;
    wire [SRAM_ADDR_WIDTH-1:0] sram_input_rd_word_addr;
    reg sram_input_rd_word_valid = 1'b0;
    reg [31:0] sram_input_rd_word_data = 32'd0;
    wire sram_output_wr_en;
    wire [SRAM_ADDR_WIDTH-1:0] sram_output_wr_addr;
    wire signed [7:0] sram_output_wr_data;
    wire sram_output_wr4_en;
    wire [SRAM_ADDR_WIDTH-1:0] sram_output_wr4_addr;
    wire [31:0] sram_output_wr4_data;
    wire [3:0] sram_output_wr4_be;

    reg [7:0] input_mem [0:SRAM_BYTES-1];
    reg [7:0] output_mem [0:SRAM_BYTES-1];
    integer i;
    integer cycle;
    integer output_writes;
    integer output_bytes;
    integer errors;
    integer config_reads;
    integer source_word_reads;

    cnn_layer_runner #(
        .MAX_CIN(128), .MAX_COUT(256), .MAX_DS_IN_H(17), .MAX_DS_IN_W(17),
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH),
        .USE_DS1_RETAINED_ORCHESTRATOR(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .desc_words(desc_words),
        .busy(busy), .done(done), .error(error),
        .mem_req_valid(mem_req_valid), .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready), .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata),
        .sram_input_rd_en(sram_input_rd_en),
        .sram_input_rd_addr(sram_input_rd_addr),
        .sram_input_rd_valid(sram_input_rd_valid),
        .sram_input_rd_data(sram_input_rd_data),
        .sram_input_rd_word_en(sram_input_rd_word_en),
        .sram_input_rd_word_addr(sram_input_rd_word_addr),
        .sram_input_rd_word_valid(sram_input_rd_word_valid),
        .sram_input_rd_word_data(sram_input_rd_word_data),
        .sram_output_wr_en(sram_output_wr_en),
        .sram_output_wr_addr(sram_output_wr_addr),
        .sram_output_wr_data(sram_output_wr_data),
        .sram_output_wr4_en(sram_output_wr4_en),
        .sram_output_wr4_addr(sram_output_wr4_addr),
        .sram_output_wr4_data(sram_output_wr4_data),
        .sram_output_wr4_be(sram_output_wr4_be)
    );

    function [31:0] parameter_word;
        input [31:0] addr;
        begin
            parameter_word = 32'd0;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            sram_input_rd_valid <= 1'b0;
            sram_input_rd_data <= 8'sd0;
            sram_input_rd_word_valid <= 1'b0;
            sram_input_rd_word_data <= 32'd0;
        end else begin
            mem_resp_valid <= mem_req_valid && mem_req_ready && !mem_req_write;
            mem_resp_rdata <= parameter_word(mem_req_addr);
            sram_input_rd_valid <= sram_input_rd_en;
            sram_input_rd_data <= input_mem[sram_input_rd_addr];
            sram_input_rd_word_valid <= sram_input_rd_word_en;
            sram_input_rd_word_data <= {
                input_mem[sram_input_rd_word_addr + 15'd3],
                input_mem[sram_input_rd_word_addr + 15'd2],
                input_mem[sram_input_rd_word_addr + 15'd1],
                input_mem[sram_input_rd_word_addr]
            };

            if (mem_req_valid && mem_req_ready && !mem_req_write)
                config_reads <= config_reads + 1;
            if (sram_input_rd_word_en)
                source_word_reads <= source_word_reads + 1;

            if (sram_output_wr4_en) begin
                output_writes <= output_writes + 1;
                for (i = 0; i < 4; i = i + 1) begin
                    if (sram_output_wr4_be[i]) begin
                        if ((sram_output_wr4_addr + i) >= SRAM_BYTES)
                            errors = errors + 1;
                        else if (sram_output_wr4_data[(i*8) +: 8] !== 8'h07)
                            errors = errors + 1;
                        else begin
                            output_mem[sram_output_wr4_addr + i] <=
                                sram_output_wr4_data[(i*8) +: 8];
                            output_bytes = output_bytes + 1;
                        end
                    end
                end
            end
        end
    end

    initial begin
        cycle = 0;
        output_writes = 0;
        output_bytes = 0;
        errors = 0;
        config_reads = 0;
        source_word_reads = 0;
        for (i = 0; i < SRAM_BYTES; i = i + 1) begin
            input_mem[i] = i[7:0];
            output_mem[i] = 8'h00;
        end
        /* op=DS, input base=0, output base=0, and the eight parameter bases
         * are deliberately separated so the phase-loader request sequence is
         * observable. */
        desc_words = 1024'd0;
        desc_words[(0*32) +: 32] = 32'd1;
        desc_words[(1*32) +: 32] = 32'h0000_0000;
        desc_words[(2*32) +: 32] = 32'h0000_0000;
        desc_words[(3*32) +: 32] = 32'h0001_0000;
        desc_words[(4*32) +: 32] = 32'h0002_0000;
        desc_words[(5*32) +: 32] = 32'h0003_0000;
        desc_words[(6*32) +: 32] = 32'h0004_0000;
        desc_words[(7*32) +: 32] = 32'h0005_0000;
        desc_words[(8*32) +: 32] = 32'h0006_0000;
        desc_words[(9*32) +: 32] = 32'h0007_0000;
        desc_words[(10*32) +: 32] = 32'h0008_0000;
        desc_words[(11*32) +: 32] = {16'd32,16'd32};
        desc_words[(12*32) +: 32] = {16'd32,16'd16};
        desc_words[(13*32) +: 32] = 32'h0000_0101;
        desc_words[(14*32) +: 32] = 32'd0;
        desc_words[(15*32) +: 32] = 32'd0;
        desc_words[(16*32) +: 32] = 32'd7;
        desc_words[(17*32) +: 32] = 32'h7f80_7f80;
        desc_words[(18*32) +: 32] = 32'h0000_0036;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        while (!done && cycle < 2000000) begin
            @(posedge clk);
            cycle = cycle + 1;
        end
        if (!done) begin
            $display("FAIL tb_cnn_layer_runner_ds1_retained timeout cycle=%0d state=%0d busy=%b error=%b cfg_reads=%0d source_words=%0d output_writes=%0d bytes=%0d",
                     cycle, dut.state, busy, error, config_reads,
                     source_word_reads, output_writes, output_bytes);
            $fatal(1);
        end
        @(posedge clk);
        if (error || output_writes != 8192 || output_bytes != 32768 ||
            config_reads != 800 || source_word_reads == 0 || errors != 0) begin
            $display("FAIL tb_cnn_layer_runner_ds1_retained error=%b errors=%0d cycles=%0d cfg_reads=%0d source_words=%0d output_writes=%0d bytes=%0d",
                     error, errors, cycle, config_reads, source_word_reads,
                     output_writes, output_bytes);
            $fatal(1);
        end
        $display("PASS tb_cnn_layer_runner_ds1_retained cycles=%0d cfg_reads=%0d source_words=%0d output_writes=%0d bytes=%0d",
                 cycle, config_reads, source_word_reads, output_writes,
                 output_bytes);
        $finish(0);
    end
endmodule

`default_nettype wire
