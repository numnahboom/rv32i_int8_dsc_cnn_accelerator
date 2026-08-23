`timescale 1ns/1ps
`default_nettype none

// Small direct test for the three-cycle Stem requant path.  Zero input and
// weights make bias the exact accumulator value, allowing fixed-point tie,
// shift-63, int8 saturation, and activation-boundary cases to be isolated.
module tb_conv3x3_stem_engine_new_requant;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg cfg_wr_en = 1'b0;
    wire cfg_ready;
    reg [3:0] cfg_target;
    reg [15:0] cfg_index;
    reg [31:0] cfg_data;
    reg start = 1'b0;
    wire busy;
    wire done;
    wire error;
    wire out_wr_en;
    wire [5:0] out_wr_pixel_idx;
    wire [3:0] out_wr_channel_idx;
    wire signed [7:0] out_wr_data_int8;
    integer writes = 0;
    integer errors = 0;
    integer cycles = 0;
    integer i;
    reg signed [7:0] expected [0:15];

    always #5 clk = ~clk;

    conv3x3_stem_engine_new dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr_en(cfg_wr_en), .cfg_ready(cfg_ready),
        .cfg_target(cfg_target), .cfg_index(cfg_index), .cfg_data(cfg_data),
        .start(start), .busy(busy), .done(done), .error(error),
        .out_h(4'd1), .out_w(4'd1),
        .output_zero_point(32'sd1),
        .activation_min(-32'sd2), .activation_max(32'sd2),
        .out_wr_en(out_wr_en), .out_wr_pixel_idx(out_wr_pixel_idx),
        .out_wr_channel_idx(out_wr_channel_idx),
        .out_wr_data_int8(out_wr_data_int8)
    );

    task automatic cfg_write(input [3:0] target, input integer index,
                             input [31:0] data);
        begin
            while (!cfg_ready) @(posedge clk);
            @(negedge clk);
            cfg_target = target;
            cfg_index = index;
            cfg_data = data;
            cfg_wr_en = 1'b1;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (out_wr_en) begin
            if (out_wr_pixel_idx !== 0 || out_wr_channel_idx !== writes[3:0]) begin
                $display("FAIL write order pixel=%0d channel=%0d index=%0d",
                         out_wr_pixel_idx, out_wr_channel_idx, writes);
                errors = errors + 1;
            end
            if (out_wr_data_int8 !== expected[writes]) begin
                $display("FAIL data channel=%0d expected=%0d actual=%0d",
                         writes, expected[writes], out_wr_data_int8);
                errors = errors + 1;
            end
            writes = writes + 1;
        end
    end

    initial begin
        cfg_target = 0;
        cfg_index = 0;
        cfg_data = 0;
        expected[0] = 8'sd2;   // +1 * 2^30: positive half-tie rounds away
        expected[1] = 8'sd0;   // -1 * 2^30: negative half-tie rounds away
        expected[2] = 8'sd1;   // shift=63 arithmetic shift of rounded +1
        expected[3] = 8'sd2;   // int8 127 + zp, then activation max=2
        expected[4] = -8'sd2;  // negative int8, then activation min=-2
        for (i = 5; i < 16; i = i + 1) expected[i] = 8'sd1;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        // Initialize every input/weight byte so no X can enter the MAC.
        for (i = 0; i < 300; i = i + 1) cfg_write(4'd0, i, 32'd0);
        for (i = 0; i < 432; i = i + 1) cfg_write(4'd1, i, 32'd0);
        for (i = 0; i < 16; i = i + 1) begin
            case (i)
                0: cfg_write(4'd2, i, 32'd1);
                1: cfg_write(4'd2, i, -32'sd1);
                2: cfg_write(4'd2, i, 32'd1);
                3: cfg_write(4'd2, i, 32'd127);
                4: cfg_write(4'd2, i, -32'sd128);
                default: cfg_write(4'd2, i, 32'd0);
            endcase
            case (i)
                0, 1: cfg_write(4'd3, i, 32'h40000000);
                3, 4: cfg_write(4'd3, i, 32'h7fffffff);
                default: cfg_write(4'd3, i, 32'd0);
            endcase
            cfg_write(4'd4, i, (i == 2) ? 32'd63 : 32'd0);
        end
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        while (!done && cycles < 20000) begin @(posedge clk); cycles = cycles + 1; end
        if (!done || error || writes != 16 || errors != 0) begin
            $display("FAIL tb_conv3x3_stem_engine_new_requant done=%b error=%b writes=%0d errors=%0d cycles=%0d",
                     done, error, writes, errors, cycles);
            $fatal;
        end
        $display("PASS tb_conv3x3_stem_engine_new_requant writes=%0d cycles=%0d", writes, cycles);
        $finish;
    end
endmodule

`default_nettype wire
