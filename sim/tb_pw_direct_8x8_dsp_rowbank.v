`timescale 1ns/1ps
`default_nettype none

/* Differential and overlap stress for the row-bank PW prototype.  Every
 * accepted block is checked against an independent integer requant reference;
 * output is a narrow two-lane row stream (32 beats per block). */
module tb_pw_direct_8x8_dsp_rowbank;
    localparam integer MAX_PAIRS = 128 * 32 + 64;
    reg clk, rst_n, valid_in, first_k, last_k, ready_out;
    wire ready_in, valid_out, busy;
    reg [7:0] k_idx, pixel_mask, cout_mask;
    reg signed [63:0] act_vec, wgt_vec;
    reg [5:0] pixel_base;
    reg [8:0] cout_base;
    reg [7:0] output_pixels;
    reg [8:0] output_channels;
    reg signed [255:0] bias_vec, multiplier_vec;
    reg [47:0] shift_vec;
    reg signed [31:0] output_zero_point_int32;
    reg signed [31:0] activation_min_int32, activation_max_int32;
    wire [2:0] out_row_idx;
    wire [1:0] out_beat_idx, out_lane_mask;
    wire [5:0] out_pixel_idx;
    wire [8:0] out_channel_base;
    wire signed [15:0] out_data;

    pw_direct_8x8_dsp_rowbank dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .pixel_mask(pixel_mask), .cout_mask(cout_mask),
        .act_vec(act_vec), .wgt_vec(wgt_vec),
        .pixel_base(pixel_base), .cout_base(cout_base),
        .output_pixels(output_pixels), .output_channels(output_channels),
        .bias_vec(bias_vec), .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32),
        .ready_out(ready_out), .valid_out(valid_out),
        .out_row_idx(out_row_idx), .out_beat_idx(out_beat_idx),
        .out_pixel_idx(out_pixel_idx), .out_channel_base(out_channel_base),
        .out_lane_mask(out_lane_mask), .out_data(out_data), .busy(busy)
    );

    always #5 clk = ~clk;

    function integer act_value;
        input integer kk, pp, bb;
        begin act_value = ((kk*13 + pp*7 + bb*3 + 19) % 61) - 30; end
    endfunction
    function integer wgt_value;
        input integer kk, cc, bb;
        begin wgt_value = ((kk*17 + cc*5 + bb*11 + 23) % 47) - 23; end
    endfunction
    function signed [7:0] rq_ref;
        input integer acc_i, bias_i, mul_i, shift_i, zp_i, min_i, max_i;
        reg signed [32:0] sum;
        reg signed [64:0] product, fixed_mul, abs_value, rounded_abs, value;
        reg signed [64:0] offset;
        begin
            sum = acc_i + bias_i;
            product = $signed(sum) * $signed({{33{mul_i[31]}},mul_i});
            offset = 65'sd1 <<< 30;
            if (product >= 0)
                fixed_mul = (product + offset) >>> 31;
            else begin
                abs_value = -product;
                rounded_abs = (abs_value + offset) >>> 31;
                fixed_mul = -rounded_abs;
            end
            value = (fixed_mul >>> shift_i) + zp_i;
            if (value > 127) value = 127;
            else if (value < -128) value = -128;
            if (value < min_i) value = min_i;
            else if (value > max_i) value = max_i;
            rq_ref = value[7:0];
        end
    endfunction

    reg [5:0] exp_pixel [0:MAX_PAIRS-1];
    reg [8:0] exp_cout [0:MAX_PAIRS-1];
    reg [2:0] exp_row [0:MAX_PAIRS-1];
    reg [1:0] exp_beat [0:MAX_PAIRS-1];
    reg [1:0] exp_mask [0:MAX_PAIRS-1];
    reg signed [15:0] exp_data [0:MAX_PAIRS-1];
    integer expected_count, output_count, errors, cycle_no, seed;
    integer overlap_accepts;
    integer p_total, c_total, p_lanes, c_lanes, cin;
    integer p_base_i, c_base_i, block_no, k, i, j, q, pair_idx;
    integer acc [0:63];
    integer cfg_bias [0:7], cfg_mul [0:7], cfg_shift [0:7];
    integer cfg_zp, cfg_min, cfg_max;
    reg stalled_prev;
    reg [5:0] stalled_pixel;
    reg [8:0] stalled_cout;
    reg [1:0] stalled_mask;
    reg signed [15:0] stalled_data;

    task build_config;
        begin
            for (q = 0; q < 8; q = q + 1) begin
                cfg_bias[q] = ((block_no*97 + q*31) % 20001) - 10000;
                case ((block_no + q) % 7)
                    0: cfg_mul[q] = 32'sh7fffffff;
                    1: cfg_mul[q] = -32'sh80000000;
                    2: cfg_mul[q] = 32'sh40000000;
                    3: cfg_mul[q] = -32'sh40000000;
                    4: cfg_mul[q] = 32'sh20000000;
                    default: cfg_mul[q] = (($urandom(seed) % 1000000001) - 500000000);
                endcase
                cfg_shift[q] = (block_no*3 + q*5) % 8;
                bias_vec[(q*32) +: 32] = cfg_bias[q];
                multiplier_vec[(q*32) +: 32] = cfg_mul[q];
                shift_vec[(q*6) +: 6] = cfg_shift[q];
            end
            case (block_no % 6)
                0: begin cfg_zp=0; cfg_min=-128; cfg_max=127; end
                1: begin cfg_zp=17; cfg_min=-100; cfg_max=100; end
                2: begin cfg_zp=-23; cfg_min=-64; cfg_max=63; end
                3: begin cfg_zp=127; cfg_min=0; cfg_max=127; end
                4: begin cfg_zp=-7; cfg_min=-7; cfg_max=9; end
                default: begin cfg_zp=3; cfg_min=-128; cfg_max=126; end
            endcase
            output_zero_point_int32 = cfg_zp;
            activation_min_int32 = cfg_min;
            activation_max_int32 = cfg_max;
        end
    endtask

    task append_expected;
        integer lane, rr, bb, base;
        reg [1:0] m;
        reg signed [7:0] d0, d1;
        begin
            for (rr = 0; rr < 8; rr = rr + 1)
                for (bb = 0; bb < 4; bb = bb + 1) begin
                    base = rr*8 + bb*2;
                    m = 2'b0;
                    d0 = rq_ref(acc[base], cfg_bias[bb*2], cfg_mul[bb*2],
                                cfg_shift[bb*2], cfg_zp, cfg_min, cfg_max);
                    d1 = rq_ref(acc[base+1], cfg_bias[bb*2+1], cfg_mul[bb*2+1],
                                cfg_shift[bb*2+1], cfg_zp, cfg_min, cfg_max);
                    if ((rr < p_lanes) && (bb*2 < c_lanes)) m[0] = 1'b1;
                    if ((rr < p_lanes) && (bb*2+1 < c_lanes)) m[1] = 1'b1;
                    exp_pixel[expected_count] = p_base_i + rr;
                    exp_cout[expected_count] = c_base_i + bb*2;
                    exp_row[expected_count] = rr;
                    exp_beat[expected_count] = bb;
                    exp_mask[expected_count] = m;
                    exp_data[expected_count] = {d1,d0};
                    expected_count = expected_count + 1;
                end
        end
    endtask

    task drive_block;
        begin
            p_lanes = p_total-p_base_i; if (p_lanes > 8) p_lanes=8;
            c_lanes = c_total-c_base_i; if (c_lanes > 8) c_lanes=8;
            build_config();
            for (i=0; i<64; i=i+1) acc[i]=0;
            for (k=0; k<cin; k=k+1) begin
                @(negedge clk);
                act_vec=0; wgt_vec=0;
                for (i=0; i<8; i=i+1)
                    act_vec[(i*8)+:8] = act_value(k,p_base_i+i,block_no);
                for (j=0; j<8; j=j+1)
                    wgt_vec[(j*8)+:8] = wgt_value(k,c_base_i+j,block_no);
                for (i=0; i<8; i=i+1)
                    for (j=0; j<8; j=j+1)
                        if ((i<p_lanes) && (j<c_lanes))
                            acc[i*8+j] = acc[i*8+j] +
                                act_value(k,p_base_i+i,block_no) *
                                wgt_value(k,c_base_i+j,block_no);
                first_k=(k==0); last_k=(k==cin-1); k_idx=k;
                pixel_mask=(p_lanes==8)?8'hff:((1<<p_lanes)-1);
                cout_mask=(c_lanes==8)?8'hff:((1<<c_lanes)-1);
                valid_in=1'b1;
                while (!ready_in) begin @(posedge clk); @(negedge clk); end
                @(posedge clk);
                @(negedge clk);
                valid_in=1'b0; first_k=0; last_k=0; k_idx=0;
                if ((k % 11)==4) repeat (2) @(posedge clk);
            end
            append_expected();
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            if (valid_in && ready_in && dut.drain_active)
                overlap_accepts = overlap_accepts + 1;
            if (stalled_prev) begin
                if (!valid_out || out_pixel_idx!==stalled_pixel ||
                    out_channel_base!==stalled_cout ||
                    out_lane_mask!==stalled_mask || out_data!==stalled_data)
                    errors = errors + 1;
                if (ready_out) stalled_prev=0;
            end
            if (valid_out && !ready_out) begin
                stalled_prev=1; stalled_pixel=out_pixel_idx;
                stalled_cout=out_channel_base; stalled_mask=out_lane_mask;
                stalled_data=out_data;
            end
            if (valid_out && ready_out) begin
                if (output_count >= expected_count) errors=errors+1;
                else begin
                    if (out_pixel_idx!==exp_pixel[output_count] ||
                        out_channel_base!==exp_cout[output_count] ||
                        out_row_idx!==exp_row[output_count] ||
                        out_beat_idx!==exp_beat[output_count] ||
                        out_lane_mask!==exp_mask[output_count]) begin
                        $display("TAG_MISMATCH n=%0d got p=%0d c=%0d r=%0d b=%0d m=%b exp p=%0d c=%0d r=%0d b=%0d m=%b",
                                 output_count,out_pixel_idx,out_channel_base,
                                 out_row_idx,out_beat_idx,out_lane_mask,
                                 exp_pixel[output_count],exp_cout[output_count],
                                 exp_row[output_count],exp_beat[output_count],
                                 exp_mask[output_count]);
                        errors=errors+1;
                    end
                    if ((out_lane_mask[0] && out_data[7:0] !== exp_data[output_count][7:0]) ||
                        (out_lane_mask[1] && out_data[15:8] !== exp_data[output_count][15:8])) begin
                        $display("DATA_MISMATCH n=%0d got=%h exp=%h mask=%b",
                                 output_count,out_data,exp_data[output_count],out_lane_mask);
                        errors=errors+1;
                    end
                end
                output_count=output_count+1;
            end
        end
    end

    always @(negedge clk) begin
        if (!rst_n) ready_out <= 1'b1;
        else begin
            cycle_no=cycle_no+1;
            ready_out <= ((cycle_no % 29)==3 || (cycle_no % 29)==4 ||
                          (cycle_no % 37)==11) ? 1'b0 : 1'b1;
        end
    end

    integer pp, cc, ci;
    initial begin
        clk=0; rst_n=0; valid_in=0; first_k=0; last_k=0; k_idx=0;
        pixel_mask=0; cout_mask=0; act_vec=0; wgt_vec=0;
        pixel_base=0; cout_base=0; output_pixels=8; output_channels=8;
        bias_vec=0; multiplier_vec=0; shift_vec=0;
        output_zero_point_int32=0; activation_min_int32=-128;
        activation_max_int32=127; ready_out=1; expected_count=0;
        output_count=0; errors=0; cycle_no=0; seed=32'h19a5d7c3;
        overlap_accepts=0;
        stalled_prev=0; block_no=0;
        repeat (5) @(posedge clk); rst_n=1;
        /* All requested tail/channel/K shapes.  The second bank is exercised
         * by presenting each next reduction as soon as ready_in permits. */
        for (ci=0; ci<4; ci=ci+1) begin
            cin = (ci==0)?16:(ci==1)?32:(ci==2)?48:128;
            for (pp=0; pp<3; pp=pp+1) begin
                p_total=(pp==0)?1:(pp==1)?8:17;
                for (cc=0; cc<3; cc=cc+1) begin
                    c_total=(cc==0)?8:(cc==1)?13:16;
                    for (p_base_i=0; p_base_i<p_total; p_base_i=p_base_i+8) begin
                        pixel_base=p_base_i; p_base_i=p_base_i;
                        for (c_base_i=0; c_base_i<c_total; c_base_i=c_base_i+8) begin
                            pixel_base = p_base_i;
                            cout_base = c_base_i;
                            drive_block();
                            block_no=block_no+1;
                        end
                    end
                end
            end
        end
        valid_in=0;
        while ((output_count < expected_count || busy) && cycle_no < 500000)
            @(posedge clk);
        if (output_count != expected_count || busy) begin
            $display("FAIL timeout outputs=%0d/%0d busy=%b cycles=%0d",
                     output_count,expected_count,busy,cycle_no); $fatal;
        end
        if (overlap_accepts == 0) begin
            $display("FAIL no overlap admissions observed"); $fatal;
        end
        if (errors != 0) begin
            $display("FAIL tb_pw_direct_8x8_dsp_rowbank errors=%0d",errors); $fatal;
        end
        $display("PASS tb_pw_direct_8x8_dsp_rowbank blocks=%0d pairs=%0d cycles=%0d",
                 block_no,expected_count,cycle_no);
        $display("OVERLAP admissions=%0d", overlap_accepts);
        $finish;
    end
endmodule

`default_nettype wire
