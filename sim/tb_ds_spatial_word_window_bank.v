`timescale 1ns/1ps
`default_nettype none

/*
 * Closed-loop verification of the passive quarter-plane window bank.
 * The model updates on accepted writes (the externally visible write-first
 * contract), while reads are checked after arbitrary response stalls.
 */
module tb_ds_spatial_word_window_bank;
    localparam integer H = 17;
    localparam integer W = 17;
    localparam integer GROUPS = 3;
    localparam integer DEPTH = H * W * GROUPS;
    localparam integer AW = $clog2(DEPTH);
    localparam integer EW = 4;
    localparam integer TW = 9;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg wr_valid = 1'b0;
    wire wr_ready;
    reg [AW-1:0] wr_vector_addr = 0;
    reg [1:0] wr_quarter = 0;
    reg [31:0] wr_data = 0;
    reg [EW-1:0] wr_epoch = 0;
    wire [EW-1:0] wr_epoch_seen;
    reg rd_req_valid = 1'b0;
    wire rd_req_ready;
    reg [AW-1:0] rd_vector_addr = 0;
    reg [15:0] rd_lane_mask = 0;
    reg [TW-1:0] rd_tag = 0;
    reg [EW-1:0] rd_epoch = 0;
    wire rd_resp_valid;
    reg rd_resp_ready = 1'b0;
    wire [127:0] rd_data_vector;
    wire [15:0] rd_resp_lane_mask;
    wire [TW-1:0] rd_resp_tag;
    wire [EW-1:0] rd_resp_epoch;

    reg [31:0] model [0:DEPTH-1][0:3];
    integer errors = 0;
    integer accepted_writes = 0;
    integer checked_reads = 0;
    integer cycle_count = 0;
    integer i, q, lane;
    integer seed = 32'h35a17e91;
    reg [127:0] expected_data;
    reg [15:0] expected_mask;

    ds_spatial_word_window_bank #(
        .MAX_IN_H(H), .MAX_IN_W(W), .MAX_CHANNEL_GROUPS(GROUPS),
        .DEPTH(DEPTH), .ADDR_WIDTH(AW), .EPOCH_WIDTH(EW), .TAG_WIDTH(TW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_vector_addr(wr_vector_addr), .wr_quarter(wr_quarter),
        .wr_data(wr_data), .wr_epoch(wr_epoch), .wr_epoch_seen(wr_epoch_seen),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
        .rd_vector_addr(rd_vector_addr), .rd_lane_mask(rd_lane_mask),
        .rd_tag(rd_tag), .rd_epoch(rd_epoch),
        .rd_resp_valid(rd_resp_valid), .rd_resp_ready(rd_resp_ready),
        .rd_data_vector(rd_data_vector), .rd_resp_lane_mask(rd_resp_lane_mask),
        .rd_resp_tag(rd_resp_tag), .rd_resp_epoch(rd_resp_epoch)
    );

    always #1 clk = ~clk;

    function integer rand_int;
        begin
            seed = (seed * 1103515245) + 12345;
            rand_int = seed & 32'h7fffffff;
        end
    endfunction

    task do_write;
        input integer addr;
        input integer quarter;
        input [31:0] value;
        input integer epoch;
        begin
            @(negedge clk);
            wr_vector_addr = addr[AW-1:0]; wr_quarter = quarter[1:0];
            wr_data = value; wr_epoch = epoch[EW-1:0]; wr_valid = 1'b1;
            begin : wait_write
                while (1) begin
                    @(posedge clk);
                    if (wr_ready) begin
                        model[addr][quarter] = value;
                        accepted_writes = accepted_writes + 1;
                        disable wait_write;
                    end
                end
            end
            @(negedge clk); wr_valid = 1'b0;
        end
    endtask

    task do_read;
        input integer addr;
        input [15:0] mask;
        input integer tag;
        input integer epoch;
        integer timeout;
        begin
            expected_data = {model[addr][3], model[addr][2],
                             model[addr][1], model[addr][0]};
            expected_mask = mask;
            for (lane = 0; lane < 16; lane = lane + 1)
                if (!mask[lane]) expected_data[(lane*8) +: 8] = 0;
            @(negedge clk);
            rd_vector_addr = addr[AW-1:0]; rd_lane_mask = mask;
            rd_tag = tag[TW-1:0]; rd_epoch = epoch[EW-1:0];
            rd_req_valid = 1'b1;
            begin : accept_read
                while (1) begin
                    @(posedge clk);
                    if (rd_req_ready) disable accept_read;
                end
            end
            @(negedge clk); rd_req_valid = 1'b0;
            timeout = 0;
            begin : await_response
                while (!rd_resp_valid) begin
                    @(posedge clk); timeout = timeout + 1;
                    if (timeout > 100) begin
                        $display("TIMEOUT read addr=%0d tag=%0d", addr, tag);
                        errors = errors + 1; disable await_response;
                    end
                end
            end
            /* Hold ready low for a deterministic pseudo-random stall. */
            rd_resp_ready = (tag % 5 == 0) ? 1'b0 : 1'b1;
            while (!rd_resp_ready) begin @(posedge clk); rd_resp_ready = 1'b1; end
            #0.1;
            if (rd_data_vector !== expected_data) begin
                $display("DATA mismatch addr=%0d tag=%0d got=%h exp=%h",
                         addr, tag, rd_data_vector, expected_data);
                errors = errors + 1;
            end
            if (rd_resp_lane_mask !== expected_mask ||
                rd_resp_tag !== tag[TW-1:0] || rd_resp_epoch !== epoch[EW-1:0]) begin
                $display("META mismatch addr=%0d tag=%0d mask=%h/%h tag=%0d/%0d epoch=%0d/%0d",
                         addr, tag, rd_resp_lane_mask, expected_mask,
                         rd_resp_tag, tag, rd_resp_epoch, epoch);
                errors = errors + 1;
            end
            @(posedge clk); rd_resp_ready = 1'b0;
            checked_reads = checked_reads + 1;
        end
    endtask

    task do_collision;
        input integer addr;
        input integer quarter;
        input [31:0] value;
        input integer tag;
        integer timeout;
        begin
            /* Write and read are launched on the same edge.  The read must
             * observe the newly accepted quarter (write-first contract). */
            @(negedge clk);
            wr_vector_addr = addr[AW-1:0]; wr_quarter = quarter[1:0];
            wr_data = value; wr_epoch = 4'hd; wr_valid = 1'b1;
            rd_vector_addr = addr[AW-1:0]; rd_lane_mask = 16'hffff;
            rd_tag = tag[TW-1:0]; rd_epoch = 4'hd; rd_req_valid = 1'b1;
            begin : accept_both
                while (1) begin
                    @(posedge clk);
                    if (wr_ready && rd_req_ready) disable accept_both;
                end
            end
            model[addr][quarter] = value;
            accepted_writes = accepted_writes + 1;
            @(negedge clk); wr_valid = 1'b0; rd_req_valid = 1'b0;
            timeout = 0;
            begin : collision_response
                while (!rd_resp_valid) begin
                    @(posedge clk); timeout = timeout + 1;
                    if (timeout > 100) begin errors = errors + 1; disable collision_response; end
                end
            end
            rd_resp_ready = 1'b1; #0.1;
            expected_data = {model[addr][3], model[addr][2],
                             model[addr][1], model[addr][0]};
            if (rd_data_vector !== expected_data) begin
                $display("COLLISION mismatch addr=%0d q=%0d got=%h exp=%h",
                         addr, quarter, rd_data_vector, expected_data);
                errors = errors + 1;
            end
            @(posedge clk); rd_resp_ready = 1'b0;
            checked_reads = checked_reads + 1;
        end
    endtask

    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            for (q = 0; q < 4; q = q + 1) model[i][q] = 32'd0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        /* Fill all 867 vectors in unaligned quarter order. */
        for (i = 0; i < DEPTH; i = i + 1)
            for (q = 0; q < 4; q = q + 1)
                do_write(i, (q + i) & 3,
                         32'h10000000 ^ (i * 32'h01010101) ^
                         (q * 32'h11112222), (i + q) & 15);

        /* Thousands of exact reads with tails/padding and unaligned writes. */
        for (i = 0; i < 2200; i = i + 1) begin
            q = rand_int() % DEPTH;
            do_read(q, rand_int() & 16'hffff, i, rand_int() & 15);
        end
        for (i = 0; i < 256; i = i + 1)
            do_collision((i * 37) % DEPTH, i & 3,
                         32'hcaf00000 ^ i, 3000 + i);

        if (wr_epoch_seen !== 4'hd) begin
            $display("epoch_seen mismatch got=%h", wr_epoch_seen);
            errors = errors + 1;
        end
        repeat (5) @(posedge clk);
        if (errors == 0)
            $display("PASS ds_spatial_word_window_bank writes=%0d reads=%0d cycles=%0d",
                     accepted_writes, checked_reads, cycle_count);
        else
            $display("FAIL ds_spatial_word_window_bank errors=%0d writes=%0d reads=%0d",
                     errors, accepted_writes, checked_reads);
        $finish;
    end

    always @(posedge clk) cycle_count = cycle_count + 1;
endmodule

`default_nettype wire
