`timescale 1ns/1ps
`default_nettype none

/* Exact end-to-end block shell test.  All operands and expected bytes are
 * generated from the frozen D4 deployment archive; no synthetic arithmetic
 * vectors are used. */
module tb_edgembconv_hwacandidate_d4_block_shell;
    localparam integer INPUT_BYTES = 32*32*16;
    localparam integer MAX_WEIGHT_BYTES = 1024;
    localparam integer MAX_DW_BYTES = 288;

    reg clk, rst_n;
    reg cfg_valid;
    wire cfg_ready;
    reg [2:0] cfg_kind;
    reg [15:0] cfg_addr;
    reg [31:0] cfg_data;
    reg start_valid;
    wire start_ready;
    reg start_block_id;
    reg [3:0] start_epoch;
    wire done_valid;
    reg done_ready;
    wire done_block_id;
    wire [3:0] done_epoch;
    wire out_valid;
    reg out_ready;
    wire [15:0] out_index;
    wire signed [7:0] out_data;
    wire out_bank, busy;
    wire [1:0] scratch0_state, scratch1_state;
    wire [3:0] active_epoch;
    wire [31:0] cycle_count, pw_mac_count, dw_mac_count, overlap_cycles, protocol_errors;

    reg [7:0] input_vec [0:INPUT_BYTES-1];
    reg [7:0] expected_vec [0:INPUT_BYTES-1];
    reg [7:0] pw_expand_w [0:MAX_WEIGHT_BYTES-1];
    reg [7:0] pw_project_w [0:MAX_WEIGHT_BYTES-1];
    reg [7:0] dw_w [0:MAX_DW_BYTES-1];
    reg [31:0] pw_expand_bias [0:31];
    reg [31:0] pw_expand_mul [0:31];
    reg [7:0] pw_expand_shift [0:31];
    reg [31:0] pw_project_bias [0:31];
    reg [31:0] pw_project_mul [0:31];
    reg [7:0] pw_project_shift [0:31];
    reg [31:0] dw_bias [0:31];
    reg [31:0] dw_mul [0:31];
    reg [7:0] dw_shift [0:31];
    reg [31:0] residual_vec [0:3];

    integer errors, i, n, expected_count, start_cycle, end_cycle;
    integer input_count, output_count, expand_weight_count, project_weight_count;
    integer dw_weight_count, expand_cout, project_cout, expand_cin;
    integer stable_index, checked_outputs;
    integer seen_s0_fill, seen_s0_ready, seen_s0_active, seen_s0_free;
    integer seen_s1_fill, seen_s1_ready, seen_s1_active, seen_s1_free;

    edgembconv_hwacandidate_d4_block_shell dut (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_kind(cfg_kind), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_block_id(start_block_id), .start_epoch(start_epoch),
        .done_valid(done_valid), .done_ready(done_ready),
        .done_block_id(done_block_id), .done_epoch(done_epoch),
        .out_valid(out_valid), .out_ready(out_ready), .out_index(out_index),
        .out_data(out_data), .out_bank(out_bank), .busy(busy),
        .scratch0_state(scratch0_state), .scratch1_state(scratch1_state),
        .active_epoch(active_epoch), .cycle_count(cycle_count),
        .pw_mac_count(pw_mac_count), .dw_mac_count(dw_mac_count),
        .overlap_cycles(overlap_cycles), .protocol_errors(protocol_errors)
    );

    always #5 clk = ~clk;

    task cfg_word;
        input integer kind;
        input integer addr;
        input [31:0] data;
        begin
            @(negedge clk);
            while (!cfg_ready) @(negedge clk);
            cfg_kind = kind[2:0]; cfg_addr = addr[15:0]; cfg_data = data;
            cfg_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cfg_valid = 1'b0; cfg_kind = 3'd0; cfg_addr = 16'd0; cfg_data = 32'd0;
        end
    endtask

    task cfg_byte;
        input integer kind;
        input integer addr;
        input [7:0] data;
        begin cfg_word(kind, addr, {24'd0, data}); end
    endtask

    task load_block;
        input integer which;
        begin
            if (which == 0) begin
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_input.mem", input_vec);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_output.mem", expected_vec);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_pw_expand_weight.mem", pw_expand_w);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_pw_project_weight.mem", pw_project_w);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_dw_weight.mem", dw_w);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_pw_expand_bias.mem", pw_expand_bias);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_pw_expand_multiplier.mem", pw_expand_mul);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_pw_expand_shift.mem", pw_expand_shift);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_pw_project_bias.mem", pw_project_bias);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_pw_project_multiplier.mem", pw_project_mul);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_pw_project_shift.mem", pw_project_shift);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_dw_bias.mem", dw_bias);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_dw_multiplier.mem", dw_mul);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_dw_shift.mem", dw_shift);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb32_residual.mem", residual_vec);
                input_count = 16384; output_count = 16384; expand_weight_count = 512; project_weight_count = 512; expand_cin = 16; expand_cout = 32; project_cout = 16; dw_weight_count = 288;
            end else begin
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_input.mem", input_vec);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_output.mem", expected_vec);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_weight.mem", pw_expand_w);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_weight.mem", pw_project_w);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_weight.mem", dw_w);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_bias.mem", pw_expand_bias);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_multiplier.mem", pw_expand_mul);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_expand_shift.mem", pw_expand_shift);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_bias.mem", pw_project_bias);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_multiplier.mem", pw_project_mul);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_pw_project_shift.mem", pw_project_shift);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_bias.mem", dw_bias);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_multiplier.mem", dw_mul);
                $readmemh("build/edgembconv_hwacandidate_d4_block_shell_vectors/mb16_down_dw_shift.mem", dw_shift);
                input_count = 16384; output_count = 8192; expand_weight_count = 512; project_weight_count = 1024; expand_cin = 16; expand_cout = 32; project_cout = 32; dw_weight_count = 288;
            end
            for (i = 0; i < input_count; i = i + 1) cfg_byte(0, i, input_vec[i]);
            /* Shell op offsets are 0/1/2/3, each reserved 1024 bytes. */
            for (i = 0; i < expand_weight_count; i = i + 1) cfg_byte(1, (which*2)*1024 + i, pw_expand_w[i]);
            for (i = 0; i < project_weight_count; i = i + 1) cfg_byte(1, (which*2+1)*1024 + i, pw_project_w[i]);
            for (i = 0; i < dw_weight_count; i = i + 1) cfg_byte(2, which*288 + i, dw_w[i]);
            for (i = 0; i < expand_cout; i = i + 1) begin
                cfg_word(3, (which*2)*32 + i, pw_expand_bias[i]); cfg_word(4, (which*2)*32 + i, pw_expand_mul[i]); cfg_byte(5, (which*2)*32 + i, pw_expand_shift[i]);
            end
            for (i = 0; i < project_cout; i = i + 1) begin
                cfg_word(3, (which*2+1)*32 + i, pw_project_bias[i]); cfg_word(4, (which*2+1)*32 + i, pw_project_mul[i]); cfg_byte(5, (which*2+1)*32 + i, pw_project_shift[i]);
            end
            for (i = 0; i < 32; i = i + 1) begin
                cfg_word(3, 128 + which*32 + i, dw_bias[i]); cfg_word(4, 128 + which*32 + i, dw_mul[i]); cfg_byte(5, 128 + which*32 + i, dw_shift[i]);
            end
            if (which == 0) begin
                cfg_word(6, 0, residual_vec[0]); cfg_word(6, 1, residual_vec[1]); cfg_word(6, 2, residual_vec[2]); cfg_word(6, 3, residual_vec[3]);
            end
        end
    endtask

    task run_block;
        input integer which;
        begin
            load_block(which);
            @(negedge clk); while (!start_ready) @(negedge clk);
            start_block_id = which[0:0]; start_epoch = which + 1; start_valid = 1'b1;
            @(posedge clk); @(negedge clk); start_valid = 1'b0;
            start_cycle = cycle_count;
            checked_outputs = 0; stable_index = -1;
            seen_s0_fill = 0; seen_s0_ready = 0; seen_s0_active = 0; seen_s0_free = 0;
            seen_s1_fill = 0; seen_s1_ready = 0; seen_s1_active = 0; seen_s1_free = 0;
            while (!done_valid) begin
                @(posedge clk);
                if (busy) begin
                    if (scratch0_state == 1) seen_s0_fill = 1;
                    if (scratch0_state == 2) seen_s0_ready = 1;
                    if (scratch0_state == 3) seen_s0_active = 1;
                    if (scratch1_state == 1) seen_s1_fill = 1;
                    if (scratch1_state == 2) seen_s1_ready = 1;
                    if (scratch1_state == 3) seen_s1_active = 1;
                end
                if (out_valid && !out_ready) begin
                    if (stable_index < 0) begin
                        stable_index = out_index;
                    end else if (out_index !== stable_index[15:0]) begin
                        $display("D4_BLOCK_STALL_INDEX_CHANGED block=%0d exp=%0d got=%0d", which, stable_index, out_index);
                        errors = errors + 1;
                    end
                end else begin
                    stable_index = -1;
                end
                if (out_valid && out_ready) begin
                    if (out_index !== checked_outputs[15:0] || out_data !== expected_vec[checked_outputs]) begin
                        $display("D4_BLOCK_MISMATCH block=%0d index=%0d exp=%02x got=%02x", which, checked_outputs, expected_vec[checked_outputs], out_data);
                        errors = errors + 1;
                    end
                    checked_outputs = checked_outputs + 1;
                end
            end
            end_cycle = cycle_count;
            if (checked_outputs != output_count) errors = errors + 1;
            if (!(seen_s0_fill && seen_s0_ready && seen_s0_active &&
                  seen_s1_fill && seen_s1_ready && seen_s1_active)) begin
                $display("D4_BLOCK_BANK_FENCE_MISSING block=%0d s0=%0d%0d%0d s1=%0d%0d%0d", which, seen_s0_fill, seen_s0_ready, seen_s0_active, seen_s1_fill, seen_s1_ready, seen_s1_active);
                errors = errors + 1;
            end
            if (done_block_id !== which[0:0] || done_epoch !== which + 1 || active_epoch !== which + 1) errors = errors + 1;
            if (protocol_errors != 0) errors = errors + 1;
            $display("D4_BLOCK block=%0d name=%s output_bytes=%0d cycles=%0d pw_mac=%0d dw_mac=%0d overlap=%0d scratch=%b/%b errors=%0d", which, which ? "mb16_down" : "mb32", checked_outputs, end_cycle-start_cycle, pw_mac_count, dw_mac_count, overlap_cycles, scratch0_state, scratch1_state, errors);
            @(posedge clk);
        end
    endtask

    always @(negedge clk) begin
        if (rst_n) begin
            /* Regular output stalls test valid/data/index stability. */
            out_ready <= ((cycle_count % 11) != 4);
        end
    end

    initial begin
        clk = 1'b0; rst_n = 1'b0; cfg_valid = 1'b0; cfg_kind = 0; cfg_addr = 0; cfg_data = 0;
        start_valid = 1'b0; start_block_id = 0; start_epoch = 0; done_ready = 1'b1; out_ready = 1'b1; errors = 0;
        repeat (5) @(posedge clk); rst_n = 1'b1;
        run_block(0);
        run_block(1);
        if (errors == 0) begin
            $display("PASS edgembconv_hwacandidate_d4_block_shell blocks=2 exact_bytes=24576 protocol_errors=0");
        end else begin
            $display("FAIL edgembconv_hwacandidate_d4_block_shell errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
