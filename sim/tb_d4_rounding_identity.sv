`timescale 1ns/1ps
module tb_d4_rounding_identity;
    reg clk=0;
    always #4 clk=~clk;
    d4_fullnet_top dut(.clk(clk),.rst_n(1'b0),.start_valid(1'b0),
        .input_valid(1'b0),.input_data(128'd0),.logit_ready(1'b0),.done_ready(1'b0));
    function automatic signed [63:0] reference_round(input signed [63:0] x,input [5:0] sh);
        reg [63:0] mag,q;
        begin
            mag=x<0?-x:x;
            q=sh==0?mag:((mag+(64'd1<<(sh-1)))>>sh);
            reference_round=x<0?-$signed(q):$signed(q);
        end
    endfunction
    reg signed [31:0] edges[0:13];
    reg signed [31:0] a,b;
    reg signed [63:0] x,want,got;
    reg [63:0] bias;
    reg [31:0] rng=32'hd4202618;
    integer i,j,s,n,count=0;
    task automatic check_product(input signed [31:0] av,bv);
        begin
            x=$signed(av)*$signed(bv);
            for(s=0;s<64;s=s+1) begin
                bias=dut.make_round_bias(s[5:0],av[31]^bv[31]);
                got=dut.round_biased(x,bias,s[5:0]);
                want=reference_round(x,s[5:0]);
                if(got!==want) $fatal(1,"ROUND_PRODUCT a=%0d b=%0d sh=%0d got=%0d want=%0d",av,bv,s,got,want);
                count=count+1;
            end
        end
    endtask
    initial begin
        edges[0]=32'sh80000000;edges[1]=32'sh80000001;
        edges[2]=-65536;edges[3]=-32768;edges[4]=-129;edges[5]=-128;
        edges[6]=-1;edges[7]=0;edges[8]=1;edges[9]=127;edges[10]=128;
        edges[11]=32767;edges[12]=65535;edges[13]=32'sh7fffffff;
        for(i=0;i<14;i=i+1) for(j=0;j<14;j=j+1) check_product(edges[i],edges[j]);
        for(n=0;n<10000;n=n+1) begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);a=$signed(rng);
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);b=$signed(rng);
            check_product(a,b);
        end
        for(n=0;n<10000;n=n+1) begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);x[31:0]=rng;
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);x[63:32]=rng;
            for(s=0;s<64;s=s+1) begin
                got=dut.round_shift(x,s[5:0]);want=reference_round(x,s[5:0]);
                if(got!==want) $fatal(1,"ROUND64 x=%0d sh=%0d",x,s);
                count=count+1;
            end
        end
        $display("D4_ROUNDING_IDENTITY_PASS cases=%0d",count);
        $finish;
    end
endmodule
