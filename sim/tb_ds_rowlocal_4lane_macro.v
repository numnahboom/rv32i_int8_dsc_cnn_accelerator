`timescale 1ns/1ps
`default_nettype none

module tb_ds_rowlocal_4lane_macro;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg cfg_valid = 0, cfg_island = 0; reg [5:0] cfg_lane = 0;
    reg signed [31:0] cfg_bias = 0, cfg_multiplier = 32'sh7fffffff;
    reg [5:0] cfg_shift = 0; wire cfg_ready;
    reg token_valid = 0, token_first = 0, token_last = 0; wire token_ready;
    reg [7:0] token_k = 0; reg [9:0] token_pixel_base = 0; reg [8:0] token_cout_base = 0;
    reg [7:0] token_pixel_mask = 8'hff, token_cout_mask = 8'hff;
    reg [63:0] token_act_vec = 0, token_wgt_vec = 0; reg [7:0] token_tag = 0;
    reg [3:0] token_epoch = 0, token_session = 0; reg [1:0] token_mode = 0;
    reg signed [31:0] token_zp = 0, token_min = -128, token_max = 127;
    wire out_valid; reg out_ready = 1; wire [31:0] out_word; wire [3:0] out_mask;
    wire [9:0] out_pixel; wire [8:0] out_channel; wire [2:0] out_group; wire [7:0] out_tag;
    wire [3:0] out_epoch, out_session; wire [1:0] out_mode; wire busy; wire [4:0] occupancy;

    ds_rowlocal_4lane_macro dut (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_island(cfg_island), .cfg_lane(cfg_lane), .cfg_bias(cfg_bias),
        .cfg_multiplier(cfg_multiplier), .cfg_shift(cfg_shift),
        .token_valid(token_valid), .token_ready(token_ready), .token_first(token_first),
        .token_last(token_last), .token_k(token_k), .token_pixel_base(token_pixel_base),
        .token_cout_base(token_cout_base), .token_pixel_mask(token_pixel_mask),
        .token_cout_mask(token_cout_mask), .token_act_vec(token_act_vec),
        .token_wgt_vec(token_wgt_vec), .token_tag(token_tag), .token_epoch(token_epoch),
        .token_session(token_session), .token_mode(token_mode),
        .token_output_zero_point(token_zp), .token_activation_min(token_min),
        .token_activation_max(token_max), .out_valid(out_valid), .out_ready(out_ready),
        .out_word(out_word), .out_word_mask(out_mask), .out_pixel_base(out_pixel),
        .out_channel_base(out_channel), .out_group(out_group), .out_tag(out_tag),
        .out_epoch(out_epoch), .out_session(out_session), .out_mode(out_mode),
        .busy(busy), .row_occupancy(occupancy));

    integer errors = 0, cycles = 0, out_count = 0, expected_count = 0;
    integer token_count = 0, last_token_cycle = -1, min_token_ii = 999999,
            max_token_ii = 0, last_out_cycle = -1, min_out_ii = 999999,
            max_out_ii = 0, max_occupancy = 0;
    integer cfg_i, cfg_l;
    reg [31:0] exp_word [0:255]; reg [3:0] exp_mask [0:255];
    reg [9:0] exp_pixel [0:255]; reg [8:0] exp_channel [0:255];
    reg [2:0] exp_group [0:255]; reg [7:0] exp_tag [0:255];
    reg [1:0] exp_mode [0:255];

    /* temporary settle probe */
    // initial begin #1; $display("EARLY PROBE"); $finish; end

    always @(negedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            out_ready <= ((cycles % 11) != 3) && ((cycles % 17) != 5);
        end else out_ready <= 1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            #1;
            if (occupancy > max_occupancy) max_occupancy = occupancy;
            if (token_valid && token_ready) begin
                if (last_token_cycle >= 0) begin
                    if ((cycles-last_token_cycle) < min_token_ii) min_token_ii = cycles-last_token_cycle;
                    if ((cycles-last_token_cycle) > max_token_ii) max_token_ii = cycles-last_token_cycle;
                end
                last_token_cycle = cycles;
                token_count = token_count + 1;
            end
            if (out_valid && out_ready) begin
                if (last_out_cycle >= 0) begin
                    if ((cycles-last_out_cycle) < min_out_ii) min_out_ii = cycles-last_out_cycle;
                    if ((cycles-last_out_cycle) > max_out_ii) max_out_ii = cycles-last_out_cycle;
                end
                last_out_cycle = cycles;
                if (out_count >= expected_count ||
                    out_word !== exp_word[out_count] ||
                    out_mask !== exp_mask[out_count] || out_pixel !== exp_pixel[out_count] ||
                    out_channel !== exp_channel[out_count] || out_group !== exp_group[out_count] ||
                    out_tag !== exp_tag[out_count] || out_mode !== exp_mode[out_count]) begin
                    if (errors < 12)
                        $display("MISMATCH n=%0d got word=%h mask=%h p=%0d c=%0d g=%0d tag=%0d mode=%0d exp word=%h mask=%h p=%0d c=%0d g=%0d tag=%0d mode=%0d",
                          out_count,out_word,out_mask,out_pixel,out_channel,out_group,out_tag,out_mode,
                          exp_word[out_count],exp_mask[out_count],exp_pixel[out_count],exp_channel[out_count],
                          exp_group[out_count],exp_tag[out_count],exp_mode[out_count]);
                    errors = errors + 1;
                end
                out_count = out_count + 1;
            end
        end
    end

    task automatic configure;
        begin
            for (cfg_i = 0; cfg_i < 2; cfg_i = cfg_i + 1)
                for (cfg_l = 0; cfg_l < 32; cfg_l = cfg_l + 1) begin
                    @(negedge clk); cfg_island = cfg_i; cfg_lane = cfg_l;
                    cfg_bias = 0; cfg_multiplier = 32'sh7fffffff; cfg_shift = 0; cfg_valid = 1;
                    while (1) begin
                        @(posedge clk); #1;
                        if (cfg_ready) break;
                        if (cycles > 500) begin $display("CFG HANG ready=%b tok=%b prod=%b block=%b empty=%b rqbusy=%b side=%b occ=%0d",cfg_ready,dut.tok_valid,dut.prod_valid,dut.block_active, dut.rows_empty,dut.rq_busy,dut.side_valid,occupancy); $fatal; end
                    end
                end
            @(negedge clk); cfg_valid = 0;
        end
    endtask

    function automatic integer sat8(input integer value);
        begin if (value > 127) sat8=127; else if (value < -128) sat8=-128; else sat8=value; end
    endfunction

    task automatic send_block;
        input integer kval;
        input integer base;
        input integer tagv;
        input [1:0] modev;
        integer k, p, c, ii, lane, sum, bytev, idx; reg [3:0] m;
        begin
            /* Build expected row-local order: island 0 rows, then island 1. */
            for (ii = 0; ii < 2; ii = ii + 1)
                for (p = 0; p < 8; p = p + 1) begin
                    idx = expected_count + ii*8 + p;
                    exp_pixel[idx] = base + p; exp_channel[idx] = 20 + ii*4;
                    exp_group[idx] = p; exp_tag[idx] = tagv; exp_mode[idx] = modev;
                    exp_word[idx] = 0; m = 0;
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        sum = 0;
                        for (k = 0; k < kval; k = k + 1)
                            sum = sum + ((p+1) * (ii*4+lane+1));
                        bytev = sat8(sum); exp_word[idx][lane*8 +: 8] = bytev[7:0];
                        m[lane] = (p < 6); /* exercise spatial/channel masks */
                    end
                    exp_mask[idx] = m;
                end
            expected_count = expected_count + 16;
            for (k = 0; k < kval; k = k + 1) begin
                @(negedge clk); token_valid=1; token_first=(k==0); token_last=(k==kval-1);
                token_k=k; token_pixel_base=base; token_cout_base=20; token_tag=tagv;
                token_epoch=4'hb; token_session=4'h6; token_mode=modev;
                token_pixel_mask=8'h3f; token_cout_mask=8'hff;
                token_act_vec=0; token_wgt_vec=0;
                for (p=0;p<8;p=p+1) token_act_vec[p*8 +: 8] = p+1;
                for (c=0;c<8;c=c+1) token_wgt_vec[c*8 +: 8] = c+1;
                while (1) begin @(posedge clk); #1; if (token_ready) break; end
            end
            @(negedge clk); token_valid=0; token_first=0; token_last=0;
            while (busy) @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk); rst_n=1; configure();
        send_block(16, 3, 8'h21, 0);
        send_block(128, 7, 8'h42, 0);
        send_block(9, 11, 8'h63, 2);
        while (busy || out_count < expected_count) @(posedge clk);
        if (out_count !== expected_count) begin $display("FAIL count %0d/%0d",out_count,expected_count); errors=errors+1; end
        if (errors != 0) $fatal(1,"FAIL rowlocal errors=%0d",errors);
        $display("PASS ds_rowlocal_4lane_macro outputs=%0d tokens=%0d cycles=%0d token_ii=%0d..%0d out_ii=%0d..%0d max_occupancy=%0d final_occupancy=%0d",
                 out_count,token_count,cycles,min_token_ii,max_token_ii,min_out_ii,max_out_ii,
                 max_occupancy,occupancy);
        $finish;
    end
endmodule
`default_nettype wire
