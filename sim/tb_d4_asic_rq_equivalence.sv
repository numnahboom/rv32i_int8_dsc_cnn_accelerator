`timescale 1ns/1ps
module tb_d4_asic_rq_equivalence;
    reg clk=0;
    always #4 clk=~clk;
    reg rst_n=0, in_valid=0;
    reg signed [31:0] a=0,b=0;
    wire signed [63:0] partial_product,native_product;
    wire partial_valid,native_valid;
    d4_rq_partial_multiplier_lane partial_dut(clk,rst_n,in_valid,a,b,partial_product,partial_valid);
    d4_rq_native_multiplier_lane native_dut(clk,rst_n,in_valid,a,b,native_product,native_valid);
    reg signed [63:0] expected [0:3];
    reg [3:0] valid=0;
    reg [31:0] random_state=32'hd4a51c19;
    reg [31:0] corner [0:8];
    integer checks=0, resets=0, cycle=0, i,j,k;
    task step;
        input reset_value, accept;
        input [31:0] av,bv;
        begin
            @(negedge clk);rst_n=reset_value;in_valid=accept;a=av;b=bv;
            @(posedge clk);
            if (!rst_n) begin valid=0; resets=resets+1; end
            else begin
                for(k=3;k>0;k=k-1) expected[k]=expected[k-1];
                expected[0]=$signed(a)*$signed(b);
                valid={valid[2:0],in_valid};
            end
            #1;
            if(partial_valid!==valid[3] || native_valid!==valid[3]) $fatal(1,"VALID cycle=%0d",cycle);
            if(!rst_n && (partial_product!==0 || native_product!==0)) $fatal(1,"RESET_VALUE");
            if(valid[3]) begin
                if(partial_product!==expected[3] || native_product!==expected[3])
                    $fatal(1,"ARITHMETIC cycle=%0d partial=%h native=%h expected=%h",cycle,partial_product,native_product,expected[3]);
                checks=checks+1;
            end
            cycle=cycle+1;
        end
    endtask
    initial begin
        corner[0]=0;corner[1]=1;corner[2]=32'hffffffff;corner[3]=32'h80000000;
        corner[4]=32'h7fffffff;corner[5]=32'h0000ffff;corner[6]=32'hffff0000;
        corner[7]=32'h8000ffff;corner[8]=32'h7fff8000;
        step(0,0,0,0);
        for(i=0;i<9;i=i+1) for(j=0;j<9;j=j+1) step(1,1,corner[i],corner[j]);
        for(i=0;i<20000;i=i+1) begin
            random_state=random_state ^ (random_state<<13);
            random_state=random_state ^ (random_state>>17);
            random_state=random_state ^ (random_state<<5);
            a=random_state;
            random_state=random_state ^ (random_state<<13);
            random_state=random_state ^ (random_state>>17);
            random_state=random_state ^ (random_state<<5);
            step((i%997)!=996,random_state[2:0]!=0,a,random_state);
        end
        repeat(5) step(1,0,0,0);
        if(checks<17000 || resets<20) $fatal(1,"INSUFFICIENT_COVERAGE");
        $display("D4_ASIC_RQ_EQUIVALENCE_PASS checks=%0d resets=%0d full_signed32=1",checks,resets);
        $finish;
    end
endmodule
