`timescale 1ns/1ps
`default_nettype none

// Direction-3 contract check: 27 external NHWC bytes are fetched as seven
// aligned words, with a delayed response and intermittent ready stalls.  The
// first scalar parameter request must not inherit the packed request address.
module tb_cnn_layer_runner_packed_input;
    reg clk = 0, rst_n = 0, start = 0;
    reg [1023:0] desc_words = 0;
    wire busy, done, error, mem_req_valid, mem_req_write;
    wire [31:0] mem_req_addr, mem_req_wdata;
    wire mem_req_ready;
    reg mem_resp_valid = 0;
    reg [31:0] mem_resp_rdata = 32'h03020100;
    wire sram_input_rd_en, sram_output_wr_en;
    wire [14:0] sram_input_rd_addr, sram_output_wr_addr;
    reg sram_input_rd_valid = 0;
    reg signed [7:0] sram_input_rd_data = 0;
    wire signed [7:0] sram_output_wr_data;
    integer cycle = 0, handshakes = 0, errors = 0, pending = 0, delay = 0;
    reg [31:0] seen [0:7];

    cnn_layer_runner dut (
        .clk(clk), .rst_n(rst_n), .start(start), .desc_words(desc_words),
        .busy(busy), .done(done), .error(error),
        .mem_req_valid(mem_req_valid), .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready), .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata), .sram_input_rd_en(sram_input_rd_en),
        .sram_input_rd_addr(sram_input_rd_addr),
        .sram_input_rd_valid(sram_input_rd_valid),
        .sram_input_rd_data(sram_input_rd_data),
        .sram_output_wr_en(sram_output_wr_en),
        .sram_output_wr_addr(sram_output_wr_addr),
        .sram_output_wr_data(sram_output_wr_data)
    );
    always #5 clk = ~clk;
    // The responder accepts exactly one read at a time; ready stalls are
    // independent of the registered two-cycle response delay.
    assign mem_req_ready = (pending == 0) && ((cycle % 3) != 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle <= 0; mem_resp_valid <= 0; pending <= 0;
        end else begin
            cycle <= cycle + 1;
            mem_resp_valid <= 0;
            if (pending != 0) begin
                if (delay == 0) begin
                    mem_resp_valid <= 1;
                    pending <= 0;
                end else delay <= delay - 1;
            end
            if (mem_req_valid && !mem_req_write && mem_req_ready) begin
                if (handshakes < 8) seen[handshakes] <= mem_req_addr;
                handshakes <= handshakes + 1;
                if (pending != 0) errors <= errors + 1;
                pending <= 1; delay <= 2;
                // Distinct lane values make the byte-lane selection observable
                // in waveforms without depending on engine completion.
                mem_resp_rdata <= {8'h04, 8'h03, 8'h02, 8'h01};
            end
        end
    end

    initial begin
        desc_words[31:0] = 32'd0;       // Stem
        desc_words[63:32] = 32'h0000_1000; // aligned packed NHWC byte base
        desc_words[95:64] = 32'h0000_3000;
        desc_words[127:96] = 32'h0000_2001; // scalar DW base must remain unaligned
        desc_words[383:352] = {16'd3, 16'd3};  // word 11: in_w, in_h
        desc_words[415:384] = {16'd16, 16'd3}; // word 12: out_c, in_c
        desc_words[447:416] = 32'h0000_0101;   // word 13: stride=1, pad=1
        desc_words[607:576] = 32'h0000_0040;   // word 18: FLAG_PACKED_INPUT
        #12 rst_n = 1; #10 start = 1; #10 start = 0;
        wait (handshakes >= 8);
        #10;
        if (errors != 0 || handshakes != 8) $fatal(1, "single outstanding violated");
        if (seen[0] !== 32'h0000_1000 || seen[1] !== 32'h0000_1004 ||
            seen[2] !== 32'h0000_1008 || seen[3] !== 32'h0000_100c ||
            seen[4] !== 32'h0000_1010 || seen[5] !== 32'h0000_1014 ||
            seen[6] !== 32'h0000_1018 || seen[7] !== 32'h0000_2001)
            $fatal(1, "packed/scalar address sequence incorrect");
        $display("PASS tb_cnn_layer_runner_packed_input packed_reads=7 scalar_transition=%h", seen[7]);
        $finish;
    end
endmodule
