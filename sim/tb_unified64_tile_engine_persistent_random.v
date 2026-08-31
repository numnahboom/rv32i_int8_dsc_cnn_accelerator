`timescale 1ns/1ps
`default_nettype none

/* Randomized contract regression for the persistent unified64 composition.
 * The scoreboard consumes the actual feed tokens hierarchically, so it
 * checks the BRAM window, parameter stream, masks, epoch fence and the
 * arithmetic/writeback path without duplicating the feed address mapping. */
module tb_unified64_tile_engine_persistent_random;
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
    wire valid_out; reg ready_out=1; wire [10:0] out_pixel_idx; wire [8:0] out_channel_base;
    wire [3:0] out_lane_mask; wire signed [31:0] out_data;
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

    reg [31:0] lfsr=32'h1a2b3c4d;
    integer cyc=0, errors=0, jobs=0, stale=0, token_fires=0, output_count=0, expected_count=0;
    integer stall_seen=0, source_req_count=0, param_req_count=0;
    integer last_pb=0, last_ct=0;
    integer acc[0:63]; integer i,j,r,idx;
    integer exp_pixel[0:1023], exp_cout[0:1023], exp_mask[0:1023]; reg signed [31:0] exp_data[0:1023];

    function automatic integer s8(input [7:0] x);
        begin if (x[7]) s8 = x - 256; else s8 = x; end
    endfunction
    function automatic integer clamp8(input integer x);
        begin if (x > 127) clamp8=127; else if (x < -128) clamp8=-128; else clamp8=x; end
    endfunction
    function automatic [31:0] source_pat(input [31:0] a);
        integer wi,b; begin wi=(a-load_source_base_addr)>>2; source_pat=0;
            for(b=0;b<4;b=b+1) source_pat[(b*8)+:8]=(wi*4+b+1)&255; end
    endfunction
    function automatic [31:0] param_pat(input [31:0] a);
        integer wi,b; begin wi=(a-load_param_base_addr)>>2; param_pat=0;
            for(b=0;b<4;b=b+1) param_pat[(b*8)+:8]=(wi*4+b+3)&255; end
    endfunction

    assign source_req_ready = lfsr[2] | lfsr[5];
    assign param_req_ready = lfsr[9] | lfsr[13];
    always @(negedge clk) begin
        if (!rst_n) begin lfsr<=32'h1a2b3c4d; ready_out<=1; end
        else begin
            cyc=cyc+1;
            lfsr <= {lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            ready_out <= !(lfsr[17:15]==3'b000 || lfsr[23:21]==3'b101);
            if (!ready_out && valid_out) stall_seen=stall_seen+1;
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin source_resp_valid<=0; param_resp_valid<=0; end
        else begin
            source_resp_valid<=source_req_valid&&source_req_ready;
            param_resp_valid<=param_req_valid&&param_req_ready;
            if(source_req_valid&&source_req_ready) begin source_resp_data<=source_pat(source_req_addr); source_req_count=source_req_count+1; end
            if(param_req_valid&&param_req_ready) begin param_resp_data<=param_pat(param_req_addr); param_req_count=param_req_count+1; end
            if(job_reject_stale) stale=stale+1;
            if(valid_out&&ready_out) begin
                if(output_count>=expected_count) begin errors=errors+1; end
                else begin
                    if(out_pixel_idx!==exp_pixel[output_count] || out_channel_base!==exp_cout[output_count] || out_lane_mask!==exp_mask[output_count]) begin
                        if(errors<8) $display("TAG/MASK n=%0d got p=%0d c=%0d m=%b exp p=%0d c=%0d m=%b",output_count,out_pixel_idx,out_channel_base,out_lane_mask,exp_pixel[output_count],exp_cout[output_count],exp_mask[output_count]);
                        errors=errors+1;
                    end
                    for(j=0;j<4;j=j+1) if(out_lane_mask[j] && out_data[(j*8)+:8] !== exp_data[output_count][(j*8)+:8]) begin
                        if(errors<8) $display("DATA n=%0d lane=%0d got=%0d exp=%0d",output_count,j,$signed(out_data[(j*8)+:8]),$signed(exp_data[output_count][(j*8)+:8]));
                        errors=errors+1;
                    end
                end
                output_count=output_count+1;
            end
            /* Scoreboard the actual accepted feed token.  The array MACs
             * intentionally receive all eight values; masks only gate the
             * externally committed lanes, matching the production contract. */
            if (dut.feed_token_valid && dut.feed_token_ready) begin
                token_fires=token_fires+1;
                if (dut.feed_token_first) for(i=0;i<64;i=i+1) acc[i]=0;
                for(i=0;i<8;i=i+1) for(j=0;j<8;j=j+1)
                    acc[i*8+j]=acc[i*8+j]+s8(dut.feed_act[i*8 +: 8])*s8(dut.feed_wgt[j*8 +: 8]);
                if (dut.feed_token_last) begin
                    for(r=0;r<8;r=r+1) for(j=0;j<2;j=j+1) begin
                        idx=expected_count; exp_pixel[idx]=dut.feed_token_pixel+r;
                        exp_cout[idx]=dut.feed_token_cout+j*4;
                        exp_mask[idx]=dut.feed_pixel_mask[r] ? (dut.feed_cout_mask[j*4 +: 4]) : 0;
                        exp_data[idx]=0;
                        for(i=0;i<4;i=i+1) exp_data[idx][i*8 +: 8]=clamp8(acc[r*8+j*4+i]);
                        expected_count=expected_count+1;
                    end
                end
            end
        end
    end

    task automatic setup; begin
        @(negedge clk); cfg_layer_id=1; cfg_epoch=5; cfg_session=6;
        while(!cfg_ready) @(posedge clk); cfg_valid=1; @(posedge clk); @(negedge clk); cfg_valid=0;
        load_source_base_addr=32'h100000; load_param_base_addr=32'h200000; load_start_valid=1;
        while(!load_start_ready) @(posedge clk); @(posedge clk); @(negedge clk); load_start_valid=0;
        while(!load_done) @(posedge clk);
        commit_valid=1; while(!committed_valid) @(posedge clk); @(negedge clk); commit_valid=0;
    end endtask
    task automatic random_job(input integer n); integer pb,ct,pm,cm; begin
        pb=(lfsr[11:2] % 1016); ct=(lfsr[19:15] % 4); pm=(lfsr[27:20] | 1); cm=(lfsr[14:7] | 1);
        /* Repeated bases deliberately exercise the feed's epoch/session
         * guarded source-window reuse while masks change every job. */
        if ((n%5)==0) pb=0; if ((n%7)==0) ct=0;
        /* Every odd job is deliberately a different cout tile on the same
         * source window as the preceding job.  This makes the persistent
         * window-reuse branch an observed contract, rather than merely a
         * random possibility. */
        if ((n%2)==1) begin pb=last_pb; ct=(last_ct+1)%4; end
        @(negedge clk); job_pixel_base=pb; job_cout_tile=ct; job_pixel_mask=pm; job_cout_mask=cm; job_epoch=5; job_session=6; job_valid=1;
        while(!job_ready) @(posedge clk); @(posedge clk); @(negedge clk); job_valid=0;
        while(!job_done) @(posedge clk); while(busy) @(posedge clk); jobs=jobs+1; last_pb=pb; last_ct=ct;
    end endtask
    initial begin
        cfg_layer_id=0;cfg_epoch=0;cfg_session=0;load_source_base_addr=0;load_param_base_addr=0;job_epoch=0;job_session=0;job_pixel_base=0;job_cout_tile=0;job_pixel_mask=0;job_cout_mask=0;
        repeat(5) @(posedge clk); rst_n=1; setup();
        /* Hold an invalid epoch long enough to observe rejection without
         * allowing it to enter the feed. */
        @(negedge clk); job_epoch=9; job_session=9; job_pixel_base=0; job_cout_tile=0; job_pixel_mask=8'hff; job_cout_mask=8'hff; job_valid=1;
        repeat(7) @(posedge clk); job_valid=0;
        for(i=0;i<40;i=i+1) random_job(i);
        while(output_count<expected_count || busy) begin @(posedge clk); if(cyc>300000) $fatal; end
        if(errors!=0 || jobs!=40 || stale==0 || token_fires!=feed_token_count || output_count!=expected_count || stall_seen==0 || feed_window_reuse_count < 19 || source_req_count != 4096) begin
            $display("FAIL random errors=%0d jobs=%0d stale=%0d tokens=%0d/%0d outputs=%0d/%0d stalls=%0d reuse=%0d source_req=%0d",errors,jobs,stale,token_fires,feed_token_count,output_count,expected_count,stall_seen,feed_window_reuse_count,source_req_count); $fatal;
        end
        $display("PASS persistent_random jobs=%0d tokens=%0d outputs=%0d stale=%0d source_req=%0d param_req=%0d stalls=%0d reuse=%0d cycles=%0d",jobs,token_fires,output_count,stale,source_req_count,param_req_count,stall_seen,feed_window_reuse_count,cyc);
        $finish;
    end
endmodule
`default_nettype wire
