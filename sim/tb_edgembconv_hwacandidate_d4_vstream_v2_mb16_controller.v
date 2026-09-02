`timescale 1ns/1ps
`default_nettype none
module tb_edgembconv_hwacandidate_d4_vstream_v2_mb16_controller;
 localparam integer INB=32*32*16, OUTB=16*16*32;
 reg clk,rst_n,cfg_valid,start_valid,done_ready,out_ready,scratch_read_ready;
 reg [2:0] cfg_kind; reg [15:0] cfg_addr; reg [31:0] cfg_data; reg [3:0] start_epoch;
 wire cfg_ready,start_ready,done_valid,out_valid,busy; wire [3:0] done_epoch,active_epoch;
 wire [15:0] out_index; wire signed [7:0] out_data; wire [1:0] scratch0_state,scratch1_state;
 wire [31:0] cycle_count,pw_mac_count,dw_mac_count,overlap_cycles,protocol_errors;
 reg [7:0] input_vec[0:INB-1], expected_vec[0:OUTB-1];
 reg [7:0] exp_w[0:511],proj_w[0:1023],dw_w[0:287],exp_shift[0:31],proj_shift[0:31],dw_shift[0:31];
 reg [31:0] exp_bias[0:31],exp_mul[0:31],proj_bias[0:31],proj_mul[0:31],dw_bias[0:31],dw_mul[0:31];
 integer i,errors,checked,start_cycle,end_cycle,stable_index;
 integer sc[0:12];
 edgembconv_hwacandidate_d4_vstream_v2_mb16_controller dut(
  .clk(clk),.rst_n(rst_n),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_kind(cfg_kind),
  .cfg_addr(cfg_addr),.cfg_data(cfg_data),.start_valid(start_valid),.start_ready(start_ready),
  .start_epoch(start_epoch),.done_valid(done_valid),.done_ready(done_ready),.done_epoch(done_epoch),
  .out_valid(out_valid),.out_ready(out_ready),.out_index(out_index),.out_data(out_data),
  .busy(busy),.scratch0_state(scratch0_state),.scratch1_state(scratch1_state),
  .active_epoch(active_epoch),.cycle_count(cycle_count),.pw_mac_count(pw_mac_count),
  .dw_mac_count(dw_mac_count),.overlap_cycles(overlap_cycles),.protocol_errors(protocol_errors),
  .scratch_read_ready(scratch_read_ready));
 always #5 clk=~clk;
 task cfg_word; input integer k,a; input [31:0] d; begin
  @(negedge clk); while(!cfg_ready) @(negedge clk); cfg_kind=k[2:0];cfg_addr=a[15:0];cfg_data=d;cfg_valid=1;
  @(posedge clk);@(negedge clk);cfg_valid=0;cfg_kind=0;cfg_addr=0;cfg_data=0;
 end endtask
 task cfg_byte; input integer k,a; input [7:0] d; begin cfg_word(k,a,{24'd0,d}); end endtask
 task load_all; begin
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_input.mem",input_vec);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_output.mem",expected_vec);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_weight.mem",exp_w);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_weight.mem",proj_w);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_weight.mem",dw_w);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_bias.mem",exp_bias);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_multiplier.mem",exp_mul);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_shift.mem",exp_shift);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_bias.mem",proj_bias);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_multiplier.mem",proj_mul);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_shift.mem",proj_shift);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_bias.mem",dw_bias);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_multiplier.mem",dw_mul);
  $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_shift.mem",dw_shift);
  for(i=0;i<INB;i=i+1) cfg_byte(0,i,input_vec[i]);
  for(i=0;i<512;i=i+1) cfg_byte(1,2048+i,exp_w[i]);
  for(i=0;i<1024;i=i+1) cfg_byte(1,3072+i,proj_w[i]);
  for(i=0;i<288;i=i+1) cfg_byte(2,i,dw_w[i]);
  for(i=0;i<32;i=i+1) begin
   cfg_word(3,64+i,exp_bias[i]);cfg_word(4,64+i,exp_mul[i]);cfg_byte(5,64+i,exp_shift[i]);
   cfg_word(3,96+i,proj_bias[i]);cfg_word(4,96+i,proj_mul[i]);cfg_byte(5,96+i,proj_shift[i]);
   cfg_word(3,160+i,dw_bias[i]);cfg_word(4,160+i,dw_mul[i]);cfg_byte(5,160+i,dw_shift[i]);
  end
 end endtask
 always @(negedge clk) if(rst_n) begin
`ifdef V2_NO_BACKPRESSURE
  scratch_read_ready<=1'b1; out_ready<=1'b1;
`else
  scratch_read_ready<=((cycle_count*17+3)%7)!=1;
  out_ready<=((cycle_count*13+5)%17)!=4;
`endif
 end
 always @(posedge clk) if(rst_n&&out_valid&&out_ready) begin
  if(out_index!==checked[15:0]||out_data!==expected_vec[checked]) begin
   $display("V2_MISMATCH index=%0d exp=%02x got=%02x",checked,expected_vec[checked],out_data); errors=errors+1;
  end
  checked=checked+1;
 end
 always @(posedge clk) if(rst_n) sc[dut.state]=sc[dut.state]+1;
 initial begin #5000000; $display("V2_TIMEOUT cycle=%0d state=%0d out=%0d",cycle_count,dut.state,checked);$fatal; end
 initial begin
  clk=0;rst_n=0;cfg_valid=0;cfg_kind=0;cfg_addr=0;cfg_data=0;start_valid=0;start_epoch=0;
  done_ready=1;out_ready=1;scratch_read_ready=1;errors=0;checked=0;stable_index=-1;for(i=0;i<13;i=i+1) sc[i]=0;
  repeat(5) @(posedge clk);rst_n=1;load_all();
  @(negedge clk);while(!start_ready) @(negedge clk);start_epoch=4'ha;start_valid=1;
  @(posedge clk);@(negedge clk);start_valid=0;start_cycle=cycle_count;
  while(!done_valid) @(posedge clk);end_cycle=cycle_count;
  if(checked!=OUTB) begin $display("V2_OUTPUT_COUNT %0d",checked);errors=errors+1;end
  if(done_epoch!==4'ha||active_epoch!==4'ha||protocol_errors!=0) errors=errors+1;
  $display("D4_V2_MB16 output=%0d cycles=%0d pw_mac=%0d dw_mac=%0d rq_accept=%0d dw_cfg=%0d dw_start=%0d dw_req=%0d dw_resp=%0d final=%0d states=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d errors=%0d",checked,end_cycle-start_cycle,pw_mac_count,dw_mac_count,dut.rq_accept_count,dut.dw_config_count,dut.dw_start_count,dut.dw_req_count,dut.dw_resp_count,dut.final_commit_count,sc[0],sc[1],sc[2],sc[3],sc[4],sc[5],sc[6],sc[7],sc[8],sc[9],sc[10],sc[11],sc[12],errors);
  if(errors==0) $display("PASS edgembconv_hwacandidate_d4_vstream_v2_mb16_controller exact=8192 random_backpressure=checked"); else $fatal;
  $finish;
 end
endmodule
`default_nettype wire
