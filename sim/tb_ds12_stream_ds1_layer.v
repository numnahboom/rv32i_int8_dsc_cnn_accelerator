`timescale 1ns/1ps
`default_nettype none
module tb_ds12_stream_ds1_layer;
    localparam integer DS1_CFG=308, DS2_CFG=872, CFG_TOTAL=1180;
    localparam integer INPUT_BYTES=16384, OUTPUT_BYTES=32768, OUTPUT_WORDS=8192;
    localparam integer MAX_CYCLES=30000;
    reg clk=0, rst_n=0, start=0;
    always #5 clk=~clk;
    wire cfg_req_valid; reg cfg_req_ready; wire [31:0] cfg_req_addr; wire [3:0] cfg_req_strb;
    wire [1:0] cfg_req_layer; wire [15:0] cfg_req_index; reg cfg_resp_valid; reg [31:0] cfg_resp_data;
    wire in_req_valid; reg in_req_ready; wire in_req_write; wire [31:0] in_req_addr;
    wire [127:0] in_req_wdata; wire [15:0] in_req_strb; wire [1:0] in_req_context; wire in_req_owner; wire [31:0] in_req_epoch;
    reg in_resp_valid; reg [127:0] in_resp_data;
    wire out_valid; reg out_ready; wire out_bank; wire [31:0] out_epoch, out_addr, out_data; wire [3:0] out_be; wire out_last;
    wire layer_done, dut_error, ds1_cfg_done, ds2_cfg_done; wire [31:0] cycle_count, dw_first, dw_last, pw_first, pw_last, overlap, dw_idle, pw_idle;
    wire [31:0] dw_mac, pw_mac, out_count, cfg_reads, cfg_writes; wire [1:0] cfg_layer; wire [31:0] cfg_epoch; wire cfg_bank;
    wire [1:0] ab0, ab1; wire [31:0] aw_count, aw_expected, input_count, dw_vectors; wire aw_last, commit_done;
    ds12_stream_ds1_layer dut (
        .clk(clk),.rst_n(rst_n),.start(start), .cfg_mem_req_valid(cfg_req_valid),.cfg_mem_req_ready(cfg_req_ready),
        .cfg_mem_req_addr(cfg_req_addr),.cfg_mem_req_strb(cfg_req_strb),.cfg_mem_req_layer(cfg_req_layer),.cfg_mem_req_word_index(cfg_req_index),
        .cfg_mem_resp_valid(cfg_resp_valid),.cfg_mem_resp_data(cfg_resp_data), .input_mem_req_valid(in_req_valid),.input_mem_req_ready(in_req_ready),
        .input_mem_req_write(in_req_write),.input_mem_req_addr(in_req_addr),.input_mem_req_wdata(in_req_wdata),.input_mem_req_strb(in_req_strb),
        .input_mem_req_context(in_req_context),.input_mem_req_owner(in_req_owner),.input_mem_req_epoch(in_req_epoch),
        .input_mem_resp_valid(in_resp_valid),.input_mem_resp_data(in_resp_data), .output_write_valid(out_valid),.output_ready(out_ready),
        .output_write_bank(out_bank),.output_write_epoch(out_epoch),.output_write_addr(out_addr),.output_write_data(out_data),.output_write_be(out_be),.output_write_last(out_last),
        .layer_done(layer_done),.error(dut_error),.ds1_config_done(ds1_cfg_done),.ds2_preload_done(ds2_cfg_done),.cycle_count(cycle_count),
        .dw_first_cycle(dw_first),.dw_last_cycle(dw_last),.pw_first_cycle(pw_first),.pw_last_cycle(pw_last),.overlap_cycles(overlap),.dw_idle_cycles(dw_idle),.pw_idle_cycles(pw_idle),
        .dw_mac_count(dw_mac),.pw_mac_count(pw_mac),.output_word_count(out_count),.config_read_count(cfg_reads),.config_write_count(cfg_writes),
        .active_config_layer(cfg_layer),.active_config_epoch(cfg_epoch),.active_config_bank(cfg_bank),.activation_bank0_state(ab0),.activation_bank1_state(ab1),
        .activation_write_count(aw_count),.activation_commit_done(commit_done),.activation_write_expected_bytes(aw_expected),.activation_write_last_seen(aw_last),
        .ds1_input_read_count(input_count),.ds1_dw_vector_count(dw_vectors));

    reg [31:0] cfg1[0:DS1_CFG-1], cfg2[0:DS2_CFG-1];
    reg [7:0] in_bytes[0:INPUT_BYTES-1], expected[0:OUTPUT_BYTES-1];
    reg cfg_pending; integer cfg_delay; reg [31:0] cfg_pending_data; integer cfg_lfsr;
    reg in_pending; integer in_delay; integer in_lfsr; integer in_pending_addr;
    integer fd, rc, layer, kind, idx, address, mask, data_word, i, j;
    integer sink_seen, sink_errors, cycles, overlap_seen;
    reg seen_word[0:OUTPUT_WORDS-1];
    integer input_req_seen; integer expected_addr;
    reg [31:0] rand_lfsr, cfg_ready_lfsr, in_ready_lfsr;

    initial begin
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_input_i8.hex", in_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_output_i8.hex", expected);
        fd=$fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex","r");
        if (!fd) $fatal(1,"missing reference config transactions");
        i=0; while (!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %h %h %h\n",layer,kind,idx,address,mask,data_word);
            if (rc==6 && layer==1 && idx<DS1_CFG) cfg1[idx]=data_word;
            if (rc==6 && layer==2 && idx<DS2_CFG) cfg2[idx]=data_word;
            if (rc==6) i=i+1;
        end
        $fclose(fd);
    end
`ifdef DS12_NO_BP
    assign cfg_req_ready = !cfg_pending && !cfg_resp_valid;
`else
    assign cfg_req_ready = !cfg_pending && !cfg_resp_valid && ((cfg_ready_lfsr & 8'hff) != 0);
`endif
    always @(posedge clk) begin
        if (!rst_n) begin cfg_pending<=0; cfg_resp_valid<=0; cfg_resp_data<=0; cfg_delay=0; cfg_lfsr=32'h19; end
        else begin
            cfg_resp_valid<=0;
            if (cfg_pending) begin
                if (cfg_resp_valid) cfg_pending<=0;
                else if (cfg_delay>0) cfg_delay=cfg_delay-1;
                else begin cfg_resp_data<=cfg_pending_data; cfg_resp_valid<=1; cfg_pending<=0; end
            end else if (cfg_req_valid && cfg_req_ready) begin
                if (cfg_req_strb!=4'hf || cfg_req_addr[1:0]!=0) $fatal(1,"bad config request");
                if (cfg_req_layer==1) cfg_pending_data<=cfg1[cfg_req_index];
                else if (cfg_req_layer==2) cfg_pending_data<=cfg2[cfg_req_index];
                else $fatal(1,"bad config layer");
                cfg_lfsr={cfg_lfsr[30:0],cfg_lfsr[31]^cfg_lfsr[21]^cfg_lfsr[1]^cfg_lfsr[0]};
`ifdef DS12_NO_BP
                if (cfg_req_layer==1) cfg_resp_data<=cfg1[cfg_req_index]; else cfg_resp_data<=cfg2[cfg_req_index];
                cfg_resp_valid<=1; cfg_pending<=1;
`else
                // Mostly same-cycle acceptance plus sparse delayed returns
                // exercises the response bookkeeping without hiding the
                // layer latency behind an artificial serial memory model.
                cfg_delay=((cfg_req_index[5:0]) == 0);
                if (cfg_delay == 0) begin
                    if (cfg_req_layer==1) cfg_resp_data<=cfg1[cfg_req_index]; else cfg_resp_data<=cfg2[cfg_req_index];
                    cfg_resp_valid<=1;
                end
                cfg_pending<=1;
`endif
            end
        end
    end
`ifdef DS12_NO_BP
    assign in_req_ready = !in_pending && !in_resp_valid;
`else
    assign in_req_ready = !in_pending && !in_resp_valid && ((in_ready_lfsr & 8'hff) != 0);
`endif
    always @(posedge clk) begin
        if (!rst_n) begin in_pending<=0; in_resp_valid<=0; in_resp_data<=0; in_delay=0; in_lfsr=32'h2d; input_req_seen=0; end
        else begin
            in_resp_valid<=0;
            if (in_pending) begin
                if (in_resp_valid) in_pending<=0;
                else if (in_delay>0) in_delay=in_delay-1;
                else begin
                    in_resp_data<=0;
                    for (j=0;j<16;j=j+1) in_resp_data[j*8 +: 8]<=in_bytes[in_pending_addr+j];
                    in_resp_valid<=1; in_pending<=0;
                end
            end else if (in_req_valid && in_req_ready) begin
                if (in_req_write || in_req_strb!=0 || in_req_addr[3:0]!=0 || in_req_addr>=INPUT_BYTES ||
                    in_req_addr != input_req_seen*16) $fatal(1,"bad input request n=%0d addr=%0d",input_req_seen,in_req_addr);
                if (in_req_context != ((input_req_seen/8)&3) || in_req_owner != ((input_req_seen/8)&1) || in_req_epoch != ((input_req_seen/8)/2))
                    $fatal(1,"bad input tag n=%0d",input_req_seen);
                in_pending_addr<=in_req_addr; in_pending<=1; input_req_seen=input_req_seen+1;
                in_lfsr={in_lfsr[30:0],in_lfsr[31]^in_lfsr[21]^in_lfsr[1]^in_lfsr[0]}; in_delay=((input_req_seen % 64) == 0);
`ifdef DS12_NO_BP
                in_resp_data<=0;
                for (j=0;j<16;j=j+1) in_resp_data[j*8 +: 8]<=in_bytes[in_req_addr+j];
                in_resp_valid<=1;
`else
                if (in_delay == 0) begin
                    in_resp_data<=0;
                    for (j=0;j<16;j=j+1) in_resp_data[j*8 +: 8]<=in_bytes[in_req_addr+j];
                    in_resp_valid<=1;
                end
`endif
            end
        end
    end
    always @(negedge clk) begin
        if (!rst_n) begin out_ready<=1; rand_lfsr<=32'h61; cfg_ready_lfsr<=32'h9b; in_ready_lfsr<=32'he7; end
        else begin
            rand_lfsr<={rand_lfsr[30:0],rand_lfsr[31]^rand_lfsr[21]^rand_lfsr[1]^rand_lfsr[0]};
            cfg_ready_lfsr<={cfg_ready_lfsr[30:0],cfg_ready_lfsr[31]^cfg_ready_lfsr[21]^cfg_ready_lfsr[1]^cfg_ready_lfsr[0]};
            in_ready_lfsr<={in_ready_lfsr[30:0],in_ready_lfsr[31]^in_ready_lfsr[21]^in_ready_lfsr[1]^in_ready_lfsr[0]};
`ifdef DS12_NO_BP
            out_ready<=1'b1;
`else
            out_ready<=(rand_lfsr[7:0] != 0);
`endif
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin sink_seen=0; sink_errors=0; cycles=0; end
        else begin
            cycles=cycles+1;
            if (out_valid && out_ready) begin
                if (out_bank!==1'b1 || out_epoch!==32'd1 || out_be!==4'hf || out_addr[1:0]!=0 || (out_addr/4)>=OUTPUT_WORDS || seen_word[out_addr/4] || out_data[7:0]!==expected[(out_addr/4)*4] || out_data[15:8]!==expected[(out_addr/4)*4+1] || out_data[23:16]!==expected[(out_addr/4)*4+2] || out_data[31:24]!==expected[(out_addr/4)*4+3]) begin
                    sink_errors=sink_errors+1; if (sink_errors<4) $display("OUTPUT_MISMATCH n=%0d addr=%h data=%h",sink_seen,out_addr,out_data);
                end
                else seen_word[out_addr/4]=1'b1;
                sink_seen=sink_seen+1;
            end
        end
    end
    initial begin
        for (i=0;i<OUTPUT_WORDS;i=i+1) seen_word[i]=1'b0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk); start=1; @(posedge clk); start=0;
        while (!layer_done && cycles<MAX_CYCLES) @(posedge clk);
        $display("DS12_DS1_LAYER cycles=%0d done=%0d err=%0d cfg=%0d/%0d active=%0d/%0d/b%0d ds2=%0d input=%0d vectors=%0d dwmac=%0d pwmac=%0d words=%0d writes=%0d banks=%0d/%0d overlap=%0d dw=%0d..%0d pw=%0d..%0d idle=%0d/%0d",cycles,layer_done,dut_error,cfg_reads,cfg_writes,cfg_layer,cfg_epoch,cfg_bank,ds2_cfg_done,input_count,dw_vectors,dw_mac,pw_mac,out_count,aw_count,ab0,ab1,overlap,dw_first,dw_last,pw_first,pw_last,dw_idle,pw_idle);
`ifdef DS12_NO_BP
        if (!layer_done || dut_error || !ds1_cfg_done || !ds2_cfg_done || cfg_reads!=CFG_TOTAL || cfg_writes!=CFG_TOTAL || cfg_layer!=2 || cfg_epoch!=2 || cfg_bank!=0 || dw_mac!=147456 || pw_mac!=524288 || out_count!=OUTPUT_WORDS || sink_seen!=OUTPUT_WORDS || sink_errors!=0 || aw_count!=OUTPUT_BYTES || aw_expected!=OUTPUT_BYTES || !aw_last || !commit_done || ab0!=0 || ab1!=1 || overlap==0 || dw_vectors!=1024 || cycles>12500)
`else
        if (!layer_done || dut_error || !ds1_cfg_done || !ds2_cfg_done || cfg_reads!=CFG_TOTAL || cfg_writes!=CFG_TOTAL || cfg_layer!=2 || cfg_epoch!=2 || cfg_bank!=0 || dw_mac!=147456 || pw_mac!=524288 || out_count!=OUTPUT_WORDS || sink_seen!=OUTPUT_WORDS || sink_errors!=0 || aw_count!=OUTPUT_BYTES || aw_expected!=OUTPUT_BYTES || !aw_last || !commit_done || ab0!=0 || ab1!=1 || overlap==0 || dw_vectors!=1024)
`endif
            $fatal(2,"DS12 DS1 layer acceptance failed");
        $finish(0);
    end
endmodule
`default_nettype wire
