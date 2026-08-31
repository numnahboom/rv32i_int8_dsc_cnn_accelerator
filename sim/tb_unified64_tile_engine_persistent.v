`timescale 1ns/1ps
`default_nettype none

/* Persistent BRAM feed composition smoke/differential boundary test.  The
 * source and parameter responses are deterministic non-zero data; this test
 * checks fixed addresses, epoch rejection, real token/commit counts and all
 * output handshakes.  Arithmetic/value differential coverage is provided by
 * tb_unified64_tile_engine_experiment. */
module tb_unified64_tile_engine_persistent;
    reg clk=0, rst_n=0, cfg_valid=0, cfg_mode=0, load_start_valid=0;
    reg [2:0] cfg_layer_id; reg [3:0] cfg_epoch,cfg_session;
    wire cfg_ready; reg [31:0] load_source_base_addr,load_param_base_addr;
    wire load_start_ready,source_req_valid,source_req_ready,source_resp_ready,param_req_valid,param_req_ready,param_resp_ready;
    wire [31:0] source_req_addr,param_req_addr; reg source_resp_valid=0,param_resp_valid=0;
    reg [31:0] source_resp_data=0,param_resp_data=0; wire load_active,load_done;
    wire [15:0] source_external_word_count,param_external_word_count,source_request_stall_count,param_request_stall_count;
    reg commit_valid=0; wire commit_ready,commit_reject,committed_valid; wire [3:0] committed_epoch,committed_session;
    reg job_valid=0; wire job_ready; reg [3:0] job_epoch,job_session; reg [9:0] job_pixel_base; reg [4:0] job_cout_tile;
    reg [7:0] job_pixel_mask,job_cout_mask; wire job_reject_stale,job_done,busy;
    wire valid_out; reg ready_out=1; wire [10:0] out_pixel_idx; wire [8:0] out_channel_base; wire [3:0] out_lane_mask; wire signed [31:0] out_data;
    wire [31:0] metric_token_count,metric_masked_mac_count,metric_commit_count,metric_output_stall_count,metric_overlap_count,metric_peak_occupancy,metric_nonzero_token_count;
    wire [15:0] local_source_word_read_count,feed_window_reuse_count; wire [31:0] local_param_row_read_count,feed_token_count;
    unified64_tile_engine_persistent_wrapper dut (
      .clk(clk),.rst_n(rst_n),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_layer_id(cfg_layer_id),.cfg_mode(cfg_mode),.cfg_epoch(cfg_epoch),.cfg_session(cfg_session),
      .load_start_valid(load_start_valid),.load_start_ready(load_start_ready),.load_source_base_addr(load_source_base_addr),.load_param_base_addr(load_param_base_addr),
      .source_req_valid(source_req_valid),.source_req_ready(source_req_ready),.source_req_addr(source_req_addr),.source_resp_valid(source_resp_valid),.source_resp_ready(source_resp_ready),.source_resp_data(source_resp_data),
      .param_req_valid(param_req_valid),.param_req_ready(param_req_ready),.param_req_addr(param_req_addr),.param_resp_valid(param_resp_valid),.param_resp_ready(param_resp_ready),.param_resp_data(param_resp_data),
      .load_active(load_active),.load_done(load_done),.source_external_word_count(source_external_word_count),.param_external_word_count(param_external_word_count),.source_request_stall_count(source_request_stall_count),.param_request_stall_count(param_request_stall_count),
      .commit_valid(commit_valid),.commit_ready(commit_ready),.commit_reject(commit_reject),.committed_valid(committed_valid),.committed_epoch(committed_epoch),.committed_session(committed_session),
      .job_valid(job_valid),.job_ready(job_ready),.job_epoch(job_epoch),.job_session(job_session),.job_pixel_base(job_pixel_base),.job_cout_tile(job_cout_tile),.job_pixel_mask(job_pixel_mask),.job_cout_mask(job_cout_mask),.job_reject_stale(job_reject_stale),.job_done(job_done),.busy(busy),
      .valid_out(valid_out),.ready_out(ready_out),.out_pixel_idx(out_pixel_idx),.out_channel_base(out_channel_base),.out_lane_mask(out_lane_mask),.out_data(out_data),
      .metric_token_count(metric_token_count),.metric_masked_mac_count(metric_masked_mac_count),.metric_commit_count(metric_commit_count),.metric_output_stall_count(metric_output_stall_count),.metric_overlap_count(metric_overlap_count),.metric_peak_occupancy(metric_peak_occupancy),.metric_nonzero_token_count(metric_nonzero_token_count),
      .local_source_word_read_count(local_source_word_read_count),.local_param_row_read_count(local_param_row_read_count),.feed_token_count(feed_token_count),.feed_window_reuse_count(feed_window_reuse_count)
    );
    always #5 clk=~clk;
    integer cyc=0, errors=0, outputs=0, jobs=0, stale=0, reqsrc=0, reqparam=0;
    assign source_req_ready=((cyc%7)!=2); assign param_req_ready=((cyc%11)!=5);
    function automatic [31:0] source_pat(input [31:0] a); integer wi,b; begin wi=(a-load_source_base_addr)>>2; source_pat=0; for(b=0;b<4;b=b+1) source_pat[(b*8)+:8]=(wi*4+b+1)&255; end endfunction
    function automatic [31:0] param_pat(input [31:0] a); integer wi,b; begin wi=(a-load_param_base_addr)>>2; param_pat=0; for(b=0;b<4;b=b+1) param_pat[(b*8)+:8]=(wi*4+b+3)&255; end endfunction
    always @(negedge clk) begin if(rst_n) begin cyc=cyc+1; ready_out<=((cyc%29)==4)||((cyc%41)==9)?0:1; end end
    always @(posedge clk) begin
      if(!rst_n) begin source_resp_valid<=0; param_resp_valid<=0; end else begin
        source_resp_valid<=source_req_valid&&source_req_ready; param_resp_valid<=param_req_valid&&param_req_ready;
        if(source_req_valid&&source_req_ready) begin source_resp_data<=source_pat(source_req_addr); reqsrc=reqsrc+1; end
        if(param_req_valid&&param_req_ready) begin param_resp_data<=param_pat(param_req_addr); reqparam=reqparam+1; end
        if(job_reject_stale) stale=stale+1;
        if(valid_out&&ready_out) outputs=outputs+1;
      end
    end
    task automatic setup; begin
      @(negedge clk); cfg_layer_id=1; cfg_epoch=4'd5; cfg_session=4'd6; while(!cfg_ready) @(posedge clk); cfg_valid=1; @(posedge clk); @(negedge clk); cfg_valid=0;
      load_source_base_addr=32'h100000; load_param_base_addr=32'h200000; load_start_valid=1; while(!load_start_ready) @(posedge clk); @(posedge clk); @(negedge clk); load_start_valid=0; while(!load_done) @(posedge clk);
      commit_valid=1; while(!committed_valid) @(posedge clk); @(negedge clk); commit_valid=0;
    end endtask
    task automatic do_job(input integer pb,input integer tile,input [7:0] pm,input [7:0] cm); begin
      @(negedge clk); job_pixel_base=pb; job_cout_tile=tile; job_pixel_mask=pm; job_cout_mask=cm; job_epoch=5; job_session=6; job_valid=1; while(!job_ready) @(posedge clk); @(posedge clk); @(negedge clk); job_valid=0; while(!job_done) @(posedge clk); while(busy) @(posedge clk); jobs=jobs+1;
    end endtask
    initial begin
      cfg_layer_id=0;cfg_epoch=0;cfg_session=0;load_source_base_addr=0;load_param_base_addr=0;job_epoch=0;job_session=0;job_pixel_base=0;job_cout_tile=0;job_pixel_mask=0;job_cout_mask=0;
      repeat(5) @(posedge clk); rst_n=1; setup();
      do_job(0,0,8'hff,8'hff); do_job(8,1,8'h0f,8'h3f);
      job_epoch=4'd7; job_session=4'd7; job_pixel_base=0; job_cout_tile=0; @(negedge clk); job_valid=1; repeat(4) @(posedge clk); job_valid=0;
      if(!job_reject_stale) errors=errors+1;
      if(errors!=0 || jobs!=2 || outputs!=32 || metric_nonzero_token_count==0 || metric_masked_mac_count==0 || stale==0) begin $display("FAIL persistent errors=%0d jobs=%0d outputs=%0d stale=%0d nonzero=%0d macs=%0d",errors,jobs,outputs,stale,metric_nonzero_token_count,metric_masked_mac_count); $fatal; end
      $display("PASS persistent jobs=%0d outputs=%0d feed_tokens=%0d source_words=%0d param_words=%0d local_reads=%0d/%0d reuse=%0d commits=%0d stalls=%0d overlap=%0d",jobs,outputs,feed_token_count,source_external_word_count,param_external_word_count,local_source_word_read_count,local_param_row_read_count,feed_window_reuse_count,metric_commit_count,metric_output_stall_count,metric_overlap_count); $finish;
    end
endmodule
`default_nettype wire
