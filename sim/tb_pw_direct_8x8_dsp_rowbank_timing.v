`timescale 1ns/1ps
`default_nettype none

/* No-backpressure issue/drain timing probe for one 8-pixel x 8-cout PW job.
 * The full packed-consumer regression covers scratch/loader correctness; this
 * probe isolates the exact row-bank service time so the DS ledger can charge
 * scratch reads and packed weight loading separately. */
module tb_pw_direct_8x8_dsp_rowbank_timing #(parameter integer TB_CIN=16);
    reg clk=0; always #1 clk=~clk;
    reg rst_n=0, valid_in=0, ready_out=1;
    wire ready_in, valid_out;
    reg first_k=0,last_k=0; reg [7:0] k_idx=0;
    reg [7:0] pixel_mask=8'hff, cout_mask=8'hff;
    reg signed [63:0] act_vec=64'sd0, wgt_vec=64'sd0;
    reg [5:0] pixel_base=0; reg [8:0] cout_base=0;
    reg [7:0] output_pixels=8; reg [8:0] output_channels=8;
    reg signed [255:0] bias_vec=0, multiplier_vec=0; reg [47:0] shift_vec=0;
    reg signed [31:0] zp=0, amin=-128, amax=127;
    wire [2:0] out_row; wire [1:0] out_beat, out_mask;
    wire [5:0] out_pixel; wire [8:0] out_cout;
    wire signed [15:0] out_data; wire busy;
    pw_direct_8x8_dsp_rowbank dut (
        .clk(clk),.rst_n(rst_n),.valid_in(valid_in),.ready_in(ready_in),
        .first_k(first_k),.last_k(last_k),.k_idx(k_idx),
        .pixel_mask(pixel_mask),.cout_mask(cout_mask),.act_vec(act_vec),
        .wgt_vec(wgt_vec),.pixel_base(pixel_base),.cout_base(cout_base),
        .output_pixels(output_pixels),.output_channels(output_channels),
        .bias_vec(bias_vec),.multiplier_vec(multiplier_vec),.shift_vec(shift_vec),
        .output_zero_point_int32(zp),.activation_min_int32(amin),
        .activation_max_int32(amax),.ready_out(ready_out),
        .valid_out(valid_out),.out_row_idx(out_row),.out_beat_idx(out_beat),
        .out_pixel_idx(out_pixel),.out_channel_base(out_cout),
        .out_lane_mask(out_mask),.out_data(out_data),.busy(busy)
    );
    integer cycles=0, start_cycle, end_cycle, errors=0, k, output_count=0;
    reg [2:0] last_row; reg [1:0] last_beat, last_mask;
    initial begin
        repeat(4) @(posedge clk); rst_n=1;
        @(negedge clk); valid_in=1; first_k=1; last_k=(TB_CIN==1);
        k_idx=0;
        while (!ready_in) @(posedge clk);
        @(posedge clk); start_cycle=cycles;
        /* Keep valid asserted: this is the packed feeder's one-token/cycle
         * contract, rather than a pulse-per-token testbench bubble. */
        for (k=1; k<TB_CIN; k=k+1) begin
            @(negedge clk); first_k=0; last_k=(k==TB_CIN-1); k_idx=k;
        end
        @(negedge clk); valid_in=0; first_k=0; last_k=0;
        while (output_count < 32) @(posedge clk);
        end_cycle=cycles;
        if (last_row!==3'd7 || last_beat!==2'd3 || last_mask!==2'b11) begin
            $display("PW_LAST got row=%0d beat=%0d mask=%b pixel=%0d cout=%0d valid=%b",
                     last_row,last_beat,last_mask,out_pixel,out_cout,valid_out);
            errors=errors+1;
        end
        if (errors==0)
            $display("PASS pw timing cin=%0d issue_to_last=%0d total_cycles=%0d",TB_CIN,
                     end_cycle-start_cycle,cycles);
        else begin $display("FAIL pw timing cin=%0d errors=%0d",TB_CIN,errors);$fatal(1);end
        $finish;
    end
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (rst_n && valid_out && ready_out) begin
            output_count <= output_count+1;
            last_row <= out_row; last_beat <= out_beat; last_mask <= out_mask;
        end
    end
    initial begin repeat(200000) @(posedge clk); $fatal(1,"WATCHDOG cin=%0d",TB_CIN); end
endmodule
`default_nettype wire
