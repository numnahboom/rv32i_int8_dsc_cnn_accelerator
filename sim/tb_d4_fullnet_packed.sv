`timescale 1ns/1ps
module tb_d4_fullnet_packed;
    reg clk=0;
    always #4 clk=~clk;
    reg rst_n=0, start_valid=0, input_valid=0, logit_ready=0, done_ready=0;
    reg [31:0] input_data;
    wire start_ready, input_ready, logit_valid, done_valid, busy, error;
    wire [3:0] logit_index;
    wire signed [31:0] logit_acc;
    wire [31:0] cycle_count, semantic_mac_count;
    wire trace_valid;
    wire [5:0] trace_op;
    wire [10:0] trace_index;
    wire [127:0] trace_data;
    d4_fullnet_impl_top dut(.*);
    assign cycle_count=dut.u_core.cycle_count;
    assign semantic_mac_count=dut.u_core.semantic_mac_count;
    assign trace_valid=dut.u_core.trace_valid;
    assign trace_op=dut.u_core.trace_op;
    assign trace_index=dut.u_core.trace_index;
    assign trace_data=dut.u_core.trace_data;
    reg [127:0] image [0:1023];
    reg [127:0] expected [0:32767];
    reg [31:0] offsets [0:40], fc [0:9];
    integer counts [0:40];
    integer op_started=0;
    string vectors="build/d4_fullnet_vectors/sample_0";
    string vcd_path;
    integer mode=0, epochs=1, throughput=0, control_probe=0, reset_pipeline_probe=0;
    integer completion_reset_probe=0, start_token_probe=0;
    integer reset_probe_quiet=0, reset_probe_wait=0;
    integer previous_start=0, previous_start_to_done=0;
    integer tick=0, started=0, input_pos=0, received=0, checked=0;
    integer control_start_count=0, core_start_count=0;
    integer t, e, elapsed, held_cycles=0, final_stall=0;
    reg hold_logit=0;
    reg [3:0] held_index;
    reg [31:0] held_acc;
    reg hold_input=0;
    reg [127:0] held_input;
    reg [31:0] lfsr=32'h1a141c6e;
    always @(negedge clk) lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    always @(posedge clk) if(rst_n) begin
        tick=tick+1;
        if(start_valid && start_ready) control_start_count=control_start_count+1;
        if(dut.core_start_valid && dut.core_start_ready) core_start_count=core_start_count+1;
        if(hold_logit && (!logit_valid || held_index!==logit_index || held_acc!==logit_acc))
            $fatal(1,"LOGIT_UNSTABLE mode=%0d",mode);
        hold_logit=logit_valid && !logit_ready;
        held_index=logit_index;held_acc=logit_acc;
        if(hold_logit) held_cycles=held_cycles+1;
        if(hold_input && (!input_valid || input_data!==held_input)) $fatal(1,"TB_INPUT_UNSTABLE");
        hold_input=input_valid && !input_ready;
        held_input=input_data;
        if(start_valid && start_ready) begin
            if(reset_probe_quiet) reset_probe_quiet=0;
            if(throughput && previous_start!=0) begin
                if(tick-previous_start!=previous_start_to_done+2) $fatal(1,"BAD_START_INTERVAL");
                $display("D4_PACKED_START_INTERVAL cycles=%0d",tick-previous_start);
            end
            previous_start=tick;started=tick;
        end
        if(dut.u_core.state==2) op_started=tick;
        if(dut.u_core.state==12)
            $display("D4_OP_CYCLES mode=%0d epoch=%0d op=%0d kind=%0d cycles=%0d",
                     mode,e,dut.u_core.op_index,dut.u_core.kind,tick-op_started+1);
        if(input_valid && input_ready) input_pos=input_pos+1;
        if(trace_valid) begin
            if(reset_probe_quiet) $fatal(1,"RESET_PIPELINE_TRACE_LEAK");
            if(trace_op>=40 || trace_index!==counts[trace_op][10:0])
                $fatal(1,"TRACE_ORDER op=%0d index=%0d expected=%0d",trace_op,trace_index,counts[trace_op]);
            if(trace_data!==expected[offsets[trace_op]+trace_index])
                $fatal(1,"TAP_MISMATCH op=%0d word=%0d got=%032x expected=%032x",
                       trace_op,trace_index,trace_data,expected[offsets[trace_op]+trace_index]);
            counts[trace_op]=counts[trace_op]+1;
            checked=checked+1;
        end
        if(logit_valid && logit_ready) begin
            if(logit_index!==received[3:0] || logit_acc!==fc[received])
                $fatal(1,"FC_MISMATCH index=%0d got=%0d expected=%0d",logit_index,logit_acc,$signed(fc[received]));
            received=received+1;
        end
        if(tick-started>3000000 && busy) $fatal(1,"TIMEOUT state=%0d op=%0d",dut.u_core.state,dut.u_core.op_index);
    end
    initial begin
        if($value$plusargs("vcd=%s",vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(2,dut);
        end
        if($value$plusargs("vectors=%s",vectors)) begin end
        if($value$plusargs("mode=%d",mode)) begin end
        if($value$plusargs("epochs=%d",epochs)) begin end
        control_probe=$test$plusargs("control_probe");
        reset_pipeline_probe=$test$plusargs("reset_pipeline_probe");
        completion_reset_probe=$test$plusargs("completion_reset_probe");
        start_token_probe=$test$plusargs("start_token_probe");
        if(control_probe) epochs=2;
        if(completion_reset_probe) epochs=2;
        throughput=$test$plusargs("throughput");
        $readmemh({vectors,"/input.mem"},image);
        $readmemh({vectors,"/expected_taps.mem"},expected);
        $readmemh({vectors,"/tap_offsets.mem"},offsets);
        $readmemh({vectors,"/fc_acc.mem"},fc);
        repeat(5) @(negedge clk);
        if(start_ready || input_ready || logit_valid || done_valid || busy || error)
            $fatal(1,"EXTERNAL_RESET_NOT_MASKED");
        rst_n=1;
        repeat(3) @(negedge clk);
        if(dut.clock_locked || dut.operational || start_ready || input_ready ||
           logit_valid || done_valid || busy || error)
            $fatal(1,"CLOCK_READY_BEFORE_LOCK");
        while(!dut.operational) begin
            if(start_ready || input_ready || logit_valid || done_valid || busy || error)
                $fatal(1,"INTERFACE_ACTIVE_DURING_CLOCK_STARTUP");
            @(negedge clk);
        end
        while(!start_ready) @(negedge clk);
        if(throughput) done_ready=1;
        if(start_token_probe) begin
            if(control_probe || reset_pipeline_probe || completion_reset_probe || throughput)
                $fatal(1,"START_TOKEN_PROBE_MODE_CONFLICT");
            // Reset after external admission but before the core can consume
            // the pending token. No core launch or stale external busy may survive.
            start_valid=1;
            @(negedge clk);
            if(!dut.pending_start || !busy || start_ready || input_ready ||
               dut.u_core.state!=0 || dut.u_core.busy || core_start_count!=0 ||
               control_start_count!=1)
                $fatal(1,"PENDING_START_SETUP");
            start_valid=0;
            rst_n=0;
            repeat(3) @(negedge clk);
            if(dut.pending_start || start_ready || input_ready || done_valid || busy ||
               dut.operational || core_start_count!=0)
                $fatal(1,"PENDING_START_RESET_CLEAR");
            hold_input=0;input_valid=0;input_pos=0;
            control_start_count=0;core_start_count=0;
            rst_n=1;
            while(!dut.operational || !start_ready) @(negedge clk);

            // Hold start high across enqueue and core consumption while
            // presenting the first packed beats immediately. The first beat
            // must remain stable through the token latency and be accepted once.
            input_valid=1;input_data=32'h51000001;start_valid=1;
            @(negedge clk);
            if(!dut.pending_start || !busy || start_ready || input_ready ||
               input_pos!=0 || control_start_count!=1 || core_start_count!=0)
                $fatal(1,"START_TOKEN_HELD_ENQUEUE");
            @(negedge clk);
            if(dut.pending_start || !busy || start_ready || !input_ready ||
               input_pos!=0 || control_start_count!=1 || core_start_count!=1)
                $fatal(1,"START_TOKEN_HELD_CONSUME");
            @(negedge clk);
            if(input_pos!=1 || dut.image_chunks!=1 || dut.chunk_index!=1 ||
               control_start_count!=1 || core_start_count!=1)
                $fatal(1,"START_TOKEN_FIRST_BEAT");
            input_data=32'h51000002;
            @(negedge clk);
            if(input_pos!=2 || dut.image_chunks!=2 || dut.chunk_index!=2 ||
               control_start_count!=1 || core_start_count!=1)
                $fatal(1,"START_TOKEN_SECOND_BEAT");
            input_valid=0;start_valid=0;hold_input=0;
            rst_n=0;
            repeat(3) @(negedge clk);
            if(dut.pending_start || start_ready || input_ready || done_valid || busy ||
               dut.operational || dut.image_chunks!=0 || dut.chunk_index!=0 ||
               dut.u_core.image_index!=0 || core_start_count!=1)
                $fatal(1,"START_TOKEN_PROBE_ABORT_RESET");
            rst_n=1;
            while(!dut.operational || !start_ready) @(negedge clk);
            control_start_count=0;core_start_count=0;input_pos=0;
            $display("D4_START_TOKEN_PROBE_PASS pending_reset=1 held_start_launches=1 first_beats=2");
        end
        if(control_probe) begin
            if(!start_ready || input_ready || done_valid || busy)
                $fatal(1,"RESET_CONTROL_STATE");
            start_valid=1;
            @(negedge clk);
            if(!busy || start_ready || input_ready || !dut.pending_start)
                $fatal(1,"START_CONTROL_PENDING_STATE");
            @(negedge clk);
            if(!busy || start_ready || !input_ready || dut.pending_start)
                $fatal(1,"START_CONTROL_STATE");
            start_valid=0;input_valid=1;
            for(t=0;t<2;t=t+1) begin
                input_data=32'hd4000000+t;
                @(negedge clk);
            end
            input_valid=0;
            if(dut.chunk_index!=2 || dut.packed_valid || dut.u_core.image_index!=0)
                $fatal(1,"PARTIAL_IMAGE_SETUP");
            rst_n=0;
            repeat(3) @(negedge clk);
            if(start_ready || input_ready || done_valid || busy || dut.operational ||
               dut.chunk_index!=0 || dut.image_chunks!=0 || dut.packed_valid || dut.u_core.image_index!=0)
                $fatal(1,"PARTIAL_IMAGE_RESET_RECOVERY");
            input_pos=0;started=0;control_start_count=0;
            rst_n=1;
            @(negedge clk);
            while(!dut.operational || !start_ready) @(negedge clk);
        end
        if(control_probe) begin
            // Exercise the core's illegal-state error token, acknowledge it,
            // then restart the exact inference in the normal epoch loop.
            start_valid=1;
            @(negedge clk);
            if(!busy || start_ready || input_ready || !dut.pending_start)
                $fatal(1,"ERROR_RESTART_PENDING_STATE");
            @(negedge clk);
            if(!busy || start_ready || !input_ready || dut.pending_start)
                $fatal(1,"ERROR_RESTART_START_STATE");
            dut.u_core.state=6'h3f;
            @(negedge clk);
            if(!error || !done_valid || busy || start_ready || input_ready ||
               dut.u_core.state!=0)
                $fatal(1,"ERROR_RESTART_TOKEN_STATE err=%0d done=%0d busy=%0d ready=%0d input=%0d state=%0d",
                       error,done_valid,busy,start_ready,input_ready,dut.u_core.state);
            repeat(3) begin
                @(negedge clk);
                if(!error || !done_valid || busy || start_ready || input_ready ||
                   dut.u_core.state!=0 || control_start_count!=1)
                    $fatal(1,"ERROR_RESTART_TOKEN_UNSTABLE");
            end
            done_ready=1;
            @(negedge clk);
            done_ready=0;
            if(done_valid || !start_ready || busy || input_ready || !error ||
               control_start_count!=1)
                $fatal(1,"ERROR_RESTART_ACK_STATE");
            // The held start is enqueued after the acknowledgement, then
            // consumed by the core on the following edge.
            @(negedge clk);
            if(done_valid || !busy || start_ready || input_ready || error ||
               !dut.pending_start || dut.u_core.state!=0 || control_start_count!=2)
                $fatal(1,"ERROR_RESTART_HELD_ENQUEUE_STATE done=%0d busy=%0d ready=%0d input=%0d err=%0d pending=%0d state=%0d accepted=%0d",
                       done_valid,busy,start_ready,input_ready,error,dut.pending_start,
                       dut.u_core.state,control_start_count);
            @(negedge clk);
            if(done_valid || !busy || start_ready || !input_ready || error ||
               dut.pending_start || dut.u_core.state!=1 || control_start_count!=2)
                $fatal(1,"ERROR_RESTART_HELD_CONSUME_STATE");
            $display("D4_ERROR_RESTART_PASS");
        end
        if(reset_pipeline_probe) begin
            if(control_probe || throughput || completion_reset_probe)
                $fatal(1,"RESET_PROBE_MODE_CONFLICT");
            for(t=0;t<41;t=t+1) counts[t]=0;
            input_pos=0;received=0;checked=0;started=0;
            start_valid=1;
            @(negedge clk);
            start_valid=0;
            while(input_pos<4096) begin
                input_valid=1;
                input_data=image[input_pos>>2][(input_pos&3)*32+:32];
                @(negedge clk);
            end
            input_valid=0;
            reset_probe_wait=0;
            while(!(dut.u_core.op_index==0 && dut.u_core.state==22 &&
                    dut.u_core.rq_product_valid && dut.u_core.sum_valid)) begin
                @(negedge clk);
                reset_probe_wait=reset_probe_wait+1;
                if(reset_probe_wait>2000) $fatal(1,"RESET_PROBE_PIPELINE_NOT_REACHED");
            end
            if(!busy || !(dut.u_core.bank_busy[0] || dut.u_core.bank_busy[1]) ||
               !dut.u_core.rq_product_valid)
                $fatal(1,"RESET_PROBE_BAD_INFLIGHT_SETUP");
            rst_n=0;
            repeat(3) @(negedge clk);
            if(start_ready || input_ready || done_valid || busy || dut.operational || trace_valid ||
               dut.u_core.read_valid || dut.u_core.operand_valid || dut.u_core.product_valid ||
               dut.u_core.sum_valid || dut.u_core.rq_pending_valid || dut.u_core.rq_input_valid ||
               dut.u_core.rq_partial_valid || dut.u_core.rq_merge_valid ||
               dut.u_core.rq_product_valid || dut.u_core.rq_round_valid || dut.u_core.rq_clamp_valid ||
               dut.u_core.rq_lane_valid!=0 ||
               dut.u_core.bank_busy[0] || dut.u_core.bank_busy[1])
                $fatal(1,"RESET_PROBE_PIPELINE_NOT_CLEARED");
            reset_probe_quiet=1;
            tick=0;started=0;previous_start=0;previous_start_to_done=0;
            rst_n=1;
            while(!dut.operational || !start_ready) @(negedge clk);
            repeat(5) @(negedge clk);
            if(trace_valid || logit_valid || done_valid || busy || input_ready)
                $fatal(1,"RESET_PROBE_IDLE_LEAK");
            $display("D4_RQ_MAC_RESET_PASS inflight_rq_product=1 inflight_sum=1");
        end
        if(completion_reset_probe && (control_probe || reset_pipeline_probe || throughput))
            $fatal(1,"COMPLETION_RESET_MODE_CONFLICT");
        for(e=0;e<epochs;e=e+1) begin
            for(t=0;t<41;t=t+1) counts[t]=0;
            received=0;input_pos=0;checked=0;held_cycles=0;final_stall=0;
            if(!throughput) @(negedge clk);
            if(control_probe && e==0) begin
                // The held request acknowledged the error token and already
                // started this exact inference.
                if(!busy || start_ready || !input_ready || done_valid || !start_valid)
                    $fatal(1,"ERROR_RESTART_INFERENCE_STATE");
            end else if(control_probe && e==1) begin
                // The held request from epoch 0 was accepted exactly once on
                // the cycle after its completion token was acknowledged.
                if(!busy || start_ready || !input_ready || done_valid)
                    $fatal(1,"HELD_START_RESTART_STATE");
            end else begin
                while(!start_ready) @(negedge clk);
                start_valid=1;
                @(negedge clk);
                if(control_probe && e==0) begin
                    if(!busy || start_ready || input_ready || !dut.pending_start)
                        $fatal(1,"HELD_START_PENDING_SETUP");
                    // Keep start_valid asserted through completion. It must
                    // remain unaccepted under backpressure, then start once.
                end else start_valid=0;
            end
            while(input_pos<4096) begin
                input_valid=mode==0 || (mode==2 ? ((tick%97)>=64) : (lfsr[0]||lfsr[7]));
                input_data=image[input_pos>>2][(input_pos&3)*32+:32];
                @(negedge clk);
            end
            input_valid=0;
            if(control_probe && e==1) begin
                if(input_ready || dut.image_chunks!=4096) $fatal(1,"LAST_INPUT_READY_STATE");
                input_valid=1;input_data=32'hffffffff;
                repeat(4) begin
                    @(negedge clk);
                    if(input_ready || input_pos!=4096 || dut.image_chunks!=4096)
                        $fatal(1,"EXCESS_IMAGE_ACCEPTED");
                end
            end
            while(!done_valid) begin
                // Mode 2 exercises 64-cycle input/last-logit stalls. It is a
                // streaming test, not a response-64 external memory claim.
                if(mode==0) logit_ready=1;
                else if(mode==2 && logit_valid && logit_index==9 && final_stall<64) begin
                    logit_ready=0;final_stall=final_stall+1;
                end
                else if(mode==2) logit_ready=(tick%97)>=64;
                else logit_ready=lfsr[2]||lfsr[13];
                if(control_probe && e==0 && start_ready) $fatal(1,"HELD_START_READY_WHILE_BUSY");
                @(negedge clk);
            end
            elapsed=tick-started;
            previous_start_to_done=elapsed;
            if(error || received!=10 || input_pos!=4096 || semantic_mac_count!=11645440)
                $fatal(1,"BAD_DONE error=%0d logits=%0d input=%0d macs=%0d",error,received,input_pos,semantic_mac_count);
            // Compare every output word of every layer, including final tails.
            for(t=0;t<40;t=t+1)
                if(counts[t]!=dut.u_core.descriptors[t*32+20])
                    $fatal(1,"MISSING_TAP op=%0d words=%0d expected=%0d",t,counts[t],dut.u_core.descriptors[t*32+20]);
            if(elapsed!=cycle_count+1)
                $fatal(1,"CYCLE_ACCOUNT external_start_to_done=%0d core_busy_cycles=%0d",elapsed,cycle_count);
            $display("D4_PACKED_FULLNET_PASS mode=%0d epoch=%0d cycles=%0d start_to_done=%0d tap_words=%0d logits=%0d macs=%0d logit_stall=%0d",
                     mode,e,cycle_count,elapsed,checked,received,semantic_mac_count,held_cycles);
            if(completion_reset_probe && e==0) begin
                // Reset while the completion token is pending, then run an
                // exact restart in epoch 1 with the usual output/ledger checks.
                done_ready=0;logit_ready=0;
                repeat(5) begin
                    @(negedge clk);
                    if(!done_valid || busy || start_ready || input_ready ||
                       dut.u_core.state!=0 || cycle_count+1!=elapsed)
                        $fatal(1,"COMPLETION_RESET_PENDING_UNSTABLE");
                end
                input_valid=0;hold_input=0;rst_n=0;
                repeat(3) @(negedge clk);
                if(start_ready || input_ready || done_valid || busy || dut.operational)
                    $fatal(1,"COMPLETION_RESET_NOT_CLEARED");
                rst_n=1;
                while(!dut.operational || !start_ready) @(negedge clk);
                if(done_valid || busy || input_ready)
                    $fatal(1,"COMPLETION_RESET_IDLE_LEAK");
                $display("D4_COMPLETION_RESET_PASS");
            end else begin
                // Done backpressure retains the token and freezes the count.
                if(!throughput) begin
                    repeat(5) begin
                        @(negedge clk);
                        if(!done_valid || busy || start_ready || dut.u_core.state!=0 ||
                           cycle_count+1!=elapsed)
                            $fatal(1,"DONE_UNSTABLE");
                    end
                    done_ready=1;
                    if(control_probe && e==0 && !start_valid)
                        $fatal(1,"HELD_START_DROPPED_EARLY");
                end
                @(negedge clk);
                if(!throughput) done_ready=0;
                logit_ready=0;
                if(control_probe && e==0) begin
                    if(done_valid || !start_ready || busy || input_ready || dut.u_core.state!=0)
                        $fatal(1,"HELD_START_ACK_STATE");
                    // The held request is accepted once into the wrapper token.
                    @(negedge clk);
                    if(done_valid || !busy || start_ready || input_ready ||
                       !dut.pending_start || dut.u_core.state!=0)
                        $fatal(1,"HELD_START_ENQUEUE_STATE");
                    @(negedge clk);
                    if(done_valid || !busy || start_ready || !input_ready ||
                       dut.pending_start || dut.u_core.state==0)
                        $fatal(1,"HELD_START_CONSUME_STATE");
                    start_valid=0;
                end else if(!start_ready || done_valid || busy || input_ready ||
                            dut.u_core.state!=0) begin
                    $fatal(1,"RESTART_NOT_READY");
                end
                if(control_probe && e==1) begin
                    // Abort the intentionally stalled excess beat under reset.
                    input_valid=0;hold_input=0;rst_n=0;
                    repeat(2) @(negedge clk);
                    if(start_ready || input_ready || done_valid || busy || dut.operational)
                        $fatal(1,"POST_PROBE_RESET_STATE");
                    rst_n=1;
                    while(!dut.operational || !start_ready) @(negedge clk);
                end
            end
        end
        if(control_probe && control_start_count!=3)
            $fatal(1,"HELD_START_ACCEPT_COUNT count=%0d",control_start_count);
        $finish;
    end
endmodule
