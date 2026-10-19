`timescale 1ns/1ps
module tb_d4_fullnet;
    reg clk=0;
    always #4 clk=~clk;
    reg rst_n=0, start_valid=0, input_valid=0, logit_ready=0, done_ready=0;
    reg [127:0] input_data;
    wire start_ready, input_ready, logit_valid, done_valid, busy, error;
    wire [3:0] logit_index;
    wire signed [31:0] logit_acc;
    wire [31:0] cycle_count, semantic_mac_count;
    wire trace_valid;
    wire [5:0] trace_op;
    wire [10:0] trace_index;
    wire [127:0] trace_data;
    d4_fullnet_top dut(.*);
    reg [127:0] image [0:1023];
    reg [127:0] expected [0:32767];
    reg [31:0] offsets [0:40], fc [0:9];
    integer counts [0:40];
    integer op_started=0;
    string vectors="build/d4_fullnet_vectors/sample_0";
    string vcd_path;
    integer mode=0, epochs=1, throughput=0;
    integer previous_start=0, previous_cycles=0;
    integer tick=0, started=0, input_pos=0, received=0, checked=0;
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
        if(hold_logit && (!logit_valid || held_index!==logit_index || held_acc!==logit_acc))
            $fatal(1,"LOGIT_UNSTABLE mode=%0d",mode);
        hold_logit=logit_valid && !logit_ready;
        held_index=logit_index;held_acc=logit_acc;
        if(hold_logit) held_cycles=held_cycles+1;
        if(hold_input && (!input_valid || input_data!==held_input)) $fatal(1,"TB_INPUT_UNSTABLE");
        hold_input=input_valid && !input_ready;
        held_input=input_data;
        if(start_valid && start_ready) begin
            if(throughput && previous_start!=0) begin
                if(tick-previous_start!=previous_cycles+2) $fatal(1,"BAD_START_INTERVAL");
                $display("D4_START_INTERVAL cycles=%0d",tick-previous_start);
            end
            previous_start=tick;started=tick;
        end
        if(dut.state==2) op_started=tick;
        if(dut.state==12)
            $display("D4_OP_CYCLES mode=%0d epoch=%0d op=%0d kind=%0d cycles=%0d",
                     mode,e,dut.op_index,dut.kind,tick-op_started+1);
        if(input_valid && input_ready) input_pos=input_pos+1;
        if(trace_valid) begin
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
        if(tick-started>3000000 && busy) $fatal(1,"TIMEOUT state=%0d op=%0d",dut.state,dut.op_index);
    end
    initial begin
        if($value$plusargs("vcd=%s",vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(1,dut);
        end
        if($value$plusargs("vectors=%s",vectors)) begin end
        if($value$plusargs("mode=%d",mode)) begin end
        if($value$plusargs("epochs=%d",epochs)) begin end
        throughput=$test$plusargs("throughput");
        $readmemh({vectors,"/input.mem"},image);
        $readmemh({vectors,"/expected_taps.mem"},expected);
        $readmemh({vectors,"/tap_offsets.mem"},offsets);
        $readmemh({vectors,"/fc_acc.mem"},fc);
        repeat(5) @(negedge clk);
        rst_n=1;
        if(throughput) done_ready=1;
        for(e=0;e<epochs;e=e+1) begin
            for(t=0;t<41;t=t+1) counts[t]=0;
            received=0;input_pos=0;checked=0;held_cycles=0;final_stall=0;
            if(!throughput) @(negedge clk);
            while(!start_ready) @(negedge clk);
            start_valid=1;
            @(negedge clk);start_valid=0;
            while(input_pos<1024) begin
                input_valid=mode==0 || (mode==2 ? ((tick%97)>=64) : (lfsr[0]||lfsr[7]));
                input_data=image[input_pos];
                @(negedge clk);
            end
            input_valid=0;
            while(!done_valid) begin
                // Mode 2 exercises 64-cycle input/last-logit stalls. It is a
                // streaming test, not a response-64 external memory claim.
                if(mode==0) logit_ready=1;
                else if(mode==2 && logit_valid && logit_index==9 && final_stall<64) begin
                    logit_ready=0;final_stall=final_stall+1;
                end
                else if(mode==2) logit_ready=(tick%97)>=64;
                else logit_ready=lfsr[2]||lfsr[13];
                @(negedge clk);
            end
            elapsed=tick-started;
            previous_cycles=cycle_count;
            if(error || received!=10 || input_pos!=1024 || semantic_mac_count!=11645440)
                $fatal(1,"BAD_DONE error=%0d logits=%0d input=%0d macs=%0d",error,received,input_pos,semantic_mac_count);
            // Compare every output word of every layer, including final tails.
            for(t=0;t<40;t=t+1)
                if(counts[t]!=dut.descriptors[t*32+20])
                    $fatal(1,"MISSING_TAP op=%0d words=%0d expected=%0d",t,counts[t],dut.descriptors[t*32+20]);
            if(elapsed!=cycle_count) $fatal(1,"CYCLE_ACCOUNT tb=%0d dut=%0d",elapsed,cycle_count);
            $display("D4_FULLNET_PASS mode=%0d epoch=%0d cycles=%0d tap_words=%0d logits=%0d macs=%0d logit_stall=%0d",
                     mode,e,cycle_count,checked,received,semantic_mac_count,held_cycles);
            // Done backpressure must retain completion and freeze its count.
            if(!throughput) begin
                repeat(5) begin
                    @(negedge clk);
                    if(!done_valid || cycle_count!=elapsed) $fatal(1,"DONE_UNSTABLE");
                end
                done_ready=1;
            end
            @(negedge clk);
            if(!throughput) done_ready=0;
            logit_ready=0;
            if(!start_ready) $fatal(1,"RESTART_NOT_READY");
        end
        $finish;
    end
endmodule
