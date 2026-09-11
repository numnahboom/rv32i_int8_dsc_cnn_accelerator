`timescale 1ns/1ps
`default_nettype none

/*
 * One-cycle/XPM-equivalent contract test for the v6 PW fetch pair.  The two
 * tiny memory models below implement the same one-entry response behavior as
 * the activation and weight XPM wrappers: a request is accepted only when a
 * prior response is empty or being consumed, and response data/descriptor
 * remain stable while ready is low.  The test deliberately combines
 * continuous K bursts, request bubbles, response stalls, K15/K31 last tags,
 * and epoch/slot context switches.
 */
module tb_edgembconv_hwacandidate_d4_vstream_v6_fetch_pair;
    reg clk;
    reg rst_n;
    reg req_valid;
    reg [15:0] req_desc;
    wire req_ready;
    wire act_req_valid, wgt_req_valid;
    wire act_req_ready, wgt_req_ready;
    wire [15:0] act_req_desc, wgt_req_desc;
    reg act_resp_valid, wgt_resp_valid;
    wire act_resp_ready, wgt_resp_ready;
    reg [31:0] act_resp_data, wgt_resp_data;
    reg [15:0] act_resp_desc, wgt_resp_desc;
    wire pair_resp_valid;
    reg pair_resp_ready;
    wire [31:0] pair_act_data, pair_wgt_data;
    wire [15:0] pair_resp_desc;
    wire descriptor_mismatch;

    integer errors;
    integer cycle_count;
    integer request_count;
    integer response_count;
    reg [15:0] expected_desc [0:127];
    reg [15:0] held_desc;
    reg [31:0] held_act_data;
    reg [31:0] held_wgt_data;
    reg held_valid;

    assign act_req_ready = rst_n && (!act_resp_valid || act_resp_ready);
    assign wgt_req_ready = rst_n && (!wgt_resp_valid || wgt_resp_ready);

    edgembconv_hwacandidate_d4_vstream_v6_fetch_pair #(
        .ACT_WIDTH(32), .WGT_WIDTH(32)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_desc(req_desc),
        .act_req_valid(act_req_valid), .act_req_ready(act_req_ready),
        .act_req_desc(act_req_desc), .wgt_req_valid(wgt_req_valid),
        .wgt_req_ready(wgt_req_ready), .wgt_req_desc(wgt_req_desc),
        .act_resp_valid(act_resp_valid), .act_resp_ready(act_resp_ready),
        .act_resp_data(act_resp_data), .act_resp_desc(act_resp_desc),
        .wgt_resp_valid(wgt_resp_valid), .wgt_resp_ready(wgt_resp_ready),
        .wgt_resp_data(wgt_resp_data), .wgt_resp_desc(wgt_resp_desc),
        .pair_resp_valid(pair_resp_valid), .pair_resp_ready(pair_resp_ready),
        .pair_act_data(pair_act_data), .pair_wgt_data(pair_wgt_data),
        .pair_resp_desc(pair_resp_desc),
        .descriptor_mismatch(descriptor_mismatch)
    );

    always #5 clk = ~clk;

    /* Both physical response channels return one cycle after a request and
     * can be replaced on the same edge as a paired response consume. */
    always @(posedge clk) begin
        if (!rst_n) begin
            act_resp_valid <= 1'b0;
            wgt_resp_valid <= 1'b0;
            act_resp_desc <= 16'd0;
            wgt_resp_desc <= 16'd0;
            act_resp_data <= 32'd0;
            wgt_resp_data <= 32'd0;
        end else begin
            if (act_resp_valid && act_resp_ready)
                act_resp_valid <= 1'b0;
            if (wgt_resp_valid && wgt_resp_ready)
                wgt_resp_valid <= 1'b0;
            if (act_req_valid && act_req_ready) begin
                act_resp_valid <= 1'b1;
                act_resp_desc <= act_req_desc;
                act_resp_data <= {16'ha501, act_req_desc};
            end
            if (wgt_req_valid && wgt_req_ready) begin
                wgt_resp_valid <= 1'b1;
                wgt_resp_desc <= wgt_req_desc;
                wgt_resp_data <= {16'h5a02, wgt_req_desc};
            end
        end
    end

    /* Check the old response at the active edge, before the memory model's
     * nonblocking replacement.  This is the exact handshake edge used by a
     * synchronous XPM response queue. */
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count = 0;
            request_count = 0;
            response_count = 0;
            held_valid = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;
            if (act_req_valid !== wgt_req_valid ||
                act_req_desc !== wgt_req_desc) begin
                $display("V6_FETCH_PAIR_REQUEST_MISMATCH cycle=%0d", cycle_count);
                errors = errors + 1;
            end
            if (act_req_valid && act_req_ready) begin
                if (!req_valid || !req_ready || req_desc !== act_req_desc) begin
                    $display("V6_FETCH_PAIR_REQUEST_FIRE_MISMATCH cycle=%0d", cycle_count);
                    errors = errors + 1;
                end
                expected_desc[request_count] = act_req_desc;
                request_count = request_count + 1;
            end
            if (pair_resp_valid && pair_resp_ready) begin
                if (response_count >= request_count ||
                    pair_resp_desc !== expected_desc[response_count] ||
                    pair_act_data !== {16'ha501, pair_resp_desc} ||
                    pair_wgt_data !== {16'h5a02, pair_resp_desc}) begin
                    $display("V6_FETCH_PAIR_RESPONSE_MISMATCH cycle=%0d index=%0d exp=%04x got=%04x",
                             cycle_count, response_count,
                             expected_desc[response_count], pair_resp_desc);
                    errors = errors + 1;
                end
                response_count = response_count + 1;
            end
            if (pair_resp_valid && !pair_resp_ready) begin
                if (act_resp_ready || wgt_resp_ready || req_ready) begin
                    $display("V6_FETCH_PAIR_STALL_LEAK cycle=%0d", cycle_count);
                    errors = errors + 1;
                end
                if (!held_valid) begin
                    held_valid = 1'b1;
                    held_desc = pair_resp_desc;
                    held_act_data = pair_act_data;
                    held_wgt_data = pair_wgt_data;
                end else if (pair_resp_desc !== held_desc ||
                             pair_act_data !== held_act_data ||
                             pair_wgt_data !== held_wgt_data) begin
                    $display("V6_FETCH_PAIR_HOLD_FAILURE cycle=%0d", cycle_count);
                    errors = errors + 1;
                end
            end else if (pair_resp_ready) begin
                held_valid = 1'b0;
            end
            if (descriptor_mismatch) begin
                $display("V6_FETCH_PAIR_UNEXPECTED_DESCRIPTOR_MISMATCH cycle=%0d", cycle_count);
                errors = errors + 1;
            end
        end
    end

    function [15:0] make_desc;
        input [3:0] epoch_arg;
        input slot_arg;
        input project_arg;
        input group_arg;
        input pass_arg;
        input integer k_arg;
        begin
            make_desc = {epoch_arg,slot_arg,project_arg,group_arg,pass_arg,
                         k_arg[5:0],(k_arg==0),
                         (k_arg==(project_arg ? 31 : 15))};
        end
    endfunction

    /* Drive one descriptor.  All stimulus changes happen on a falling edge,
     * leaving the complete request stable through the accepting rising edge;
     * this is the same phase relationship used by the synchronous RAM model. */
    task send_one;
        input [15:0] desc_arg;
        integer guard;
        begin
            @(negedge clk);
            req_desc = desc_arg;
            req_valid = 1'b1;
            guard = 0;
            while (1) begin
                @(posedge clk);
                if (req_valid && req_ready) begin
                    @(negedge clk);
                    req_valid = 1'b0;
                    break;
                end
                guard = guard + 1;
                if (guard > 200)
                    $fatal(1,"V6_FETCH_PAIR_REQUEST_TIMEOUT desc=%04x",desc_arg);
            end
        end
    endtask

    /* Drive an entire K burst.  Optional one-cycle bubbles are inserted
     * between accepted requests.  The first burst deliberately stalls while
     * its first response is live, so the response-hold check observes a real
     * pending pair rather than an idle interval. */
    task run_burst;
        input [3:0] epoch_arg;
        input slot_arg;
        input project_arg;
        input group_arg;
        input pass_arg;
        input integer last_k;
        input integer bubble_period;
        input stall_first;
        integer k;
        integer before_req;
        begin
            before_req = request_count;
            for (k = 0; k <= last_k; k = k + 1) begin
                if (bubble_period > 0 && k > 0 && (k % bubble_period) == 0) begin
                    @(negedge clk);
                    req_valid = 1'b0;
                    @(posedge clk);
                end
                send_one(make_desc(epoch_arg,slot_arg,project_arg,group_arg,pass_arg,k));
                if (stall_first && k == 0) begin
                    /* send_one returns immediately after the request's
                     * response has become valid, so this is a genuine live
                     * response stall. */
                    pair_resp_ready = 1'b0;
                    repeat (3) @(posedge clk);
                    @(negedge clk);
                    pair_resp_ready = 1'b1;
                end
            end
            while (response_count < before_req + last_k + 1) begin
                @(posedge clk);
                if (cycle_count > 5000)
                    $fatal(1,"V6_FETCH_PAIR_RESPONSE_TIMEOUT epoch=%0d req=%0d resp=%0d",
                           epoch_arg,request_count,response_count);
            end
            if (request_count != before_req + last_k + 1) begin
                $display("V6_FETCH_PAIR_BURST_REQUEST_COUNT epoch=%0d",epoch_arg);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_desc = 16'd0;
        pair_resp_ready = 1'b1;
        errors = 0;
        cycle_count = 0;
        request_count = 0;
        response_count = 0;
        held_valid = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        /* Full II=1 expand burst and K15 last tag. */
        run_burst(4'ha,1'b0,1'b0,1'b0,1'b0,15,0,1);

        /* A context/slot switch with request bubbles. */
        run_burst(4'ha,1'b1,1'b0,1'b1,1'b1,15,4,0);

        /* Project-sized burst exercises K31 and a different epoch. */
        run_burst(4'hb,1'b0,1'b1,1'b0,1'b1,31,5,0);
        run_burst(4'hc,1'b1,1'b1,1'b1,1'b0,31,0,0);

        if (request_count != 96 || response_count != 96)
            begin
                $display("V6_FETCH_PAIR_COUNT_FAILURE req=%0d resp=%0d",
                         request_count,response_count);
                errors = errors + 1;
            end
        if (errors == 0)
            $display("PASS edgembconv_hwacandidate_d4_vstream_v6_fetch_pair one_cycle=1 burst=K15+K31 bubble=1 stall_hold=1 context_switch=1 requests=%0d responses=%0d",
                     request_count,response_count);
        else
            $fatal(1,"V6_FETCH_PAIR_ERRORS=%0d",errors);
        $finish;
    end
endmodule

`default_nettype wire
