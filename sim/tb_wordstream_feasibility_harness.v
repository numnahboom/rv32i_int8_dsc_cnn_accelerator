`timescale 1ns/1ps
`default_nettype none
module tb_wordstream_feasibility_harness;
    localparam integer STEM_PIXELS=1024;
    reg clk=0, rst_n=0, start=0;
    wire mem_req_valid; reg mem_req_ready;
    wire [23:0] mem_req_addr; reg mem_resp_valid; reg [31:0] mem_resp_data;
    wire busy, done, error;
    wire [31:0] perf_cycles, perf_mac_tokens, perf_mem_issues, perf_mem_responses,
                 perf_consumes, perf_overlap_cycles;
    wire stem_wr_valid, pw_wr_valid; wire [15:0] stem_wr_index, pw_wr_index;
    wire signed [7:0] stem_wr_data, pw_wr_data;
    integer errors=0, checks=0, timeout, i, p, c, k, ky, kx, ic, co, q;
    integer s, d, w, a;
    reg signed [7:0] exp_stem [0:STEM_PIXELS*16-1];
    reg signed [7:0] exp_ds [0:STEM_PIXELS*16-1];
    reg signed [7:0] exp_pw [0:STEM_PIXELS*32-1];

    wordstream_feasibility_harness dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .busy(busy), .done(done), .error(error),
        .perf_cycles(perf_cycles), .perf_mac_tokens(perf_mac_tokens),
        .perf_mem_issues(perf_mem_issues), .perf_mem_responses(perf_mem_responses),
        .perf_consumes(perf_consumes), .perf_overlap_cycles(perf_overlap_cycles),
        .stem_wr_valid(stem_wr_valid), .stem_wr_index(stem_wr_index),
        .stem_wr_data(stem_wr_data), .pw_wr_valid(pw_wr_valid),
        .pw_wr_index(pw_wr_index), .pw_wr_data(pw_wr_data)
    );
    always #5 clk = ~clk;

    function integer stem_byte(input integer addr);
        integer off; begin
            off=addr-3; stem_byte=((off*17)%31)-15;
        end
    endfunction
    function integer ds_byte(input integer addr);
        integer off; begin
            off=addr-16387; ds_byte=((off*7)%23)-11;
        end
    endfunction
    function integer mem_byte(input integer addr);
        begin
            if (addr>=3 && addr<3+3072) mem_byte=stem_byte(addr);
            else if (addr>=16387 && addr<16387+16384) mem_byte=ds_byte(addr);
            else mem_byte=0;
        end
    endfunction
    function integer signed_i8(input integer x);
        begin if (x>127) signed_i8=127; else if (x < -128) signed_i8=-128; else signed_i8=x; end
    endfunction
    function integer stem_w(input integer idx); begin stem_w=((idx*13)%7)-3; end endfunction
    function integer ds_w(input integer idx); begin ds_w=((idx*7)%5)-2; end endfunction
    function integer pw_w(input integer idx); begin pw_w=((idx*11)%7)-3; end endfunction

    always @(*) begin
        mem_req_ready = ((dut.perf_cycles % 11) != 3) && ((dut.perf_cycles % 17) != 5);
    end
    always @(posedge clk) begin
        if (!rst_n) begin mem_resp_valid<=0; mem_resp_data<=0; end
        else begin
            mem_resp_valid<=0;
            if (mem_req_valid && mem_req_ready) begin
                mem_resp_valid<=1;
                mem_resp_data <= (mem_byte(mem_req_addr+3)&255) << 24 |
                                 (mem_byte(mem_req_addr+2)&255) << 16 |
                                 (mem_byte(mem_req_addr+1)&255) << 8 |
                                 (mem_byte(mem_req_addr)&255);
            end
        end
    end

    initial begin
        repeat(4) @(posedge clk); rst_n=1;
        @(negedge clk); start=1; @(negedge clk); start=0;
        timeout=0;
        while (!done && timeout<1000000) begin timeout=timeout+1; @(posedge clk); end
        if (!done) begin $display("FAIL timeout cycles=%0d state=%0d busy=%b fill=%b/%b active=%b pixel=%0d token=%0d ch=%0d mem=%0d/%0d",timeout,dut.state,busy,dut.bank0_state,dut.bank1_state,dut.feeder_active_bank,dut.stem_pixel,dut.stem_token,dut.ds_channel,perf_mem_issues,perf_mem_responses); $fatal; end
        if (error) begin $display("FAIL harness error"); errors=errors+1; end
        /* Exact software reference: signed int8 operands, zero padding,
         * native NHWC layout, and the same low-byte writeback contract. */
        for (p=0;p<STEM_PIXELS;p=p+1) begin
            for (co=0;co<16;co=co+1) begin
                s=0;
                for (k=0;k<27;k=k+1) begin
                    ky=k/9; kx=(k/3)%3; ic=k%3;
                    if ((p/32+ky)>=1 && (p/32+ky)<=32 &&
                        (p%32+kx)>=1 && (p%32+kx)<=32)
                        s=s+stem_byte(3+((p/32+ky-1)*96)+((p%32+kx-1)*3)+ic)*stem_w(co*27+k);
                end
                exp_stem[p*16+co]=signed_i8(s);
            end
        end
        for (p=0;p<STEM_PIXELS;p=p+1) begin
            for (c=0;c<16;c=c+1) begin
                d=0;
                for (k=0;k<9;k=k+1) begin
                    ky=k/3; kx=k%3;
                    if ((p/32+ky)>=1 && (p/32+ky)<=32 &&
                        (p%32+kx)>=1 && (p%32+kx)<=32)
                        d=d+ds_byte(16387+((p/32+ky-1)*512)+((p%32+kx-1)*16)+c)*ds_w(c*9+k);
                end
                exp_ds[p*16+c]=signed_i8(d);
            end
        end
        for (p=0;p<STEM_PIXELS;p=p+1) for (co=0;co<32;co=co+1) begin
            w=0;
            for (k=0;k<16;k=k+1) w=w+$signed(exp_ds[p*16+k])*pw_w(co*16+k);
            exp_pw[p*32+co]=signed_i8(w);
        end
        for (i=0;i<STEM_PIXELS*16;i=i+1) begin
            if (dut.stem_mem[i] !== exp_stem[i]) begin errors=errors+1; if(errors<5) $display("stem mismatch %0d got=%0d exp=%0d",i,dut.stem_mem[i],exp_stem[i]); end
            if (dut.ds_mem[i] !== exp_ds[i]) begin errors=errors+1; if(errors<5) $display("ds mismatch %0d got=%0d exp=%0d",i,dut.ds_mem[i],exp_ds[i]); end
            checks=checks+2;
        end
        for (i=0;i<STEM_PIXELS*32;i=i+1) begin
            if (dut.pw_mem[i] !== exp_pw[i]) begin errors=errors+1; if(errors<5) $display("pw mismatch %0d got=%0d exp=%0d",i,dut.pw_mem[i],exp_pw[i]); end
            checks=checks+1;
        end
        if (perf_mem_issues !== perf_mem_responses) begin $display("FAIL mem issue/response %0d/%0d",perf_mem_issues,perf_mem_responses); errors=errors+1; end
        if (perf_overlap_cycles == 0) begin $display("FAIL no fill/compute overlap"); errors=errors+1; end
        if (perf_mac_tokens !== 32'd45056) begin $display("FAIL mac token count %0d",perf_mac_tokens); errors=errors+1; end
        if (errors==0) $display("PASS tb_wordstream_feasibility_harness checks=%0d cycles=%0d mac_tokens=%0d mem_words=%0d overlap=%0d",checks,perf_cycles,perf_mac_tokens,perf_mem_issues,perf_overlap_cycles);
        else begin $display("FAIL tb_wordstream_feasibility_harness checks=%0d errors=%0d",checks,errors); $fatal; end
        $finish;
    end
endmodule
`default_nettype wire
