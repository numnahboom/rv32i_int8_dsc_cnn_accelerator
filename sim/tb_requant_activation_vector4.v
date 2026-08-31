`timescale 1ns/1ps
`default_nettype none

/* Directed vector4 differential/scheduling check.  The selected operands are
 * deliberately small exact half-scale products, so the expected result is
 * independent of a simulator-specific integer helper.  The lane ready mask
 * is varied while every tagged result is checked by coordinates. */
module tb_requant_activation_vector4;
    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg signed [2047:0] psum_in;
    reg [5:0] pixel_base;
    reg [8:0] cout_base;
    reg [7:0] output_pixels;
    reg [8:0] output_channels;
    reg signed [255:0] bias_vec;
    reg signed [255:0] multiplier_vec;
    reg [47:0] shift_vec;
    reg signed [31:0] output_zero_point;
    reg signed [31:0] activation_min;
    reg signed [31:0] activation_max;
    wire [3:0] valid_out;
    reg [3:0] ready_out;
    wire [23:0] pixel_vec;
    wire [31:0] channel_vec;
    wire signed [31:0] data_vec;
    wire busy;

    integer i;
    integer errors;
    integer writes;
    integer expected;
    integer pix;
    integer cout;
    reg signed [7:0] expected_mem [0:63];
    reg seen [0:63];

    requant_activation_vector4 dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .psum_in(psum_in), .pixel_base(pixel_base), .cout_base(cout_base),
        .output_pixels(output_pixels), .output_channels(output_channels),
        .bias_vec(bias_vec), .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec), .output_zero_point_int32(output_zero_point),
        .activation_min_int32(activation_min),
        .activation_max_int32(activation_max), .valid_out(valid_out),
        .ready_out(ready_out), .out_pixel_idx_vec(pixel_vec),
        .out_channel_idx_vec(channel_vec), .out_data_int8_vec(data_vec),
        .busy(busy)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid_in = 1'b0;
        psum_in = 2048'sd0;
        pixel_base = 6'd0;
        cout_base = 9'd0;
        output_pixels = 8'd8;
        output_channels = 9'd8;
        bias_vec = 256'sd0;
        multiplier_vec = 256'sh4000000040000000400000004000000040000000400000004000000040000000;
        shift_vec = 48'd0;
        output_zero_point = 32'sd0;
        activation_min = -32'sd128;
        activation_max = 32'sd127;
        ready_out = 4'b1111;
        errors = 0;
        writes = 0;
        for (i = 0; i < 64; i = i + 1) begin
            expected_mem[i] = 8'sd0;
            seen[i] = 1'b0;
        end
        for (i = 0; i < 64; i = i + 1) begin
            /* Even values avoid a tie: Q31 0.5 maps 2*n -> n exactly. */
            psum_in[(i*32) +: 32] = (i - 31) * 2;
            expected_mem[i] = i - 31;
        end
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        valid_in <= 1'b1;
        while (!ready_in) @(posedge clk);
        @(posedge clk);
        valid_in <= 1'b0;

        while (writes < 64 && $time < 20000) begin
            /* Exercise independent elastic output lanes. */
            ready_out <= (($time / 10) & 3) == 1 ? 4'b0101 :
                         ((($time / 10) & 3) == 2 ? 4'b1010 : 4'b1111);
            @(posedge clk);
            for (i = 0; i < 4; i = i + 1) begin
                if (valid_out[i] && ready_out[i]) begin
                    pix = pixel_vec[(i*6) +: 6];
                    cout = channel_vec[(i*8) +: 8];
                    if (pix >= 8 || cout >= 8) begin
                        $display("BAD_TAG lane=%0d p=%0d c=%0d", i, pix, cout);
                        errors = errors + 1;
                    end else begin
                        expected = expected_mem[pix*8 + cout];
                        if ($signed(data_vec[(i*8) +: 8]) !== expected) begin
                            $display("MISMATCH p=%0d c=%0d expected=%0d actual=%0d",
                                     pix, cout, expected,
                                     $signed(data_vec[(i*8) +: 8]));
                            errors = errors + 1;
                        end
                        if (seen[pix*8 + cout]) errors = errors + 1;
                        seen[pix*8 + cout] = 1'b1;
                        writes = writes + 1;
                    end
                end
            end
        end
        if (writes != 64) begin
            $display("FAIL vector4 timeout writes=%0d busy=%0d", writes, busy);
            $fatal;
        end
        if (errors != 0) begin
            $display("FAIL vector4 errors=%0d", errors);
            $fatal;
        end
        $display("PASS tb_requant_activation_vector4 writes=%0d", writes);
        $finish;
    end
endmodule

`default_nettype wire
