`timescale 1ns/1ps
`default_nettype none
// External-port contract bench.  The memory models are intentionally kept
// outside the DUT; the full exact-vector driver is supplied by the DS2
// harness when this candidate is promoted.  This bench checks elaboration and
// the ready/valid ownership boundary without claiming arithmetic PASS.
module tb_ds12_stream_ds2_datapath_external;
  reg clk=0; always #5 clk=~clk; reg rst_n=0, start=0;
  reg active_valid=0, active_bank=0; reg [1:0] active_layer=2; reg [31:0] active_epoch=32'h52;
  wire cfg_rd_valid,cfg_rd_ready,cfg_rd_bank; wire [15:0] cfg_rd_addr; reg cfg_rd_resp_valid=0; reg [31:0] cfg_rd_resp_data=0;
  wire activation_rd_valid,activation_rd_ready,activation_rd_bank; wire [31:0] activation_rd_epoch,activation_rd_addr; reg activation_rd_resp_valid=0; reg [127:0] activation_rd_resp_data=0; reg activation_rd_resp_bank=0; reg [31:0] activation_rd_resp_epoch=0,activation_rd_resp_addr=0;
  wire output_write_valid; reg output_write_ready=1; wire [31:0] output_write_addr,output_write_data; wire [3:0] output_write_be; wire output_write_last,output_write_bank; wire [31:0] output_write_epoch;
  wire bank_start_valid,bank_start_bank; reg bank_start_ready=1; wire [31:0] bank_start_epoch,bank_start_expected_words; wire bank_commit_req; reg bank_commit_ack=0; wire bank_commit_bank; wire [31:0] bank_commit_epoch;
  wire busy,done,error; wire [7:0] error_code; wire [31:0] window_count,dw_vector_count,dw_mac_count,pw_token_count,pw_mac_count,output_word_count,config_read_count,config_weight_read_count,write_count;
  assign cfg_rd_ready=1'b1; assign activation_rd_ready=1'b1;
  ds12_stream_ds2_datapath dut(.*);
  initial begin repeat(2) @(posedge clk); rst_n=1; active_valid=1; @(posedge clk); start=1; @(posedge clk); start=0; repeat(4) @(posedge clk); $display("DS12_DS2_DATAPATH_EXTERNAL_ELAB_OK"); $finish; end
endmodule
`default_nettype wire
