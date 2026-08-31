`timescale 1ns/1ps
`default_nettype none

/*
 * Differential source/weight regression for the group-ready island.
 * The stream is generated from a non-zero software reference, not from the
 * scratch memories: every byte is checked against the same signed DW/PW
 * reference.  Bundle-major ordering deliberately matches the existing DW
 * producer and therefore exercises the row/group reorder cache.
 */
module tb_ds_group_ready_partial_k_pipeline #(
    parameter integer TB_FENCE = 0,
    parameter integer TB_CIN = 48,
    parameter integer TB_PIXELS = 17,
    parameter integer TB_COUT = 13
);
    localparam integer ROWS = (TB_PIXELS+7)/8;
    localparam integer GROUPS = (TB_CIN+7)/8;
    localparam integer BUNDLES = (TB_CIN+15)/16;
    localparam integer HALF_WRITES = ROWS*GROUPS*2;
    localparam integer VECTORS = ROWS*GROUPS;

    reg clk=0; always #1 clk=~clk;
    reg rst_n=0;
    reg start_valid=0; wire start_ready;
    reg [7:0] start_cin=TB_CIN, start_pixels=TB_PIXELS, start_cout=TB_COUT;
    reg start_bank=TB_FENCE; reg [1:0] start_session=2'd1; reg [3:0] start_epoch=4'ha;
    reg stream_valid=0; wire stream_ready;
    reg [5:0] stream_pixel=0; reg [2:0] stream_bundle=0;
    reg [1:0] stream_lane_base=0; reg [31:0] stream_data=0; reg [3:0] stream_lane_mask=0;
    reg weight_load_valid=0; wire weight_load_ready; reg [7:0] weight_load_k=0; reg [63:0] weight_load_vec=0;
    wire out_valid; reg out_ready=1; wire signed [2047:0] out_psum;
    wire [7:0] out_pixel_mask, out_cout_mask; wire [63:0] out_lane_mask;
    wire [3:0] out_group_count; wire done; wire error;
    wire [31:0] perf_total_cycles, perf_half_writes, perf_group_descriptors;
    wire [31:0] perf_pw_tokens, perf_output_groups, perf_first_output_cycle;

    ds_group_ready_partial_k_pipeline #(
        .MAX_PIXELS(17), .MAX_CIN(64), .MAX_BUNDLES(8), .MAX_ROWS(8),
        .MAX_GROUPS(16), .DESC_DEPTH(32), .FENCE_MODE(TB_FENCE)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid), .start_ready(start_ready),
        .start_cin(start_cin), .start_pixels(start_pixels), .start_cout(start_cout),
        .start_bank(start_bank), .start_session(start_session), .start_epoch(start_epoch),
        .stream_valid(stream_valid), .stream_ready(stream_ready), .stream_pixel(stream_pixel),
        .stream_bundle(stream_bundle), .stream_lane_base(stream_lane_base),
        .stream_data(stream_data), .stream_lane_mask(stream_lane_mask),
        .weight_load_valid(weight_load_valid), .weight_load_ready(weight_load_ready),
        .weight_load_k(weight_load_k), .weight_load_vec(weight_load_vec),
        .out_valid(out_valid), .out_ready(out_ready), .out_psum(out_psum),
        .out_pixel_mask(out_pixel_mask), .out_cout_mask(out_cout_mask),
        .out_lane_mask(out_lane_mask), .out_group_count(out_group_count),
        .done(done), .error(error), .perf_total_cycles(perf_total_cycles),
        .perf_half_writes(perf_half_writes), .perf_group_descriptors(perf_group_descriptors),
        .perf_pw_tokens(perf_pw_tokens), .perf_output_groups(perf_output_groups),
        .perf_first_output_cycle(perf_first_output_cycle)
    );

    integer cycles=0, errors=0, output_seen=0, held_checks=0;
    integer descriptor_seen_count=0, token_seen_count=0;
    reg [127:0] descriptor_seen=0;
    reg hold_active=0;
    reg signed [2047:0] held_psum=0;
    reg signed [7:0] act_ref [0:TB_PIXELS-1][0:TB_CIN-1];
    reg signed [7:0] wgt_ref [0:TB_CIN-1][0:7];
    integer p,k,c,r,lane,base,actual,expected,valid_pixel,valid_cout;

    function automatic integer act_value(input integer pp, input integer kk);
        integer v;
        begin v = (((pp+1)*(kk+3)+5) % 31) - 15; act_value=v; end
    endfunction
    function automatic integer wgt_value(input integer kk, input integer cc);
        integer v;
        begin v = (((kk+2)*(cc+1)+3) % 9) - 4; wgt_value=v; end
    endfunction

    always @(negedge clk) begin
        if (rst_n)
            out_ready <= ((cycles % 13) != 5) && ((cycles % 17) != 9);
        else
            out_ready <= 1'b1;
    end
    always @(posedge clk) begin
        cycles <= cycles + 1;
        /* Handshake-bound protocol assertions cover bubbles/backpressure. */
        if (rst_n && dut.group_data_fire) begin
            if (descriptor_seen[dut.group_cache_addr]) begin
                errors <= errors + 1;
                $display("ASSERT descriptor duplicate addr=%0d",dut.group_cache_addr);
            end
            descriptor_seen[dut.group_cache_addr] <= 1'b1;
            descriptor_seen_count <= descriptor_seen_count + 1;
            if (TB_FENCE == 0) begin
                if (!(dut.u_scratch0.top_seen[dut.group_cache_addr] &&
                      dut.u_scratch0.bottom_seen[dut.group_cache_addr])) begin
                    errors <= errors + 1;
                    $display("ASSERT descriptor before pair bank0 addr=%0d",dut.group_cache_addr);
                end
            end else if (!(dut.u_scratch1.top_seen[dut.group_cache_addr] &&
                           dut.u_scratch1.bottom_seen[dut.group_cache_addr])) begin
                errors <= errors + 1;
                $display("ASSERT descriptor before pair bank1 addr=%0d",dut.group_cache_addr);
            end
        end
        if (rst_n && dut.token_fire) begin
            token_seen_count <= token_seen_count + 1;
            if (dut.token_idx >= dut.token_group_kcount) begin
                errors <= errors + 1;
                $display("ASSERT token index overrun idx=%0d count=%0d",dut.token_idx,dut.token_group_kcount);
            end
            if (dut.token_last !== (dut.token_group_last &&
                                    (dut.token_idx + 1'b1 >= dut.token_group_kcount))) begin
                errors <= errors + 1;
                $display("ASSERT token last mismatch idx=%0d group_last=%b kcount=%0d",dut.token_idx,dut.token_group_last,dut.token_group_kcount);
            end
        end
        if (rst_n && dut.pw_valid_out && !dut.token_group_last) begin
            errors <= errors + 1;
            $display("ASSERT intermediate PW output/requant observed");
        end
        if (rst_n && dut.commit_fire_i) begin
            if ((TB_FENCE == 0 ? dut.s0_write_count : dut.s1_write_count) < HALF_WRITES) begin
                errors <= errors + 1;
                $display("ASSERT commit before all half writes");
            end
        end
        if (rst_n && dut.state == dut.ST_RELEASE && dut.release_ready_i) begin
            if (dut.cache_count != 0 || dut.token_active || dut.waiting_output) begin
                errors <= errors + 1;
                $display("ASSERT release before descriptor/output drain");
            end
        end
        if ($test$plusargs("TRACE_GR")) begin
            if (dut.asm_error)
                $display("GR_ASM_ERROR t=%0d pixel=%0d bundle=%0d lane=%0d next=%0d row=%0d",cycles,stream_pixel,stream_bundle,stream_lane_base,dut.u_assembler.next_pixel,dut.u_assembler.current_row);
            if (dut.group_data_fire)
                $display("GR_DESC t=%0d row=%0d group=%0d cache=%0d",cycles,dut.group_row_i,dut.group_idx_i,dut.cache_count);
            if (dut.cache_start_fire)
                $display("GR_START t=%0d row=%0d group=%0d exp=%0d/%0d",cycles,dut.pw_row_expect,dut.pw_group_expect,dut.expected_cache_addr,dut.cache_count);
            if (dut.token_fire)
                $display("GR_TOK t=%0d group=%0d idx=%0d end=%b last=%b ready=%b",cycles,dut.token_group_idx,dut.token_idx,dut.group_token_end,dut.token_last,dut.pw_ready_in);
            if (out_valid)
                $display("GR_OUT t=%0d valid=%b ready=%b waiting=%b",cycles,out_valid,out_ready,dut.waiting_output);
        end
        if (rst_n && out_valid && !out_ready) begin
            held_checks <= held_checks + 1;
            /* A held PW result must not change under output backpressure. */
            if (hold_active && held_psum !== out_psum)
                errors <= errors + 1;
            held_psum <= out_psum;
            hold_active <= 1'b1;
        end else begin
            hold_active <= 1'b0;
        end
        if (rst_n && out_valid && out_ready) begin
            if (output_seen >= ROWS) begin
                errors <= errors + 1;
            end else begin
                r = output_seen;
                for (p=0;p<8;p=p+1) begin
                    valid_pixel = ((r*8+p) < TB_PIXELS);
                    for (c=0;c<8;c=c+1) begin
                        valid_cout = (c < TB_COUT);
                        expected = 0;
                        if (valid_pixel && valid_cout)
                            for (k=0;k<TB_CIN;k=k+1)
                                expected = expected + act_ref[r*8+p][k]*wgt_ref[k][c];
                        actual = $signed(out_psum[((p*8+c)*32) +: 32]);
                        if (out_lane_mask[p*8+c] !== (valid_pixel && valid_cout)) begin
                            if (errors < 8) $display("MASK_MISMATCH row=%0d p=%0d c=%0d got=%b exp=%b",r,p,c,out_lane_mask[p*8+c],(valid_pixel&&valid_cout));
                            errors <= errors + 1;
                        end
                        if ((valid_pixel && valid_cout) && actual !== expected) begin
                            if (errors < 8) $display("DATA_MISMATCH row=%0d p=%0d c=%0d got=%0d exp=%0d",r,p,c,actual,expected);
                            errors <= errors + 1;
                        end
                    end
                end
                output_seen <= output_seen + 1;
            end
        end
    end

    task load_weights;
        integer kk,cc,vv;
        begin
            for (kk=0;kk<TB_CIN;kk=kk+1) begin
                weight_load_k=kk; weight_load_vec=0;
                for (cc=0;cc<8;cc=cc+1) begin
                    vv = (cc<TB_COUT) ? wgt_value(kk,cc) : 0;
                    weight_load_vec[(cc*8) +: 8] = vv[7:0];
                end
                @(negedge clk); weight_load_valid=1;
                while (!weight_load_ready) @(posedge clk);
                @(posedge clk); @(negedge clk); weight_load_valid=0;
            end
        end
    endtask

    task send_stream;
        integer bb,pp,bbt,ll,cc,vv,fire;
        begin
            for (bb=0;bb<BUNDLES;bb=bb+1) begin
                for (pp=0;pp<TB_PIXELS;pp=pp+1) begin
                    for (ll=0;ll<4;ll=ll+1) begin
                        stream_bundle=bb; stream_pixel=pp; stream_lane_base=ll;
                        stream_data=0; stream_lane_mask=0;
                        for (cc=0;cc<4;cc=cc+1) begin
                            bbt=bb*16+ll*4+cc;
                            if (bbt<TB_CIN) begin
                                vv=act_value(pp,bbt);
                                stream_data[(cc*8) +: 8]=vv[7:0];
                                stream_lane_mask[cc]=1'b1;
                            end
                        end
                        @(negedge clk); stream_valid=1;
                        while (!stream_ready) @(posedge clk);
                        @(posedge clk); @(negedge clk); stream_valid=0;
                    end
                end
            end
        end
    endtask

    initial begin
        for (p=0;p<TB_PIXELS;p=p+1)
            for (k=0;k<TB_CIN;k=k+1)
                act_ref[p][k] = act_value(p,k);
        for (k=0;k<TB_CIN;k=k+1)
            for (c=0;c<8;c=c+1)
                wgt_ref[k][c] = (c<TB_COUT) ? wgt_value(k,c) : 0;
        repeat(5) @(posedge clk); rst_n=1;
        load_weights();
        @(negedge clk); start_valid=1;
        while (!start_ready) @(posedge clk);
        @(posedge clk); @(negedge clk); start_valid=0;
        send_stream();
        while (!done) @(posedge clk);
        if (error) errors=errors+1;
        if (output_seen != ROWS) errors=errors+1;
        if (perf_half_writes != HALF_WRITES) errors=errors+1;
        if (perf_group_descriptors != VECTORS) errors=errors+1;
        if (perf_pw_tokens != ROWS*TB_CIN) errors=errors+1;
        if (perf_output_groups != ROWS) errors=errors+1;
        if (descriptor_seen_count != VECTORS) errors=errors+1;
        if (token_seen_count != ROWS*TB_CIN) errors=errors+1;
        if (errors==0)
            $display("PASS group_ready fence=%0d cin=%0d pixels=%0d cout=%0d cycles=%0d first_output=%0d half_writes=%0d descriptors=%0d tokens=%0d held=%0d",TB_FENCE,TB_CIN,TB_PIXELS,TB_COUT,perf_total_cycles,perf_first_output_cycle,perf_half_writes,perf_group_descriptors,perf_pw_tokens,held_checks);
        else begin
            $display("FAIL group_ready fence=%0d cin=%0d pixels=%0d cout=%0d errors=%0d error_sig=%b cycles=%0d outputs=%0d half_writes=%0d descriptors=%0d tokens=%0d outgroups=%0d held=%0d",TB_FENCE,TB_CIN,TB_PIXELS,TB_COUT,errors,error,perf_total_cycles,output_seen,perf_half_writes,perf_group_descriptors,perf_pw_tokens,perf_output_groups,held_checks);
            $fatal(1);
        end
        $finish;
    end
    initial begin
        repeat(1000000) @(posedge clk);
        $display("WATCHDOG state=%0d asm=%0d cache=%0d token=%b wait=%b s0=%0d s1=%0d writes=%0d desc=%0d",dut.state,dut.u_assembler.state,dut.cache_count,dut.token_active,dut.waiting_output,dut.bank0_owner_state,dut.bank1_owner_state,dut.s0_write_count,dut.s0_desc_count);
        $fatal(1);
    end
endmodule
`default_nettype wire
