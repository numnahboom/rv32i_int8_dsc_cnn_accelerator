`timescale 1ns/1ps
`default_nettype none

/* Directed differential stress for the isolated 64-MAC experiment. */
module tb_unified64_tile_engine_experiment;
    reg clk, rst_n, valid_in, first_k, last_k, ready_out;
    wire ready_in, valid_out, busy;
    reg [7:0] k_idx, pixel_mask, cout_mask;
    reg signed [63:0] act_vec, wgt_vec;
    reg [10:0] pixel_base;
    reg [8:0] cout_base;
    reg signed [255:0] bias_vec, multiplier_vec;
    reg [47:0] shift_vec;
    reg signed [31:0] zp, amin, amax;
    wire [10:0] out_pixel_idx;
    wire [8:0] out_channel_base;
    wire [3:0] out_lane_mask;
    wire signed [31:0] out_data;
    wire [31:0] metric_token_count, metric_masked_mac_count, metric_commit_count;
    wire [31:0] metric_output_stall_count, metric_overlap_count, metric_peak_occupancy;

    unified64_tile_engine dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .pixel_mask(pixel_mask), .cout_mask(cout_mask), .act_vec(act_vec), .wgt_vec(wgt_vec),
        .pixel_base(pixel_base), .cout_base(cout_base), .bias_vec(bias_vec),
        .multiplier_vec(multiplier_vec), .shift_vec(shift_vec),
        .output_zero_point_int32(zp), .activation_min_int32(amin),
        .activation_max_int32(amax), .ready_out(ready_out), .valid_out(valid_out),
        .out_pixel_idx(out_pixel_idx), .out_channel_base(out_channel_base),
        .out_lane_mask(out_lane_mask), .out_data(out_data), .busy(busy),
        .metric_token_count(metric_token_count), .metric_masked_mac_count(metric_masked_mac_count),
        .metric_commit_count(metric_commit_count), .metric_output_stall_count(metric_output_stall_count),
        .metric_overlap_count(metric_overlap_count), .metric_peak_occupancy(metric_peak_occupancy)
    );
    always #5 clk = ~clk;

    function integer av;
        input integer kk, pp, bb;
        begin av=((kk*17+pp*5+bb*11+3)%63)-31; end
    endfunction
    function integer wv;
        input integer kk, cc, bb;
        begin wv=((kk*13+cc*7+bb*19+7)%59)-29; end
    endfunction
    function signed [7:0] rq_ref;
        input integer acc_i, bias_i, mul_i, shift_i, zp_i, min_i, max_i;
        reg signed [32:0] sum;
        reg signed [64:0] product, fixed_mul, abs_value, rounded_abs, value;
        reg signed [64:0] offset;
        begin
            sum=acc_i+bias_i;
            product=$signed(sum)*$signed({{33{mul_i[31]}},mul_i});
            offset=65'sd1 <<< 30;
            if (product>=0) fixed_mul=(product+offset)>>>31;
            else begin abs_value=-product; rounded_abs=(abs_value+offset)>>>31; fixed_mul=-rounded_abs; end
            value=(fixed_mul>>>shift_i)+zp_i;
            if (value>127) value=127; else if (value < -128) value=-128;
            if (value<min_i) value=min_i; else if (value>max_i) value=max_i;
            rq_ref=value[7:0];
        end
    endfunction

    integer exp_p[0:4095], exp_c[0:4095], exp_r[0:4095], exp_b[0:4095];
    integer exp_m[0:4095]; reg signed [31:0] exp_d[0:4095];
    integer expected_count, output_count, errors, cycles, block_no, overlap_seen;
    integer acc[0:63]; integer b_bias[0:7], b_mul[0:7], b_shift[0:7];
    integer p_total, c_total, p_lanes, c_lanes, cin, pbase, cbase;
    integer k, i, j, r, bt, idx;
    reg stalled; integer stall_count;

    task append_expected;
        begin
            for (r=0;r<8;r=r+1) for (bt=0;bt<2;bt=bt+1) begin
                idx=r*2+bt;
                exp_p[expected_count]=pbase+r;
                exp_c[expected_count]=cbase+bt*4;
                exp_r[expected_count]=r; exp_b[expected_count]=bt;
                exp_m[expected_count]=0;
                exp_d[expected_count][7:0]=rq_ref(acc[r*8+bt*4],b_bias[bt*4],b_mul[bt*4],b_shift[bt*4],zp,amin,amax);
                exp_d[expected_count][15:8]=rq_ref(acc[r*8+bt*4+1],b_bias[bt*4+1],b_mul[bt*4+1],b_shift[bt*4+1],zp,amin,amax);
                exp_d[expected_count][23:16]=rq_ref(acc[r*8+bt*4+2],b_bias[bt*4+2],b_mul[bt*4+2],b_shift[bt*4+2],zp,amin,amax);
                exp_d[expected_count][31:24]=rq_ref(acc[r*8+bt*4+3],b_bias[bt*4+3],b_mul[bt*4+3],b_shift[bt*4+3],zp,amin,amax);
                for (j=0;j<4;j=j+1) if ((r<p_lanes)&&(bt*4+j<c_lanes)) exp_m[expected_count][j]=1;
                expected_count=expected_count+1;
            end
        end
    endtask

    task send_block;
        begin
            p_lanes=p_total-pbase; if(p_lanes>8)p_lanes=8;
            c_lanes=c_total-cbase; if(c_lanes>8)c_lanes=8;
            for (j=0;j<8;j=j+1) begin
                b_bias[j]=((block_no*97+j*23)%2001)-1000;
                case((block_no+j)%5)
                    0:b_mul[j]=32'sh7fffffff; 1:b_mul[j]=-32'sh40000000;
                    2:b_mul[j]=32'sh40000000; 3:b_mul[j]=32'sh20000000;
                    default:b_mul[j]=32'sh10000000;
                endcase
                b_shift[j]=(block_no+j*3)%6;
                bias_vec[(j*32)+:32]=b_bias[j]; multiplier_vec[(j*32)+:32]=b_mul[j];
                shift_vec[(j*6)+:6]=b_shift[j];
            end
            zp=(block_no%3==0)?0:(block_no%3==1)?17:-9;
            amin=(block_no%2)?-96:-128; amax=(block_no%2)?101:127;
            for(i=0;i<64;i=i+1) acc[i]=0;
            for(k=0;k<cin;k=k+1) begin
                @(negedge clk);
                act_vec=0; wgt_vec=0;
                for(i=0;i<8;i=i+1) act_vec[(i*8)+:8]=av(k,pbase+i,block_no);
                for(j=0;j<8;j=j+1) wgt_vec[(j*8)+:8]=wv(k,cbase+j,block_no);
                for(i=0;i<8;i=i+1) for(j=0;j<8;j=j+1)
                    if((i<p_lanes)&&(j<c_lanes)) acc[i*8+j]=acc[i*8+j]+av(k,pbase+i,block_no)*wv(k,cbase+j,block_no);
                first_k=(k==0); last_k=(k==cin-1); k_idx=k;
                pixel_mask=(p_lanes==8)?8'hff:((1<<p_lanes)-1);
                cout_mask=(c_lanes==8)?8'hff:((1<<c_lanes)-1);
                valid_in=1;
                while(!ready_in) begin @(posedge clk); @(negedge clk); end
                @(posedge clk); @(negedge clk);
                valid_in=0; first_k=0; last_k=0;
            end
            append_expected(); block_no=block_no+1;
        end
    endtask

    always @(negedge clk) begin
        if(!rst_n) ready_out<=1;
        else begin cycles=cycles+1; ready_out<=((cycles%31)==4)||((cycles%47)==9)||((cycles%53)==17)?0:1; end
    end
    always @(posedge clk) begin
        if(rst_n) begin
            if(valid_in&&ready_in&&dut.drain_active) overlap_seen=overlap_seen+1;
            if(stalled) begin
                if(!valid_out) errors=errors+1;
                if(ready_out) stalled=0;
            end
            if(valid_out&&!ready_out) begin stalled=1; stall_count=stall_count+1; end
            if(valid_out&&ready_out) begin
                if(output_count>=expected_count) errors=errors+1;
                else begin
                    if(out_pixel_idx!==exp_p[output_count] || out_channel_base!==exp_c[output_count]) begin
                        if(errors<12) $display("TAG n=%0d got p=%0d c=%0d exp p=%0d c=%0d",output_count,out_pixel_idx,out_channel_base,exp_p[output_count],exp_c[output_count]);
                        errors=errors+1;
                    end
                    for(j=0;j<4;j=j+1) if(out_lane_mask[j] && out_data[(j*8)+:8]!==exp_d[output_count][(j*8)+:8]) begin
                        if(errors<12) $display("DATA n=%0d lane=%0d got=%0d exp=%0d mask=%b",output_count,j,$signed(out_data[(j*8)+:8]),$signed(exp_d[output_count][(j*8)+:8]),out_lane_mask);
                        errors=errors+1;
                    end
                    if(out_lane_mask!==exp_m[output_count]) begin
                        if(errors<12) $display("MASK n=%0d got=%b exp=%b",output_count,out_lane_mask,exp_m[output_count]);
                        errors=errors+1;
                    end
                end
                output_count=output_count+1;
            end
        end
    end
    integer shape;
    initial begin
        clk=0; rst_n=0; valid_in=0; first_k=0; last_k=0; k_idx=0; pixel_mask=0; cout_mask=0;
        act_vec=0; wgt_vec=0; pixel_base=0; cout_base=0; bias_vec=0; multiplier_vec=0; shift_vec=0;
        zp=0; amin=-128; amax=127; ready_out=1; expected_count=0; output_count=0; errors=0;
        cycles=0; block_no=0; overlap_seen=0; stalled=0; stall_count=0;
        repeat(5) @(posedge clk); rst_n=1;
        /* PW throughput shapes and a complete K=27 stem contract. */
        for(shape=0;shape<4;shape=shape+1) begin
            cin=(shape==0)?16:(shape==1)?64:(shape==2)?128:27;
            p_total=(shape==0)?1:(shape==1)?8:(shape==2)?17:64;
            c_total=(shape==0)?8:(shape==1)?13:(shape==2)?16:16;
            for(pbase=0;pbase<p_total;pbase=pbase+8)
                for(cbase=0;cbase<c_total;cbase=cbase+8) begin
                    pixel_base=pbase; cout_base=cbase; send_block();
                end
        end
        while((output_count<expected_count)||busy) begin @(posedge clk); if(cycles>500000) $fatal; end
        if(errors!=0 || output_count!=expected_count || overlap_seen==0) begin
            $display("FAIL unified64 errors=%0d out=%0d exp=%0d overlap=%0d",errors,output_count,expected_count,overlap_seen); $fatal;
        end
        if(metric_token_count !== (16+64+128+27)*((1+1+1+8+2+8))) $display("INFO token counter=%0d",metric_token_count);
        $display("PASS unified64 blocks=%0d commits=%0d tokens=%0d masked_macs=%0d stalls=%0d overlap=%0d peak_occ=%0d cycles=%0d",
            block_no,metric_commit_count,metric_token_count,metric_masked_mac_count,metric_output_stall_count,metric_overlap_count,metric_peak_occupancy,cycles);
        $finish;
    end
endmodule
`default_nettype wire
