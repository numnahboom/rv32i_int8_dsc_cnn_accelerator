`timescale 1ns/1ps
`default_nettype none

module tb_feature_tile_word_feeder;
    localparam MEM_BYTES = 1 << 16;
    localparam BANK_BYTES = 16384;
    reg clk = 0, rst_n = 0;
    reg fill_start_valid = 0, fill_bank = 0;
    reg [7:0] fill_tile_id = 0;
    reg [3:0] fill_epoch = 0;
    reg [23:0] fill_base_byte_addr = 0;
    reg [15:0] fill_row_stride_bytes = 0;
    reg [4:0] fill_tile_h = 0, fill_tile_w = 0;
    reg [7:0] fill_channels = 0;
    reg [31:0] fill_row_valid_mask = 0, fill_col_valid_mask = 0;
    reg [7:0] fill_pad_value = 0;
    wire fill_start_ready;
    wire fill_done_valid, fill_done_bank;
    wire [7:0] fill_done_tile_id; wire [3:0] fill_done_epoch;
    wire mem_req_valid; reg mem_req_ready = 1;
    wire [23:0] mem_req_addr; reg mem_resp_valid = 0; reg [31:0] mem_resp_data = 0;
    reg activate_valid = 0, activate_bank = 0;
    reg [7:0] activate_tile_id = 0; reg [3:0] activate_epoch = 0;
    wire activate_ready; wire active_bank; wire [7:0] active_tile_id; wire [3:0] active_epoch;
    reg release_valid = 0, release_bank = 0; reg [7:0] release_tile_id = 0; reg [3:0] release_epoch = 0;
    wire release_ready;
    reg consume_req_valid = 0; wire consume_req_ready; reg [31:0] consume_byte_offset = 0;
    wire consume_resp_valid; reg consume_resp_ready = 1; wire [7:0] consume_resp_data;
    wire [7:0] consume_resp_tile_id; wire [3:0] consume_resp_epoch; wire consume_resp_bank;
    wire [1:0] bank0_state, bank1_state;
    wire [31:0] perf_mem_issue_count, perf_mem_resp_count, perf_consume_count, perf_consume_stall_count;
    reg [7:0] mem [0:MEM_BYTES-1];
    integer cycle = 0;
    integer i, errors = 0, checks = 0, issues_at_start, issues_at_done;

    always #5 clk = ~clk;
    feature_tile_word_feeder #(.ADDR_WIDTH(24), .BANK_BYTES(BANK_BYTES), .MEM_RD_LATENCY(1)) dut (
      .clk(clk), .rst_n(rst_n), .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
      .fill_bank(fill_bank), .fill_tile_id(fill_tile_id), .fill_epoch(fill_epoch), .fill_base_byte_addr(fill_base_byte_addr),
      .fill_row_stride_bytes(fill_row_stride_bytes), .fill_tile_h(fill_tile_h), .fill_tile_w(fill_tile_w), .fill_channels(fill_channels),
      .fill_row_valid_mask(fill_row_valid_mask), .fill_col_valid_mask(fill_col_valid_mask), .fill_pad_value(fill_pad_value),
      .fill_done_valid(fill_done_valid), .fill_done_bank(fill_done_bank), .fill_done_tile_id(fill_done_tile_id), .fill_done_epoch(fill_done_epoch),
      .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
      .activate_valid(activate_valid), .activate_ready(activate_ready), .activate_bank(activate_bank), .activate_tile_id(activate_tile_id), .activate_epoch(activate_epoch),
      .active_bank(active_bank), .active_tile_id(active_tile_id), .active_epoch(active_epoch), .release_valid(release_valid), .release_ready(release_ready),
      .release_bank(release_bank), .release_tile_id(release_tile_id), .release_epoch(release_epoch), .consume_req_valid(consume_req_valid), .consume_req_ready(consume_req_ready),
      .consume_byte_offset(consume_byte_offset), .consume_resp_valid(consume_resp_valid), .consume_resp_ready(consume_resp_ready), .consume_resp_data(consume_resp_data),
      .consume_resp_tile_id(consume_resp_tile_id), .consume_resp_epoch(consume_resp_epoch), .consume_resp_bank(consume_resp_bank), .bank0_state(bank0_state), .bank1_state(bank1_state),
      .perf_mem_issue_count(perf_mem_issue_count), .perf_mem_resp_count(perf_mem_resp_count), .perf_consume_count(perf_consume_count), .perf_consume_stall_count(perf_consume_stall_count));

    always @(posedge clk) begin
      if (!rst_n) begin mem_resp_valid <= 0; cycle <= 0; end
      else begin
        cycle <= cycle + 1;
        // One-cycle synchronous SRAM: every accepted request gets a
        // registered response, including back-to-back requests.
        mem_resp_valid <= mem_req_valid && mem_req_ready;
        if (mem_req_valid && mem_req_ready) mem_resp_data <= {mem[mem_req_addr+3], mem[mem_req_addr+2], mem[mem_req_addr+1], mem[mem_req_addr]};
        // Realistic intermittent SRAM port acceptance.
        mem_req_ready <= ((cycle % 11) != 3) && ((cycle % 11) != 4);
      end
    end

    task fill_tile;
      input bit b; input [7:0] tid; input [3:0] ep; input [23:0] base; input [15:0] stride;
      input [4:0] h; input [4:0] w; input [7:0] c; input [31:0] rm; input [31:0] cm; input [7:0] pad;
      begin
        @(negedge clk); fill_bank=b; fill_tile_id=tid; fill_epoch=ep; fill_base_byte_addr=base; fill_row_stride_bytes=stride;
        fill_tile_h=h; fill_tile_w=w; fill_channels=c; fill_row_valid_mask=rm; fill_col_valid_mask=cm; fill_pad_value=pad; fill_start_valid=1;
        #1;
        while (!fill_start_ready) @(negedge clk);
        @(posedge clk); @(negedge clk); fill_start_valid=0;
        while (!fill_done_valid) @(posedge clk);
        @(posedge clk); // consume the one-cycle completion pulse
      end
    endtask

    task activate;
      input bit b; input [7:0] tid; input [3:0] ep;
      begin
        @(negedge clk); activate_bank=b; activate_tile_id=tid; activate_epoch=ep; activate_valid=1;
        #1;
        while (!activate_ready) @(negedge clk);
        @(posedge clk); @(negedge clk); activate_valid=0;
      end
    endtask

    task release_tile;
      input bit b; input [7:0] tid; input [3:0] ep;
      begin
        @(negedge clk); release_bank=b; release_tile_id=tid; release_epoch=ep; release_valid=1;
        #1;
        while (!release_ready) @(negedge clk);
        @(posedge clk); @(negedge clk); release_valid=0;
      end
    endtask

    task consume_check;
      input integer off; input [7:0] expected; input bit backpressure;
      begin
        @(negedge clk); consume_byte_offset=off; consume_req_valid=1;
        #1;
        if (backpressure) consume_resp_ready=0;
        while (!consume_req_ready) @(negedge clk);
        @(posedge clk); @(negedge clk); consume_req_valid=0;
        if (backpressure) begin @(posedge clk); #1; consume_resp_ready=1; #1; end
        else begin @(posedge clk); #1; end // XPM synchronous read response cycle
        checks=checks+1;
        if (!consume_resp_valid) begin $display("MISSING response off=%0d",off); errors=errors+1; end
        if (consume_resp_data !== expected || consume_resp_bank !== active_bank || consume_resp_tile_id !== active_tile_id || consume_resp_epoch !== active_epoch) begin
          $display("MISMATCH off=%0d got=%02x exp=%02x tag=%0d/%0d/%0d", off, consume_resp_data, expected, consume_resp_bank, consume_resp_tile_id, consume_resp_epoch); errors=errors+1;
        end
        @(negedge clk); consume_resp_ready=1;
      end
    endtask

    function [7:0] source_byte; input integer a; begin source_byte = mem[a]; end endfunction
    initial begin
      repeat (100000) @(posedge clk);
      $display("WATCHDOG cycle=%0d state=%0d/%0d fillstate=%0d req=%b resp=%b issue=%0d response=%0d consume=%0d done=%b", cycle, bank0_state, bank1_state, dut.fill_state, mem_req_valid, mem_resp_valid, perf_mem_issue_count, perf_mem_resp_count, perf_consume_count, fill_done_valid);
      $fatal;
    end
    initial begin
      for (i=0;i<MEM_BYTES;i=i+1) mem[i] = (i*37 + 11) & 8'hff;
      repeat(3) @(posedge clk); rst_n=1;
      // Actual first Stem tiled shape: 10x10, 3 channels, unaligned base.
      fill_tile(0, 8'h11, 4'h1, 24'd3, 16'd37, 5'd10, 5'd10, 8'd3, 32'hffffffff, 32'hffffffff, 8'h80);
      activate(0,8'h11,4'h1);
      $display("ACTIVATED bank=%0d state=%0d ready=%b resp=%b",active_bank,bank0_state,consume_req_ready,consume_resp_valid);
      for (i=0;i<300;i=i+1) consume_check(i, source_byte(3+(i/30)*37+(i%30)), (i%17)==0);
      // Traffic-heavy DS layer shape: 10x10, 48 channels.  Edge masks make
      // the final row and two rightmost columns padding, while bank 0 is
      // still being consumed only until this fill starts.
      issues_at_start = perf_mem_issue_count;
      fork
        begin fill_tile(1,8'h22,4'h2,24'd1003,16'd64,5'd10,5'd10,8'd48,32'h000001ff,32'h000000ff,8'h80); end
        begin for (i=0;i<32;i=i+1) consume_check(i,source_byte(3+(i/30)*37+(i%30)),(i%5)==0); end
      join
      issues_at_done = perf_mem_issue_count;
      activate(1,8'h22,4'h2); release_tile(0,8'h11,4'h1);
      for (i=0;i<4800;i=i+1) begin
        if ((i/480)<9 && (i%480)<8*48) consume_check(i, source_byte(1003+(i/480)*64+(i%480)), ((i%31)==0) && (i<4500));
        else consume_check(i,8'h80,((i%31)==0) && (i<4500));
      end
      if (errors==0) begin $display("PASS tb_feature_tile_word_feeder checks=%0d issues=%0d responses=%0d consume_stalls=%0d overlap_issue_delta=%0d cycles=%0d", checks,perf_mem_issue_count,perf_mem_resp_count,perf_consume_stall_count,issues_at_done-issues_at_start,cycle); $finish; end
      else begin $display("FAIL tb_feature_tile_word_feeder checks=%0d errors=%0d",checks,errors); $fatal; end
    end
endmodule
`default_nettype wire
