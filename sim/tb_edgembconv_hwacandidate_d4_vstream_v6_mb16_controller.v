`timescale 1ns/1ps
`default_nettype none
module tb_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller;
 localparam integer INB=32*32*16, OUTB=16*16*32;
 reg clk,rst_n,cfg_valid,start_valid,done_ready,sink_ready,scratch_read_ready;
 reg [2:0] cfg_kind; reg [15:0] cfg_addr; reg [31:0] cfg_data; reg [3:0] start_epoch;
 wire cfg_ready,start_ready,done_valid,sink_valid,busy; wire [3:0] done_epoch,active_epoch,sink_epoch;
 wire [31:0] sink_addr,sink_data; wire [3:0] sink_byte_enable; wire [15:0] sink_index;
 wire [1:0] scratch0_state,scratch1_state;
 wire out_valid; wire [15:0] out_index; wire signed [7:0] out_data;
 wire [31:0] cycle_count,pw_mac_count,dw_mac_count,overlap_cycles,protocol_errors;
 wire [31:0] word_sink_fire_count,byte_commit_count,sink_stall_count,sink_protocol_errors;
 reg [7:0] input_vec[0:INB-1], expected_vec[0:OUTB-1];
 reg [7:0] exp_w[0:511],proj_w[0:1023],dw_w[0:287],exp_shift[0:31],proj_shift[0:31],dw_shift[0:31];
 reg [31:0] exp_bias[0:31],exp_mul[0:31],proj_bias[0:31],proj_mul[0:31],dw_bias[0:31],dw_mul[0:31];
 integer i,j,errors,checked,start_cycle,end_cycle,tb_cycle_count,final_stall_count,tb_dw_rq_accept,tb_p_rq_accept;
 integer epoch_number,epoch_cycles[0:1],epoch_words[0:1];
 reg [3:0] sink_expected_epoch;
 reg final_stall_done;
 reg sink_hold_valid; reg [31:0] sink_hold_addr,sink_hold_data; reg [15:0] sink_hold_index; reg [3:0] sink_hold_epoch;
 edgembconv_hwacandidate_d4_vstream_v6_mb16_controller dut(
  .clk(clk),.rst_n(rst_n),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_kind(cfg_kind),
  .cfg_addr(cfg_addr),.cfg_data(cfg_data),.start_valid(start_valid),.start_ready(start_ready),
  .start_epoch(start_epoch),.done_valid(done_valid),.done_ready(done_ready),.done_epoch(done_epoch),
  .out_valid(out_valid),.out_ready(1'b1),.out_index(out_index),.out_data(out_data),.busy(busy),
  .scratch0_state(scratch0_state),.scratch1_state(scratch1_state),.active_epoch(active_epoch),
  .cycle_count(cycle_count),.pw_mac_count(pw_mac_count),.dw_mac_count(dw_mac_count),
  .overlap_cycles(overlap_cycles),.protocol_errors(protocol_errors),.scratch_read_ready(scratch_read_ready),
  .sink_valid(sink_valid),.sink_ready(sink_ready),.sink_addr(sink_addr),.sink_data(sink_data),
  .sink_byte_enable(sink_byte_enable),.sink_index(sink_index),.sink_epoch(sink_epoch),
  .word_sink_fire_count(word_sink_fire_count),.byte_commit_count(byte_commit_count),
  .sink_stall_count(sink_stall_count),.sink_protocol_errors(sink_protocol_errors));
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
`ifdef V6_NO_BACKPRESSURE
  scratch_read_ready<=1'b1; sink_ready<=1'b1;
`else
  /* Drive randomized service independently of the child cycle counter.  The
   * child is allowed to finish before the wrapper's final packed word drains;
   * tying ready to cycle_count would freeze ready low in that legal state. */
  scratch_read_ready<=((tb_cycle_count*17+3)%7)!=1;
`ifdef V6_FINAL_WORD_STALL
  if(!final_stall_done && sink_valid && sink_index==16'd2047) begin
    if(final_stall_count<32) begin
      sink_ready<=1'b0;
      final_stall_count=final_stall_count+1;
    end else begin
      sink_ready<=1'b1;
      final_stall_done<=1'b1;
    end
  end else if(final_stall_done) sink_ready<=1'b1;
  else sink_ready<=((tb_cycle_count*13+5)%17)!=4;
`else
  sink_ready<=((tb_cycle_count*13+5)%17)!=4;
`endif
`endif
  tb_cycle_count=tb_cycle_count+1;
 end
 always @(posedge clk) if(rst_n&&sink_valid&&sink_ready) begin
  if(checked>=OUTB/4) begin
    $display("V6_EXTRA_WORD epoch=%0d index=%0d",sink_epoch,sink_index);
    errors=errors+1;
  end else begin
    if(sink_index!==checked[15:0] || sink_addr!==(checked*4) ||
       sink_epoch!==sink_expected_epoch || sink_byte_enable!==4'hf)
      errors=errors+1;
    for(j=0;j<4;j=j+1)
      if(sink_data[j*8 +:8]!==expected_vec[checked*4+j]) begin
        $display("V6_MISMATCH epoch=%0d word=%0d byte=%0d exp=%02x got=%02x",sink_expected_epoch,checked,j,expected_vec[checked*4+j],sink_data[j*8 +:8]);
        errors=errors+1;
      end
  end
  checked=checked+1;
end
  always @(posedge clk) if(rst_n) begin
  if(dut.u_arithmetic.state==6 && dut.u_arithmetic.pool_rq_fire) tb_dw_rq_accept=tb_dw_rq_accept+1;
  if(dut.u_arithmetic.state==10 && dut.u_arithmetic.pool_rq_fire) tb_p_rq_accept=tb_p_rq_accept+1;
  if(sink_hold_valid && !sink_ready) begin
    if(!sink_valid || sink_addr!==sink_hold_addr || sink_data!==sink_hold_data ||
       sink_index!==sink_hold_index || sink_epoch!==sink_hold_epoch) begin
      $display("V6_SINK_UNSTABLE_OR_DROPPED while stalled addr=%0d",sink_hold_addr);
      errors=errors+1;
    end
  end
  sink_hold_valid = sink_valid && !sink_ready;
  if(sink_valid && !sink_ready) begin
    sink_hold_addr=sink_addr; sink_hold_data=sink_data;
    sink_hold_index=sink_index; sink_hold_epoch=sink_epoch;
  end
  end
 /* Check one complete transaction after its done handshake.  These checks
  * are intentionally per-epoch: a second start must not inherit counters,
  * sink indices, or tags from the first run.  The pool counters provide an
  * independent conservation ledger for each offered mode and for the
  * aggregate stream. */
 task check_epoch;
   input [3:0] epoch_arg;
   input integer epoch_idx;
   input integer elapsed_cycles;
   begin
     if(checked!=OUTB/4) begin
       $display("V6_WORD_OUTPUT_COUNT epoch=%0d count=%0d",epoch_arg,checked);
       errors=errors+1;
     end
     if(done_epoch!==epoch_arg || active_epoch!==epoch_arg ||
        protocol_errors!=0 || sink_protocol_errors!=0) begin
       $display("V6_EPOCH_TAG_OR_PROTOCOL epoch=%0d done=%0d active=%0d protocol=%0d sink_protocol=%0d",epoch_arg,done_epoch,active_epoch,protocol_errors,sink_protocol_errors);
       errors=errors+1;
     end
`ifdef V6_FINAL_WORD_STALL
     if(final_stall_count<32 || !final_stall_done) begin
       $display("V6_FINAL_STALL_NOT_OBSERVED epoch=%0d count=%0d done=%0d",epoch_arg,final_stall_count,final_stall_done);
       errors=errors+1;
     end
`endif
     /* Keep the semantic work ledgers explicit so a faster candidate cannot
      * pass by dropping PW/DW/RQ work or final writes. */
     if(pw_mac_count!=32'd786432) begin $display("V6_PW_LEDGER epoch=%0d value=%0d",epoch_arg,pw_mac_count);errors=errors+1;end
     if(dw_mac_count!=32'd73728) begin $display("V6_DW_LEDGER epoch=%0d value=%0d",epoch_arg,dw_mac_count);errors=errors+1;end
     if(dut.u_arithmetic.rq_accept_count!=32'd12288) begin $display("V6_RQ_LEDGER epoch=%0d value=%0d",epoch_arg,dut.u_arithmetic.rq_accept_count);errors=errors+1;end
     if(dut.u_arithmetic.dw_req_count!=dut.u_arithmetic.dw_resp_count || dut.u_arithmetic.dw_req_count!=32'd4418) begin $display("V6_DW_READ_LEDGER epoch=%0d value=%0d/%0d",epoch_arg,dut.u_arithmetic.dw_req_count,dut.u_arithmetic.dw_resp_count);errors=errors+1;end
     if(dut.u_arithmetic.final_commit_count!=32'd8192 || word_sink_fire_count!=32'd2048 || byte_commit_count!=32'd8192) begin $display("V6_SINK_LEDGER epoch=%0d final=%0d words=%0d bytes=%0d",epoch_arg,dut.u_arithmetic.final_commit_count,word_sink_fire_count,byte_commit_count);errors=errors+1;end
     if(dut.u_arithmetic.diag_pool_pw_accept_count!=dut.u_arithmetic.diag_pool_pw_output_count ||
        dut.u_arithmetic.diag_pool_rq_accept_count!=dut.u_arithmetic.diag_pool_rq_output_count ||
        dut.u_arithmetic.diag_pool_total_input_count!=dut.u_arithmetic.diag_pool_total_output_count ||
        dut.u_arithmetic.diag_pool_total_input_count!=dut.u_arithmetic.diag_pool_pw_accept_count+dut.u_arithmetic.diag_pool_rq_accept_count ||
        dut.u_arithmetic.diag_pool_conservation_error_count!=0) begin
       $display("V6_LEDGER_CONSERVATION epoch=%0d total=%0d/%0d pw=%0d/%0d rq=%0d/%0d errors=%0d",epoch_arg,dut.u_arithmetic.diag_pool_total_input_count,dut.u_arithmetic.diag_pool_total_output_count,dut.u_arithmetic.diag_pool_pw_accept_count,dut.u_arithmetic.diag_pool_pw_output_count,dut.u_arithmetic.diag_pool_rq_accept_count,dut.u_arithmetic.diag_pool_rq_output_count,dut.u_arithmetic.diag_pool_conservation_error_count);
       errors=errors+1;
     end
     if(dut.u_arithmetic.diag_pool_pw_accept_count!=32'd2048 ||
        dut.u_arithmetic.diag_pool_rq_accept_count!=32'd12288 ||
        dut.u_arithmetic.diag_pool_total_input_count!=32'd14336) begin
       $display("V6_LEDGER_MODE epoch=%0d total=%0d pw=%0d rq=%0d",epoch_arg,dut.u_arithmetic.diag_pool_total_input_count,dut.u_arithmetic.diag_pool_pw_accept_count,dut.u_arithmetic.diag_pool_rq_accept_count);
       errors=errors+1;
     end
     epoch_cycles[epoch_idx]=elapsed_cycles;
     epoch_words[epoch_idx]=checked;
     $display("D4_V6_MB16 epoch=%0d words=%0d bytes=%0d cycles=%0d pw_mac=%0d dw_mac=%0d rq_accept=%0d dw_cfg=%0d dw_start=%0d dw_req=%0d dw_resp=%0d final=%0d sink_stall=%0d sink_errors=%0d child_overlap=%0d errors=%0d dw_rq=%0d p_rq=%0d",epoch_arg,checked,byte_commit_count,elapsed_cycles,pw_mac_count,dw_mac_count,dut.u_arithmetic.rq_accept_count,dut.u_arithmetic.dw_config_count,dut.u_arithmetic.dw_start_count,dut.u_arithmetic.dw_req_count,dut.u_arithmetic.dw_resp_count,dut.u_arithmetic.final_commit_count,sink_stall_count,sink_protocol_errors,overlap_cycles,errors,tb_dw_rq_accept,tb_p_rq_accept);
   end
 endtask

 /* Drive one epoch, optionally holding done_valid for a visible interval.
  * The output sink checker above is active for the whole task, so random
  * service, final-word stall, and done backpressure are exercised by the
  * same byte/word exactness assertions. */
 task run_epoch;
   input [3:0] epoch_arg;
   input integer epoch_idx;
   integer local_start,local_end,hold_i;
   reg [3:0] held_done_epoch;
   begin
     checked=0;
     sink_expected_epoch=epoch_arg;
     final_stall_count=0;
     final_stall_done=0;
     tb_dw_rq_accept=0;
     tb_p_rq_accept=0;
     sink_hold_valid=0;
`ifdef V6_DONE_BACKPRESSURE
     done_ready=0;
`else
     done_ready=1;
`endif
     @(negedge clk);
     while(!start_ready) @(negedge clk);
     start_epoch=epoch_arg;
     start_valid=1;
     @(posedge clk);
     @(negedge clk);
     start_valid=0;
     local_start=cycle_count;
      while(!done_valid) begin
        @(posedge clk);
        if(tb_cycle_count>200000)
          $fatal(1,"V6_TIMEOUT epoch=%0d child=%0d state=%0d pw=%0d dw=%0d rq=%0d dwreq=%0d/%0d out=%0d/%0d",epoch_arg,cycle_count,dut.u_arithmetic.state,pw_mac_count,dw_mac_count,dut.u_arithmetic.rq_accept_count,dut.u_arithmetic.dw_req_count,dut.u_arithmetic.dw_resp_count,dut.word_sink_fire_count,checked);
     end
     while(sink_valid) @(posedge clk);
`ifdef V6_DONE_BACKPRESSURE
     held_done_epoch=done_epoch;
     for(hold_i=0;hold_i<17;hold_i=hold_i+1) begin
       @(posedge clk);
       if(!done_valid || done_epoch!==held_done_epoch) begin
         $display("V6_DONE_NOT_HELD epoch=%0d cycle=%0d valid=%0d done_epoch=%0d expected=%0d",epoch_arg,tb_cycle_count,done_valid,done_epoch,held_done_epoch);
         errors=errors+1;
       end
     end
     @(negedge clk);
     done_ready=1;
     @(posedge clk);
`else
     /* done_valid is observed after the edge that accepted the final word;
      * consume it on the following edge and then sample the idle state. */
     @(posedge clk);
`endif
     @(negedge clk);
     local_end=cycle_count;
     start_cycle=local_start;
     end_cycle=local_end;
     check_epoch(epoch_arg,epoch_idx,local_end-local_start);
   end
 endtask

 initial begin
   clk=0;rst_n=0;cfg_valid=0;cfg_kind=0;cfg_addr=0;cfg_data=0;start_valid=0;start_epoch=0;
    done_ready=1; sink_ready=1;scratch_read_ready=1;errors=0;checked=0;tb_cycle_count=0;final_stall_count=0;final_stall_done=0;tb_dw_rq_accept=0;tb_p_rq_accept=0;sink_hold_valid=0;sink_expected_epoch=0;epoch_number=0;epoch_cycles[0]=0;epoch_cycles[1]=0;epoch_words[0]=0;epoch_words[1]=0;
    repeat(5) @(posedge clk);rst_n=1;load_all();
    run_epoch(4'ha,0);
`ifdef V6_TWO_EPOCH
   run_epoch(4'hb,1);
   if(epoch_words[0]!=OUTB/4 || epoch_words[1]!=OUTB/4) begin
     $display("V6_TWO_EPOCH_OUTPUT_COUNTS %0d/%0d",epoch_words[0],epoch_words[1]);
     errors=errors+1;
   end
`endif
   if(errors==0) $display("PASS edgembconv_hwacandidate_d4_vstream_v6_mb16_controller exact=8192 aligned_word_sink=2048"); else $fatal;
   $finish;
 end
endmodule
`default_nettype wire
