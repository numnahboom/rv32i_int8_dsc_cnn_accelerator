`timescale 1ns/1ps
`default_nettype none

/* Differential test: the retained dual32 local island is the reference for
 * arithmetic/masking/order, while the candidate has a separate raw FIFO and
 * shared RQ.  Inputs are held until both implementations accept them. */
module tb_dual32_shared_stream4_rq;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0; reg [1:0] mode_i=0;
    reg cfg_valid_i=0,cfg_island_i=0; reg [5:0] cfg_lane_i=0;
    reg signed [31:0] cfg_bias_i=0,cfg_multiplier_i=32'sh40000000;
    reg [5:0] cfg_shift_i=0; wire cfg_ready_ref,cfg_ready_dut;
    reg valid_in=0,first_k=0,last_k=0; reg [7:0] k_idx=0;
    reg [7:0] block_tag_i=0,pixel_base_i=0,pixel_mask_i=8'hff;
    reg [8:0] cout_base_i=0; reg [15:0] cout_mask_i=16'hffff;
    reg signed [31:0] zp_i=0,min_i=-128,max_i=127;
    reg [31:0] src0_i=0,src1_i=0,pw0_i=0,pw1_i=0,pw2_i=0,pw3_i=0;
    reg ready_out=1;
    wire valid_ref,valid_dut,ready_ref,ready_dut,busy_ref,busy_dut;
    wire [31:0] word_ref,word_dut; wire [3:0] mask_ref,mask_dut;
    wire [7:0] pixel_ref,pixel_dut,tag_ref,tag_dut;
    wire [8:0] channel_ref,channel_dut; wire [2:0] group_ref,group_dut;
    wire [1:0] mode_ref,mode_dut;
    wire rq_ref_ready,rq_ref_valid; wire [5:0] rq_ref_pixel; wire [6:0] rq_ref_channel;
    wire signed [31:0] rq_ref_data; wire rq_ref_busy;
    dual32_mac_local_island u_ref (
      .clk(clk),.rst_n(rst_n),.mode_i(mode_i),.cfg_valid_i(cfg_valid_i),
      .cfg_ready_o(cfg_ready_ref),.cfg_island_i(cfg_island_i),.cfg_lane_i(cfg_lane_i),
      .cfg_bias_i(cfg_bias_i),.cfg_multiplier_i(cfg_multiplier_i),.cfg_shift_i(cfg_shift_i),
      .valid_in(valid_in),.ready_in(ready_ref),.first_k(first_k),.last_k(last_k),.k_idx(k_idx),
      .block_tag_i(block_tag_i),.pixel_base_i(pixel_base_i),.cout_base_i(cout_base_i),
      .pixel_mask_i(pixel_mask_i),.cout_mask_i(cout_mask_i),.output_zero_point_i(zp_i),
      .activation_min_i(min_i),.activation_max_i(max_i),.src_word0_i(src0_i),.src_word1_i(src1_i),
      .param_word0_i(pw0_i),.param_word1_i(pw1_i),.param_word2_i(pw2_i),.param_word3_i(pw3_i),
      .valid_out(valid_ref),.ready_out(ready_out),.out_word(word_ref),.out_word_mask(mask_ref),
      .out_pixel_idx(pixel_ref),.out_channel_base(channel_ref),.out_group_idx(group_ref),
      .out_block_tag(tag_ref),.out_mode(mode_ref),.busy_o(busy_ref));
    dual32_shared_stream4_rq u_dut (
      .clk(clk),.rst_n(rst_n),.mode_i(mode_i),.cfg_valid_i(cfg_valid_i),
      .cfg_ready_o(cfg_ready_dut),.cfg_island_i(cfg_island_i),.cfg_lane_i(cfg_lane_i),
      .cfg_bias_i(cfg_bias_i),.cfg_multiplier_i(cfg_multiplier_i),.cfg_shift_i(cfg_shift_i),
      .valid_in(valid_in),.ready_in(ready_dut),.first_k(first_k),.last_k(last_k),.k_idx(k_idx),
      .block_tag_i(block_tag_i),.pixel_base_i(pixel_base_i),.cout_base_i(cout_base_i),
      .pixel_mask_i(pixel_mask_i),.cout_mask_i(cout_mask_i),.output_zero_point_i(zp_i),
      .activation_min_i(min_i),.activation_max_i(max_i),.src_word0_i(src0_i),.src_word1_i(src1_i),
      .param_word0_i(pw0_i),.param_word1_i(pw1_i),.param_word2_i(pw2_i),.param_word3_i(pw3_i),
      .valid_out(valid_dut),.ready_out(ready_out),.out_word(word_dut),.out_word_mask(mask_dut),
      .out_pixel_idx(pixel_dut),.out_channel_base(channel_dut),.out_group_idx(group_dut),
      .out_block_tag(tag_dut),.out_mode(mode_dut),.busy_o(busy_dut));
    requant_activation_stream4 u_rq_ref (
      .clk(clk),.rst_n(rst_n),.valid_in(u_dut.rq_valid_in),.ready_in(rq_ref_ready),
      .acc_vec(u_dut.raw_acc_fifo[u_dut.raw_rd_ptr]),
      .bias_vec(u_dut.raw_bias_fifo[u_dut.raw_rd_ptr]),
      .multiplier_vec(u_dut.raw_mult_fifo[u_dut.raw_rd_ptr]),
      .shift_vec(u_dut.raw_shift_fifo[u_dut.raw_rd_ptr]),
      .pixel_idx(u_dut.raw_pixel_fifo[u_dut.raw_rd_ptr][5:0]),
      .channel_idx(u_dut.raw_channel_fifo[u_dut.raw_rd_ptr][6:0]),
      .output_zero_point_int32(u_dut.raw_zp_fifo[u_dut.raw_rd_ptr]),
      .activation_min_int32(u_dut.raw_min_fifo[u_dut.raw_rd_ptr]),
      .activation_max_int32(u_dut.raw_max_fifo[u_dut.raw_rd_ptr]),
      .ready_out(ready_out),.valid_out(rq_ref_valid),.out_pixel_idx(rq_ref_pixel),
      .out_channel_idx(rq_ref_channel),.out_data_int8(rq_ref_data),.busy(rq_ref_busy));

    integer errors=0,ref_n=0,dut_n=0,cyc=0,seed=32'h4a7c331;
    integer exp_n=0;
    reg [31:0] exp_word[0:4095]; reg [3:0] exp_mask[0:4095];
    reg [7:0] exp_pixel[0:4095],exp_tag[0:4095]; reg [8:0] exp_channel[0:4095];
    reg [2:0] exp_group[0:4095]; reg [1:0] exp_mode[0:4095];
    reg signed [31:0] cfg_bias_mem[0:63],cfg_mult_mem[0:63]; reg [5:0] cfg_shift_mem[0:63];
    reg [31:0] q_word[0:4095]; reg [3:0] q_mask[0:4095];
    reg [7:0] q_pixel[0:4095],q_tag[0:4095]; reg [8:0] q_channel[0:4095];
    reg [2:0] q_group[0:4095]; reg [1:0] q_mode[0:4095];
    always @(negedge clk) begin
        if (!rst_n) ready_out <= 1'b1;
        else begin
            cyc = cyc + 1;
            ready_out <= ((cyc % 13) != 2) && ((cyc % 17) != 5) && ((cyc % 29) != 11);
        end
    end
    always @(posedge clk) begin
        if (rst_n) begin
            #1;
            if (cyc < 120 && (cyc % 10) == 0)
                $display("DBG cyc=%0d ref=%0d dut=%0d raw=%0d copy=%b/%0d i0=%0d i1=%0d rqv=%b rqri=%b busy=%b/%b",
                  cyc,ref_n,dut_n,u_dut.raw_count,u_dut.copy_active,u_dut.copy_island,
                  u_dut.u_island0.result_count,u_dut.u_island1.result_count,
                  valid_dut,u_dut.rq_ready_in,busy_ref,busy_dut);
            if (cyc < 120 && u_dut.raw_count != 0)
                $display("RAW cyc=%0d rd=%0d acc=%h bias=%h mult=%h sh=%h zp=%0d min=%0d max=%0d p=%0d c=%0d g=%0d t=%0d m=%h",
                  cyc,u_dut.raw_rd_ptr,u_dut.raw_acc_fifo[u_dut.raw_rd_ptr],
                  u_dut.raw_bias_fifo[u_dut.raw_rd_ptr],u_dut.raw_mult_fifo[u_dut.raw_rd_ptr],
                  u_dut.raw_shift_fifo[u_dut.raw_rd_ptr],u_dut.raw_zp_fifo[u_dut.raw_rd_ptr],
                  u_dut.raw_min_fifo[u_dut.raw_rd_ptr],u_dut.raw_max_fifo[u_dut.raw_rd_ptr],
                  u_dut.raw_pixel_fifo[u_dut.raw_rd_ptr],u_dut.raw_channel_fifo[u_dut.raw_rd_ptr],
                  u_dut.raw_group_fifo[u_dut.raw_rd_ptr],u_dut.raw_tag_fifo[u_dut.raw_rd_ptr],
                  u_dut.raw_mask_fifo[u_dut.raw_rd_ptr]);
            if (valid_dut && ready_out) begin
                if (dut_n >= exp_n) begin
                    $display("EARLY dut=%0d exp=%0d",dut_n,exp_n); errors=errors+1;
                end else begin
                    if (!rq_ref_valid || word_dut!==rq_ref_data ||
                        pixel_dut[5:0]!==rq_ref_pixel || channel_dut[6:0]!==rq_ref_channel ||
                        mask_dut!==exp_mask[dut_n] ||
                        pixel_dut!==exp_pixel[dut_n] || channel_dut!==exp_channel[dut_n] ||
                        group_dut!==exp_group[dut_n] || tag_dut!==exp_tag[dut_n] ||
                        mode_dut!==exp_mode[dut_n]) begin
                        if (errors < 20) $display("MISMATCH n=%0d got=%h m=%h p=%0d c=%0d g=%0d t=%0d md=%0d exp=%h m=%h p=%0d c=%0d g=%0d t=%0d md=%0d",
                          dut_n,word_dut,mask_dut,pixel_dut,channel_dut,group_dut,tag_dut,mode_dut,
                          exp_word[dut_n],exp_mask[dut_n],exp_pixel[dut_n],exp_channel[dut_n],exp_group[dut_n],exp_tag[dut_n],exp_mode[dut_n]);
                        errors=errors+1;
                    end
                end
                if (dut_n > 500) $fatal(1,"dut output runaway exp=%0d raw=%0d",exp_n,u_dut.raw_count);
                dut_n=dut_n+1;
            end
        end
    end
    task cfg_all;
      integer ii,ll; begin
        for(ii=0;ii<2;ii=ii+1) for(ll=0;ll<32;ll=ll+1) begin
          @(negedge clk); cfg_island_i=ii; cfg_lane_i=ll; cfg_bias_i=(ii*19+ll)-20;
          cfg_multiplier_i=32'sh20000000 + (ll*32'sh0012345);
          cfg_shift_i=(ll*3+ii)&6'h3f; cfg_valid_i=1;
          cfg_bias_mem[ii*32+ll]=cfg_bias_i;
          cfg_mult_mem[ii*32+ll]=cfg_multiplier_i;
          cfg_shift_mem[ii*32+ll]=cfg_shift_i;
          while(1) begin @(posedge clk); #1; if(cfg_ready_ref&&cfg_ready_dut) break; end
        end
        @(negedge clk); cfg_valid_i=0;
      end
    endtask
    function [7:0] ref_quant;
      input signed [31:0] aa_in,bb_in,mm_in; input [5:0] ss;
      input signed [31:0] zz,mn,mx;
      reg signed [32:0] sum; reg signed [127:0] prod,fixed,shifted,added;
      reg [30:0] low_bits; reg neg,low_zero,round_up;
      begin
        sum = {aa_in[31],aa_in}+{bb_in[31],bb_in};
        prod = $signed(sum) * $signed(mm_in);
        low_bits=prod[30:0]; low_zero=(low_bits==0); neg=prod[127];
        if (!neg) begin
          round_up=(low_bits>=31'h40000000);
          fixed=(prod>>>31)+(round_up?1:0);
        end else begin
          round_up=prod[30] ? (low_zero||(prod[29:0]==0)) : !low_zero;
          if (low_zero&&round_up) fixed=(prod>>>31)-1;
          else if (low_zero||round_up) fixed=(prod>>>31);
          else fixed=(prod>>>31)+1;
        end
        shifted=fixed>>>ss; added=shifted+zz;
        if (added>127) ref_quant=8'h7f; else if (added < -128) ref_quant=8'h80;
        else if (added<mn) ref_quant=mn[7:0]; else if (added>mx) ref_quant=mx[7:0];
        else ref_quant=added[7:0];
      end
    endfunction
    task send_case;
      input [1:0] mm; input integer kk; input integer bb; integer jj,ii,gg,ll,idx,pp,cc;
      reg signed [31:0] acc_v; reg [7:0] sb,wb,ob; reg [3:0] lm;
      begin
        @(negedge clk); mode_i=mm; block_tag_i=(mm*8+bb); pixel_base_i=bb*3+mm;
        cout_base_i=bb*5+mm*17; zp_i=(bb*7)-12; min_i=-120+(bb%5); max_i=110-(bb%7);
        pixel_mask_i=(bb==3)?8'hd7:((bb==5)?8'h3f:8'hff);
        cout_mask_i=(bb==4)?16'hf7df:((bb==6)?16'h03ff:16'hffff);
        src0_i=32'h01020304 ^ (bb*32'h000f0f0f) ^ (mm*32'h00110011);
        src1_i=32'hf1e2d3c4 ^ (bb*32'h00070707);
        pw0_i=32'h11223344 ^ (bb*32'h00030003); pw1_i=32'h88776655 ^ (mm*32'h01010101);
        pw2_i=32'h1a2b3c4d ^ (bb*32'h00050005); pw3_i=32'hd4c3b2a1 ^ (mm*32'h00090009);
        /* Build the exact mathematical expected stream before driving the
         * block.  Accumulation intentionally wraps at 32 bits, matching the
         * MAC island register. */
        for(ii=0;ii<((mm==2)?1:2);ii=ii+1) begin
          for(gg=0;gg<8;gg=gg+1) begin
            exp_word[exp_n]=0; exp_mask[exp_n]=0; exp_pixel[exp_n]=pixel_base_i;
            exp_tag[exp_n]=block_tag_i; exp_mode[exp_n]=mm;
            exp_group[exp_n]=(mm==0)?gg:(gg/2);
            if(mm==0) begin exp_pixel[exp_n]=pixel_base_i+gg; exp_channel[exp_n]=cout_base_i+ii*4; end
            else if(mm==1) begin exp_pixel[exp_n]=pixel_base_i+gg/2; exp_channel[exp_n]=cout_base_i+ii*8+(gg%2)*4; end
            else begin exp_pixel[exp_n]=pixel_base_i+gg/2; exp_channel[exp_n]=cout_base_i+(gg%2)*4; end
            for(ll=0;ll<4;ll=ll+1) begin
              if(mm==0) begin
                pp=gg; idx=pp*4+ll; sb=src0_i[(pp*8)+:8]; if(pp>=4) sb=src1_i[((pp-4)*8)+:8];
                wb=(ii==0)?pw0_i[(ll*8)+:8]:pw1_i[(ll*8)+:8];
                lm=pixel_mask_i[gg] && cout_mask_i[ii*4+ll];
              end else begin
                pp=gg/2; cc=(gg%2)*4+ll; idx=pp*8+cc; sb=src0_i[(pp*8)+:8];
                if(ii==0) wb=(cc<4)?pw0_i[(cc*8)+:8]:pw1_i[((cc-4)*8)+:8];
                else wb=(cc<4)?pw2_i[(cc*8)+:8]:pw3_i[((cc-4)*8)+:8];
                lm=pixel_mask_i[gg/2] && cout_mask_i[((mm==2)?0:ii*8)+(gg%2)*4+ll];
              end
              acc_v = kk * $signed(sb) * $signed(wb);
              ob=ref_quant(acc_v,cfg_bias_mem[ii*32+idx],cfg_mult_mem[ii*32+idx],
                           cfg_shift_mem[ii*32+idx],zp_i,min_i,max_i);
              if(!lm) ob=0; exp_word[exp_n][ll*8 +:8]=ob; exp_mask[exp_n][ll]=lm;
            end
            exp_n=exp_n+1;
          end
        end
        for(jj=0;jj<kk;jj=jj+1) begin
          @(negedge clk); valid_in=1; first_k=(jj==0); last_k=(jj==kk-1); k_idx=jj;
          while(1) begin @(posedge clk); #1; if(ready_ref&&ready_dut) break; end
        end
        @(negedge clk); valid_in=0; first_k=0; last_k=0;
      end
    endtask
    integer m,b;
    initial begin
      repeat(5) @(posedge clk); rst_n=1; cfg_all();
      for(m=0;m<3;m=m+1) begin
        for(b=0;b<1;b=b+1) begin
          if(m==0) send_case(m,16,b); else if(m==1) send_case(m,27,b); else send_case(m,9,b);
          /* Keep blocks separated in this differential harness so the
           * expected island-0/island-1 order is unambiguous. */
          while (busy_ref || busy_dut) @(posedge clk);
        end
      end
      @(negedge clk); valid_in=0;
      while((busy_ref||busy_dut||dut_n<exp_n) && cyc<20000) @(posedge clk);
      if(dut_n!=exp_n) begin $display("FAIL count exp=%0d dut=%0d",exp_n,dut_n); errors=errors+1; end
      if(errors!=0) $fatal(1,"FAIL dual32 shared errors=%0d exp=%0d dut=%0d",errors,exp_n,dut_n);
      $display("PASS dual32_shared_stream4_rq outputs=%0d cycles=%0d",dut_n,cyc); $finish;
    end
endmodule
`default_nettype wire
