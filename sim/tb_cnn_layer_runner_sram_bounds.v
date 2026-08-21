`timescale 1ns/1ps
`default_nettype none

// Directed descriptor validation tests for the two 32 KiB feature-SRAM banks.
// The runner is instantiated directly so an invalid descriptor can be proven to
// fail before it issues either an external-memory or an SRAM transaction.
module tb_cnn_layer_runner_sram_bounds;
    localparam [31:0] SRAM_BYTES = 32'd32768;
    localparam OP_STEM = 32'd0;
    localparam OP_DS   = 32'd1;
    localparam OP_GAP  = 32'd2;
    localparam OP_FC   = 32'd3;
    localparam [31:0] FLAG_SKIP       = 32'h0000_0001;
    localparam [31:0] FLAG_INPUT_SRAM = 32'h0000_0002;
    localparam [31:0] FLAG_OUTPUT_SRAM= 32'h0000_0004;
    localparam [31:0] FLAG_TILED      = 32'h0000_0020;

    reg clk;
    reg rst_n;
    reg start;
    reg [1023:0] desc_words;
    wire busy;
    wire done;
    wire error;
    wire mem_req_valid;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    reg mem_req_ready;
    reg mem_resp_valid;
    reg [31:0] mem_resp_rdata;
    wire sram_input_rd_en;
    wire [14:0] sram_input_rd_addr;
    reg sram_input_rd_valid;
    reg signed [7:0] sram_input_rd_data;
    wire sram_output_wr_en;
    wire [14:0] sram_output_wr_addr;
    wire signed [7:0] sram_output_wr_data;

    integer errors;
    integer checks;
    integer timeout;
    integer sram_read_count;
    integer sram_write_count;
    integer ext_request_count;
    integer sram_read_addr_errors;
    integer sram_write_addr_errors;

    cnn_layer_runner dut (
        .clk(clk), .rst_n(rst_n), .start(start), .desc_words(desc_words),
        .busy(busy), .done(done), .error(error),
        .mem_req_valid(mem_req_valid), .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready), .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata),
        .sram_input_rd_en(sram_input_rd_en),
        .sram_input_rd_addr(sram_input_rd_addr),
        .sram_input_rd_valid(sram_input_rd_valid),
        .sram_input_rd_data(sram_input_rd_data),
        .sram_output_wr_en(sram_output_wr_en),
        .sram_output_wr_addr(sram_output_wr_addr),
        .sram_output_wr_data(sram_output_wr_data)
    );

    always #5 clk = ~clk;

    // SRAM reads have one registered response cycle.  External data is zero,
    // sufficient for the FC case because this TB verifies addressing/control.
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            sram_input_rd_valid <= 1'b0;
            sram_input_rd_data <= 8'sd0;
        end else begin
            mem_resp_valid <= mem_req_valid && !mem_req_write && mem_req_ready;
            mem_resp_rdata <= 32'd0;
            sram_input_rd_valid <= sram_input_rd_en;
            sram_input_rd_data <= 8'sd0;
            if (mem_req_valid && mem_req_ready)
                ext_request_count <= ext_request_count + 1;
            if (sram_input_rd_en) begin
                // The only legal SRAM-reading case in this TB is the FC
                // endpoint case below.  Check every accepted address instead
                // of retaining a last-address sample: Verilator may otherwise
                // localize a write-only scoreboard sample into this process.
                if (sram_input_rd_addr !== ((SRAM_BYTES - 32'd256) + sram_read_count)) begin
                    $display("MISMATCH SRAM read index=%0d addr=%0d expected=%0d",
                             sram_read_count, sram_input_rd_addr,
                             (SRAM_BYTES - 32'd256) + sram_read_count);
                    sram_read_addr_errors <= sram_read_addr_errors + 1;
                end
                sram_read_count <= sram_read_count + 1;
            end
            if (sram_output_wr_en) begin
                if (sram_output_wr_addr !== ((SRAM_BYTES - 32'd10) + sram_write_count)) begin
                    $display("MISMATCH SRAM write index=%0d addr=%0d expected=%0d",
                             sram_write_count, sram_output_wr_addr,
                             (SRAM_BYTES - 32'd10) + sram_write_count);
                    sram_write_addr_errors <= sram_write_addr_errors + 1;
                end
                sram_write_count <= sram_write_count + 1;
            end
        end
    end

    task clear_descriptor;
        begin
            desc_words = 1024'd0;
        end
    endtask

    task set_descriptor;
        input [31:0] op;
        input [31:0] input_base;
        input [31:0] output_base;
        input [15:0] h;
        input [15:0] w;
        input [15:0] cin;
        input [15:0] cout;
        input [7:0] stride;
        input [7:0] pad;
        input [31:0] flags;
        begin
            clear_descriptor();
            desc_words[(0*32) +: 32] = op;
            desc_words[(1*32) +: 32] = input_base;
            desc_words[(2*32) +: 32] = output_base;
            // The FC parameter blocks are external and all-zero in this TB.
            desc_words[(11*32) +: 32] = {w, h};
            desc_words[(12*32) +: 32] = {cout, cin};
            desc_words[(13*32) +: 32] = {16'd0, pad, stride};
            desc_words[(18*32) +: 32] = flags;
        end
    endtask

    task reset_and_start;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            start = 1'b0;
            mem_req_ready = 1'b1;
            mem_resp_valid = 1'b0;
            mem_resp_rdata = 32'd0;
            sram_input_rd_valid = 1'b0;
            sram_input_rd_data = 8'sd0;
            sram_read_count = 0;
            sram_write_count = 0;
            ext_request_count = 0;
            sram_read_addr_errors = 0;
            sram_write_addr_errors = 0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task wait_for_done;
        input integer max_cycles;
        begin
            timeout = 0;
            while (!done && timeout < max_cycles) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!done) begin
                $display("MISMATCH timeout after %0d cycles", max_cycles);
                errors = errors + 1;
            end
        end
    endtask

    task expect_invalid_no_access;
        input integer case_id;
        begin
            wait_for_done(40);
            checks = checks + 4;
            if (!error) begin
                $display("MISMATCH case=%0d expected error", case_id);
                errors = errors + 1;
            end
            if (sram_read_count != 0 || sram_write_count != 0) begin
                $display("MISMATCH case=%0d unexpected SRAM access reads=%0d writes=%0d",
                         case_id, sram_read_count, sram_write_count);
                errors = errors + 1;
            end
            if (ext_request_count != 0) begin
                $display("MISMATCH case=%0d unexpected external request count=%0d",
                         case_id, ext_request_count);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        desc_words = 1024'd0;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        sram_input_rd_valid = 1'b0;
        sram_input_rd_data = 8'sd0;
        errors = 0;
        checks = 0;
        sram_read_count = 0;
        sram_write_count = 0;
        ext_request_count = 0;
        sram_read_addr_errors = 0;
        sram_write_addr_errors = 0;

        // 1. Both FC spans end exactly at address 32767 and must execute.
        set_descriptor(OP_FC, SRAM_BYTES - 32'd256, SRAM_BYTES - 32'd10,
                       16'd1, 16'd1, 16'd256, 16'd10, 8'd1, 8'd0,
                       FLAG_INPUT_SRAM | FLAG_OUTPUT_SRAM);
        reset_and_start();
        wait_for_done(10000);
        checks = checks + 7;
        if (error) begin
            $display("MISMATCH FC endpoint case unexpectedly errored");
            errors = errors + 1;
        end
        if (sram_read_count != 256 || sram_read_addr_errors != 0) begin
            $display("MISMATCH FC input endpoint reads=%0d address_errors=%0d",
                     sram_read_count, sram_read_addr_errors);
            errors = errors + 1;
        end
        if (sram_write_count != 10 || sram_write_addr_errors != 0) begin
            $display("MISMATCH FC output endpoint writes=%0d address_errors=%0d",
                     sram_write_count, sram_write_addr_errors);
            errors = errors + 1;
        end
        if (ext_request_count == 0) begin
            $display("MISMATCH FC case did not load external parameter blocks");
            errors = errors + 1;
        end

        // 2. GAP input end would be 32768: reject before transaction issue.
        set_descriptor(OP_GAP, SRAM_BYTES - 32'd4096 + 32'd1, 32'd0,
                       16'd4, 16'd4, 16'd256, 16'd256, 8'd1, 8'd0,
                       FLAG_INPUT_SRAM);
        reset_and_start();
        expect_invalid_no_access(2);

        // 3. 33-bit addition/large base cannot alias into the low 15 bits.
        set_descriptor(OP_FC, 32'hffff_ff80, 32'd0,
                       16'd1, 16'd1, 16'd256, 16'd10, 8'd1, 8'd0,
                       FLAG_INPUT_SRAM);
        reset_and_start();
        expect_invalid_no_access(3);

        // 4. Tiled DS input map is 32*32*128, greater than one SRAM bank.
        set_descriptor(OP_DS, 32'd0, 32'd0,
                       16'd32, 16'd32, 16'd128, 16'd1, 8'd1, 8'd1,
                       FLAG_INPUT_SRAM | FLAG_TILED);
        reset_and_start();
        expect_invalid_no_access(4);

        // 5. Tiled stem output is 32*32*16.  This base exceeds its endpoint by one.
        set_descriptor(OP_STEM, 32'd0, SRAM_BYTES - 32'd16384 + 32'd1,
                       16'd32, 16'd32, 16'd3, 16'd16, 8'd1, 8'd1,
                       FLAG_OUTPUT_SRAM | FLAG_TILED);
        reset_and_start();
        expect_invalid_no_access(5);

        // 6. Skip is explicitly a no-op contract: invalid bases produce no access/error.
        set_descriptor(OP_FC, 32'hffff_ffff, 32'hffff_ffff,
                       16'd1, 16'd1, 16'd256, 16'd10, 8'd1, 8'd0,
                       FLAG_SKIP | FLAG_INPUT_SRAM | FLAG_OUTPUT_SRAM);
        reset_and_start();
        wait_for_done(40);
        checks = checks + 4;
        if (error || sram_read_count != 0 || sram_write_count != 0 || ext_request_count != 0) begin
            $display("MISMATCH skip case error=%0d sram_r=%0d sram_w=%0d ext=%0d",
                     error, sram_read_count, sram_write_count, ext_request_count);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS tb_cnn_layer_runner_sram_bounds cases=6 checks=%0d", checks);
        end else begin
            $display("FAIL tb_cnn_layer_runner_sram_bounds cases=6 checks=%0d errors=%0d", checks, errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
