`timescale 1ns/1ps
`default_nettype none

// DS2 PW boundary TB.  It uses the real packed-bank loader and the generated
// DS2 DW reference vectors, while permuting pixels, delaying bank responses,
// stalling the DW source and applying sink backpressure.
module tb_ds12_stream_ds2_pw_consumer;
    localparam integer PIXELS=256, DW_VECTORS=512, CFG_WORDS=872;
    localparam integer DW_BYTES=PIXELS*32, OUT_BYTES=PIXELS*64;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0;

    reg cfg_start; wire cfg_start_ready;
    wire mem_req_valid; wire mem_req_ready; wire [31:0] mem_req_addr;
    wire [3:0] mem_req_strb; wire [15:0] mem_req_word_index;
    reg mem_resp_valid; wire mem_resp_ready; reg [31:0] mem_resp_rdata;
    wire cfg_load_done,cfg_active_valid,cfg_active_bank,cfg_busy,cfg_error;
    wire [1:0] cfg_active_layer; wire [31:0] cfg_active_epoch;
    wire [3:0] cfg_error_code; wire [15:0] cfg_received;
    wire [1:0] cfg_bank_valid; wire [15:0] cfg_expected_count,cfg_issued_count;
    wire [31:0] cfg_load_crc32;

    reg start; wire ready;
    wire cfg_rd_en,cfg_rd_bank,cfg_rd_valid; wire [15:0] cfg_rd_addr;
    wire [31:0] cfg_rd_data; wire [15:0] config_index; wire [31:0] config_payload;
    reg [127:0] dw_data; reg dw_valid; wire dw_ready; reg [5:0] dw_row;
    reg [7:0] dw_pixel; reg dw_group; reg [1:0] dw_context; reg dw_owner;
    reg [31:0] dw_epoch; reg dw_last;
    wire sink_valid; reg sink_ready; wire [31:0] sink_addr,sink_data;
    wire [3:0] sink_strb; wire [5:0] sink_row; wire [7:0] sink_pixel;
    wire [3:0] sink_word_in_pixel; wire [1:0] sink_context; wire sink_owner;
    wire [31:0] sink_epoch; wire sink_last; wire busy,done,error;
    wire [7:0] error_code; wire [31:0] cfg_read_count,cfg_weight_read_count;
    wire [31:0] dw_vector_count,pw_token_count,pw_mac_count,output_word_count;
    wire [3:0] partial_context_peak;

    reg [7:0] dw_bytes [0:DW_BYTES-1];
    reg [7:0] expected_bytes [0:OUT_BYTES-1];
    reg [31:0] cfg_words [0:CFG_WORDS-1];
    integer source_index, pidx_calc, grp_calc, b, j;
    integer tile_idx, kgroup_idx, weight_map_errors;
    integer expected_weight_index, weight_prefetch_checks, weight_prefetch_errors;
    integer cycles, first_cycle, last_cycle, errors, dw_accepts, sink_accepts;
    integer cfg_q_count, cfg_q_delay, cfg_q_index;
    integer compute_active_cycles, compute_segments, k_sequence_errors;
    integer dw_ready_stall_cycles, dw_input_gap_cycles, sink_stall_cycles;
    integer dw_commit_count, last_pending_cycles, result_pending_cycles, dsp_width_errors;
    reg compute_monitor_active;
    reg [7:0] compute_monitor_step;
    reg [31:0] lfsr;
    reg sink_stall_active;
    reg [31:0] stall_addr, stall_data, stall_epoch;
    reg [3:0] stall_strb, stall_word;
    reg [5:0] stall_row;
    reg [7:0] stall_pixel;
    reg [1:0] stall_context;
    reg stall_owner, stall_last;
    reg cfg_resp_valid_r; reg [31:0] cfg_resp_data_r;
    reg weight_map_checked;
    assign mem_req_ready = (cfg_q_count == 0) && !cfg_resp_valid_r && (lfsr[1:0] != 0);
    assign mem_resp_valid = cfg_resp_valid_r;
    assign mem_resp_rdata = cfg_resp_data_r;

    ds12_stream_config_banks #(.BANK_WORDS(872),.REQUEST_FIFO_WORDS(8)) cfg (
      .clk(clk),.rst_n(rst_n),.start(cfg_start),.start_layer(2'd2),.start_base_addr(0),.start_word_count(872),.start_epoch(1),.start_ready(cfg_start_ready),
      .mem_req_valid(mem_req_valid),.mem_req_ready(mem_req_ready),.mem_req_addr(mem_req_addr),.mem_req_strb(mem_req_strb),.mem_req_word_index(mem_req_word_index),
      .mem_resp_valid(mem_resp_valid),.mem_resp_ready(mem_resp_ready),.mem_resp_rdata(mem_resp_rdata),.commit_req(0),.clear_error(0),
      .cfg_rd_en(cfg_rd_en),.cfg_rd_bank(cfg_rd_bank),.cfg_rd_addr(cfg_rd_addr),.cfg_rd_data(cfg_rd_data),.cfg_rd_valid(cfg_rd_valid),
      .busy(cfg_busy),.active_bank(cfg_active_bank),.active_layer(cfg_active_layer),.active_epoch(cfg_active_epoch),.active_valid(cfg_active_valid),.bank_valid(cfg_bank_valid),.expected_count(cfg_expected_count),.issued_count(cfg_issued_count),.received_count(cfg_received),.load_crc32(cfg_load_crc32),.load_done(cfg_load_done),.error(cfg_error),.error_code(cfg_error_code));

    ds12_stream_ds2_pw_consumer dut (
      .clk(clk),.rst_n(rst_n),.start(start),.ready(ready),
      .cfg_rd_en(cfg_rd_en),.cfg_rd_bank(cfg_rd_bank),.cfg_rd_addr(cfg_rd_addr),.cfg_rd_data(cfg_rd_data),.cfg_rd_valid(cfg_rd_valid),
      .cfg_active_valid(cfg_active_valid),.cfg_active_layer(cfg_active_layer),.cfg_active_bank(cfg_active_bank),.cfg_active_epoch(cfg_active_epoch),.config_index(config_index),.config_payload(config_payload),
      .dw_valid(dw_valid),.dw_ready(dw_ready),.dw_data(dw_data),.dw_row(dw_row),.dw_pixel(dw_pixel),.dw_group(dw_group),.dw_context(dw_context),.dw_owner(dw_owner),.dw_epoch(dw_epoch),.dw_last(dw_last),
      .sink_valid(sink_valid),.sink_ready(sink_ready),.sink_addr(sink_addr),.sink_data(sink_data),.sink_strb(sink_strb),.sink_row(sink_row),.sink_pixel(sink_pixel),.sink_word_in_pixel(sink_word_in_pixel),.sink_context(sink_context),.sink_owner(sink_owner),.sink_epoch(sink_epoch),.sink_last(sink_last),
      .busy(busy),.done(done),.error(error),.error_code(error_code),.cfg_read_count(cfg_read_count),.cfg_weight_read_count(cfg_weight_read_count),.dw_vector_count(dw_vector_count),.pw_token_count(pw_token_count),.pw_mac_count(pw_mac_count),.output_word_count(output_word_count),.partial_context_peak(partial_context_peak));

    always @* begin
        dw_valid=0; dw_data=0; dw_pixel=0; dw_row=0; dw_group=0; dw_context=0; dw_owner=0; dw_epoch=0; dw_last=0;
        pidx_calc=0; grp_calc=0;
        if (source_index < DW_VECTORS) begin
            pidx_calc=((source_index/2)*73)%PIXELS; grp_calc=source_index%2;
            dw_valid=(lfsr[4:0] != 0) || (source_index[2:0] == 0);
            dw_pixel=pidx_calc[7:0]; dw_row={2'd0,pidx_calc[7:4]}; dw_group=grp_calc[0];
            dw_context=pidx_calc[4:3]; dw_owner=pidx_calc[5]; dw_epoch=32'd64+{30'd0,pidx_calc[7:6]};
            dw_last=(&pidx_calc[7:0]) && grp_calc[0];
            for (j=0;j<16;j=j+1) dw_data[j*8 +: 8]=dw_bytes[(pidx_calc[7:0]*32)+(grp_calc[0]*16)+j];
        end
    end
    always @* sink_ready=(lfsr[10:8] != 0);

    // Observe the internal token scheduler at the opposite clock edge.  A
    // compute segment must expose step 0..255 on consecutive cycles: the
    // lower five bits are K=0..31 and the upper three bits select Cout tile.
    // This makes an II=2 regression visible independently of the final count.
    always @(negedge clk) begin
        if (!rst_n) begin
            compute_active_cycles = 0;
            compute_segments = 0;
            k_sequence_errors = 0;
            weight_prefetch_checks = 0;
            weight_prefetch_errors = 0;
            compute_monitor_active = 1'b0;
            compute_monitor_step = 8'd0;
        end else if (dut.compute_active) begin
            compute_active_cycles = compute_active_cycles + 1;
            expected_weight_index = 168 +
                (((dut.compute_step[7:5] * 8) + 0) * 8) + dut.compute_step[4:2];
            if (dut.gen_weight_lane_bank[0].weight_prefetch_lane !== cfg_words[expected_weight_index]) weight_prefetch_errors = weight_prefetch_errors + 1;
            expected_weight_index = 168 +
                (((dut.compute_step[7:5] * 8) + 1) * 8) + dut.compute_step[4:2];
            if (dut.gen_weight_lane_bank[1].weight_prefetch_lane !== cfg_words[expected_weight_index]) weight_prefetch_errors = weight_prefetch_errors + 1;
            expected_weight_index = 168 +
                (((dut.compute_step[7:5] * 8) + 2) * 8) + dut.compute_step[4:2];
            if (dut.gen_weight_lane_bank[2].weight_prefetch_lane !== cfg_words[expected_weight_index]) weight_prefetch_errors = weight_prefetch_errors + 1;
            expected_weight_index = 168 +
                (((dut.compute_step[7:5] * 8) + 3) * 8) + dut.compute_step[4:2];
            if (dut.gen_weight_lane_bank[3].weight_prefetch_lane !== cfg_words[expected_weight_index]) weight_prefetch_errors = weight_prefetch_errors + 1;
            expected_weight_index = 168 +
                (((dut.compute_step[7:5] * 8) + 4) * 8) + dut.compute_step[4:2];
            if (dut.gen_weight_lane_bank[4].weight_prefetch_lane !== cfg_words[expected_weight_index]) weight_prefetch_errors = weight_prefetch_errors + 1;
            expected_weight_index = 168 +
                (((dut.compute_step[7:5] * 8) + 5) * 8) + dut.compute_step[4:2];
            if (dut.gen_weight_lane_bank[5].weight_prefetch_lane !== cfg_words[expected_weight_index]) weight_prefetch_errors = weight_prefetch_errors + 1;
            expected_weight_index = 168 +
                (((dut.compute_step[7:5] * 8) + 6) * 8) + dut.compute_step[4:2];
            if (dut.gen_weight_lane_bank[6].weight_prefetch_lane !== cfg_words[expected_weight_index]) weight_prefetch_errors = weight_prefetch_errors + 1;
            expected_weight_index = 168 +
                (((dut.compute_step[7:5] * 8) + 7) * 8) + dut.compute_step[4:2];
            if (dut.gen_weight_lane_bank[7].weight_prefetch_lane !== cfg_words[expected_weight_index]) weight_prefetch_errors = weight_prefetch_errors + 1;
            weight_prefetch_checks = weight_prefetch_checks + 8;
            if (!compute_monitor_active) begin
                compute_segments = compute_segments + 1;
                if (dut.compute_step !== 8'd0)
                    k_sequence_errors = k_sequence_errors + 1;
            end else if (dut.compute_step !== (compute_monitor_step + 8'd1)) begin
                k_sequence_errors = k_sequence_errors + 1;
            end
            compute_monitor_active = 1'b1;
            compute_monitor_step = dut.compute_step;
        end else if (compute_monitor_active) begin
            if (compute_monitor_step !== 8'd255)
                k_sequence_errors = k_sequence_errors + 1;
            compute_monitor_active = 1'b0;
        end
    end

    // Single-entry delayed source for the real packed bank.  This intentionally
    // exercises both loader request backpressure and delayed responses.
    always @(posedge clk) begin
        if (!rst_n) begin cfg_resp_valid_r<=0; cfg_resp_data_r<=0; cfg_q_count<=0; cfg_q_delay<=0; cfg_q_index<=0; end
        else begin
            if (cfg_resp_valid_r) cfg_resp_valid_r<=0;
            if (cfg_q_count != 0 && !cfg_resp_valid_r) begin
                if (cfg_q_delay != 0) cfg_q_delay<=cfg_q_delay-1;
                else begin cfg_resp_data_r<=cfg_words[cfg_q_index]; cfg_resp_valid_r<=1; cfg_q_count<=0; end
            end
            if (mem_req_valid && mem_req_ready) begin
                cfg_q_count<=1; cfg_q_index<={16'd0,mem_req_word_index}; cfg_q_delay<=({30'd0,lfsr[3:2]}+32'd1);
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cycles<=0; first_cycle<=-1; last_cycle<=-1; errors<=0; dw_accepts<=0; sink_accepts<=0;
            weight_map_errors=0; weight_map_checked=0;
            dw_ready_stall_cycles=0; dw_input_gap_cycles=0; sink_stall_cycles=0;
            dw_commit_count=0; last_pending_cycles=0; result_pending_cycles=0; dsp_width_errors=0;
            sink_stall_active<=0; stall_addr<=0; stall_data<=0; stall_epoch<=0;
            stall_strb<=0; stall_word<=0; stall_row<=0; stall_pixel<=0; stall_context<=0; stall_owner<=0; stall_last<=0;
            source_index<=DW_VECTORS; start<=0; cfg_start<=0; lfsr<=32'h31415927;
        end else begin
            cycles<=cycles+1; start<=0; cfg_start<=0;
            if (!cfg_loaded && !cfg_load_done && cfg_start_ready && !cfg_start) cfg_start<=1;
            if (cfg_load_done) cfg_loaded<=1;
            // First pulse asks the consumer to read PW indices 168..871;
            // after that fence a second pulse starts the DW stream.
            if (cfg_loaded && !pw_loaded && ready) start<=1;
            if (cfg_loaded && pw_loaded && ready && source_index==DW_VECTORS) begin start<=1; source_index<=0; end
            if (cfg_read_count==704) pw_loaded<=1;
            // The real packed DS2 view starts at local bank word 168.  Check
            // the physical BRAM organization directly: Cout=(tile*8+lane),
            // K-group is the low three address bits, and each lane receives
            // the original 32-bit packed word unchanged.
            if (!weight_map_checked && cfg_read_count==704) begin
                for (tile_idx=0;tile_idx<8;tile_idx=tile_idx+1) begin
                    for (kgroup_idx=0;kgroup_idx<8;kgroup_idx=kgroup_idx+1) begin
                        if (dut.gen_weight_lane_bank[0].weight_mem[tile_idx*8+kgroup_idx] !== cfg_words[168+((tile_idx*8+0)*8)+kgroup_idx]) weight_map_errors=weight_map_errors+1;
                        if (dut.gen_weight_lane_bank[1].weight_mem[tile_idx*8+kgroup_idx] !== cfg_words[168+((tile_idx*8+1)*8)+kgroup_idx]) weight_map_errors=weight_map_errors+1;
                        if (dut.gen_weight_lane_bank[2].weight_mem[tile_idx*8+kgroup_idx] !== cfg_words[168+((tile_idx*8+2)*8)+kgroup_idx]) weight_map_errors=weight_map_errors+1;
                        if (dut.gen_weight_lane_bank[3].weight_mem[tile_idx*8+kgroup_idx] !== cfg_words[168+((tile_idx*8+3)*8)+kgroup_idx]) weight_map_errors=weight_map_errors+1;
                        if (dut.gen_weight_lane_bank[4].weight_mem[tile_idx*8+kgroup_idx] !== cfg_words[168+((tile_idx*8+4)*8)+kgroup_idx]) weight_map_errors=weight_map_errors+1;
                        if (dut.gen_weight_lane_bank[5].weight_mem[tile_idx*8+kgroup_idx] !== cfg_words[168+((tile_idx*8+5)*8)+kgroup_idx]) weight_map_errors=weight_map_errors+1;
                        if (dut.gen_weight_lane_bank[6].weight_mem[tile_idx*8+kgroup_idx] !== cfg_words[168+((tile_idx*8+6)*8)+kgroup_idx]) weight_map_errors=weight_map_errors+1;
                        if (dut.gen_weight_lane_bank[7].weight_mem[tile_idx*8+kgroup_idx] !== cfg_words[168+((tile_idx*8+7)*8)+kgroup_idx]) weight_map_errors=weight_map_errors+1;
                    end
                end
                weight_map_checked=1;
            end
            if (dw_valid && dw_ready) begin dw_accepts<=dw_accepts+1; if(first_cycle<0) first_cycle<=cycles; source_index<=source_index+1; end
            if (dut.dw_commit_fire) dw_commit_count = dw_commit_count + 1;
            if (dut.last_pending) last_pending_cycles = last_pending_cycles + 1;
            if (dut.result_pending) result_pending_cycles = result_pending_cycles + 1;
            if (dut.compute_active)
                for (b=0;b<64;b=b+1)
                    if (dut.dsp_accum[b][47:32] !== {16{dut.dsp_accum[b][31]}})
                        dsp_width_errors = dsp_width_errors + 1;
            if (dw_valid && !dw_ready) dw_ready_stall_cycles = dw_ready_stall_cycles + 1;
            if ((source_index < DW_VECTORS) && !dw_valid) dw_input_gap_cycles = dw_input_gap_cycles + 1;
            if (sink_valid && !sink_ready) sink_stall_cycles = sink_stall_cycles + 1;
            if (sink_valid && !sink_ready) begin
                if (sink_stall_active &&
                    (sink_addr!==stall_addr || sink_data!==stall_data || sink_strb!==stall_strb ||
                     sink_row!==stall_row || sink_pixel!==stall_pixel || sink_word_in_pixel!==stall_word ||
                     sink_context!==stall_context || sink_owner!==stall_owner || sink_epoch!==stall_epoch ||
                     sink_last!==stall_last))
                    $fatal(1,"DS2 sink payload changed while stalled");
                if (!sink_stall_active) begin
                    sink_stall_active<=1'b1;
                    stall_addr<=sink_addr; stall_data<=sink_data; stall_strb<=sink_strb;
                    stall_row<=sink_row; stall_pixel<=sink_pixel; stall_word<=sink_word_in_pixel;
                    stall_context<=sink_context; stall_owner<=sink_owner; stall_epoch<=sink_epoch; stall_last<=sink_last;
                end
            end else begin
                sink_stall_active<=1'b0;
            end
            if (sink_valid && sink_ready) begin
                sink_accepts<=sink_accepts+1;
                if (sink_addr !== (32'h00200000 + ({24'd0,sink_pixel}*32'd64) + ({28'd0,sink_word_in_pixel}*32'd4)) || sink_strb!==4'hf || sink_row!=={2'd0,sink_pixel[7:4]}) errors<=errors+1;
                if (sink_context !== sink_pixel[4:3] || sink_owner !== sink_pixel[5] || sink_epoch !== (32'd64+{30'd0,sink_pixel[7:6]})) errors<=errors+1;
                if (sink_last !== ((sink_pixel==8'd255) && (sink_word_in_pixel==4'd15))) errors<=errors+1;
                for (b=0;b<4;b=b+1) if(sink_data[b*8 +: 8] !== expected_bytes[({24'd0,sink_pixel}*32'd64)+({28'd0,sink_word_in_pixel}*32'd4)+b]) begin
                    errors<=errors+1;
                    if (errors < 4) $display("mismatch pix=%0d word=%0d data=%h exp=%h byte=%0d",sink_pixel,sink_word_in_pixel,sink_data,expected_bytes[sink_pixel*64+sink_word_in_pixel*4+b],b);
                end
                if (sink_accepts==4095) last_cycle<=cycles;
            end
            if (done) begin
                if (error || cfg_error || cfg_received!=16'd872 || dw_accepts!=DW_VECTORS || dw_commit_count!=DW_VECTORS || sink_accepts!=4096 || cfg_read_count!=704 || cfg_weight_read_count!=512 || dw_vector_count!=512 || pw_token_count!=8192 || pw_mac_count!=524288 || output_word_count!=4096 || errors!=0 || weight_map_errors!=0 || !weight_map_checked || weight_prefetch_errors!=0 || weight_prefetch_checks!=65536 || partial_context_peak<2 || last_cycle-first_cycle>10000 || compute_active_cycles!=8192 || compute_segments!=32 || last_pending_cycles!=32 || result_pending_cycles!=32 || dsp_width_errors!=0 || k_sequence_errors!=0 || dw_input_gap_cycles==0 || sink_stall_cycles==0) begin
                    $display("DS12_DS2_PW_FAIL cfg=%0d weight=%0d dw=%0d commit=%0d tok=%0d mac=%0d out=%0d peak=%0d span=%0d errors=%0d weight_map_errors=%0d weight_map_checked=%0d weight_prefetch_errors=%0d weight_prefetch_checks=%0d dsp_width_errors=%0d ce=%0d active_cycles=%0d segments=%0d last_pending=%0d result_pending=%0d k_seq_errors=%0d dw_input_gaps=%0d dw_ready_stalls=%0d sink_stalls=%0d",cfg_read_count,cfg_weight_read_count,dw_accepts,dw_commit_count,pw_token_count,pw_mac_count,output_word_count,partial_context_peak,last_cycle-first_cycle,errors,weight_map_errors,weight_map_checked,weight_prefetch_errors,weight_prefetch_checks,dsp_width_errors,error_code,compute_active_cycles,compute_segments,last_pending_cycles,result_pending_cycles,k_sequence_errors,dw_input_gap_cycles,dw_ready_stall_cycles,sink_stall_cycles); $fatal(1,"DS2 PW consumer acceptance failed");
                end
                $display("DS12_DS2_PW_PASS byteexact=1 weight_map=512/512 weight_prefetch=65536/65536 cfg_reads=%0d weight_reads=%0d dw_vectors=%0d dw_commits=%0d pw_tokens=%0d mac=%0d output_words=%0d partial_context_peak=%0d span=%0d active_cycles=%0d compute_segments=%0d last_pending=%0d result_pending=%0d dsp_width_errors=%0d k_seq_errors=%0d errors=%0d error=%0d error_code=%02h cfg_error=%0d dw_input_gaps=%0d dw_ready_stalls=%0d sink_stalls=%0d",cfg_read_count,cfg_weight_read_count,dw_accepts,dw_commit_count,pw_token_count,pw_mac_count,output_word_count,partial_context_peak,last_cycle-first_cycle,compute_active_cycles,compute_segments,last_pending_cycles,result_pending_cycles,dsp_width_errors,k_sequence_errors,errors,error,error_code,cfg_error,dw_input_gap_cycles,dw_ready_stall_cycles,sink_stall_cycles); $finish(0);
            end
            lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            if(cycles>30000) $fatal(2,"DS2 PW consumer timeout ready=%0d source=%0d cfg=%0d dw=%0d out=%0d",ready,source_index,cfg_read_count,dw_accepts,output_word_count);
        end
    end
    reg cfg_loaded, pw_loaded;
    initial begin
        cfg_loaded=0; pw_loaded=0;
        $readmemh("build/ds12_stream_harness/ds12_stream_ds2_dw_output_i8.hex",dw_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds2_output_i8.hex",expected_bytes);
        begin : read_cfg
            integer fd,rc,layer,kind,index,address,mask,data_word,n;
            fd=$fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex","r"); if(fd==0)$fatal(2,"missing packed config ledger"); n=0;
            while(!$feof(fd)) begin rc=$fscanf(fd,"%d %d %d %h %h %h\n",layer,kind,index,address,mask,data_word); if(rc==6 && layer==2 && n<872) begin cfg_words[n]=data_word; n=n+1; end end
            $fclose(fd); if(n!=872)$fatal(2,"DS2 config rows=%0d",n);
        end
        repeat(4) @(posedge clk); rst_n=1;
    end
endmodule
`default_nettype wire
