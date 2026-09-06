`timescale 1ns/1ps
`default_nettype none

// DS2 DW compute boundary test.  The reader below is the checked-in
// ds12_stream_ds2_window_vector_reader; its memory side is a delayed 128-bit
// bank model, so this TB drives the real 4-context 4,608-beat reader stream.
// Configuration is loaded through the real packed config bank, not constants.
module tb_ds12_stream_ds2_dw_compute;
    localparam integer PIXELS=256, INPUT_BYTES=32768, OUTPUT_BYTES=8192, CFG_WORDS=872;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0;
    reg start_valid,start_bank,start_last; reg [5:0] start_row,start_col; reg [31:0] start_epoch;
    wire start_ready, win_valid, win_ready; wire [127:0] win_data;
    wire [5:0] win_row,win_col; wire [1:0] win_tr,win_tc,win_ctx; wire win_slice,win_owner,win_last; wire [31:0] win_epoch;
    wire rd_req_valid,rd_req_ready,rd_req_bank; wire [31:0] rd_req_epoch,rd_req_addr;
    wire rd_resp_valid; reg [127:0] rd_resp_data_r; wire [127:0] rd_resp_data=rd_resp_data_r; wire rd_resp_ready; reg rd_resp_bank_r; reg [31:0] rd_resp_epoch_r,rd_resp_addr_r; wire rd_resp_bank=rd_resp_bank_r; wire [31:0] rd_resp_epoch=rd_resp_epoch_r,rd_resp_addr=rd_resp_addr_r;
    wire reader_busy; wire [3:0] reader_active,reader_peak; wire [31:0] reader_reads,reader_vectors; wire reader_error; wire [7:0] reader_error_code;
    reg cfg_start; wire cfg_start_ready; wire cfg_req_valid,cfg_req_ready; wire [31:0] cfg_req_addr; wire [3:0] cfg_req_strb; wire [15:0] cfg_req_index;
    reg cfg_resp_valid; reg [31:0] cfg_resp_data; wire cfg_resp_ready; wire cfg_load_done,cfg_active_valid,cfg_active_bank; wire [1:0] cfg_active_layer; wire [31:0] cfg_active_epoch;
    wire cfg_busy,cfg_error; wire [3:0] cfg_error_code; wire [15:0] cfg_received;
    wire c_cfg_en,c_cfg_bank,c_cfg_valid; wire [15:0] c_cfg_addr,cfg_index; wire [31:0] c_cfg_data,cfg_payload;
    reg compute_start; wire compute_ready; wire c_win_ready; wire c_dw_valid,c_dw_ready; wire [127:0] c_dw_data; wire [5:0] c_dw_row; wire [7:0] c_dw_pixel; wire c_dw_group; wire [1:0] c_dw_ctx; wire c_dw_owner; wire [31:0] c_dw_epoch; wire c_dw_last;
    wire c_done,c_error; wire [7:0] c_error_code; wire [31:0] c_win_count,c_dw_count,c_mac_count,c_pad_count,c_cfg_reads; wire [3:0] c_peak;
    reg [7:0] input_bytes[0:INPUT_BYTES-1]; reg [7:0] expected[0:OUTPUT_BYTES-1]; reg [31:0] cfg_words[0:CFG_WORDS-1];
    reg [1:0] pixel_ctx[0:PIXELS-1]; reg pixel_ctx_seen[0:PIXELS-1];
    integer fd,rc,layer,kind,index,address,mask,data_word; integer i,j;
    integer cycles,perf_start,perf_cycles,inputs_seen,outputs_seen,errors,window_stalls; reg random_mode; reg [31:0] lfsr;
    reg out_hold; reg [127:0] held_dw_data; reg [7:0] held_dw_pixel; reg held_dw_group; reg [1:0] held_dw_ctx; reg [31:0] held_dw_epoch;
    reg mem_pending; reg [31:0] mem_addr; integer mem_delay;

    ds12_stream_ds2_window_vector_reader #(.CONTEXTS(4)) reader (
      .clk(clk),.rst_n(rst_n),.window_start_valid(start_valid),.window_start_ready(start_ready),.window_start_row(start_row),.window_start_col(start_col),.window_start_bank(start_bank),.window_start_epoch(start_epoch),.window_start_last(start_last),
      .window_valid(win_valid),.window_ready(win_ready),.window_data(win_data),.window_row(win_row),.window_col(win_col),.window_tap_row(win_tr),.window_tap_col(win_tc),.window_channel_slice(win_slice),.window_context(win_ctx),.window_owner(win_owner),.window_epoch(win_epoch),.window_last(win_last),
      .read_req_valid(rd_req_valid),.read_req_ready(rd_req_ready),.read_req_bank(rd_req_bank),.read_req_epoch(rd_req_epoch),.read_req_addr(rd_req_addr),.read_resp_valid(rd_resp_valid),.read_resp_ready(rd_resp_ready),.read_resp_data(rd_resp_data),.read_resp_bank(rd_resp_bank),.read_resp_epoch(rd_resp_epoch),.read_resp_addr(rd_resp_addr),.busy(reader_busy),.context_active(reader_active),.context_peak(reader_peak),.read_count(reader_reads),.window_count(reader_vectors),.error(reader_error),.error_code(reader_error_code));
    ds12_stream_config_banks #(.BANK_WORDS(872),.REQUEST_FIFO_WORDS(1024)) cfg (
      .clk(clk),.rst_n(rst_n),.start(cfg_start),.start_layer(2'd2),.start_base_addr(0),.start_word_count(872),.start_epoch(start_epoch),.start_ready(cfg_start_ready),.mem_req_valid(cfg_req_valid),.mem_req_ready(cfg_req_ready),.mem_req_addr(cfg_req_addr),.mem_req_strb(cfg_req_strb),.mem_req_word_index(cfg_req_index),.mem_resp_valid(cfg_resp_valid),.mem_resp_ready(cfg_resp_ready),.mem_resp_rdata(cfg_resp_data),.commit_req(0),.clear_error(0),.cfg_rd_en(c_cfg_en),.cfg_rd_bank(c_cfg_bank),.cfg_rd_addr(c_cfg_addr),.cfg_rd_data(c_cfg_data),.cfg_rd_valid(c_cfg_valid),.busy(cfg_busy),.active_bank(cfg_active_bank),.active_layer(cfg_active_layer),.active_epoch(cfg_active_epoch),.active_valid(cfg_active_valid),.bank_valid(),.expected_count(),.issued_count(),.received_count(cfg_received),.load_crc32(),.load_done(cfg_load_done),.error(cfg_error),.error_code(cfg_error_code));
    ds12_stream_ds2_dw_compute compute (
      .clk(clk),.rst_n(rst_n),.start(compute_start),.ready(compute_ready),.cfg_rd_en(c_cfg_en),.cfg_rd_bank(c_cfg_bank),.cfg_rd_addr(c_cfg_addr),.cfg_rd_data(c_cfg_data),.cfg_rd_valid(c_cfg_valid),.cfg_active_valid(cfg_active_valid),.cfg_active_layer(cfg_active_layer),.cfg_active_bank(cfg_active_bank),.cfg_active_epoch(cfg_active_epoch),.config_index(cfg_index),.config_payload(cfg_payload),
      .window_valid(win_valid),.window_ready(c_win_ready),.window_data(win_data),.window_row(win_row),.window_col(win_col),.window_tap_row(win_tr),.window_tap_col(win_tc),.window_channel_slice(win_slice),.window_context(win_ctx),.window_owner(win_owner),.window_epoch(win_epoch),.window_last(win_last),
      .dw_valid(c_dw_valid),.dw_ready(c_dw_ready),.dw_data(c_dw_data),.dw_row(c_dw_row),.dw_pixel(c_dw_pixel),.dw_group(c_dw_group),.dw_context(c_dw_ctx),.dw_owner(c_dw_owner),.dw_epoch(c_dw_epoch),.dw_last(c_dw_last),.done(c_done),.error(c_error),.error_code(c_error_code),.window_vector_count(c_win_count),.dw_vector_count(c_dw_count),.dw_mac_count(c_mac_count),.padding_tap_count(c_pad_count),.context_peak(c_peak),.config_read_count(c_cfg_reads));
    assign win_ready=c_win_ready; assign rd_req_ready=1'b1; assign cfg_req_ready=1'b1; assign c_dw_ready = !random_mode || lfsr[2] || lfsr[5];
    assign rd_resp_valid = mem_pending && (mem_delay == 0);

    function automatic [31:0] next_lfsr(input [31:0] x); next_lfsr={x[30:0],x[31]^x[21]^x[1]^x[0]}; endfunction
    // Delayed bank response.  Address is the reader's byte address and is
    // deliberately checked against the DS2 32-byte pixel layout.
    always @(posedge clk) begin
      if (!rst_n) begin mem_pending<=0; rd_resp_data_r<=0; cfg_resp_valid<=0; rd_resp_bank_r<=0; rd_resp_epoch_r<=0; rd_resp_addr_r<=0; end else begin
        cfg_resp_valid<=0;
        if (mem_pending && rd_resp_valid && rd_resp_ready && !(rd_req_valid && rd_req_ready)) mem_pending<=0;
        if (mem_pending && mem_delay>0) mem_delay=mem_delay-1;
        if (rd_req_valid && rd_req_ready) begin
          mem_addr<=rd_req_addr; rd_resp_addr_r<=rd_req_addr; rd_resp_bank_r<=rd_req_bank; rd_resp_epoch_r<=rd_req_epoch; for(j=0;j<16;j=j+1) rd_resp_data_r[j*8 +: 8] <= input_bytes[rd_req_addr+j]; mem_pending<=1; mem_delay=random_mode ? (lfsr[1:0]+1) : 0;
        end
        if (cfg_req_valid && cfg_req_ready) begin cfg_resp_data<=cfg_words[cfg_req_index]; cfg_resp_valid<=1; end
      end
    end
    always @(posedge clk) if (rst_n) begin
      cycles=cycles+1; lfsr<=next_lfsr(lfsr);
      if (win_valid && !win_ready) window_stalls=window_stalls+1;
      if (win_valid && win_ready) begin
        inputs_seen=inputs_seen+1;
        if (win_row>=16 || win_col>=16 || win_tr>2 || win_tc>2 || win_slice>1) errors=errors+1;
        else begin
          if (!win_slice && win_tr==0 && win_tc==0) begin pixel_ctx[win_row*16+win_col]<=win_ctx; pixel_ctx_seen[win_row*16+win_col]<=1; end
          for(j=0;j<16;j=j+1) begin
            if ((win_row*2+win_tr-1)<0 || (win_row*2+win_tr-1)>=32 || (win_col*2+win_tc-1)<0 || (win_col*2+win_tc-1)>=32) begin
              if (win_data[j*8 +: 8]!==0) errors=errors+1;
            end else if (win_data[j*8 +: 8] !== input_bytes[((win_row*2+win_tr-1)*32+(win_col*2+win_tc-1))*32+win_slice*16+j]) errors=errors+1;
          end
        end
        if (inputs_seen==1) perf_start=cycles;
      end
      if (c_dw_valid && c_dw_ready) begin
        if (c_dw_pixel>=256 || c_dw_row!==(c_dw_pixel/16) || c_dw_group>1 || c_dw_owner!==1 || c_dw_epoch!==start_epoch || !pixel_ctx_seen[c_dw_pixel] || c_dw_ctx!==pixel_ctx[c_dw_pixel]) errors=errors+1;
        for(j=0;j<16;j=j+1) if (c_dw_data[j*8 +: 8] !== expected[c_dw_pixel*32+c_dw_group*16+j]) errors=errors+1;
        if (c_dw_last !== (c_dw_pixel==255 && c_dw_group==1)) errors=errors+1;
        outputs_seen=outputs_seen+1; if(outputs_seen==512) perf_cycles=cycles-perf_start;
        out_hold=0;
      end else if (c_dw_valid && !c_dw_ready) begin
        if (out_hold && (c_dw_data!==held_dw_data || c_dw_pixel!==held_dw_pixel || c_dw_group!==held_dw_group || c_dw_ctx!==held_dw_ctx || c_dw_epoch!==held_dw_epoch)) errors=errors+1;
        held_dw_data=c_dw_data; held_dw_pixel=c_dw_pixel; held_dw_group=c_dw_group; held_dw_ctx=c_dw_ctx; held_dw_epoch=c_dw_epoch; out_hold=1;
      end
    end
    task load_cfg; begin @(negedge clk); cfg_start<=1; while(!cfg_start_ready) @(negedge clk); @(posedge clk); @(negedge clk); cfg_start<=0; while(!cfg_load_done) @(posedge clk); $display("cfg loaded t=%0t received=%0d bank=%0d",$time,cfg_received,cfg_active_bank); end endtask
    task start_windows; begin for(i=0;i<256;i=i+1) begin @(negedge clk); start_row<=i/16; start_col<=i%16; start_bank<=1; start_epoch<=start_epoch; start_last<=(i==255); start_valid<=1; while(!start_ready) @(negedge clk); @(posedge clk); @(negedge clk); start_valid<=0; end end endtask
    task run_case; input integer rm; begin
      random_mode=rm; rst_n=0; start_valid=0; cfg_start=0; compute_start=0; mem_pending=0; inputs_seen=0; outputs_seen=0; errors=0; window_stalls=0; cycles=0; perf_start=0; perf_cycles=0; out_hold=0; lfsr=32'h1; start_epoch=rm?32'h12:32'h11; $display("run case %0d",rm);
      for(i=0;i<256;i=i+1) pixel_ctx_seen[i]=0;
      repeat(3) @(posedge clk); rst_n=1; load_cfg; @(negedge clk); compute_start=1; while(!compute_ready) @(negedge clk); @(posedge clk); @(negedge clk); compute_start=0; start_windows;
      while(!c_done) begin @(posedge clk); if(cycles>100000) $fatal(1,"timeout case=%0d in=%0d out=%0d",rm,inputs_seen,outputs_seen); end
      perf_cycles=cycles-perf_start;
      if(inputs_seen!=4608 || outputs_seen!=512 || c_win_count!=4608 || c_dw_count!=512 || c_mac_count!=73728 || c_pad_count!=95 || c_cfg_reads!=168 || errors!=0 || c_error || reader_error || cfg_error) $fatal(1,"FAIL case=%0d in=%0d out=%0d mac=%0d pad=%0d cfg=%0d errors=%0d ce=%0d/%h re=%0d/%h ge=%0d/%h",rm,inputs_seen,outputs_seen,c_mac_count,c_pad_count,c_cfg_reads,errors,c_error,c_error_code,reader_error,reader_error_code,cfg_error,cfg_error_code);
      if(!rm && perf_cycles>5000) $fatal(1,"no-backpressure gate cycles=%0d stalls=%0d",perf_cycles,window_stalls);
      $display("DS12_DS2_DW_CASE_PASS random=%0d cycles=%0d input_vectors=%0d output_vectors=%0d mac=%0d padding=%0d config_reads=%0d context_peak=%0d window_stalls=%0d",rm,perf_cycles,inputs_seen,outputs_seen,c_mac_count,c_pad_count,c_cfg_reads,c_peak,window_stalls);
    end endtask
    initial begin
      $readmemh("build/ds12_stream_harness/ds12_stream_ds2_input_i8.hex",input_bytes); $readmemh("build/ds12_stream_harness/ds12_stream_ds2_dw_output_i8.hex",expected);
      fd=$fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex","r"); if(fd==0)$fatal(1,"missing cfg"); i=0; while(!$feof(fd)) begin rc=$fscanf(fd,"%d %d %d %h %h %h\n",layer,kind,index,address,mask,data_word); if(rc==6 && layer==2 && i<872) begin cfg_words[i]=data_word; i=i+1; end end $fclose(fd); if(i!=872)$fatal(1,"cfg words=%0d",i);
      run_case(0); run_case(1); $display("DS12_DS2_DW_COMPUTE_PASS bit_exact=1 real_config_bank=1 reader_stream=1 backpressure=1"); $finish(0);
    end
endmodule
`default_nettype wire
