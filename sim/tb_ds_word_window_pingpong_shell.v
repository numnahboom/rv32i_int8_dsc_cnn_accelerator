`timescale 1ns/1ps
`default_nettype none

/* Integration-level scoreboard for the one-engine/two-bank shell. */
module tb_ds_word_window_pingpong_shell #(
    parameter integer TB_H = 10,
    parameter integer TB_W = 10,
    parameter integer TB_GROUPS = 1,
    parameter integer TB_STRIDE = 1
);
    localparam integer DEPTH = 17*17*3;
    localparam integer VAW = $clog2(DEPTH);
    localparam integer WORDS = (TB_STRIDE == 2) ?
        ((((TB_H-1)*TB_STRIDE*TB_W + (TB_W-1)*TB_STRIDE + 1)*TB_GROUPS)*4) :
        (TB_H*TB_W*TB_GROUPS*4);
    localparam integer TOTAL_READS = TB_H*TB_W;
    localparam [23:0] BASE0 = 24'h001000;
    localparam [23:0] BASE1 = 24'h101000;

    reg clk = 1'b0, rst_n = 1'b0;
    always #1 clk = ~clk;

    reg fill_start_valid = 0, fill_start_bank = 0;
    reg [3:0] fill_start_epoch = 0;
    reg [23:0] fill_start_base_addr = 0;
    reg [15:0] fill_start_word_count = 0;
    wire fill_start_ready;
    wire fill_done_valid; reg fill_done_ready = 0;
    wire fill_done_bank; wire [3:0] fill_done_epoch;
    wire mem_req_valid; reg mem_req_ready = 1;
    wire [23:0] mem_req_addr;
    reg mem_resp_valid = 0; reg [31:0] mem_resp_data = 0;
    reg read_start_valid = 0, read_start_bank = 0;
    reg [3:0] read_start_epoch = 0;
    reg [7:0] read_height = 0, read_width = 0, read_stride = 1, read_pitch = 0;
    reg [VAW-1:0] read_base_vector = 0; reg [1:0] read_group = 0;
    reg [15:0] read_lane_mask = 16'hffff;
    wire read_start_ready; wire read_done_valid; reg read_done_ready = 0;
    wire read_done_bank; wire [3:0] read_done_epoch;
    wire rd_valid; reg rd_ready = 1;
    wire [VAW-1:0] rd_vector_addr; wire [15:0] rd_lane_mask;
    wire [15:0] rd_tag; wire [3:0] rd_epoch; wire [127:0] rd_data_vector;
    reg release_valid = 0, release_bank = 0; reg [3:0] release_epoch = 0;
    wire release_ready; wire release_resp_valid; wire release_resp_ok;
    reg release_resp_ready = 1;
    wire [1:0] bank0_state, bank1_state; wire fill_busy, read_busy;
    wire [31:0] fill_word_count_seen, read_vector_count, overlap_cycles;
    wire [31:0] stale_command_count;

    ds_word_window_pingpong_shell #(
        .MAX_IN_H(17), .MAX_IN_W(17), .MAX_CHANNEL_GROUPS(3),
        .LAYOUT_GROUPS(TB_GROUPS),
        .ADDR_WIDTH(24), .WORD_COUNT_WIDTH(16), .VECTOR_ADDR_WIDTH(VAW),
        .EPOCH_WIDTH(4), .TAG_WIDTH(16), .FIFO_DEPTH(8)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr), .fill_start_word_count(fill_start_word_count),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
        .read_start_valid(read_start_valid), .read_start_ready(read_start_ready),
        .read_start_bank(read_start_bank), .read_start_epoch(read_start_epoch),
        .read_height(read_height), .read_width(read_width), .read_stride(read_stride),
        .read_pitch(read_pitch), .read_base_vector(read_base_vector), .read_group(read_group),
        .read_lane_mask(read_lane_mask), .read_done_valid(read_done_valid),
        .read_done_ready(read_done_ready), .read_done_bank(read_done_bank), .read_done_epoch(read_done_epoch),
        .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_vector_addr(rd_vector_addr),
        .rd_lane_mask(rd_lane_mask), .rd_tag(rd_tag), .rd_epoch(rd_epoch),
        .rd_data_vector(rd_data_vector), .release_valid(release_valid), .release_ready(release_ready),
        .release_bank(release_bank), .release_epoch(release_epoch),
        .release_resp_valid(release_resp_valid), .release_resp_ready(release_resp_ready),
        .release_resp_ok(release_resp_ok), .bank0_state(bank0_state), .bank1_state(bank1_state),
        .fill_busy(fill_busy), .read_busy(read_busy), .fill_word_count_seen(fill_word_count_seen),
        .read_vector_count(read_vector_count), .overlap_cycles(overlap_cycles),
        .stale_command_count(stale_command_count)
    );

    /* Four-cycle source response pipe with deterministic request bubbles. */
    reg pipe_valid [0:3]; reg [31:0] pipe_data [0:3];
    integer p, cycle_count = 0, errors = 0, recv_count = 0;
    integer current_bank = 0, current_epoch = 0;
    function [7:0] byte_value;
        input integer bank;
        input integer vector;
        input integer lane;
        integer v;
        begin
            v = (bank*37 + vector*11 + lane*5 + 17) % 127;
            byte_value = v[7:0];
        end
    endfunction
    function [31:0] word_value;
        input [23:0] addr;
        integer bank, off, lane, vec;
        begin
            bank = (addr >= BASE1) ? 1 : 0;
            off = addr - (bank ? BASE1 : BASE0);
            vec = off / 16;
            word_value = 0;
            for (lane = 0; lane < 4; lane = lane + 1)
                word_value[lane*8 +: 8] = byte_value(bank, vec, (off % 16) + lane);
        end
    endfunction
    function [127:0] expected_vector;
        input integer bank;
        input integer vec;
        integer lane;
        begin
            expected_vector = 0;
            for (lane = 0; lane < 16; lane = lane + 1)
                expected_vector[lane*8 +: 8] = byte_value(bank, vec, lane);
        end
    endfunction

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (!rst_n) begin
            mem_resp_valid <= 0;
            for (p = 0; p < 4; p = p + 1) begin pipe_valid[p] <= 0; pipe_data[p] <= 0; end
        end else begin
            mem_resp_valid <= pipe_valid[0];
            mem_resp_data <= pipe_data[0];
            for (p = 0; p < 3; p = p + 1) begin
                pipe_valid[p] <= pipe_valid[p+1]; pipe_data[p] <= pipe_data[p+1];
            end
            pipe_valid[3] <= 0;
            mem_req_ready <= ((cycle_count % 13) != 4);
            if (mem_req_valid && mem_req_ready) begin
                pipe_valid[3] <= 1;
                pipe_data[3] <= word_value({mem_req_addr[23:2],2'b00});
            end
        end
    end

    task start_fill;
        input integer bank, epoch, words;
        begin
            @(negedge clk); fill_start_bank=bank; fill_start_epoch=epoch;
            fill_start_base_addr=bank ? BASE1 : BASE0; fill_start_word_count=words;
            fill_start_valid=1;
            begin : wait_fill_accept
                while (1) begin
                    @(posedge clk);
                    if (fill_start_ready) disable wait_fill_accept;
                end
            end
            @(negedge clk); fill_start_valid=0;
        end
    endtask
    task wait_fill_done;
        input integer bank, epoch;
        begin
            while (!fill_done_valid) @(negedge clk);
            if (fill_done_bank !== bank || fill_done_epoch !== epoch) begin
                $display("fill descriptor mismatch got b%0d/e%0d exp b%0d/e%0d",fill_done_bank,fill_done_epoch,bank,epoch);
                errors=errors+1;
            end
            fill_done_ready=1; @(posedge clk); @(negedge clk); fill_done_ready=0;
        end
    endtask
    task start_read;
        input integer bank, epoch;
        begin
            @(negedge clk); read_start_bank=bank; read_start_epoch=epoch;
            read_height=TB_H; read_width=TB_W; read_stride=TB_STRIDE; read_pitch=TB_W;
            read_base_vector=0; read_group=0; read_lane_mask=16'hffff; read_start_valid=1;
            begin : wait_read_accept
                while (1) begin
                    @(posedge clk);
                    if (read_start_ready) disable wait_read_accept;
                end
            end
            @(negedge clk); read_start_valid=0;
        end
    endtask
    task consume_read;
        input integer bank;
        integer timeout, expected_addr, row, col, n;
        begin
            recv_count=0; timeout=0; rd_ready=1;
            while (!read_done_valid && timeout < 20000) begin
                @(negedge clk); timeout=timeout+1;
                rd_ready = ((timeout % 9) != 4);
                if (rd_valid) begin
                    row = recv_count / TB_W; col = recv_count % TB_W;
                    expected_addr = ((row*TB_STRIDE*TB_W + col*TB_STRIDE)*TB_GROUPS);
                    if (rd_vector_addr !== expected_addr[VAW-1:0]) errors=errors+1;
                    if (rd_data_vector !== expected_vector(bank, expected_addr)) begin
                        if (errors < 4) $display("data mismatch n=%0d addr=%0d got=%h exp=%h",recv_count,rd_vector_addr,rd_data_vector,expected_vector(bank,expected_addr));
                        errors=errors+1;
                    end
                    if (rd_lane_mask !== 16'hffff || rd_epoch !== (bank ? 4'd2 : 4'd1)) errors=errors+1;
                    if (rd_ready) recv_count=recv_count+1;
                end
            end
            rd_ready=1;
            if (recv_count != TOTAL_READS || timeout >= 20000) begin
                $display("read incomplete recv=%0d total=%0d timeout=%0d",recv_count,TOTAL_READS,timeout); errors=errors+1;
            end
            read_done_ready=1; @(posedge clk); @(negedge clk); read_done_ready=0;
        end
    endtask
    task do_release;
        input integer bank, epoch;
        begin
            @(negedge clk); release_bank=bank; release_epoch=epoch; release_valid=1;
            begin : wait_release_accept
                while (1) begin
                    @(posedge clk);
                    if (release_ready) disable wait_release_accept;
                end
            end
            @(negedge clk); release_valid=0;
            while (!release_resp_valid) @(negedge clk);
            if (!release_resp_ok) errors=errors+1;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n=1;
        start_fill(0,1,WORDS); wait_fill_done(0,1);
        start_read(0,1);
        /* The single fill engine now feeds the inactive bank while bank zero
         * emits vectors.  The source has independent ready bubbles. */
        start_fill(1,2,WORDS);
        consume_read(0); wait_fill_done(1,2);
        /* Wrong-epoch release must be rejected, then the valid fence frees it. */
        @(negedge clk); release_bank=1; release_epoch=4'hf; release_valid=1;
        @(posedge clk); @(negedge clk); release_valid=0;
        if (release_resp_ok || stale_command_count == 0) errors=errors+1;
        @(posedge clk);
        do_release(0,1);
        start_read(1,2); consume_read(1); do_release(1,2);
        if (fill_word_count_seen !== (WORDS*2)) begin
            $display("fill count mismatch got=%0d exp=%0d",fill_word_count_seen,WORDS*2); errors=errors+1;
        end
        if (read_vector_count !== (TOTAL_READS*2)) errors=errors+1;
        if (overlap_cycles == 0) begin $display("no active/fill overlap"); errors=errors+1; end
        if (errors == 0)
            $display("PASS ds_word_window_pingpong_shell H=%0d W=%0d groups=%0d stride=%0d fill_words=%0d read_vectors=%0d overlap=%0d cycles=%0d",TB_H,TB_W,TB_GROUPS,TB_STRIDE,fill_word_count_seen,read_vector_count,overlap_cycles,cycle_count);
        else begin $display("FAIL ds_word_window_pingpong_shell errors=%0d",errors); $fatal(1); end
        $finish;
    end
    initial begin repeat (40000) @(posedge clk); $fatal(1,"WATCHDOG"); end
endmodule
`default_nettype wire
