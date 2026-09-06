`timescale 1ns/1ps
`default_nettype none
// Integration smoke/contract TB for the bank layer.  It deliberately drives
// DS1 through the store's 32-bit write channel and config through its loader;
// no DUT memory array is populated by the testbench.
module tb_ds12_stream_ds2_vector_bank_layer #(parameter integer TB_RANDOM_BP=0);
  localparam integer NIN=8192, NCFG=872, NOUT=4096;
  reg clk=0; always #5 clk=~clk; reg rst_n=0;
  reg start=0; wire ready; reg [31:0] epoch=32'h52;
  reg cfg_load_start=0; wire cfg_start_ready,cfg_mem_req_valid; wire cfg_mem_req_ready;
  wire [31:0] cfg_mem_req_addr; wire [3:0] cfg_mem_req_strb; wire [15:0] cfg_mem_req_word_index;
  reg cfg_mem_resp_valid=0; wire cfg_mem_resp_ready; reg [31:0] cfg_mem_resp_rdata;
  reg cfg_commit=0; wire cfg_load_done,cfg_active_valid,cfg_active_bank; wire [1:0] cfg_active_layer; wire [31:0] cfg_active_epoch; wire cfg_error; wire [3:0] cfg_error_code;
  reg ds1_write_valid=0; wire ds1_write_ready; reg ds1_write_bank=1,ds1_write_last=0; reg [31:0] ds1_write_epoch=32'h52,ds1_write_addr,ds1_write_data; reg [3:0] ds1_write_be=4'hf; wire ds1_write_resp_valid; wire ds1_write_resp_bank; wire [31:0] ds1_write_resp_epoch,ds1_write_resp_addr;
  reg ds1_layer_start_valid=0,ds1_layer_start_bank=1; reg [31:0] ds1_layer_start_epoch=32'h52,ds1_layer_start_expected_words=NIN; reg ds1_commit_valid=0,ds1_commit_bank=1; reg [31:0] ds1_commit_epoch=32'h52;
  reg read_req_valid=0; wire read_req_ready; reg read_req_bank; reg [31:0] read_req_epoch,read_req_addr; wire read_resp_valid; reg read_resp_ready=1; wire [127:0] read_resp_data; wire read_resp_bank; wire [31:0] read_resp_epoch,read_resp_addr;
  wire busy,done,error; wire [7:0] error_code; wire [31:0] window_count,dw_vector_count,dw_mac_count,pw_token_count,pw_mac_count,output_word_count,config_read_count,config_weight_read_count,write_count; wire atomic_commit; wire output_write_valid; wire output_write_ready; wire [31:0] output_write_addr,output_write_data; wire [3:0] output_write_be;
  reg [31:0] lfsr=32'h1; integer m_start,m_win,m_dw,m_pw,m_out,m_done;
  assign cfg_mem_req_ready = !TB_RANDOM_BP || (lfsr[2:0] != 0);
  assign output_write_ready = !TB_RANDOM_BP || (lfsr[6:4] != 0);
  reg [7:0] inb[0:32767]; reg [31:0] cfg[0:NCFG-1]; integer i,fd,rc,ly,ki,ix,ad,msk,dat,cycles;
  always @(posedge clk) if (rst_n && busy) cycles = cycles + 1;
  ds12_stream_ds2_vector_bank_layer dut(.*,.cfg_start_layer(2),.cfg_start_base_addr(0),.cfg_start_word_count(NCFG),.ds1_write_resp_ready(1'b1));
  reg cfg_pending; reg [15:0] cfg_pending_index;
  always @(posedge clk) begin
    if (rst_n) lfsr <= {lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    if(!rst_n) begin cfg_mem_resp_valid<=0; cfg_mem_resp_rdata<=0; cfg_pending<=0; end else begin
      cfg_mem_resp_valid<=cfg_pending; if(cfg_pending) cfg_mem_resp_rdata<=cfg[cfg_pending_index];
      cfg_pending<=cfg_mem_req_valid && cfg_mem_req_ready; if(cfg_mem_req_valid && cfg_mem_req_ready) cfg_pending_index<=cfg_mem_req_word_index;
    end
  end
  task write_ds1; integer w,j; begin for(w=0;w<NIN;w=w+1) begin @(negedge clk); while(!ds1_write_ready) @(negedge clk); ds1_write_valid<=1; ds1_write_addr<=w*4; ds1_write_last<=w==NIN-1; for(j=0;j<4;j=j+1) ds1_write_data[j*8 +: 8]<=inb[w*4+j]; @(negedge clk); ds1_write_valid<=0; end end endtask
  initial begin
    $readmemh("build/ds12_stream_harness/ds12_stream_ds2_input_i8.hex",inb);
    fd=$fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex","r"); i=0; while(!$feof(fd)) begin rc=$fscanf(fd,"%d %d %d %h %h %h\n",ly,ki,ix,ad,msk,dat); if(rc==6 && ly==2 && i<NCFG) begin cfg[i]=dat; i=i+1; end end $fclose(fd); if(i!=NCFG)$fatal(1,"cfg");
    repeat(4) @(posedge clk); rst_n=1; @(negedge clk); cfg_load_start<=1; @(negedge clk); cfg_load_start<=0; wait(cfg_load_done);
    @(negedge clk); ds1_layer_start_valid<=1; @(negedge clk); ds1_layer_start_valid<=0; write_ds1; @(negedge clk); ds1_commit_valid<=1; @(negedge clk); ds1_commit_valid<=0; wait(atomic_commit); @(negedge clk); start<=1; @(negedge clk); start<=0; cycles=0; wait(done); $display("DS2_TIMELINE start=%0d win=%0d dw=%0d pw=%0d out=%0d done=%0d",m_start,m_win,m_dw,m_pw,m_out,m_done); if(error || window_count!=4608 || dw_vector_count!=512 || dw_mac_count!=73728 || pw_token_count!=8192 || pw_mac_count!=524288 || output_word_count!=4096 || write_count!=4096 || (!TB_RANDOM_BP && cycles>10282)) $fatal(1,"DS2 layer FAIL cycles=%0d win=%0d dw=%0d/%0d pw=%0d/%0d out=%0d wr=%0d ec=%h",cycles,window_count,dw_vector_count,dw_mac_count,pw_token_count,pw_mac_count,output_word_count,write_count,error_code); $display("DS12_DS2_VECTOR_BANK_LAYER_PASS bp=%0d cycles=%0d window=%0d dw=%0d mac=%0d pw=%0d/%0d out=%0d",TB_RANDOM_BP,cycles,window_count,dw_vector_count,dw_mac_count,pw_token_count,pw_mac_count,output_word_count); $finish;
  end
endmodule
`default_nettype wire
