`timescale 1ns/1ps
`default_nettype none

// Direct runner proof for the actual tiled DS load/store envelope.  This
// keeps the external memory transaction channel visible while selecting the
// unified64 PW implementation below the runner.
module tb_cnn_layer_runner_unified64_ds_tiled;
    localparam integer MEM_WORDS = 262144;
    localparam integer MAX_EXPECTED = 8192;
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
    reg expected_valid [0:MEM_WORDS-1];
    reg [7:0] expected_data [0:MEM_WORDS-1];
    integer fd, scan_count, num_cases, case_idx, entry_count;
    integer expected_count, layer_num_file, i, timeout, cycle_count;
    integer mem_read_count, mem_write_count, nonzero_expected, nonzero_actual;
    integer errors;
    reg [31:0] tmp_addr, tmp_data;
    reg [7:0] tmp_i8;
    integer wi;

    cnn_layer_runner #(.USE_UNIFIED64_DS(1)) dut (
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
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            sram_input_rd_valid <= 1'b0;
            sram_input_rd_word_valid <= 1'b0;
        end else begin
            mem_resp_valid <= 1'b0;
            sram_input_rd_valid <= 1'b0;
            sram_input_rd_word_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                wi = mem_req_addr[19:2];
                if (mem_req_write) begin
                    if (!expected_valid[wi] || (mem_req_wdata[7:0] !== expected_data[wi])) begin
                        $display("MISMATCH tiled write addr=%08x data=%0d expected_valid=%b expected=%0d",
                                 mem_req_addr, $signed(mem_req_wdata[7:0]),
                                 expected_valid[wi], $signed(expected_data[wi]));
                        errors = errors + 1;
                    end
                    if (mem_req_wdata[7:0] != 8'd0) nonzero_actual = nonzero_actual + 1;
                    mem[mem_req_addr[19:2]] <= mem_req_wdata;
                    mem_write_count = mem_write_count + 1;
                end else begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem[mem_req_addr[19:2]];
                    mem_read_count = mem_read_count + 1;
                end
            end
        end
    end

    task reset_and_start;
        begin
            @(negedge clk); rst_n=1'b0; start=1'b0; mem_req_ready=1'b1;
            mem_resp_valid=1'b0; mem_resp_rdata=0;
            sram_input_rd_valid=0; sram_input_rd_data=0;
            sram_input_rd_word_valid=0; sram_input_rd_word_data=0;
            repeat (4) @(posedge clk);
            @(negedge clk); rst_n=1'b1; @(posedge clk); @(negedge clk);
            start=1'b1; @(negedge clk); start=1'b0;
        end
    endtask

    task wait_done;
        begin
            timeout=0; cycle_count=0;
            while (!done && timeout < 500000) begin
                @(posedge clk); timeout=timeout+1;
                if (busy) cycle_count=cycle_count+1;
            end
            if (!done) begin
                $display("FAIL tiled timeout case=%0d", case_idx);
                errors=errors+1;
            end
        end
    endtask

    initial begin
        clk=0; rst_n=0; start=0; desc_words=0; mem_req_ready=1;
        mem_resp_valid=0; mem_resp_rdata=0; sram_input_rd_valid=0;
        sram_input_rd_data=0; sram_input_rd_word_valid=0;
        sram_input_rd_word_data=0; errors=0;
        fd=$fopen("tests/vectors/cnn_top_tiled_dsblock_cases.hex","r");
        if (!fd) begin $display("FAIL cannot open tiled DS vector"); $finish; end
        scan_count=$fscanf(fd,"%d\n",num_cases);
        for (case_idx=0; case_idx<num_cases; case_idx=case_idx+1) begin
            for (i=0;i<MEM_WORDS;i=i+1) begin mem[i]=0; expected_valid[i]=0; expected_data[i]=0; end
            desc_words=0; nonzero_expected=0; nonzero_actual=0;
            scan_count=$fscanf(fd,"%h %d %d %d\n",tmp_addr,layer_num_file,entry_count,expected_count);
            for (i=0;i<entry_count;i=i+1) begin
                scan_count=$fscanf(fd,"%h %h\n",tmp_addr,tmp_data);
                mem[tmp_addr[19:2]]=tmp_data;
                if (i<32) desc_words[(i*32)+:32]=tmp_data;
            end
            for (i=0;i<expected_count;i=i+1) begin
                scan_count=$fscanf(fd,"%h %h\n",tmp_addr,tmp_i8);
                expected_valid[tmp_addr[19:2]]=1'b1;
                expected_data[tmp_addr[19:2]]=tmp_i8;
                if (tmp_i8 != 0) nonzero_expected=nonzero_expected+1;
            end
            mem_read_count=0; mem_write_count=0; errors=0;
            reset_and_start(); wait_done();
            $display("RESULT tiled case=%0d cycles=%0d reads=%0d writes=%0d expected_writes=%0d nonzero=%0d error=%b",
                     case_idx,cycle_count,mem_read_count,mem_write_count,
                     expected_count,nonzero_actual,error);
            if (error || mem_write_count != expected_count ||
                nonzero_expected == 0 || nonzero_actual == 0) errors=errors+1;
            if (errors != 0) $finish;
        end
        $fclose(fd);
        $display("PASS tb_cnn_layer_runner_unified64_ds_tiled cases=%0d",num_cases);
        $finish;
    end
endmodule
`default_nettype wire
