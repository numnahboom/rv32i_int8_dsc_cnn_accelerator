`timescale 1ns/1ps
`default_nettype none

/* Gate A: DS1 production-boundary check against the independent non-zero
 * M1.1-A fixture.  The adapter sees the same descriptor ABI as cnn_top, the
 * parameter bus is 32-bit, and the feature source is the existing synchronous
 * 32-bit SRAM word port. */
module tb_m11a_runner_adapter;
    localparam integer SRAM_ADDR_WIDTH = 15;
    localparam integer SRAM_BYTES = (1 << SRAM_ADDR_WIDTH);
    localparam integer INPUT_BYTES = 32768;
    localparam integer OUTPUT_BYTES = 32768;
    localparam integer CONFIG_WORDS = 308;

    reg clk = 1'b0;
    always #1 clk = ~clk;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [1:0] desc_layer = 2'd1;
    reg [1023:0] desc_words = 1024'd0;

    wire busy, done, error;
    wire mem_req_valid, mem_req_write;
    wire [31:0] mem_req_addr, mem_req_wdata;
    wire mem_req_ready = 1'b1;
    reg mem_resp_valid = 1'b0;
    reg [31:0] mem_resp_rdata = 32'd0;
    reg mem_pending = 1'b0;
    reg [31:0] mem_pending_addr = 32'd0;

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

    reg [31:0] cfg_mem [0:CONFIG_WORDS-1];
    reg [7:0] input_mem [0:INPUT_BYTES-1];
    reg [7:0] expected_mem [0:OUTPUT_BYTES-1];

    integer fd;
    integer rc;
    integer ly, kind, idx;
    reg [31:0] address, mask, data_word;
    integer i;
    integer j;
    integer cycles;
    integer config_reads;
    integer input_word_reads;
    integer output_words;
    integer output_bytes;
    integer mismatches;
    integer input_nonzero;
    integer expected_nonzero;
    string fixture_dir;

    function [31:0] parameter_word;
        input [31:0] addr;
        integer cfg_idx;
        begin
            parameter_word = 32'd0;
            /* The fixture's packed DS1 map is the canonical production
             * config image. */
            if ((addr >= 32'h0000_3000) && (addr < 32'h0000_3090)) begin
                cfg_idx = (addr - 32'h0000_3000) >> 2;
                parameter_word = cfg_mem[cfg_idx];
            end else if ((addr >= 32'h0000_3100) && (addr < 32'h0000_3140)) begin
                cfg_idx = 36 + ((addr - 32'h0000_3100) >> 2);
                parameter_word = cfg_mem[cfg_idx];
            end else if ((addr >= 32'h0000_3140) && (addr < 32'h0000_3180)) begin
                cfg_idx = 52 + ((addr - 32'h0000_3140) >> 2);
                parameter_word = cfg_mem[cfg_idx];
            end else if ((addr >= 32'h0000_3180) && (addr < 32'h0000_31c0)) begin
                cfg_idx = 68 + ((addr - 32'h0000_3180) >> 2);
                parameter_word = cfg_mem[cfg_idx];
            end else if ((addr >= 32'h0000_3200) && (addr < 32'h0000_3400)) begin
                cfg_idx = 84 + ((addr - 32'h0000_3200) >> 2);
                parameter_word = cfg_mem[cfg_idx];
            end else if ((addr >= 32'h0000_3400) && (addr < 32'h0000_3480)) begin
                cfg_idx = 212 + ((addr - 32'h0000_3400) >> 2);
                parameter_word = cfg_mem[cfg_idx];
            end else if ((addr >= 32'h0000_3480) && (addr < 32'h0000_3500)) begin
                cfg_idx = 244 + ((addr - 32'h0000_3480) >> 2);
                parameter_word = cfg_mem[cfg_idx];
            end else if ((addr >= 32'h0000_3500) && (addr < 32'h0000_3580)) begin
                cfg_idx = 276 + ((addr - 32'h0000_3500) >> 2);
                parameter_word = cfg_mem[cfg_idx];
            end
        end
    endfunction

    m11a_runner_adapter #(
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .desc_layer(desc_layer),
        .desc_words(desc_words),
        .busy(busy), .done(done), .error(error),
        .mem_req_valid(mem_req_valid), .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready), .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata),
        .sram_input_rd_en(sram_input_rd_en), .sram_input_rd_addr(sram_input_rd_addr),
        .sram_input_rd_valid(sram_input_rd_valid), .sram_input_rd_data(sram_input_rd_data),
        .sram_input_rd_word_en(sram_input_rd_word_en),
        .sram_input_rd_word_addr(sram_input_rd_word_addr),
        .sram_input_rd_word_valid(sram_input_rd_word_valid),
        .sram_input_rd_word_data(sram_input_rd_word_data),
        .sram_output_wr_en(sram_output_wr_en), .sram_output_wr_addr(sram_output_wr_addr),
        .sram_output_wr_data(sram_output_wr_data),
        .sram_output_wr4_en(sram_output_wr4_en),
        .sram_output_wr4_addr(sram_output_wr4_addr),
        .sram_output_wr4_data(sram_output_wr4_data),
        .sram_output_wr4_be(sram_output_wr4_be)
    );

    /* Registered one-cycle response for the 32-bit external parameter bus
     * and the existing feature-SRAM word port. */
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            mem_pending <= 1'b0;
            mem_pending_addr <= 32'd0;
            sram_input_rd_valid <= 1'b0;
            sram_input_rd_data <= 8'sd0;
            sram_input_rd_word_valid <= 1'b0;
            sram_input_rd_word_data <= 32'd0;
        end else begin
            mem_resp_valid <= 1'b0;
            if (mem_pending) begin
                mem_resp_valid <= 1'b1;
                mem_resp_rdata <= parameter_word(mem_pending_addr);
                mem_pending <= 1'b0;
            end else if (mem_req_valid && mem_req_ready && !mem_req_write) begin
                mem_pending <= 1'b1;
                mem_pending_addr <= mem_req_addr;
                config_reads <= config_reads + 1;
            end

            sram_input_rd_valid <= sram_input_rd_en;
            sram_input_rd_data <= input_mem[sram_input_rd_addr];
            sram_input_rd_word_valid <= sram_input_rd_word_en;
            sram_input_rd_word_data <= {
                input_mem[sram_input_rd_word_addr + 15'd3],
                input_mem[sram_input_rd_word_addr + 15'd2],
                input_mem[sram_input_rd_word_addr + 15'd1],
                input_mem[sram_input_rd_word_addr]
            };
            if (sram_input_rd_word_en)
                input_word_reads <= input_word_reads + 1;
            if (sram_output_wr4_en) begin
                output_words <= output_words + 1;
                if (sram_output_wr4_be != 4'hf)
                    mismatches <= mismatches + 1;
                for (j = 0; j < 4; j = j + 1) begin
                    if (sram_output_wr4_addr + j >= OUTPUT_BYTES)
                        mismatches <= mismatches + 1;
                    else if (sram_output_wr4_data[j*8 +: 8] !==
                             expected_mem[sram_output_wr4_addr + j])
                        mismatches <= mismatches + 1;
                    else
                        output_bytes = output_bytes + 1;
                end
            end
        end
    end

    initial begin
        fixture_dir = "build/m11a_nonzero_fixture";
        if (!$value$plusargs("FIXTURE=%s", fixture_dir))
            fixture_dir = "build/m11a_nonzero_fixture";
        for (i = 0; i < CONFIG_WORDS; i = i + 1) cfg_mem[i] = 32'd0;
        for (i = 0; i < INPUT_BYTES; i = i + 1) input_mem[i] = 8'd0;
        for (i = 0; i < OUTPUT_BYTES; i = i + 1) expected_mem[i] = 8'd0;
        $readmemh($sformatf("%s/ds12_stream_ds1_input_i8.hex", fixture_dir), input_mem);
        $readmemh($sformatf("%s/ds12_stream_ds1_output_i8.hex", fixture_dir), expected_mem);
        fd = $fopen($sformatf("%s/ds12_stream_cfg_transactions.hex", fixture_dir), "r");
        if (fd == 0) $fatal(1, "cannot open DS1 config fixture");
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%d %d %d %h %h %h\n",
                         ly, kind, idx, address, mask, data_word);
            if ((rc == 6) && (ly == 1) && (idx < CONFIG_WORDS))
                cfg_mem[idx] = data_word;
        end
        $fclose(fd);
        input_nonzero = 0;
        expected_nonzero = 0;
        for (i = 0; i < INPUT_BYTES; i = i + 1)
            if (input_mem[i] != 8'd0) input_nonzero = input_nonzero + 1;
        for (i = 0; i < OUTPUT_BYTES; i = i + 1)
            if (expected_mem[i] != 8'd0) expected_nonzero = expected_nonzero + 1;
        if (input_nonzero == 0 || expected_nonzero == 0)
            $fatal(1, "non-zero fixture was not loaded");

        /* DS1 production descriptor: packed config words, feature SRAM input
         * and output, direct byte-addressed SRAM bases. */
        desc_words = 1024'd0;
        desc_words[(0*32) +: 32] = 32'd1;
        desc_words[(1*32) +: 32] = 32'h0000_0000;
        desc_words[(2*32) +: 32] = 32'h0000_0000;
        desc_words[(3*32) +: 32] = 32'h0000_3000;
        desc_words[(4*32) +: 32] = 32'h0000_3100;
        desc_words[(5*32) +: 32] = 32'h0000_3140;
        desc_words[(6*32) +: 32] = 32'h0000_3180;
        desc_words[(7*32) +: 32] = 32'h0000_3200;
        desc_words[(8*32) +: 32] = 32'h0000_3400;
        desc_words[(9*32) +: 32] = 32'h0000_3480;
        desc_words[(10*32) +: 32] = 32'h0000_3500;
        desc_words[(11*32) +: 32] = {16'd32, 16'd32};
        desc_words[(12*32) +: 32] = {16'd32, 16'd16};
        desc_words[(13*32) +: 32] = 32'h0000_0101;
        desc_words[(14*32) +: 32] = 32'd0;
        desc_words[(15*32) +: 32] = 32'd0;
        desc_words[(16*32) +: 32] = 32'd0;
        /* The fixture uses ReLU-clamped DS1 DW/PW outputs: min=0, max=127
         * for both stages (the descriptor stores each pair as min/max bytes). */
        desc_words[(17*32) +: 32] = 32'h7f00_7f00;
        desc_words[(18*32) +: 32] = 32'h0000_0086;

        config_reads = 0;
        input_word_reads = 0;
        output_words = 0;
        output_bytes = 0;
        mismatches = 0;
        cycles = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        while (!done && cycles < 500000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!done || error || mismatches != 0 || config_reads != 308 ||
            input_word_reads != 12032 || output_words != 8192 ||
            output_bytes != 32768) begin
            $display("FAIL tb_m11a_runner_adapter done=%b error=%b cycles=%0d cfg_reads=%0d input_words=%0d output_words=%0d output_bytes=%0d mismatches=%0d",
                     done, error, cycles, config_reads, input_word_reads,
                     output_words, output_bytes, mismatches);
            $fatal(1);
        end
        $display("PASS tb_m11a_runner_adapter cycles=%0d cfg_reads=%0d input_words=%0d output_words=%0d output_bytes=%0d",
                 cycles, config_reads, input_word_reads, output_words, output_bytes);
        $finish(0);
    end
endmodule

`default_nettype wire
