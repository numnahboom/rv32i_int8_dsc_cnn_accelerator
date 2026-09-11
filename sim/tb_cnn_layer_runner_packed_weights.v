`timescale 1ns/1ps
`default_nettype none

// Runner-only proof for the real DS packed-weight path.  The memory contains
// packed words at the descriptor's DW/PW weight regions; there are no scalar
// records behind those addresses.  Quant phases remain full 32-bit reads.
module tb_cnn_layer_runner_packed_weights;
    localparam integer MEM_WORDS = 16384;
    reg clk, rst_n, start;
    reg [1023:0] desc_words;
    wire busy, done, error;
    wire mem_req_valid, mem_req_write;
    wire [31:0] mem_req_addr, mem_req_wdata;
    reg mem_req_ready, mem_resp_valid;
    reg [31:0] mem_resp_rdata;
    wire sram_input_rd_en, sram_input_rd_word_en;
    wire [14:0] sram_input_rd_addr, sram_input_rd_word_addr;
    reg sram_input_rd_valid, sram_input_rd_word_valid;
    reg signed [7:0] sram_input_rd_data;
    reg [31:0] sram_input_rd_word_data;
    wire sram_output_wr_en, sram_output_wr4_en;
    wire [14:0] sram_output_wr_addr, sram_output_wr4_addr;
    wire signed [7:0] sram_output_wr_data;
    wire [31:0] sram_output_wr4_data;
    wire [3:0] sram_output_wr4_be;
    reg [31:0] mem [0:MEM_WORDS-1];
    integer i, reads, writes, errors, timeout, bus_cycle, resp_delay;
    reg pending_resp;
    reg [31:0] pending_resp_data;
    reg [31:0] read_addr [0:63];

    cnn_layer_runner dut (
        .clk(clk), .rst_n(rst_n), .start(start), .desc_words(desc_words),
        .busy(busy), .done(done), .error(error),
        .mem_req_valid(mem_req_valid), .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready), .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata),
        .sram_input_rd_en(sram_input_rd_en), .sram_input_rd_addr(sram_input_rd_addr),
        .sram_input_rd_valid(sram_input_rd_valid), .sram_input_rd_data(sram_input_rd_data),
        .sram_input_rd_word_en(sram_input_rd_word_en), .sram_input_rd_word_addr(sram_input_rd_word_addr),
        .sram_input_rd_word_valid(sram_input_rd_word_valid), .sram_input_rd_word_data(sram_input_rd_word_data),
        .sram_output_wr_en(sram_output_wr_en), .sram_output_wr_addr(sram_output_wr_addr),
        .sram_output_wr_data(sram_output_wr_data), .sram_output_wr4_en(sram_output_wr4_en),
        .sram_output_wr4_addr(sram_output_wr4_addr), .sram_output_wr4_data(sram_output_wr4_data),
        .sram_output_wr4_be(sram_output_wr4_be)
    );

    always #5 clk = ~clk;

    // Deterministic pseudo-random backpressure; the response delay below is
    // independent, so the runner must preserve one outstanding request and
    // keep its address stable until ready.
    always @(negedge clk) begin
        if (rst_n)
            mem_req_ready = ((bus_cycle % 5) != 1);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            pending_resp <= 1'b0;
            pending_resp_data <= 32'd0;
            resp_delay = 0;
            bus_cycle = 0;
        end else begin
            bus_cycle = bus_cycle + 1;
            mem_resp_valid <= 1'b0;
            if (pending_resp) begin
                if (resp_delay == 0) begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= pending_resp_data;
                    pending_resp <= 1'b0;
                end else begin
                    resp_delay = resp_delay - 1;
                end
            end
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem[mem_req_addr[15:2]] <= mem_req_wdata;
                    writes = writes + 1;
                end else begin
                    if (reads < 64) read_addr[reads] = mem_req_addr;
                    reads = reads + 1;
                    pending_resp <= 1'b1;
                    pending_resp_data <= mem[mem_req_addr[15:2]];
                    resp_delay = reads % 3;
                end
            end
        end
    end

    task run_case;
        begin
            @(negedge clk); rst_n = 1'b0; start = 1'b0;
            mem_req_ready = 1'b1; mem_resp_valid = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            @(posedge clk); @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            timeout = 0;
            while (!done && timeout < 200000) begin
                @(posedge clk); timeout = timeout + 1;
            end
            if (!done || error) begin
                $display("FAIL packed runner done=%b error=%b timeout=%0d", done, error, timeout);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0; rst_n = 1'b0; start = 1'b0; desc_words = 1024'd0;
        mem_req_ready = 1'b1; mem_resp_valid = 1'b0; mem_resp_rdata = 32'd0;
        sram_input_rd_valid = 1'b0; sram_input_rd_data = 8'sd0;
        sram_input_rd_word_valid = 1'b0; sram_input_rd_word_data = 32'd0;
        errors = 0; reads = 0; writes = 0; pending_resp = 1'b0;
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'd0;

        // DS descriptor: 3x3x2 -> 1x1x3, packed weights flag bit 7.
        desc_words[0*32 +: 32] = 32'd1;
        desc_words[1*32 +: 32] = 32'h0000_1000;
        desc_words[2*32 +: 32] = 32'h0000_2000;
        desc_words[3*32 +: 32] = 32'h0000_3000;
        desc_words[4*32 +: 32] = 32'h0000_4000;
        desc_words[5*32 +: 32] = 32'h0000_5000;
        desc_words[6*32 +: 32] = 32'h0000_6000;
        desc_words[7*32 +: 32] = 32'h0000_7000;
        desc_words[8*32 +: 32] = 32'h0000_8000;
        desc_words[9*32 +: 32] = 32'h0000_9000;
        desc_words[10*32 +: 32] = 32'h0000_a000;
        desc_words[11*32 +: 32] = {16'd3,16'd3};
        desc_words[12*32 +: 32] = {16'd3,16'd2};
        desc_words[13*32 +: 32] = 32'h0000_0101;
        desc_words[14*32 +: 32] = 32'd0;
        desc_words[15*32 +: 32] = 32'd0;
        desc_words[16*32 +: 32] = 32'd0;
        desc_words[17*32 +: 32] = 32'h7f80_7f80;
        desc_words[18*32 +: 32] = 32'h0000_0080;

        // Input is nine scalar records.  Weight regions contain only packed
        // words: 9 DW bytes (last word has three disabled/padded bytes) and
        // one PW byte.  Quant records are complete 32-bit words.
        for (i = 0; i < 18; i = i + 1) mem[(32'h1000 >> 2) + i] = 32'd1;
        for (i = 0; i < 18; i = i + 1)
            mem[(32'h3000 >> 2) + (i / 4)] =
                mem[(32'h3000 >> 2) + (i / 4)] |
                ((i + 1) << ((i % 4) * 8));
        for (i = 0; i < 2; i = i + 1) begin
            mem[(32'h4000 >> 2) + i] = 32'd0;
            mem[(32'h5000 >> 2) + i] = 32'd1;
            mem[(32'h6000 >> 2) + i] = 32'd0;
        end
        for (i = 0; i < 6; i = i + 1)
            mem[(32'h7000 >> 2) + (i / 4)] =
                mem[(32'h7000 >> 2) + (i / 4)] |
                ((8'h2a + i) << ((i % 4) * 8));
        for (i = 0; i < 3; i = i + 1) begin
            mem[(32'h8000 >> 2) + i] = 32'd0;
            mem[(32'h9000 >> 2) + i] = 32'd1;
            mem[(32'ha000 >> 2) + i] = 32'd0;
        end

        run_case();

        if (reads != 40) begin
            $display("FAIL packed transaction count reads=%0d expected=40", reads);
            errors = errors + 1;
        end
        if (read_addr[18] !== 32'h0000_3000 ||
            read_addr[19] !== 32'h0000_3004 ||
            read_addr[20] !== 32'h0000_3008 ||
            read_addr[21] !== 32'h0000_300c ||
            read_addr[22] !== 32'h0000_3010 ||
            read_addr[29] !== 32'h0000_7000 ||
            read_addr[30] !== 32'h0000_7004) begin
            $display("FAIL packed addresses DW=%08x,%08x,%08x PW=%08x",
                     read_addr[18], read_addr[19], read_addr[20], read_addr[29]);
            errors = errors + 1;
        end
        for (i = 0; i < 18; i = i + 1)
            if (dut.gen_legacy_ds_engine.u_ds_block_engine.dw_weight_mem[i] !== (i + 1)) begin
                $display("FAIL DW byte[%0d]=%0d expected=%0d", i,
                         dut.gen_legacy_ds_engine.u_ds_block_engine.dw_weight_mem[i], i + 1);
                errors = errors + 1;
            end
        // The packed loader now retires into the canonical [Cout][Cin]
        // BRAM layout.  The six bytes in this descriptor occupy consecutive
        // Cin addresses 0..5 of Cout lane 0.
        if (dut.gen_legacy_ds_engine.u_ds_block_engine.u_pw_weight_buffer.mem[0][7:0] !== 8'h2a ||
            dut.gen_legacy_ds_engine.u_ds_block_engine.u_pw_weight_buffer.mem[1][7:0] !== 8'h2b ||
            dut.gen_legacy_ds_engine.u_ds_block_engine.u_pw_weight_buffer.mem[2][7:0] !== 8'h2c ||
            dut.gen_legacy_ds_engine.u_ds_block_engine.u_pw_weight_buffer.mem[3][7:0] !== 8'h2d ||
            dut.gen_legacy_ds_engine.u_ds_block_engine.u_pw_weight_buffer.mem[4][7:0] !== 8'h2e ||
            dut.gen_legacy_ds_engine.u_ds_block_engine.u_pw_weight_buffer.mem[5][7:0] !== 8'h2f) begin
            $display("FAIL PW canonical words=%08x,%08x",
                     dut.gen_legacy_ds_engine.u_ds_block_engine.u_pw_weight_buffer.mem[0],
                     dut.gen_legacy_ds_engine.u_ds_block_engine.u_pw_weight_buffer.mem[1]);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS tb_cnn_layer_runner_packed_weights reads=%0d writes=%0d", reads, writes);

        // Exercise the compatibility direction as well: the same runner
        // instance now receives the legacy one-byte-per-32-bit-word layout.
        // The PW buffer must leave its packed shadow when the first scalar PW
        // write arrives.
        desc_words[18*32 +: 32] = 32'd0;
        for (i = 0; i < 18; i = i + 1)
            mem[(32'h3000 >> 2) + i] = i + 1;
        for (i = 0; i < 6; i = i + 1)
            mem[(32'h7000 >> 2) + i] = 8'h2a + i;
        reads = 0; writes = 0; timeout = 0;
        run_case();
        if (reads != 57) begin
            $display("FAIL scalar-after-packed reads=%0d expected=57", reads);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS scalar compatibility after packed reads=%0d", reads);
        $finish;
    end
endmodule

`default_nettype wire
