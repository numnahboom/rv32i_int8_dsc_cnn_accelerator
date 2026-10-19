`timescale 1ns/1ps
`default_nettype none
module tb_d4_rq_partial_multiplier;
    localparam integer DIRECTED_COUNT=256;
    localparam integer RANDOM_COUNT=1000000;
    localparam integer TOTAL_COUNT=DIRECTED_COUNT+RANDOM_COUNT;

    reg clk=0;
    always #2 clk<=~clk;
    reg rst_n=0, in_valid=0;
    reg signed [31:0] a=0, b=0;
    wire signed [63:0] product;
    wire out_valid;
    d4_rq_partial_multiplier_lane dut(
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.a(a),.b(b),
        .product(product),.out_valid(out_valid)
    );

    reg [31:0] hist_a [0:3], hist_b [0:3];
    reg [63:0] hist_product [0:3];
    reg hist_valid [0:3];
    reg [31:0] rng_a=32'h6d2b79f5, rng_b=32'h1a14c6e9;
    reg [31:0] next_a, next_b;
    reg signed [63:0] wide_a, wide_b, wide_product;
    reg old_in_valid, old_common_valid, old_partial_valid, old_merge_valid;
    reg [31:0] old_a_common, old_b_common, old_p00;
    reg signed [32:0] old_p01, old_p10;
    reg signed [31:0] old_p11;
    reg signed [33:0] old_cross;
    reg signed [63:0] old_base, old_product;
    integer cycle, sent=0, checks=0, gap_cycles=0, drain;
    integer slot;
    reg send_this_cycle;

    function automatic [31:0] directed_word(input integer index);
        begin
            case(index)
                0: directed_word=32'h00000000;
                1: directed_word=32'h00000001;
                2: directed_word=32'hffffffff;
                3: directed_word=32'h7fffffff;
                4: directed_word=32'h80000000;
                5: directed_word=32'h00007fff;
                6: directed_word=32'h00008000;
                7: directed_word=32'h0000ffff;
                8: directed_word=32'h00010000;
                9: directed_word=32'h7fff0000;
                10: directed_word=32'h80000001;
                11: directed_word=32'h8000ffff;
                12: directed_word=32'h7fffffff;
                13: directed_word=32'hffff0000;
                14: directed_word=32'hffff8000;
                default: directed_word=32'h1234abcd;
            endcase
        end
    endfunction

    function automatic [31:0] xorshift32(input [31:0] seed);
        reg [31:0] x;
        begin
            x=seed;
            x=x^(x<<13);
            x=x^(x>>17);
            x=x^(x<<5);
            xorshift32=x;
        end
    endfunction

    task automatic capture_preedge_state;
        begin
            old_in_valid=in_valid;
            old_common_valid=dut.common_valid;
            old_partial_valid=dut.partial_valid;
            old_merge_valid=dut.merge_valid;
            old_a_common=dut.a_common;old_b_common=dut.b_common;
            old_p00=dut.p00_q;old_p01=dut.p01_q;
            old_p10=dut.p10_q;old_p11=dut.p11_q;
            old_cross=dut.cross_q;old_base=dut.base_q;
            old_product=product;
        end
    endtask

    task automatic check_cycle(input integer cycle_number);
        integer result_slot;
        begin
            if(dut.common_valid!==old_in_valid ||
               dut.partial_valid!==old_common_valid ||
               dut.merge_valid!==old_partial_valid ||
               out_valid!==old_merge_valid)
                $fatal(1,"RQ_UNIT_VALID_SHIFT cycle=%0d",cycle_number);
            if(!old_in_valid &&
               (dut.a_common!==old_a_common || dut.b_common!==old_b_common))
                $fatal(1,"RQ_UNIT_COMMON_NOT_HELD cycle=%0d",cycle_number);
            if(!old_common_valid &&
               (dut.p00_q!==old_p00 || dut.p01_q!==old_p01 ||
                dut.p10_q!==old_p10 || dut.p11_q!==old_p11))
                $fatal(1,"RQ_UNIT_PARTIAL_NOT_HELD cycle=%0d",cycle_number);
            if(!old_partial_valid &&
               (dut.cross_q!==old_cross || dut.base_q!==old_base))
                $fatal(1,"RQ_UNIT_MERGE_NOT_HELD cycle=%0d",cycle_number);
            if(!old_merge_valid && product!==old_product)
                $fatal(1,"RQ_UNIT_PRODUCT_NOT_HELD cycle=%0d",cycle_number);

            if(cycle_number<3) begin
                if(out_valid) $fatal(1,"RQ_UNIT_EARLY_VALID cycle=%0d",cycle_number);
            end else begin
                result_slot=(cycle_number-3)%4;
                if(out_valid!==hist_valid[result_slot])
                    $fatal(1,"RQ_UNIT_VALID_MISMATCH cycle=%0d slot=%0d got=%0d expected=%0d",
                           cycle_number,result_slot,out_valid,hist_valid[result_slot]);
                if(hist_valid[result_slot]) begin
                    if(product!==hist_product[result_slot])
                        $fatal(1,"RQ_UNIT_PRODUCT cycle=%0d input=%0d a=%h b=%h got=%h expected=%h",
                               cycle_number,cycle_number-3,hist_a[result_slot],
                               hist_b[result_slot],product,hist_product[result_slot]);
                    checks=checks+1;
                end
            end
        end
    endtask

    initial begin
        for(slot=0;slot<4;slot=slot+1) begin
            hist_a[slot]=0;hist_b[slot]=0;
            hist_product[slot]=0;hist_valid[slot]=0;
        end

        // Reset while valid work is in flight. No pre-reset product may leak.
        repeat(3) @(negedge clk);
        rst_n=1;
        @(negedge clk);
        in_valid=1;a=32'h81234567;b=32'h76543210;
        @(posedge clk); #1;
        if(out_valid) $fatal(1,"RQ_UNIT_RESET_SETUP_EARLY");
        @(negedge clk);
        in_valid=1;a=32'h7fffffff;b=32'h80000000;
        @(posedge clk); #1;
        if(out_valid) $fatal(1,"RQ_UNIT_RESET_SETUP_EARLY");
        @(negedge clk);
        in_valid=0;a=32'hffffffff;b=32'h00008000;rst_n=0;
        repeat(2) begin
            @(posedge clk); #1;
            if(out_valid || product!==64'd0 || dut.common_valid ||
               dut.partial_valid || dut.merge_valid || dut.a_common!==32'd0 ||
               dut.b_common!==32'd0 || dut.p00_q!==32'd0 ||
               dut.p01_q!==33'd0 || dut.p10_q!==33'd0 || dut.p11_q!==32'd0 ||
               dut.cross_q!==34'd0 || dut.base_q!==64'd0)
                $fatal(1,"RQ_UNIT_RESET_NOT_FLUSHED");
            @(negedge clk);
            in_valid=0;a=a+32'h13579bdf;b=b-32'h2468ace1;
        end
        rst_n=1;
        for(cycle=0;cycle<4;cycle=cycle+1) begin
            @(negedge clk);
            in_valid=0;a=a+32'h01010101;b=b-32'h10101010;
            @(posedge clk); #1;
            if(out_valid) $fatal(1,"RQ_UNIT_RESET_LEAK cycle=%0d",cycle);
        end

        // Exactly 1,000,256 valid products are checked. Deterministic gaps
        // change both invalid operands while the independently clock-enabled
        // data stages must hold their previous values.
        for(cycle=0;sent<TOTAL_COUNT;cycle=cycle+1) begin
            @(negedge clk);
            rng_a=xorshift32(rng_a);rng_b=xorshift32(rng_b);
            send_this_cycle=(cycle%13!=3 && cycle%13!=4 && cycle%13!=9);
            slot=cycle%4;
            if(send_this_cycle) begin
                if(sent<DIRECTED_COUNT) begin
                    next_a=directed_word(sent/16);
                    next_b=directed_word(sent%16);
                end else begin
                    next_a=rng_a;next_b=rng_b;
                end
                a=$signed(next_a);b=$signed(next_b);in_valid=1;
                wide_a={{32{next_a[31]}},next_a};
                wide_b={{32{next_b[31]}},next_b};
                wide_product=wide_a*wide_b;
                hist_a[slot]=next_a;hist_b[slot]=next_b;
                hist_product[slot]=wide_product;hist_valid[slot]=1;
                sent=sent+1;
            end else begin
                a=rng_a;b=rng_b;in_valid=0;
                hist_valid[slot]=0;gap_cycles=gap_cycles+1;
            end
            capture_preedge_state();
            @(posedge clk); #1;
            check_cycle(cycle);
        end

        for(drain=0;drain<3;drain=drain+1) begin
            @(negedge clk);
            in_valid=0;a=rng_a+32'h31415927;b=rng_b-32'h27182818;
            hist_valid[cycle%4]=0;
            capture_preedge_state();
            @(posedge clk); #1;
            check_cycle(cycle);
            cycle=cycle+1;
        end
        if(checks!=TOTAL_COUNT)
            $fatal(1,"RQ_UNIT_CHECK_COUNT got=%0d expected=%0d",checks,TOTAL_COUNT);
        $display("PASS D4_RQ_PARTIAL_MULTIPLIER checks=%0d directed=%0d random=%0d gaps=%0d reset_flush=1 latency=3",
                 checks,DIRECTED_COUNT,RANDOM_COUNT,gap_cycles);
        $finish;
    end
endmodule
`default_nettype wire
