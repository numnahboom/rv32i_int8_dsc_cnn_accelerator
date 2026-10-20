`timescale 1ns/1ps
// Bounded four-state gate startup check. It cannot wait forever on X ready/busy.
module tb_d4_asic_gate_start;
    reg clk=0;
    always #4 clk=~clk;
    reg rst_n=0,start_valid=0,input_valid=0,logit_ready=0,done_ready=0;
    reg [127:0] input_data=0;
    wire start_ready,input_ready,logit_valid,done_valid,busy,error,trace_valid;
    wire [3:0] logit_index;
    wire signed [31:0] logit_acc;
    wire [31:0] cycle_count,semantic_mac_count;
    wire [5:0] trace_op;
    wire [10:0] trace_index;
    wire [127:0] trace_data;
    d4_fullnet_top dut(.*);
    integer cycles=0,accepted=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>500) $fatal(1,"GATE_START_TIMEOUT");
        if(cycles>8 && $isunknown({start_ready,input_ready,logit_valid,done_valid,busy,error,trace_valid}))
            $fatal(1,"GATE_START_UNKNOWN_CONTROL cycles=%0d start=%b input=%b logit=%b done=%b busy=%b error=%b trace=%b accepted=%0d",
                cycles,start_ready,input_ready,logit_valid,done_valid,busy,error,trace_valid,accepted);
        if(input_valid && input_ready) accepted=accepted+1;
    end
    always @(negedge clk) if(cycles<40) begin
`ifdef D4_GATE_INTERNAL_DIAG
        $display("GATE_START_STATE cycles=%0d start=%b input=%b logit=%b done=%b busy=%b error=%b trace=%b accepted=%0d image_index=%b ready_D=%b index0_D=%b index0_AOI=%b",
            cycles,start_ready,input_ready,logit_valid,done_valid,busy,error,trace_valid,accepted,
            dut.image_index,dut.input_ready_reg.D,dut.n95076,{dut.image_index[0],dut.n156833,dut.n156832,dut.n156831});
`else
        $display("GATE_START_STATE cycles=%0d start=%b input=%b logit=%b done=%b busy=%b error=%b trace=%b accepted=%0d",
            cycles,start_ready,input_ready,logit_valid,done_valid,busy,error,trace_valid,accepted);
`endif
    end
    initial begin
        repeat(5) @(negedge clk);
        rst_n=1;
        repeat(4) @(negedge clk);
        if(start_ready!==1'b1 || busy!==1'b0 || error!==1'b0) $fatal(1,"GATE_IDLE_BAD");
        start_valid=1;
        @(negedge clk);start_valid=0;
        repeat(4) @(negedge clk);
        if(input_ready!==1'b1 || busy!==1'b1) $fatal(1,"GATE_START_BAD");
        input_valid=1;
        while(accepted<16) @(negedge clk);
        input_valid=0;
        repeat(4) @(negedge clk);
        if(accepted!=16 || busy!==1'b1 || error!==1'b0) $fatal(1,"GATE_INPUT_BAD");
        $display("D4_GATE_START_PROBE_PASS cycles=%0d input_beats=%0d controls_known=1",cycles,accepted);
        $finish;
    end
endmodule
