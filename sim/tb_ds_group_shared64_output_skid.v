`timescale 1ns/1ps
`default_nettype none

/* Protocol-only proof for the group shared64 output command boundary. */
module tb_ds_group_shared64_output_skid;
    reg clk = 1'b0;
    always #1 clk = ~clk;
    reg rst_n = 1'b0;
    reg in_valid = 1'b0;
    wire in_ready;
    reg [14:0] in_addr = 15'd0;
    reg [31:0] in_data = 32'd0;
    reg [3:0] in_be = 4'd0;
    reg in_bank = 1'b0;
    reg in_last = 1'b0;
    wire out_valid;
    reg out_ready = 1'b1;
    wire [14:0] out_addr;
    wire [31:0] out_data;
    wire [3:0] out_be;
    wire out_bank;
    wire out_last;
    wire in_fire;
    wire out_fire;

    ds_group_shared64_output_skid dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_addr(in_addr), .in_data(in_data), .in_be(in_be),
        .in_bank(in_bank), .in_last(in_last),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_addr(out_addr), .out_data(out_data), .out_be(out_be),
        .out_bank(out_bank), .out_last(out_last),
        .in_fire(in_fire), .out_fire(out_fire)
    );

    reg [14:0] expected_addr [0:127];
    reg [31:0] expected_data [0:127];
    reg [3:0] expected_be [0:127];
    reg expected_bank [0:127];
    reg expected_last [0:127];
    integer head = 0;
    integer tail = 0;
    integer in_count = 0;
    integer out_count = 0;
    integer cycle_count = 0;
    integer first_out_cycle = -1;
    integer previous_out_cycle = -1;
    integer output_gaps = 0;
    integer stall_cycles = 0;
    integer errors = 0;
    reg hold_seen = 1'b0;
    reg [14:0] hold_addr;
    reg [31:0] hold_data;
    reg [3:0] hold_be;
    reg hold_bank;
    reg hold_last;

    always @(posedge clk) begin
        if (!rst_n) begin
            head = 0;
            tail = 0;
            in_count = 0;
            out_count = 0;
            cycle_count = 0;
            first_out_cycle = -1;
            previous_out_cycle = -1;
            output_gaps = 0;
            stall_cycles = 0;
            hold_seen = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;

            if (in_fire) begin
                expected_addr[tail] = in_addr;
                expected_data[tail] = in_data;
                expected_be[tail] = in_be;
                expected_bank[tail] = in_bank;
                expected_last[tail] = in_last;
                tail = tail + 1;
                in_count = in_count + 1;
            end

            if (out_valid && !out_ready) begin
                stall_cycles = stall_cycles + 1;
                if (!hold_seen) begin
                    hold_seen = 1'b1;
                    hold_addr = out_addr;
                    hold_data = out_data;
                    hold_be = out_be;
                    hold_bank = out_bank;
                    hold_last = out_last;
                end else if ((out_addr !== hold_addr) ||
                             (out_data !== hold_data) ||
                             (out_be !== hold_be) ||
                             (out_bank !== hold_bank) ||
                             (out_last !== hold_last)) begin
                    $display("FAIL skid command changed while stalled");
                    errors = errors + 1;
                end
                if (in_ready !== 1'b0) begin
                    $display("FAIL skid accepted input while full and stalled");
                    errors = errors + 1;
                end
            end else if (!out_valid || out_ready) begin
                hold_seen = 1'b0;
            end

            if (out_fire) begin
                if (head >= tail) begin
                    $display("FAIL skid produced output without queued input");
                    errors = errors + 1;
                end else begin
                    if ((out_addr !== expected_addr[head]) ||
                        (out_data !== expected_data[head]) ||
                        (out_be !== expected_be[head]) ||
                        (out_bank !== expected_bank[head]) ||
                        (out_last !== expected_last[head])) begin
                        $display("FAIL skid order/data head=%0d got addr=%0d data=%h be=%h bank=%b last=%b exp addr=%0d data=%h be=%h bank=%b last=%b",
                                 head, out_addr, out_data, out_be, out_bank, out_last,
                                 expected_addr[head], expected_data[head], expected_be[head],
                                 expected_bank[head], expected_last[head]);
                        errors = errors + 1;
                    end
                    head = head + 1;
                    out_count = out_count + 1;
                    if (first_out_cycle < 0)
                        first_out_cycle = cycle_count;
                    if ((previous_out_cycle >= 0) &&
                        (cycle_count != previous_out_cycle + 1))
                        output_gaps = output_gaps + 1;
                    previous_out_cycle = cycle_count;
                end
            end
        end
    end

    task reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            in_valid = 1'b0;
            out_ready = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task drive_command;
        input integer addr;
        input [31:0] data;
        input [3:0] be;
        input bank;
        input last;
        begin
            in_addr = addr[14:0];
            in_data = data;
            in_be = be;
            in_bank = bank;
            in_last = last;
        end
    endtask

    integer i;
    initial begin
        /* Continuous stream: after the first registered word, every sink
         * cycle must fire and replace the entry with no bubble. */
        reset_dut();
        @(negedge clk);
        in_valid = 1'b1;
        for (i = 0; i < 16; i = i + 1) begin
            drive_command(i * 4, 32'h1000 + i, 4'hf, i[0], 1'b0);
            @(posedge clk);
        end
        @(negedge clk);
        in_valid = 1'b0;
        drive_command(0, 0, 0, 0, 0);
        repeat (3) @(posedge clk);
        if (output_gaps != 0) begin
            $display("FAIL continuous stream had %0d output gaps", output_gaps);
            errors = errors + 1;
        end
        if (in_count != 16 || out_count != 16 || head != tail) begin
            $display("FAIL continuous counts in=%0d out=%0d head=%0d tail=%0d",
                     in_count, out_count, head, tail);
            errors = errors + 1;
        end

        /* Stall the sink after one command is resident.  The command and
         * its last/bank sidebands must remain stable; the source must see
         * ready low until the sink releases the entry. */
        reset_dut();
        @(negedge clk);
        in_valid = 1'b1;
        drive_command(64, 32'hface0001, 4'b0111, 1'b1, 1'b0);
        @(posedge clk);
        @(negedge clk);
        out_ready = 1'b0;
        drive_command(68, 32'hface0002, 4'b0011, 1'b0, 1'b1);
        repeat (3) @(posedge clk);
        if (!out_valid || out_fire || in_fire) begin
            $display("FAIL stalled skid handshake valid=%b out_fire=%b in_fire=%b",
                     out_valid, out_fire, in_fire);
            errors = errors + 1;
        end
        @(negedge clk);
        out_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        in_valid = 1'b0;
        repeat (2) @(posedge clk);
        if (in_count != 2 || out_count != 2 || head != tail) begin
            /* The second command refills on the same edge as release. */
            $display("FAIL stalled release counts in=%0d out=%0d last=%b",
                     in_count, out_count, out_last);
            errors = errors + 1;
        end

        /* Explicit last fence: hold a last-marked command, then release it
         * and verify that the marker is committed exactly once. */
        reset_dut();
        @(negedge clk);
        in_valid = 1'b1;
        out_ready = 1'b0;
        drive_command(96, 32'h1a570001, 4'h1, 1'b1, 1'b1);
        @(posedge clk);
        @(negedge clk);
        in_valid = 1'b0;
        repeat (2) @(posedge clk);
        if (!out_valid || out_last !== 1'b1 || out_fire) begin
            $display("FAIL last command not held before commit valid=%b last=%b fire=%b",
                     out_valid, out_last, out_fire);
            errors = errors + 1;
        end
        @(negedge clk);
        out_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        in_valid = 1'b0;
        repeat (2) @(posedge clk);
        if (in_count != 1 || out_count != 1 || head != tail) begin
            $display("FAIL last fence counts in=%0d out=%0d head=%0d tail=%0d",
                     in_count, out_count, head, tail);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS tb_ds_group_shared64_output_skid continuous=16 stall_cycles=%0d last=1",
                     stall_cycles);
        else begin
            $display("FAIL tb_ds_group_shared64_output_skid errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule

`default_nettype wire
