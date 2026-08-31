`timescale 1ns/1ps
`default_nettype none

module tb_native_word_response_pipe;
  localparam integer DEPTH = 64;
  localparam integer TOTAL = 4200;
  reg clk = 0, rst_n = 0;
  reg fill_start_valid = 0, fill_bank = 0;
  reg [3:0] fill_epoch = 0;
  reg [23:0] fill_base_byte_addr = 0;
  reg [31:0] fill_word_count = 0;
  wire fill_start_ready;
  reg issue_valid = 0;
  wire issue_ready, mem_req_valid;
  reg mem_req_ready = 0;
  wire [23:0] mem_req_addr;
  reg mem_rvalid_mem = 0, stale_inject = 0;
  reg [31:0] mem_rdata_mem = 0, stale_data = 32'hdeadcafe;
  wire mem_rvalid = mem_rvalid_mem | stale_inject;
  wire [31:0] mem_rdata = stale_inject ? stale_data : mem_rdata_mem;
  wire wr_valid; reg wr_ready = 0;
  wire [3:0] wr_epoch; wire wr_bank; wire [23:0] wr_byte_addr;
  wire [31:0] wr_data; wire [3:0] wr_byte_mask; wire wr_last;
  wire fill_done_valid; wire [3:0] fill_done_epoch; wire fill_done_bank;
  wire [31:0] stale_resp_count, issue_count, response_count;
  integer cycle = 0, errors = 0, checks = 0, q_count = 0, exp_count = 0, model_idx = 0;
  integer q_head = 0, exp_head = 0, last_due = 0;
  integer q_due [0:8191]; reg [31:0] q_data [0:8191];
  reg [3:0] exp_epoch [0:8191]; reg exp_bank [0:8191];
  reg [23:0] exp_addr [0:8191]; reg [31:0] exp_data [0:8191]; reg exp_last [0:8191];

  always #5 clk = ~clk;
  native_word_response_pipe #(.ADDR_WIDTH(24), .EPOCH_WIDTH(4), .FIFO_DEPTH(DEPTH), .MEM_RD_LATENCY(3)) dut (
    .clk(clk), .rst_n(rst_n), .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
    .fill_epoch(fill_epoch), .fill_bank(fill_bank), .fill_base_byte_addr(fill_base_byte_addr), .fill_word_count(fill_word_count),
    .issue_valid(issue_valid), .issue_ready(issue_ready), .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata), .wr_valid(wr_valid), .wr_ready(wr_ready),
    .wr_epoch(wr_epoch), .wr_bank(wr_bank), .wr_byte_addr(wr_byte_addr), .wr_data(wr_data), .wr_byte_mask(wr_byte_mask), .wr_last(wr_last),
    .fill_done_valid(fill_done_valid), .fill_done_epoch(fill_done_epoch), .fill_done_bank(fill_done_bank),
    .stale_resp_count(stale_resp_count), .issue_count(issue_count), .response_count(response_count));

  function [31:0] source_data(input [23:0] a);
    source_data = {a[7:0] ^ 8'h5a, a[15:8] + 8'h31, a[7:0] + 8'ha7, a[15:8] ^ 8'hc3};
  endfunction

  /* In-order memory model with variable latency and independent response
   * bubbles.  The DUT has no response-ready pin, so the model only returns
   * responses for previously accepted requests. */
  always @(posedge clk) begin : memory_model
    integer k, due;
    if (!rst_n) begin
      cycle <= 0; q_count <= 0; q_head <= 0; last_due <= 0;
      mem_rvalid_mem <= 0; mem_rdata_mem <= 0;
    end else begin
      cycle <= cycle + 1;
      mem_rvalid_mem <= 0;
      if (mem_req_valid && mem_req_ready) begin
        q_data[q_head + q_count] <= source_data(mem_req_addr);
        due = cycle + 1 + ($urandom % 8);
        if (due <= last_due) due = last_due + 1;
        q_due[q_head + q_count] <= due;
        last_due <= due;
      end
      if ((q_count != 0) && (q_due[q_head] <= cycle) && ((cycle % 7) != 2) && ((cycle % 11) != 5)) begin
        mem_rvalid_mem <= 1;
        mem_rdata_mem <= q_data[q_head];
        q_head <= q_head + 1;
      end
      if ((mem_req_valid && mem_req_ready) &&
          !((q_count != 0) && (q_due[q_head] <= cycle) && ((cycle % 7) != 2) && ((cycle % 11) != 5)))
        q_count <= q_count + 1;
      else if (!(mem_req_valid && mem_req_ready) &&
               ((q_count != 0) && (q_due[q_head] <= cycle) && ((cycle % 7) != 2) && ((cycle % 11) != 5)))
        q_count <= q_count - 1;
    end
  end

  always @(negedge clk) begin
    if (!rst_n) begin mem_req_ready <= 0; wr_ready <= 0; end
    else begin
      mem_req_ready <= (($urandom % 13) != 1) && (($urandom % 13) != 2);
      wr_ready <= (($urandom % 9) != 0) && (($urandom % 9) != 1) && (($urandom % 17) != 4);
    end
  end

  /* Expected command stream is recorded at request acceptance. */
  always @(posedge clk) begin
    if (rst_n) begin
      if (mem_req_valid && mem_req_ready) begin
        exp_epoch[exp_head + exp_count] <= fill_epoch;
        exp_bank[exp_head + exp_count] <= fill_bank;
        exp_addr[exp_head + exp_count] <= (fill_base_byte_addr + (model_idx << 2));
        exp_data[exp_head + exp_count] <= source_data(mem_req_addr);
        exp_last[exp_head + exp_count] <= (model_idx + 1 == fill_word_count);
        model_idx <= model_idx + 1;
      end
      if (wr_valid && wr_ready) begin
        if (exp_count == 0) begin $display("unexpected output cycle=%0d",cycle); errors <= errors + 1; end
        else begin
          if (wr_epoch !== exp_epoch[exp_head] || wr_bank !== exp_bank[exp_head] ||
              wr_byte_addr !== exp_addr[exp_head] || wr_data !== exp_data[exp_head] ||
              wr_byte_mask !== 4'hf || wr_last !== exp_last[exp_head]) begin
            $display("MISMATCH cycle=%0d got ep=%x bank=%b addr=%x data=%x mask=%x last=%b exp ep=%x bank=%b addr=%x data=%x last=%b",
              cycle,wr_epoch,wr_bank,wr_byte_addr,wr_data,wr_byte_mask,wr_last,exp_epoch[exp_head],exp_bank[exp_head],exp_addr[exp_head],exp_data[exp_head],exp_last[exp_head]);
            errors <= errors + 1;
          end
          exp_head <= exp_head + 1; checks <= checks + 1;
        end
      end
      case ({(mem_req_valid && mem_req_ready), (wr_valid && wr_ready)})
        2'b10: exp_count <= exp_count + 1;
        2'b01: exp_count <= exp_count - 1;
        default: ;
      endcase
    end
  end

  task automatic start_fill(input [3:0] ep, input bit b, input [23:0] base, input integer words);
    begin
      @(negedge clk); fill_epoch=ep; fill_bank=b; fill_base_byte_addr=base; fill_word_count=words; fill_start_valid=1;
      while (!fill_start_ready) @(negedge clk);
      @(posedge clk); @(negedge clk); fill_start_valid=0;
    end
  endtask

  integer watchdog;
  initial begin
    repeat (4) @(posedge clk); rst_n=1;
    // Stray responses before any issue are rejected as stale.
    @(negedge clk); stale_inject=1; @(negedge clk); stale_inject=0;
    start_fill(4'h3,1'b0,24'h00103,1900);
    issue_valid=1;
    while (!fill_done_valid) @(posedge clk);
    issue_valid=0;
    // The first fill's final command is drained before the epoch fence opens.
    while (fill_done_valid) @(posedge clk);
    @(negedge clk); stale_inject=1; stale_data=32'h12345678; @(negedge clk); stale_inject=0;
    model_idx=0;
    start_fill(4'ha,1'b1,24'h00007,2300);
    issue_valid=1;
    while (!fill_done_valid) @(posedge clk);
    issue_valid=0;
    while (fill_done_valid) @(posedge clk);
    for (watchdog=0; watchdog<10000 && (exp_count!=0 || q_count!=0); watchdog=watchdog+1) @(posedge clk);
    if (exp_count != 0 || q_count != 0) begin $display("DRAIN TIMEOUT exp=%0d memq=%0d",exp_count,q_count); errors=errors+1; end
    if (issue_count !== TOTAL || response_count !== TOTAL || checks !== TOTAL || stale_resp_count < 2) begin
      $display("COUNT MISMATCH issue=%0d response=%0d checks=%0d stale=%0d",issue_count,response_count,checks,stale_resp_count); errors=errors+1;
    end
    if (errors==0) begin $display("PASS tb_native_word_response_pipe issues=%0d responses=%0d checks=%0d stale=%0d cycles=%0d",issue_count,response_count,checks,stale_resp_count,cycle); $finish; end
    else begin $display("FAIL tb_native_word_response_pipe errors=%0d",errors); $fatal; end
  end
  initial begin repeat(200000) @(posedge clk); $display("WATCHDOG cycle=%0d",cycle); $fatal; end
endmodule
`default_nettype wire
