`timescale 1ns/1ps
`default_nettype none

/*
 * Independent contract test for the v6 sixteen-lane raw-result FIFO.
 *
 * The DUT separates a synchronous head read from retirement of that head:
 * read_valid/read_ready create one registered response, and pop_valid/pop_ready
 * retire the entry when the response is consumed.  This test keeps an
 * independent queue of accepted 512-bit vectors and exercises both sides of
 * that boundary, including a held response, full replacement, wrap-around,
 * empty/full handshakes, and no-overwrite ordering.
 */
module tb_edgembconv_hwacandidate_d4_vstream_v6_raw_fifo;
    localparam integer DEPTH = 4;
    localparam integer ADDR_WIDTH = 2;

    reg clk;
    reg rst_n;
    reg push_valid;
    wire push_ready;
    reg [511:0] push_data;
    reg read_valid;
    wire read_ready;
    wire resp_valid;
    reg resp_ready;
    wire [511:0] resp_data;
    reg pop_valid;
    wire pop_ready;
    wire [ADDR_WIDTH:0] fifo_count;
    wire [ADDR_WIDTH-1:0] fifo_head;
    wire [ADDR_WIDTH-1:0] fifo_tail;

    integer errors;
    integer queue_count;
    integer queue_head;
    integer queue_tail;
    integer push_total;
    integer pop_total;
    integer response_count;
    integer i;
    reg [511:0] expected_queue [0:127];
    reg [511:0] pending_data;
    reg pending_valid;
    reg [511:0] hold_data;

    edgembconv_hwacandidate_d4_vstream_v6_raw_fifo #(
        .DEPTH(DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .push_valid(push_valid), .push_ready(push_ready),
        .push_data(push_data),
        .read_valid(read_valid), .read_ready(read_ready),
        .resp_valid(resp_valid), .resp_ready(resp_ready),
        .resp_data(resp_data),
        .pop_valid(pop_valid), .pop_ready(pop_ready),
        .fifo_count(fifo_count), .fifo_head(fifo_head), .fifo_tail(fifo_tail)
    );

    always #5 clk = ~clk;

    function [511:0] make_data;
        input integer tag;
        integer lane;
        begin
            make_data = 512'd0;
            for (lane = 0; lane < 16; lane = lane + 1)
                make_data[lane*32 +: 32] =
                    32'hc1000000 ^ (tag * 32'h00010001) ^ lane;
        end
    endfunction

    /* Handshake scoreboard.  Its queue storage is deliberately independent
     * from the DUT's circular memory and is large enough that the software
     * indices never wrap during this bounded test. */
    always @(posedge clk) begin
        if (!rst_n) begin
            errors = 0;
            queue_count = 0;
            queue_head = 0;
            queue_tail = 0;
            push_total = 0;
            pop_total = 0;
            response_count = 0;
            pending_valid = 1'b0;
        end else begin
            if (push_valid && push_ready) begin
                if (queue_tail >= 128) begin
                    $display("V6_RAW_FIFO_SCOREBOARD_OVERFLOW");
                    errors = errors + 1;
                end else begin
                    expected_queue[queue_tail] = push_data;
                    queue_tail = queue_tail + 1;
                    queue_count = queue_count + 1;
                    push_total = push_total + 1;
                end
            end

            if (read_valid && read_ready) begin
                if (pending_valid || queue_count == 0) begin
                    $display("V6_RAW_FIFO_ILLEGAL_READ cycle=%0d pending=%0d count=%0d",
                             push_total + pop_total, pending_valid, queue_count);
                    errors = errors + 1;
                end else begin
                    pending_data = expected_queue[queue_head];
                    pending_valid = 1'b1;
                end
            end

            if (resp_valid && resp_ready) begin
                if (!pending_valid || resp_data !== pending_data) begin
                    $display("V6_RAW_FIFO_RESPONSE_MISMATCH response=%0d",
                             response_count);
                    errors = errors + 1;
                end
                pending_valid = 1'b0;
                response_count = response_count + 1;
            end

            if (pop_valid && pop_ready) begin
                if (!(resp_valid && resp_ready) || queue_count == 0) begin
                    $display("V6_RAW_FIFO_ILLEGAL_POP cycle=%0d response=%0d count=%0d",
                             push_total + pop_total, resp_valid, queue_count);
                    errors = errors + 1;
                end else begin
                    queue_head = queue_head + 1;
                    queue_count = queue_count - 1;
                    pop_total = pop_total + 1;
                end
            end
        end
    end

    /* Pointer/count checks occur after the preceding active edge has updated
     * the scoreboard and after the DUT nonblocking assignments have settled. */
    always @(negedge clk) begin
        if (rst_n) begin
            if (fifo_count !== queue_count || fifo_head !== (pop_total % DEPTH) ||
                fifo_tail !== (push_total % DEPTH)) begin
                $display("V6_RAW_FIFO_STATE_MISMATCH count=%0d/%0d head=%0d/%0d tail=%0d/%0d",
                         fifo_count, queue_count, fifo_head, pop_total % DEPTH,
                         fifo_tail, push_total % DEPTH);
                errors = errors + 1;
            end
        end
    end

    task push_item;
        input [511:0] data_arg;
        integer guard;
        begin
            guard = 0;
            while (!push_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "V6_RAW_FIFO_PUSH_TIMEOUT count=%0d", fifo_count);
            end
            @(negedge clk);
            push_data = data_arg;
            push_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            push_valid = 1'b0;
            push_data = 512'd0;
        end
    endtask

    /* Issue one read, optionally hold its response, then retire the same
     * entry.  Holding push_valid during a full response stall is intentional:
     * push_ready must remain low until the live head is retired. */
    task read_and_pop;
        input integer stall_cycles;
        integer guard;
        integer stall_i;
        begin
            guard = 0;
            while (!read_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "V6_RAW_FIFO_READ_TIMEOUT count=%0d", fifo_count);
            end

            @(negedge clk);
            read_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            read_valid = 1'b0;

            guard = 0;
            while (!resp_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "V6_RAW_FIFO_RESPONSE_TIMEOUT");
            end
            hold_data = resp_data;
            resp_ready = 1'b0;
            pop_valid = 1'b0;
            for (stall_i = 0; stall_i < stall_cycles; stall_i = stall_i + 1) begin
                @(negedge clk);
                if (!resp_valid || resp_data !== hold_data) begin
                    $display("V6_RAW_FIFO_RESPONSE_HOLD_FAILURE cycle=%0d",
                             push_total + pop_total);
                    errors = errors + 1;
                end
                if (fifo_count !== queue_count ||
                    ((fifo_count == DEPTH) && push_ready !== 1'b0)) begin
                    $display("V6_RAW_FIFO_FULL_STALL_FAILURE count=%0d/%0d push_ready=%0d",
                             fifo_count, queue_count, push_ready);
                    errors = errors + 1;
                end
                @(posedge clk);
            end

            @(negedge clk);
            if (!resp_valid || resp_data !== hold_data) begin
                $display("V6_RAW_FIFO_RESPONSE_PRE_CONSUME_FAILURE");
                errors = errors + 1;
            end
            resp_ready = 1'b1;
            pop_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
            pop_valid = 1'b0;
        end
    endtask

    /* Read/retire while pushing a replacement on a full FIFO.  This is the
     * critical full-boundary same-edge case: push_ready is derived from the
     * independent pop handshake, and both circular pointers advance once. */
    task read_pop_push_full;
        input [511:0] replacement_data;
        integer guard;
        begin
            guard = 0;
            while (!read_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "V6_RAW_FIFO_FULL_READ_TIMEOUT");
            end
            @(negedge clk);
            read_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            read_valid = 1'b0;
            while (!resp_valid) @(negedge clk);

            @(negedge clk);
            resp_ready = 1'b1;
            pop_valid = 1'b1;
            push_data = replacement_data;
            push_valid = 1'b1;
            #1;
            if (!pop_ready || !push_ready) begin
                $display("V6_RAW_FIFO_FULL_REPLACEMENT_NOT_READY count=%0d pop_ready=%0d push_ready=%0d",
                         fifo_count, pop_ready, push_ready);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
            pop_valid = 1'b0;
            push_valid = 1'b0;
            push_data = 512'd0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        push_valid = 1'b0;
        push_data = 512'd0;
        read_valid = 1'b0;
        resp_ready = 1'b0;
        pop_valid = 1'b0;
        errors = 0;
        queue_count = 0;
        queue_head = 0;
        queue_tail = 0;
        push_total = 0;
        pop_total = 0;
        response_count = 0;
        pending_valid = 1'b0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        /* Empty boundary. */
        @(negedge clk);
        if (fifo_count != 0 || !push_ready || read_ready || pop_ready) begin
            $display("V6_RAW_FIFO_EMPTY_BOUNDARY_FAILURE count=%0d push=%0d read=%0d pop=%0d",
                     fifo_count, push_ready, read_ready, pop_ready);
            errors = errors + 1;
        end

        /* Fill to full, then prove that an unretired response cannot be
         * overwritten by a fifth push. */
        for (i = 0; i < DEPTH; i = i + 1)
            push_item(make_data(i));
        @(negedge clk);
        if (fifo_count != DEPTH || push_ready) begin
            $display("V6_RAW_FIFO_FULL_BOUNDARY_FAILURE count=%0d push_ready=%0d",
                     fifo_count, push_ready);
            errors = errors + 1;
        end
        push_data = make_data(99);
        push_valid = 1'b1;
        @(posedge clk);
        if (push_ready) begin
            $display("V6_RAW_FIFO_OVERWRITE_ACCEPTED");
            errors = errors + 1;
        end
        @(negedge clk);
        push_valid = 1'b0;
        push_data = 512'd0;

        /* A held head response blocks both the full FIFO and its pop until
         * the consumer makes progress. */
        read_and_pop(3);

        /* Refill and use a full same-edge pop+push replacement. */
        push_item(make_data(4));
        read_pop_push_full(make_data(5));

        /* Drain all four surviving entries in order, including the
         * replacement.  The final read proves the queue reaches empty. */
        for (i = 0; i < DEPTH; i = i + 1)
            read_and_pop((i == 1) ? 1 : 0);
        @(negedge clk);
        if (fifo_count != 0 || read_ready || pop_ready || !push_ready) begin
            $display("V6_RAW_FIFO_DRAIN_BOUNDARY_FAILURE count=%0d push=%0d read=%0d pop=%0d",
                     fifo_count, push_ready, read_ready, pop_ready);
            errors = errors + 1;
        end

        /* Refill after both pointers have crossed the circular boundary and
         * drain a second burst.  The scoreboard verifies no stale/overwritten
         * lane data, while pointer checks prove wrap behavior. */
        for (i = 0; i < DEPTH; i = i + 1)
            push_item(make_data(100 + i));
        for (i = 0; i < DEPTH; i = i + 1)
            read_and_pop((i == 0) ? 2 : 0);

        @(negedge clk);
        if (fifo_count != 0 || response_count != push_total || errors != 0)
            $fatal(1, "V6_RAW_FIFO_ERRORS=%0d count=%0d responses=%0d pushes=%0d",
                   errors, fifo_count, response_count, push_total);
        $display("PASS edgembconv_hwacandidate_d4_vstream_v6_raw_fifo depth=%0d lanes=16 burst=1 stall_hold=1 full_empty=1 wrap=1 same_edge_push_pop=1 no_overwrite=1 pushes=%0d responses=%0d",
                 DEPTH, push_total, response_count);
        $finish;
    end
endmodule

`default_nettype wire
