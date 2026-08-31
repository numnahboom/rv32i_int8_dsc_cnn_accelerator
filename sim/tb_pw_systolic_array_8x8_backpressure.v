`timescale 1ns/1ps
`default_nettype none

module tb_pw_systolic_array_8x8_backpressure;
    reg clk, rst_n, valid_in, clear_acc, k_last, ready_out;
    reg signed [63:0] act_vec, wgt_vec;
    wire ready_in, valid_out;
    wire signed [2047:0] psum_out;
    integer i, errors;
    reg signed [31:0] held_value;

    pw_systolic_array_8x8 dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(1'b0), .last_k(1'b0), .k_group(8'd0), .k_count(8'd0),
        .clear_acc(clear_acc), .k_last(k_last), .act_vec(act_vec),
        .wgt_vec(wgt_vec), .ready_out(ready_out), .valid_out(valid_out),
        .psum_out(psum_out)
    );
    always #5 clk = ~clk;

    task feed;
        input integer value;
        input first;
        input last;
        begin
            while (!ready_in) @(posedge clk);
            act_vec = {8{value[7:0]}};
            wgt_vec = {8{8'd1}};
            clear_acc = first;
            k_last = last;
            valid_in = 1'b1;
            /* A source drops valid after observing the transfer.  It must
             * not wait for ready to rise again: ready is correctly held low
             * while the completed reduction is being replayed. */
            @(posedge clk);
            valid_in = 1'b0;
            clear_acc = 1'b0;
            k_last = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid_in = 1'b0;
        clear_acc = 1'b0;
        k_last = 1'b0;
        act_vec = 64'sd0;
        wgt_vec = 64'sd0;
        ready_out = 1'b1;
        errors = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        feed(3, 1'b1, 1'b0);
        feed(-2, 1'b0, 1'b1);
        while (!valid_out) @(posedge clk);
        held_value = psum_out[31:0];
        ready_out = 1'b0;
        repeat (5) begin
            @(posedge clk);
            if (!valid_out || psum_out[31:0] !== held_value) errors = errors + 1;
        end
        ready_out = 1'b1;
        @(posedge clk);
        if (valid_out) begin
            $display("FAIL output did not consume after ready");
            errors = errors + 1;
        end

        /* A second banked block must start from zero, not the held block. */
        feed(5, 1'b1, 1'b0);
        feed(4, 1'b0, 1'b1);
        while (!valid_out) @(posedge clk);
        for (i = 0; i < 64; i = i + 1) begin
            if ($signed(psum_out[(i*32) +: 32]) !== 9) errors = errors + 1;
        end
        if (errors == 0) $display("PASS tb_pw_systolic_array_8x8_backpressure");
        else $display("FAIL tb_pw_systolic_array_8x8_backpressure errors=%0d", errors);
        if (errors != 0) $fatal;
        $finish;
    end
endmodule

`default_nettype wire
