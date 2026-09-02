`timescale 1ns/1ps
`default_nettype none

/* Complete real-vector mb16_down controller gate. */
module tb_edgembconv_hwacandidate_d4_mb16_controller;
    localparam integer INPUT_BYTES = 32*32*16;
    localparam integer OUTPUT_BYTES = 16*16*32;
    localparam integer PW_WEIGHT_BYTES = 4096;
    localparam integer DW_WEIGHT_BYTES = 288;

    reg clk, rst_n;
    reg cfg_valid;
    wire cfg_ready;
    reg [2:0] cfg_kind;
    reg [15:0] cfg_addr;
    reg [31:0] cfg_data;
    reg start_valid;
    wire start_ready;
    reg [3:0] start_epoch;
    wire done_valid;
    reg done_ready;
    wire [3:0] done_epoch;
    wire out_valid;
    reg out_ready;
    wire [15:0] out_index;
    wire signed [7:0] out_data;
    wire busy;
    wire [1:0] scratch0_state, scratch1_state;
    wire [3:0] active_epoch;
    wire [31:0] cycle_count, pw_mac_count, dw_mac_count, overlap_cycles, protocol_errors;
    reg scratch_read_ready;

    reg [7:0] input_vec [0:INPUT_BYTES-1];
    reg [7:0] expected_vec [0:OUTPUT_BYTES-1];
    reg [7:0] exp_w [0:511];
    reg [7:0] proj_w [0:1023];
    reg [7:0] dw_w [0:287];
    reg [31:0] exp_bias [0:31], exp_mul [0:31];
    reg [7:0] exp_shift [0:31];
    reg [31:0] proj_bias [0:31], proj_mul [0:31];
    reg [7:0] proj_shift [0:31];
    reg [31:0] dw_bias [0:31], dw_mul [0:31];
    reg [7:0] dw_shift [0:31];

    integer errors, i, checked, start_cycle, end_cycle;
    integer seen_s0_fill, seen_s0_ready, seen_s0_active;
    integer seen_s1_fill, seen_s1_ready, seen_s1_active;
    integer stable_index;

    edgembconv_hwacandidate_d4_mb16_controller dut (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_kind(cfg_kind), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_epoch(start_epoch), .done_valid(done_valid),
        .done_ready(done_ready), .done_epoch(done_epoch),
        .out_valid(out_valid), .out_ready(out_ready), .out_index(out_index),
        .out_data(out_data), .busy(busy), .scratch0_state(scratch0_state),
        .scratch1_state(scratch1_state), .active_epoch(active_epoch),
        .cycle_count(cycle_count), .pw_mac_count(pw_mac_count),
        .dw_mac_count(dw_mac_count), .overlap_cycles(overlap_cycles),
        .protocol_errors(protocol_errors), .scratch_read_ready(scratch_read_ready)
    );

    always #5 clk = ~clk;

    task cfg_word;
        input integer kind; input integer addr; input [31:0] data;
        begin
            @(negedge clk);
            while (!cfg_ready) @(negedge clk);
            cfg_kind = kind[2:0]; cfg_addr = addr[15:0]; cfg_data = data;
            cfg_valid = 1'b1;
            @(posedge clk); @(negedge clk);
            cfg_valid = 1'b0; cfg_kind = 0; cfg_addr = 0; cfg_data = 0;
        end
    endtask
    task cfg_byte;
        input integer kind; input integer addr; input [7:0] data;
        begin cfg_word(kind, addr, {24'd0, data}); end
    endtask

    task load_vectors;
        begin
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_input.mem", input_vec);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_output.mem", expected_vec);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_weight.mem", exp_w);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_weight.mem", proj_w);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_weight.mem", dw_w);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_bias.mem", exp_bias);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_multiplier.mem", exp_mul);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_shift.mem", exp_shift);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_bias.mem", proj_bias);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_multiplier.mem", proj_mul);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_shift.mem", proj_shift);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_bias.mem", dw_bias);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_multiplier.mem", dw_mul);
            $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_shift.mem", dw_shift);
            for (i = 0; i < INPUT_BYTES; i = i + 1) cfg_byte(0, i, input_vec[i]);
            for (i = 0; i < 512; i = i + 1) cfg_byte(1, 2048+i, exp_w[i]);
            for (i = 0; i < 1024; i = i + 1) cfg_byte(1, 3072+i, proj_w[i]);
            for (i = 0; i < 288; i = i + 1) cfg_byte(2, i, dw_w[i]);
            for (i = 0; i < 32; i = i + 1) begin
                cfg_word(3, 64+i, exp_bias[i]); cfg_word(4, 64+i, exp_mul[i]); cfg_byte(5, 64+i, exp_shift[i]);
                cfg_word(3, 96+i, proj_bias[i]); cfg_word(4, 96+i, proj_mul[i]); cfg_byte(5, 96+i, proj_shift[i]);
                cfg_word(3, 160+i, dw_bias[i]); cfg_word(4, 160+i, dw_mul[i]); cfg_byte(5, 160+i, dw_shift[i]);
            end
        end
    endtask

    integer timeout_count;
    initial begin
        #5000000;
        $display("TIMEOUT mb16 controller cycle=%0d state=%0d out=%0d py=%0d px=%0d grp=%0d k=%0d rq=%0d cvalid=%b cmode=%b cready=%b poolfinal=%b pw112v=%b poolv=%b first=%b last=%b pf=%b pl=%b", cycle_count, dut.state, checked, dut.pw_y, dut.pw_x, dut.pw_group, dut.pw_k, dut.rq_base, dut.comp_out_valid, dut.comp_out_mode_rq, dut.comp_op_ready, dut.u_composite.pool_final_pending, dut.u_composite.pw112_valid, dut.u_composite.pool_valid_out, dut.u_composite.pool_first_d2, dut.u_composite.pool_last_d2, dut.u_composite.u_pw112.product_last, dut.u_composite.u_pw112.product_valid);
        $fatal;
    end

    /* Randomized (deterministic) backpressure at both visible boundaries. */
    always @(negedge clk) begin
        if (rst_n) begin
            scratch_read_ready <= ((cycle_count * 17 + 3) % 7) != 1;
            out_ready <= ((cycle_count * 13 + 5) % 17) != 4;
        end
    end

    always @(posedge clk) begin
        if (rst_n && busy) begin
            if (scratch0_state == 1) seen_s0_fill = 1;
            if (scratch0_state == 2) seen_s0_ready = 1;
            if (scratch0_state == 3) seen_s0_active = 1;
            if (scratch1_state == 1) seen_s1_fill = 1;
            if (scratch1_state == 2) seen_s1_ready = 1;
            if (scratch1_state == 3) seen_s1_active = 1;
        end
        if (out_valid && !out_ready) begin
            if (stable_index < 0) stable_index = out_index;
            else if (out_index !== stable_index[15:0]) begin
                $display("STALL_INDEX_CHANGED exp=%0d got=%0d", stable_index, out_index);
                errors = errors + 1;
            end
        end else stable_index = -1;
        if (out_valid && out_ready) begin
            if (out_index !== checked[15:0] || out_data !== expected_vec[checked]) begin
                $display("MISMATCH index=%0d exp=%02x got=%02x", checked, expected_vec[checked], out_data);
                errors = errors + 1;
            end
            checked = checked + 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0; cfg_valid = 0; cfg_kind = 0; cfg_addr = 0; cfg_data = 0;
        start_valid = 0; start_epoch = 0; done_ready = 1; out_ready = 1;
        scratch_read_ready = 1; errors = 0; checked = 0; stable_index = -1;
        seen_s0_fill = 0; seen_s0_ready = 0; seen_s0_active = 0;
        seen_s1_fill = 0; seen_s1_ready = 0; seen_s1_active = 0;
        repeat (5) @(posedge clk); rst_n = 1;
        load_vectors();
        @(negedge clk); while (!start_ready) @(negedge clk);
        start_epoch = 4'ha; start_valid = 1;
        @(posedge clk); @(negedge clk); start_valid = 0;
        start_cycle = cycle_count;
        while (!done_valid) @(posedge clk);
        end_cycle = cycle_count;
        if (checked != OUTPUT_BYTES) begin
            $display("OUTPUT_COUNT got=%0d exp=%0d", checked, OUTPUT_BYTES); errors = errors + 1;
        end
        if (!(seen_s0_fill && seen_s0_ready && seen_s0_active && seen_s1_fill && seen_s1_ready && seen_s1_active)) begin
            $display("BANK_FENCE_MISSING s0=%0d%0d%0d s1=%0d%0d%0d", seen_s0_fill, seen_s0_ready, seen_s0_active, seen_s1_fill, seen_s1_ready, seen_s1_active);
            errors = errors + 1;
        end
        if (done_epoch !== 4'ha || active_epoch !== 4'ha || protocol_errors != 0) errors = errors + 1;
        $display("D4_MB16 block=mb16_down output_bytes=%0d cycles=%0d pw_mac=%0d dw_mac=%0d overlap=%0d scratch=%b/%b errors=%0d", checked, end_cycle-start_cycle, pw_mac_count, dw_mac_count, overlap_cycles, scratch0_state, scratch1_state, errors);
        if (errors == 0) $display("PASS edgembconv_hwacandidate_d4_mb16_controller exact=8192 random_backpressure=checked");
        else begin $display("FAIL edgembconv_hwacandidate_d4_mb16_controller errors=%0d", errors); $fatal; end
        $finish;
    end
endmodule
`default_nettype wire
