`timescale 1ns/1ps
`default_nettype none

/*
 * Protocol-only closure for the adapter's one-entry context look-ahead.
 * The producer request stream is deliberately kept live while the first
 * context is being drained.  Context B is accepted into the adapter slot,
 * completion for A is asserted while source responses are still pending,
 * and B requests are held until the A fence promotes B and finishes the
 * normal two-cycle preparation.  No request/response tag is added.
 */
module tb_ds_group_feature_word_address_adapter_context_slot;
    localparam integer ADDR_WIDTH = 24;
    localparam integer FIFO_DEPTH = 4;
    localparam integer REQ_COUNT = 16;
    localparam [ADDR_WIDTH-1:0] A_LINEAR = 24'h200000;
    localparam [ADDR_WIDTH-1:0] B_LINEAR = 24'h210000;
    localparam [ADDR_WIDTH-1:0] A_INPUT  = 24'h000100;
    localparam [ADDR_WIDTH-1:0] B_INPUT  = 24'h000400;

    reg clk = 1'b0;
    always #1 clk = ~clk;

    reg rst_n = 1'b0;
    reg context_valid = 1'b0;
    wire context_ready;
    reg [ADDR_WIDTH-1:0] context_linear_base = 0;
    reg [ADDR_WIDTH-1:0] context_input_base = 0;
    reg [7:0] context_global_y = 0, context_global_x = 0;
    reg [7:0] context_input_zero_point = 0;
    reg [7:0] context_stride = 1;
    reg [15:0] context_input_width = 0, context_input_height = 0;
    reg [15:0] context_input_channels = 0, context_channel_offset = 0;
    reg [7:0] context_footprint_width = 0, context_footprint_height = 0;
    reg context_complete = 1'b0;

    reg producer_req_valid = 1'b0;
    wire producer_req_ready;
    reg [ADDR_WIDTH-1:0] producer_req_addr = 0;
    wire producer_resp_valid;
    reg producer_resp_ready = 1'b1;
    wire [31:0] producer_resp_data;

    wire mem_req_valid;
    reg mem_req_ready = 1'b1;
    wire [ADDR_WIDTH-1:0] mem_req_addr;
    reg mem_resp_valid = 1'b0;
    reg [31:0] mem_resp_data = 0;
    reg error;

    ds_group_feature_word_address_adapter #(
        .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .context_valid(context_valid), .context_ready(context_ready),
        .context_linear_base(context_linear_base),
        .context_input_base(context_input_base),
        .context_global_y(context_global_y), .context_global_x(context_global_x),
        .context_input_zero_point(context_input_zero_point),
        .context_stride(context_stride),
        .context_input_width(context_input_width),
        .context_input_height(context_input_height),
        .context_input_channels(context_input_channels),
        .context_channel_offset(context_channel_offset),
        .context_footprint_width(context_footprint_width),
        .context_footprint_height(context_footprint_height),
        .context_complete(context_complete),
        .producer_req_valid(producer_req_valid),
        .producer_req_ready(producer_req_ready),
        .producer_req_addr(producer_req_addr),
        .producer_resp_valid(producer_resp_valid),
        .producer_resp_ready(producer_resp_ready),
        .producer_resp_data(producer_resp_data),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .error(error)
    );

    function [31:0] source_word;
        input [ADDR_WIDTH-1:0] addr;
        begin source_word = 32'h5a000000 ^ {{(32-ADDR_WIDTH){1'b0}},addr}; end
    endfunction

    function [31:0] expected_word;
        input integer which;
        input integer q;
        integer h, w, c, off, sy, sx, ch, fw, fh, stride, gy, gx;
        integer base, addr;
        begin
            if (which == 0) begin
                h = 4; w = 4; c = 4; off = 0; stride = 1;
                gy = 0; gx = 0; fw = 2; fh = 2; base = A_INPUT;
                expected_word = {4{8'h08}};
            end else begin
                h = 4; w = 5; c = 8; off = 4; stride = 2;
                gy = 1; gx = 1; fw = 2; fh = 2; base = B_INPUT;
                expected_word = {4{8'h0d}};
            end
            sy = (gy * stride) - 1 + (q / (fw * 4));
            sx = (gx * stride) - 1 + ((q / 4) % fw);
            ch = off + ((q % 4) * 4);
            if ((sy >= 0) && (sy < h) && (sx >= 0) && (sx < w) &&
                (ch < c)) begin
                addr = base + (sy * w * c) + (sx * c) + ch;
                expected_word = source_word(addr[ADDR_WIDTH-1:0]);
            end
        end
    endfunction

    reg [2:0] mem_v_pipe;
    reg [ADDR_WIDTH-1:0] mem_a0, mem_a1, mem_a2;
    reg [31:0] mem_d0, mem_d1, mem_d2;
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_v_pipe <= 0;
            mem_a0 <= 0; mem_a1 <= 0; mem_a2 <= 0;
            mem_d0 <= 0; mem_d1 <= 0; mem_d2 <= 0;
            mem_resp_valid <= 1'b0;
            mem_resp_data <= 0;
        end else begin
            mem_resp_valid <= mem_v_pipe[2];
            mem_resp_data <= mem_d2;
            mem_v_pipe[2] <= mem_v_pipe[1];
            mem_v_pipe[1] <= mem_v_pipe[0];
            mem_v_pipe[0] <= mem_req_valid && mem_req_ready;
            mem_a2 <= mem_a1; mem_a1 <= mem_a0;
            mem_d2 <= mem_d1; mem_d1 <= mem_d0;
            mem_a0 <= mem_req_addr;
            mem_d0 <= source_word(mem_req_addr);
        end
    end

    reg [31:0] ready_lfsr = 32'h31a7c9e1;
    always @(negedge clk) begin
        if (!rst_n) begin
            ready_lfsr <= 32'h31a7c9e1;
            mem_req_ready <= 1'b1;
            producer_resp_ready <= 1'b1;
        end else begin
            /* Deterministic independent backpressure; the held-value check
             * below observes every producer response stall. */
            mem_req_ready <= !((ready_lfsr[2:0] == 3'b001) ||
                               (ready_lfsr[7:5] == 3'b101));
            producer_resp_ready <= !((ready_lfsr[12:10] == 3'b011) ||
                                     (ready_lfsr[18:16] == 3'b110));
            ready_lfsr <= {ready_lfsr[30:0],
                           ready_lfsr[31] ^ ready_lfsr[21] ^
                           ready_lfsr[1] ^ ready_lfsr[0]};
        end
    end

    reg request_run = 1'b0;
    reg request_phase = 1'b0;
    reg [7:0] request_index = 0;
    always @* begin
        producer_req_valid = request_run && (request_index < REQ_COUNT);
        producer_req_addr = request_phase ?
            (B_LINEAR + (request_index * 4)) :
            (A_LINEAR + (request_index * 4));
    end

    reg [31:0] expected_fifo [0:63];
    integer expected_wr = 0, expected_rd = 0, expected_count = 0;
    integer errors = 0;
    integer context_accepts = 0, source_checks = 0, response_checks = 0;
    integer held_response_checks = 0, held_b_requests = 0;
    reg response_hold_seen = 1'b0;
    reg [31:0] response_hold_data = 0;
    reg mem_hold_seen = 1'b0, request_hold_seen = 1'b0;
    reg [ADDR_WIDTH-1:0] mem_hold_addr = 0, request_hold_addr = 0;
    reg saw_next_slot = 1'b0, saw_a_completion_pending = 1'b0;
    reg saw_b_active = 1'b0, saw_b_request_before_active = 1'b0;
    reg b_complete_sent = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            request_index <= 0;
            response_hold_seen = 1'b0;
            mem_hold_seen = 1'b0;
            request_hold_seen = 1'b0;
        end else begin
            if (context_valid && context_ready) context_accepts = context_accepts + 1;
            if (dut.next_context_valid) saw_next_slot = 1'b1;
            if (dut.linear_base_reg == B_LINEAR && dut.context_active &&
                dut.prepared) saw_b_active = 1'b1;

            if (producer_req_valid && producer_req_ready) begin
                if (producer_req_addr !==
                    ((request_phase ? B_LINEAR : A_LINEAR) + request_index*4)) begin
                    $display("BAD_LINEAR_ADDR phase=%0d idx=%0d got=%h",
                             request_phase, request_index, producer_req_addr);
                    errors = errors + 1;
                end
                expected_fifo[expected_wr] = expected_word(request_phase, request_index);
                expected_wr = (expected_wr + 1) % 64;
                expected_count = expected_count + 1;
                request_index <= request_index + 1'b1;
            end

            if (producer_req_valid && !producer_req_ready) begin
                if (request_hold_seen && producer_req_addr !== request_hold_addr) begin
                    $display("UNSTABLE_REQUEST_ADDR got=%h held=%h",
                             producer_req_addr, request_hold_addr);
                    errors = errors + 1;
                end
                request_hold_seen = 1'b1;
                request_hold_addr = producer_req_addr;
            end else begin
                request_hold_seen = 1'b0;
            end

            if (request_phase && producer_req_valid && !producer_req_ready &&
                !(dut.linear_base_reg == B_LINEAR && dut.prepared)) begin
                held_b_requests = held_b_requests + 1;
                saw_b_request_before_active = 1'b1;
            end

            if (mem_req_valid && mem_req_ready) begin
                source_checks = source_checks + 1;
                if (request_phase && saw_b_active) begin
                    if ((mem_req_addr < B_INPUT) ||
                        (mem_req_addr >= (B_INPUT + 4*5*8))) begin
                        $display("BAD_B_SOURCE_ADDR addr=%h", mem_req_addr);
                        errors = errors + 1;
                    end
                end else if ((mem_req_addr < A_INPUT) ||
                             (mem_req_addr >= (A_INPUT + 4*4*4))) begin
                    $display("BAD_A_SOURCE_ADDR addr=%h", mem_req_addr);
                    errors = errors + 1;
                end
            end

            if (mem_req_valid && !mem_req_ready) begin
                if (mem_hold_seen && mem_req_addr !== mem_hold_addr) begin
                    $display("UNSTABLE_MEM_ADDR got=%h held=%h",
                             mem_req_addr, mem_hold_addr);
                    errors = errors + 1;
                end
                mem_hold_seen = 1'b1;
                mem_hold_addr = mem_req_addr;
            end else begin
                mem_hold_seen = 1'b0;
            end

            if (producer_resp_valid && producer_resp_ready) begin
                response_checks = response_checks + 1;
                if (expected_count == 0) begin
                    $display("ORPHAN_RESPONSE data=%h", producer_resp_data);
                    errors = errors + 1;
                end else begin
                    if (producer_resp_data !== expected_fifo[expected_rd]) begin
                        $display("BAD_RESPONSE n=%0d got=%h exp=%h phase=%0d",
                                 response_checks, producer_resp_data,
                                 expected_fifo[expected_rd], request_phase);
                        errors = errors + 1;
                    end
                    expected_rd = (expected_rd + 1) % 64;
                    expected_count = expected_count - 1;
                end
                response_hold_seen = 1'b0;
            end else if (producer_resp_valid && !producer_resp_ready) begin
                if (response_hold_seen && producer_resp_data !== response_hold_data) begin
                    $display("UNSTABLE_RESPONSE got=%h held=%h",
                             producer_resp_data, response_hold_data);
                    errors = errors + 1;
                end
                response_hold_seen = 1'b1;
                response_hold_data = producer_resp_data;
                held_response_checks = held_response_checks + 1;
            end else begin
                response_hold_seen = 1'b0;
            end

            if (context_complete && (dut.nonpad_inflight_count != 0 ||
                                     dut.response_data_count != 0 ||
                                     dut.fifo_count != 0))
                saw_a_completion_pending = 1'b1;
        end
    end

    task present_context;
        input integer which;
        begin
            if (which == 0) begin
                context_linear_base = A_LINEAR;
                context_input_base = A_INPUT;
                context_global_y = 0; context_global_x = 0;
                context_input_zero_point = 8'h08; context_stride = 1;
                context_input_width = 4; context_input_height = 4;
                context_input_channels = 4; context_channel_offset = 0;
                context_footprint_width = 2; context_footprint_height = 2;
            end else begin
                context_linear_base = B_LINEAR;
                context_input_base = B_INPUT;
                context_global_y = 1; context_global_x = 1;
                context_input_zero_point = 8'h0d; context_stride = 2;
                context_input_width = 5; context_input_height = 4;
                context_input_channels = 8; context_channel_offset = 4;
                context_footprint_width = 2; context_footprint_height = 2;
            end
            context_valid = 1'b1;
            while (!context_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            context_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        /* A becomes active; B is accepted into the one-entry slot while A is
         * still active and before A's completion fence is asserted. */
        present_context(0);
        present_context(1);

        request_phase = 1'b0;
        request_index = 0;
        request_run = 1'b1;
        while (request_index < REQ_COUNT) @(negedge clk);
        request_run = 1'b0;

        /* Complete A while the fixed-latency source pipeline and/or producer
         * response FIFO still hold traffic.  B requests are then presented
         * early and must remain unaccepted until B is promoted and prepared. */
        while ((dut.nonpad_inflight_count == 0) &&
               (dut.response_data_count == 0) && (dut.fifo_count == 0))
            @(negedge clk);
        context_complete = 1'b1;
        @(posedge clk);
        @(negedge clk);
        context_complete = 1'b0;
        request_phase = 1'b1;
        request_index = 0;
        request_run = 1'b1;
        while (request_index < REQ_COUNT) @(negedge clk);
        request_run = 1'b0;

        /* Exercise the second completion with the same response fence. */
        while ((dut.nonpad_inflight_count == 0) &&
               (dut.response_data_count == 0) && (dut.fifo_count == 0))
            @(negedge clk);
        context_complete = 1'b1;
        b_complete_sent = 1'b1;
        @(posedge clk);
        @(negedge clk);
        context_complete = 1'b0;

        /* Wait for B's responses and the retirement edge. */
        while (dut.context_active || dut.next_context_valid ||
               (expected_count != 0) || mem_resp_valid || (|mem_v_pipe))
            @(negedge clk);

        /* Reset must clear both active and queued state, including any stale
         * completion pulse or source response bookkeeping. */
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        if (dut.context_active || dut.next_context_valid ||
            dut.fifo_count != 0 || dut.nonpad_inflight_count != 0) begin
            $display("RESET_NOT_CLEAR active=%b next=%b fifo=%0d inflight=%0d",
                     dut.context_active, dut.next_context_valid,
                     dut.fifo_count, dut.nonpad_inflight_count);
            errors = errors + 1;
        end
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        if (!saw_next_slot) begin $display("MISSING_NEXT_SLOT"); errors = errors + 1; end
        if (!saw_a_completion_pending) begin
            $display("MISSING_PENDING_COMPLETION"); errors = errors + 1;
        end
        if (!saw_b_request_before_active || (held_b_requests == 0)) begin
            $display("MISSING_B_HOLD held=%0d", held_b_requests); errors = errors + 1;
        end
        if (!saw_b_active) begin $display("MISSING_B_ACTIVE"); errors = errors + 1; end
        if (context_accepts != 2) begin
            $display("BAD_CONTEXT_ACCEPTS got=%0d", context_accepts); errors = errors + 1;
        end
        if (response_checks != 2*REQ_COUNT) begin
            $display("BAD_RESPONSE_COUNT got=%0d", response_checks); errors = errors + 1;
        end
        if (source_checks == 0 || held_response_checks == 0) begin
            $display("MISSING_SOURCE_OR_RESPONSE_STALL source=%0d held_resp=%0d",
                     source_checks, held_response_checks);
            errors = errors + 1;
        end
        if (error) begin $display("ADAPTER_ERROR"); errors = errors + 1; end

        $display("CONTEXT_SLOT_RESULT errors=%0d accepts=%0d source=%0d responses=%0d held_b=%0d held_resp=%0d",
                 errors, context_accepts, source_checks, response_checks,
                 held_b_requests, held_response_checks);
        if (errors != 0) $fatal(1, "context-slot protocol failure");
        $finish;
    end
endmodule

`default_nettype wire
