`timescale 1ns/1ps
// Passive pin-level instrumentation only. It never initializes/forces DUT RAM.
module d4_gate_memory_watch #(parameter DEPTH=2048,AW=11)(
    input clk,cen,we,oe,input [AW-1:0] addr,input [127:0] din,q);
    bit written [0:DEPTH-1];
    integer i,writes=0,reads=0,unwritten_reads=0;
    initial for(i=0;i<DEPTH;i=i+1) written[i]=0;
    always @(posedge clk) if(cen===1'b0) begin
        if($isunknown({we,oe,addr}))
            $fatal(1,"GATE_MEM_UNKNOWN_REQUEST %m we=%b oe=%b addr=%b",we,oe,addr);
        if(we) begin
            if($isunknown(din)) $fatal(1,"GATE_MEM_UNKNOWN_WRITE %m addr=%0d din=%h",addr,din);
            writes=writes+1;
            written[addr]=1;
            if(addr>=1020 && addr<=1023)
                $display("GATE_MEM_LAST_INPUT_WRITE %m addr=%0d writes=%0d data=%h",addr,writes,din);
        end else if(oe) begin
            reads=reads+1;
            if(!written[addr]) begin
                unwritten_reads=unwritten_reads+1;
                if(unwritten_reads<=20)
                    $display("GATE_MEM_UNWRITTEN_READ %m addr=%0d reads=%0d writes=%0d",addr,reads,writes);
            end
            if(addr==1023)
                $display("GATE_MEM_READ_LAST_WORD %m written=%0d reads=%0d writes=%0d priorQ=%h",written[addr],reads,writes,q);
        end
    end
endmodule
bind RASP2048X16M16 d4_gate_memory_watch #(.DEPTH(2048),.AW(11)) gate_pin_watch
    (.clk(CLK),.cen(CEN),.we(WE),.oe(OE),.addr(AD),.din(DIN),.q(DOUT));
bind D4_ACT_1024X128_M8 d4_gate_memory_watch #(.DEPTH(1024),.AW(10)) gate_pin_watch
    (.clk(CLK),.cen(CEN),.we(WE),.oe(OE),.addr(AD),.din(DIN),.q(DOUT));
