`timescale 1ns/1ps
`default_nettype none

/*
 * Focused contract test for the physical v6 activation stores.
 *
 * This test intentionally drives the storage boundary directly instead of
 * going through the scheduler.  It covers the address maps, write-first
 * same-edge bypasses, one-entry response holding, and the split scratch1
 * bank-7 pool port.  It is a behavioral test; Vivado's XPM/RAMB mapping is
 * checked separately by the v6 OOC synthesis script.
 */
module tb_edgembconv_hwacandidate_d4_vstream_v6_banked_storage;
    reg clk;
    reg rst_n;

    reg        cfg_valid;
    reg [2:0]  cfg_kind;
    reg [15:0] cfg_addr;
    reg [31:0] cfg_data;

    reg  [7:0]  input_rd_valid;
    reg  [87:0] input_rd_addr_vec;
    wire        input_rd_ready;
    reg         input_rd_resp_ready;
    wire [63:0] input_rd_data_vec;
    wire        input_rd_resp_valid;

    reg         scratch0_rd_valid;
    reg  [10:0] scratch0_rd_addr;
    wire        scratch0_rd_ready;
    reg         scratch0_rd_resp_ready;
    wire [127:0] scratch0_rd_data;
    wire         scratch0_rd_resp_valid;

    reg  [15:0] scratch0_wr_valid_vec;
    reg  [10:0] scratch0_wr_addr;
    reg  [127:0] scratch0_wr_data_vec;

    reg  [7:0]  scratch1_rd_valid;
    reg  [63:0] scratch1_rd_addr_vec;
    wire        scratch1_rd_ready;
    reg         scratch1_rd_resp_ready;
    wire [255:0] scratch1_rd_data_vec;
    wire        scratch1_rd_resp_valid;

    reg         scratch1_pool_rd_valid;
    reg  [7:0]  scratch1_pool_rd_addr;
    wire        scratch1_pool_rd_ready;
    reg         scratch1_pool_rd_resp_ready;
    wire [31:0] scratch1_pool_rd_data;
    wire        scratch1_pool_rd_resp_valid;

    reg         scratch1_wr_valid;
    reg  [2:0]  scratch1_wr_bank;
    reg  [7:0]  scratch1_wr_addr;
    reg  [31:0] scratch1_wr_data;

    integer errors;
    integer b;
    integer row;
    integer addr_i;
    reg [63:0] input_hold_data;

    edgembconv_hwacandidate_d4_vstream_v6_banked_storage dut (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_valid(cfg_valid),
        .cfg_kind(cfg_kind),
        .cfg_addr(cfg_addr),
        .cfg_data(cfg_data),
        .input_rd_valid(input_rd_valid),
        .input_rd_addr_vec(input_rd_addr_vec),
        .input_rd_ready(input_rd_ready),
        .input_rd_resp_ready(input_rd_resp_ready),
        .input_rd_data_vec(input_rd_data_vec),
        .input_rd_resp_valid(input_rd_resp_valid),
        .scratch0_rd_valid(scratch0_rd_valid),
        .scratch0_rd_addr(scratch0_rd_addr),
        .scratch0_rd_ready(scratch0_rd_ready),
        .scratch0_rd_resp_ready(scratch0_rd_resp_ready),
        .scratch0_rd_data(scratch0_rd_data),
        .scratch0_rd_resp_valid(scratch0_rd_resp_valid),
        .scratch0_wr_valid_vec(scratch0_wr_valid_vec),
        .scratch0_wr_addr(scratch0_wr_addr),
        .scratch0_wr_data_vec(scratch0_wr_data_vec),
        .scratch1_rd_valid(scratch1_rd_valid),
        .scratch1_rd_addr_vec(scratch1_rd_addr_vec),
        .scratch1_rd_ready(scratch1_rd_ready),
        .scratch1_rd_resp_ready(scratch1_rd_resp_ready),
        .scratch1_rd_data_vec(scratch1_rd_data_vec),
        .scratch1_rd_resp_valid(scratch1_rd_resp_valid),
        .scratch1_pool_rd_valid(scratch1_pool_rd_valid),
        .scratch1_pool_rd_addr(scratch1_pool_rd_addr),
        .scratch1_pool_rd_ready(scratch1_pool_rd_ready),
        .scratch1_pool_rd_resp_ready(scratch1_pool_rd_resp_ready),
        .scratch1_pool_rd_data(scratch1_pool_rd_data),
        .scratch1_pool_rd_resp_valid(scratch1_pool_rd_resp_valid),
        .scratch1_wr_valid(scratch1_wr_valid),
        .scratch1_wr_bank(scratch1_wr_bank),
        .scratch1_wr_addr(scratch1_wr_addr),
        .scratch1_wr_data(scratch1_wr_data)
    );

    always #5 clk = ~clk;

    /* Byte address which selects an input bank and a physical row.  The
     * storage ABI uses byte address[6:4] as bank and folds [15:7]/[3:0]
     * into the 11-bit row. */
    function [15:0] input_addr;
        input integer bank_arg;
        input integer row_arg;
        begin
            input_addr = (((row_arg >> 4) << 7) |
                          (row_arg & 15) | (bank_arg << 4));
        end
    endfunction

    task cfg_input_byte;
        input integer byte_addr;
        input [7:0] value;
        begin
            @(negedge clk);
            cfg_valid = 1'b1;
            cfg_kind = 3'd0;
            cfg_addr = byte_addr[15:0];
            cfg_data = {24'd0, value};
            @(posedge clk);
            @(negedge clk);
            cfg_valid = 1'b0;
            cfg_kind = 3'd0;
            cfg_addr = 16'd0;
            cfg_data = 32'd0;
        end
    endtask

    task check_input_vector;
        begin
            $display("BANKED_STORAGE_PHASE input_vector_start");
            @(negedge clk);
            input_rd_valid = 8'hff;
            input_rd_resp_ready = 1'b0;
            input_rd_addr_vec = 88'd0;
            for (b = 0; b < 8; b = b + 1)
                input_rd_addr_vec[b*11 +: 11] =
                    37;
            while (!input_rd_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            if (!input_rd_resp_valid) begin
                $display("BANKED_STORAGE_INPUT_NO_RESPONSE");
                errors = errors + 1;
            end
            for (b = 0; b < 8; b = b + 1)
                if (input_rd_data_vec[b*8 +: 8] !== (8'h80 + b)) begin
                    $display("BANKED_STORAGE_INPUT_MISMATCH bank=%0d exp=%02x got=%02x",
                             b, (8'h80 + b), input_rd_data_vec[b*8 +: 8]);
                    errors = errors + 1;
            end
            input_hold_data = input_rd_data_vec;
            if (input_rd_ready) begin
                $display("BANKED_STORAGE_INPUT_READY_DURING_HOLD");
                errors = errors + 1;
            end
            /* A held response must remain unchanged until consumed. */
            @(posedge clk);
            @(negedge clk);
            if (!input_rd_resp_valid || input_rd_data_vec !== input_hold_data) begin
                $display("BANKED_STORAGE_INPUT_HOLD_FAILURE");
                errors = errors + 1;
            end
            input_rd_valid = 8'd0;
            input_rd_resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (input_rd_resp_valid) begin
                $display("BANKED_STORAGE_INPUT_RESPONSE_NOT_CONSUMED");
                errors = errors + 1;
            end
            $display("BANKED_STORAGE_PHASE input_vector_done");
        end
    endtask

    task check_scratch0_hold_and_bypass;
        integer k;
        begin
            $display("BANKED_STORAGE_PHASE scratch0_start");
            @(negedge clk);
            scratch0_wr_addr = 11'd91;
            scratch0_wr_valid_vec = 16'hffff;
            for (k = 0; k < 16; k = k + 1)
                scratch0_wr_data_vec[k*8 +: 8] = 8'h40 + k;
            scratch0_rd_addr = 11'd91;
            scratch0_rd_resp_ready = 1'b0;
            scratch0_rd_valid = 1'b1;
            /* The read and write share an edge; write-first data must be
             * observed without waiting for a second transaction. */
            $display("BANKED_STORAGE_PHASE scratch0_request ready=%0d", scratch0_rd_ready);
            while (!scratch0_rd_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            $display("BANKED_STORAGE_PHASE scratch0_response valid=%0d ready=%0d", scratch0_rd_resp_valid, scratch0_rd_ready);
            if (!scratch0_rd_resp_valid) begin
                $display("BANKED_STORAGE_SCRATCH0_NO_RESPONSE");
                errors = errors + 1;
            end
            for (k = 0; k < 16; k = k + 1)
                if (scratch0_rd_data[k*8 +: 8] !== (8'h40 + k)) begin
                    $display("BANKED_STORAGE_SCRATCH0_MISMATCH bank=%0d exp=%02x got=%02x",
                             k, (8'h40 + k), scratch0_rd_data[k*8 +: 8]);
                    errors = errors + 1;
                end
            if (scratch0_rd_ready) begin
                $display("BANKED_STORAGE_SCRATCH0_READY_DURING_HOLD");
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            $display("BANKED_STORAGE_PHASE scratch0_hold valid=%0d ready=%0d", scratch0_rd_resp_valid, scratch0_rd_ready);
            if (!scratch0_rd_resp_valid) begin
                $display("BANKED_STORAGE_SCRATCH0_HOLD_FAILURE");
                errors = errors + 1;
            end
            scratch0_rd_valid = 1'b0;
            scratch0_wr_valid_vec = 16'd0;
            scratch0_rd_resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (scratch0_rd_resp_valid) begin
                $display("BANKED_STORAGE_SCRATCH0_RESPONSE_NOT_CONSUMED");
                errors = errors + 1;
            end
            $display("BANKED_STORAGE_PHASE scratch0_done");
        end
    endtask

    task check_scratch1_ports;
        integer k;
        begin
            $display("BANKED_STORAGE_PHASE scratch1_start");
            /* Banks 0..6 use the vector port. */
            scratch1_wr_addr = 8'd173;
            for (k = 0; k < 7; k = k + 1) begin
                @(negedge clk);
                scratch1_wr_valid = 1'b1;
                scratch1_wr_bank = k[2:0];
                scratch1_wr_data = 32'h50000000 + k;
                @(posedge clk);
                @(negedge clk);
            end
            scratch1_wr_valid = 1'b0;
            scratch1_rd_valid = 8'd0;
            scratch1_rd_addr_vec = 64'd0;
            for (k = 0; k < 7; k = k + 1) begin
                scratch1_rd_valid[k] = 1'b1;
                scratch1_rd_addr_vec[k*8 +: 8] = 8'd173;
            end
            scratch1_rd_resp_ready = 1'b0;
            while (!scratch1_rd_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            if (!scratch1_rd_resp_valid) begin
                $display("BANKED_STORAGE_SCRATCH1_NO_RESPONSE");
                errors = errors + 1;
            end
            for (k = 0; k < 7; k = k + 1)
                if (scratch1_rd_data_vec[k*32 +: 32] !==
                    (32'h50000000 + k)) begin
                    $display("BANKED_STORAGE_SCRATCH1_MISMATCH bank=%0d exp=%08x got=%08x",
                             k, (32'h50000000 + k), scratch1_rd_data_vec[k*32 +: 32]);
                    errors = errors + 1;
                end
            if (scratch1_rd_ready) begin
                $display("BANKED_STORAGE_SCRATCH1_READY_DURING_HOLD");
                errors = errors + 1;
            end
            scratch1_rd_valid = 8'd0;
            scratch1_rd_resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (scratch1_rd_resp_valid) begin
                $display("BANKED_STORAGE_SCRATCH1_RESPONSE_NOT_CONSUMED");
                errors = errors + 1;
            end

            /* Bank 7 has a physically independent pool response channel. */
            @(negedge clk);
            scratch1_wr_valid = 1'b1;
            scratch1_wr_bank = 3'd7;
            scratch1_wr_addr = 8'd211;
            scratch1_wr_data = 32'h7badcafe;
            scratch1_pool_rd_valid = 1'b1;
            scratch1_pool_rd_addr = 8'd211;
            scratch1_pool_rd_resp_ready = 1'b0;
            while (!scratch1_pool_rd_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            if (!scratch1_pool_rd_resp_valid ||
                scratch1_pool_rd_data !== 32'h7badcafe) begin
                $display("BANKED_STORAGE_POOL_BYPASS_FAILURE exp=%08x got=%08x",
                         32'h7badcafe, scratch1_pool_rd_data);
                errors = errors + 1;
            end
            if (scratch1_pool_rd_ready) begin
                $display("BANKED_STORAGE_POOL_READY_DURING_HOLD");
                errors = errors + 1;
            end
            scratch1_wr_valid = 1'b0;
            scratch1_pool_rd_valid = 1'b0;
            scratch1_pool_rd_resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            if (scratch1_pool_rd_resp_valid) begin
                $display("BANKED_STORAGE_POOL_RESPONSE_NOT_CONSUMED");
                errors = errors + 1;
            end
            $display("BANKED_STORAGE_PHASE scratch1_done");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cfg_valid = 1'b0;
        cfg_kind = 3'd0;
        cfg_addr = 16'd0;
        cfg_data = 32'd0;
        input_rd_valid = 8'd0;
        input_rd_addr_vec = 88'd0;
        input_rd_resp_ready = 1'b1;
        scratch0_rd_valid = 1'b0;
        scratch0_rd_addr = 11'd0;
        scratch0_rd_resp_ready = 1'b1;
        scratch0_wr_valid_vec = 16'd0;
        scratch0_wr_addr = 11'd0;
        scratch0_wr_data_vec = 128'd0;
        scratch1_rd_valid = 8'd0;
        scratch1_rd_addr_vec = 64'd0;
        scratch1_rd_resp_ready = 1'b1;
        scratch1_pool_rd_valid = 1'b0;
        scratch1_pool_rd_addr = 8'd0;
        scratch1_pool_rd_resp_ready = 1'b1;
        scratch1_wr_valid = 1'b0;
        scratch1_wr_bank = 3'd0;
        scratch1_wr_addr = 8'd0;
        scratch1_wr_data = 32'd0;
        input_hold_data = 64'd0;
        errors = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        /* Populate one distinct row in every input bank. */
        for (b = 0; b < 8; b = b + 1)
            cfg_input_byte(input_addr(b, 37), 8'h80 + b);
        $display("BANKED_STORAGE_PHASE writes_done");
        check_input_vector();

        /* Same-edge input write-first bypass. */
        row = 52;
        addr_i = input_addr(3, row);
        @(negedge clk);
        cfg_valid = 1'b1;
        cfg_kind = 3'd0;
        cfg_addr = addr_i[15:0];
        cfg_data = 32'h000000e7;
        input_rd_valid = 8'd0;
        input_rd_valid[3] = 1'b1;
        input_rd_addr_vec = 88'd0;
        input_rd_addr_vec[3*11 +: 11] = row[10:0];
        input_rd_resp_ready = 1'b0;
        while (!input_rd_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        if (!input_rd_resp_valid || input_rd_data_vec[3*8 +: 8] !== 8'he7) begin
            $display("BANKED_STORAGE_INPUT_WRITE_FIRST_FAILURE exp=e7 got=%02x",
                     input_rd_data_vec[3*8 +: 8]);
            errors = errors + 1;
        end
        cfg_valid = 1'b0;
        input_rd_valid = 8'd0;
        input_rd_resp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);

        check_scratch0_hold_and_bypass();
        check_scratch1_ports();

        if (errors == 0)
            $display("PASS edgembconv_hwacandidate_d4_vstream_v6_banked_storage maps=8+16+7+pool handshake=hold+bypass");
        else
            $fatal(1, "BANKED_STORAGE_ERRORS=%0d", errors);
        $finish;
    end
endmodule

`default_nettype wire
