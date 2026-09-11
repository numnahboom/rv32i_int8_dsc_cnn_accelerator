`timescale 1ns/1ps
`default_nettype none

/*
 * Focused contract test for the registered v6 DW source-request boundary.
 *
 * The driver presents the same one-outstanding request stream used by the
 * fixed 8x8/stride-2 DW tile.  It deliberately includes top-left halo
 * requests (tap sequence 4,5,7,8), an interior pixel (K0..K8), a forced
 * physical-request stall, a forced response stall, and a service stall that
 * disables look-ahead while still allowing the current response to retire.
 * The memory model returns the address in every response byte, so request
 * addresses and response payloads are checked independently.
 */
module tb_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter;
    reg clk;
    reg rst_n;
    reg enable;
    reg command_start;
    reg in_req_valid;
    wire in_req_ready;
    reg [31:0] in_req_addr;
    reg [7:0] in_req_pixel_idx;
    reg [3:0] in_req_tap_idx;
    reg [31:0] in_req_metadata;
    wire in_resp_valid;
    reg in_resp_ready;
    wire [127:0] in_resp_data;
    wire mem_req_valid;
    reg mem_req_ready;
    wire [10:0] mem_req_addr;
    wire service_ready;
    reg mem_resp_valid;
    wire mem_resp_ready;
    reg [127:0] mem_resp_data;
    wire protocol_error;

    reg [10:0] expected_addr [0:63];
    integer expected_issued;
    integer mem_req_seen;
    integer resp_seen;
    integer cycle_count;
    integer errors;
    integer job_count;
    reg mem_req_hold;
    reg [10:0] mem_req_hold_addr;
    reg in_req_hold;
    reg [31:0] in_req_hold_addr;
    reg [7:0] in_req_hold_pixel;
    reg [3:0] in_req_hold_tap;
    reg [31:0] in_req_hold_metadata;
    reg in_resp_hold;
    reg [127:0] in_resp_hold_data;
    reg mem_resp_hold;
    reg [127:0] mem_resp_hold_data;
    reg force_mem_stall_active;
    reg force_mem_stall_done;
    reg force_resp_stall_active;
    reg force_resp_stall_done;
    integer mem_stall_count;
    integer resp_stall_count;
    integer service_stall_count;

    edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter #(
        .IN_W(32), .IN_H(32)
    ) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .command_start(command_start),
        .in_req_valid(in_req_valid), .in_req_ready(in_req_ready),
        .in_req_addr(in_req_addr), .in_req_pixel_idx(in_req_pixel_idx),
        .in_req_tap_idx(in_req_tap_idx), .in_req_metadata(in_req_metadata),
        .in_resp_valid(in_resp_valid), .in_resp_ready(in_resp_ready),
        .in_resp_data(in_resp_data),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .service_ready(service_ready),
        .mem_resp_valid(mem_resp_valid), .mem_resp_ready(mem_resp_ready),
        .mem_resp_data(mem_resp_data), .protocol_error(protocol_error)
    );

    always #5 clk = ~clk;

    function [10:0] calc_addr;
        input [4:0] meta_x;
        input [4:0] meta_y;
        input [7:0] pixel_idx;
        input [3:0] tap_idx;
        integer output_x;
        integer output_y;
        integer tap_row;
        integer tap_col;
        begin
            output_x = meta_x + pixel_idx[2:0];
            output_y = meta_y + pixel_idx[7:3];
            tap_row = 0;
            tap_col = 0;
            case (tap_idx)
                4'd0: begin tap_row = 0; tap_col = 0; end
                4'd1: begin tap_row = 0; tap_col = 1; end
                4'd2: begin tap_row = 0; tap_col = 2; end
                4'd3: begin tap_row = 1; tap_col = 0; end
                4'd4: begin tap_row = 1; tap_col = 1; end
                4'd5: begin tap_row = 1; tap_col = 2; end
                4'd6: begin tap_row = 2; tap_col = 0; end
                4'd7: begin tap_row = 2; tap_col = 1; end
                4'd8: begin tap_row = 2; tap_col = 2; end
                default: begin tap_row = 0; tap_col = 0; end
            endcase
            calc_addr = (((output_y * 2) + tap_row - 1) * 32) +
                        ((output_x * 2) + tap_col - 1);
        end
    endfunction

    function [127:0] make_data;
        input [10:0] addr;
        integer lane;
        begin
            make_data = 128'd0;
            for (lane = 0; lane < 16; lane = lane + 1)
                make_data[lane*8 +: 8] = addr[7:0];
        end
    endfunction

    /* Force one request-side stall and one response-side stall.  Additional
     * deterministic stalls keep the contract under nontrivial service. */
    always @(negedge clk) begin
        if (!rst_n) begin
            mem_req_ready <= 1'b1;
            in_resp_ready <= 1'b1;
            force_mem_stall_active <= 1'b0;
            force_mem_stall_done <= 1'b0;
            force_resp_stall_active <= 1'b0;
            force_resp_stall_done <= 1'b0;
        end else begin
            if (!force_mem_stall_done && !force_mem_stall_active && mem_req_valid) begin
                mem_req_ready <= 1'b0;
                force_mem_stall_active <= 1'b1;
            end else if (force_mem_stall_active) begin
                mem_req_ready <= 1'b1;
                force_mem_stall_active <= 1'b0;
                force_mem_stall_done <= 1'b1;
            end else begin
                mem_req_ready <= ((cycle_count * 5 + 1) % 9) != 3;
            end

            if (!force_resp_stall_done && !force_resp_stall_active && in_resp_valid) begin
                in_resp_ready <= 1'b0;
                force_resp_stall_active <= 1'b1;
            end else if (force_resp_stall_active) begin
                in_resp_ready <= 1'b1;
                force_resp_stall_active <= 1'b0;
                force_resp_stall_done <= 1'b1;
            end else begin
                in_resp_ready <= ((cycle_count * 7 + 2) % 11) != 4;
            end
        end
    end

    /* The first physical response is deliberately serviced with
     * service_ready low.  mem_resp_ready must still follow in_resp_ready. */
    assign service_ready = !(in_resp_valid && (resp_seen == 0));

    /* One-cycle synchronous memory model with a response hold.  A same-edge
     * response consume and replacement request is supported. */
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_data <= 128'd0;
        end else begin
            if (mem_resp_valid && mem_resp_ready)
                mem_resp_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                mem_resp_valid <= 1'b1;
                mem_resp_data <= make_data(mem_req_addr);
            end
        end
    end

    /* Independent conservation and stability checks. */
    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count = cycle_count + 1;
            if (mem_req_hold &&
                (!mem_req_valid || mem_req_addr !== mem_req_hold_addr)) begin
                $display("V6_ADAPTER_MEM_REQ_UNSTABLE cycle=%0d", cycle_count);
                errors = errors + 1;
            end
            mem_req_hold = mem_req_valid && !mem_req_ready;
            if (mem_req_hold)
                mem_req_hold_addr = mem_req_addr;

            if (in_req_hold &&
                (!in_req_valid || in_req_addr !== in_req_hold_addr ||
                 in_req_pixel_idx !== in_req_hold_pixel ||
                 in_req_tap_idx !== in_req_hold_tap ||
                 in_req_metadata !== in_req_hold_metadata)) begin
                $display("V6_ADAPTER_IN_REQ_UNSTABLE cycle=%0d", cycle_count);
                errors = errors + 1;
            end
            in_req_hold = in_req_valid && !in_req_ready;
            if (in_req_hold) begin
                in_req_hold_addr = in_req_addr;
                in_req_hold_pixel = in_req_pixel_idx;
                in_req_hold_tap = in_req_tap_idx;
                in_req_hold_metadata = in_req_metadata;
            end

            if (in_resp_hold &&
                (!in_resp_valid || in_resp_data !== in_resp_hold_data)) begin
                $display("V6_ADAPTER_IN_RESP_UNSTABLE cycle=%0d", cycle_count);
                errors = errors + 1;
            end
            in_resp_hold = in_resp_valid && !in_resp_ready;
            if (in_resp_hold)
                in_resp_hold_data = in_resp_data;

            if (mem_resp_hold &&
                (!mem_resp_valid || mem_resp_data !== mem_resp_hold_data)) begin
                $display("V6_ADAPTER_MEM_RESP_UNSTABLE cycle=%0d", cycle_count);
                errors = errors + 1;
            end
            mem_resp_hold = mem_resp_valid && !mem_resp_ready;
            if (mem_resp_hold)
                mem_resp_hold_data = mem_resp_data;

            if (mem_req_valid && !mem_req_ready) begin
                mem_stall_count = mem_stall_count + 1;
            end
            if (in_resp_valid && !in_resp_ready) begin
                resp_stall_count = resp_stall_count + 1;
            end
            if (!service_ready && in_resp_valid && in_resp_ready &&
                !mem_req_valid) begin
                service_stall_count = service_stall_count + 1;
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_seen >= expected_issued) begin
                    $display("V6_ADAPTER_EXTRA_MEM_REQ cycle=%0d addr=%0d",
                             cycle_count, mem_req_addr);
                    errors = errors + 1;
                end else if (mem_req_addr !== expected_addr[mem_req_seen]) begin
                    $display("V6_ADAPTER_ADDR_MISMATCH request=%0d exp=%0d got=%0d",
                             mem_req_seen, expected_addr[mem_req_seen], mem_req_addr);
                    errors = errors + 1;
                end
                mem_req_seen = mem_req_seen + 1;
            end

            if (in_resp_valid && in_resp_ready) begin
                if (resp_seen >= expected_issued) begin
                    $display("V6_ADAPTER_EXTRA_RESP cycle=%0d", cycle_count);
                    errors = errors + 1;
                end else if (in_resp_data !== make_data(expected_addr[resp_seen])) begin
                    $display("V6_ADAPTER_DATA_MISMATCH response=%0d exp_addr=%0d",
                             resp_seen, expected_addr[resp_seen]);
                    errors = errors + 1;
                end
                resp_seen = resp_seen + 1;
            end

            if (protocol_error) begin
                $display("V6_ADAPTER_PROTOCOL_ERROR cycle=%0d", cycle_count);
                errors = errors + 1;
            end
            if (cycle_count > 20000)
                $fatal(1, "V6_ADAPTER_TIMEOUT req=%0d/%0d resp=%0d/%0d",
                       mem_req_seen, expected_issued, resp_seen, expected_issued);
        end
    end

    task start_job;
        begin
            @(negedge clk);
            while (!in_req_ready)
                @(negedge clk);
            command_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            command_start = 1'b0;
            job_count = job_count + 1;
        end
    endtask

    task issue_request;
        input [4:0] meta_x;
        input [4:0] meta_y;
        input [7:0] pixel_idx;
        input [3:0] tap_idx;
        integer address_i;
        begin
            address_i = calc_addr(meta_x, meta_y, pixel_idx, tap_idx);
            @(negedge clk);
            while (!in_req_ready)
                @(negedge clk);
            in_req_addr = address_i;
            in_req_pixel_idx = pixel_idx;
            in_req_tap_idx = tap_idx;
            in_req_metadata = {22'd0, meta_y, meta_x};
            expected_addr[expected_issued] = address_i[10:0];
            expected_issued = expected_issued + 1;
            in_req_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            in_req_valid = 1'b0;
            in_req_addr = 32'd0;
            in_req_pixel_idx = 8'd0;
            in_req_tap_idx = 4'd0;
            in_req_metadata = 32'd0;
            while (resp_seen < expected_issued)
                @(posedge clk);
        end
    endtask

    task finish_job;
        begin
            @(negedge clk);
            in_req_valid = 1'b0;
            in_req_addr = 32'd0;
            in_req_pixel_idx = 8'd0;
            in_req_tap_idx = 4'd0;
            in_req_metadata = 32'd0;
            while (resp_seen < expected_issued)
                @(posedge clk);
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        enable = 1'b1;
        command_start = 1'b0;
        in_req_valid = 1'b0;
        in_req_addr = 32'd0;
        in_req_pixel_idx = 8'd0;
        in_req_tap_idx = 4'd0;
        in_req_metadata = 32'd0;
        in_resp_ready = 1'b1;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_data = 128'd0;
        expected_issued = 0;
        mem_req_seen = 0;
        resp_seen = 0;
        cycle_count = 0;
        errors = 0;
        job_count = 0;
        mem_req_hold = 1'b0;
        in_req_hold = 1'b0;
        in_resp_hold = 1'b0;
        mem_resp_hold = 1'b0;
        force_mem_stall_active = 1'b0;
        force_mem_stall_done = 1'b0;
        force_resp_stall_active = 1'b0;
        force_resp_stall_done = 1'b0;
        mem_stall_count = 0;
        resp_stall_count = 0;
        service_stall_count = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        /* Job 0: two top-row pixels.  Their K4/K5/K7/K8 sequence exercises
         * both the leading and trailing halo gaps. */
        start_job;
        issue_request(5'd0, 5'd0, 8'd0, 4'd4);
        issue_request(5'd0, 5'd0, 8'd0, 4'd5);
        issue_request(5'd0, 5'd0, 8'd0, 4'd7);
        issue_request(5'd0, 5'd0, 8'd0, 4'd8);
        issue_request(5'd0, 5'd0, 8'd7, 4'd4);
        issue_request(5'd0, 5'd0, 8'd7, 4'd5);
        issue_request(5'd0, 5'd0, 8'd7, 4'd7);
        issue_request(5'd0, 5'd0, 8'd7, 4'd8);
        finish_job;

        /* Job 1: two interior pixels, including the bottom-right output
         * pixel via metadata origin 8,8 and pixel index 63. */
        start_job;
        issue_request(5'd8, 5'd8, 8'd0, 4'd0);
        issue_request(5'd8, 5'd8, 8'd0, 4'd1);
        issue_request(5'd8, 5'd8, 8'd0, 4'd2);
        issue_request(5'd8, 5'd8, 8'd0, 4'd3);
        issue_request(5'd8, 5'd8, 8'd0, 4'd4);
        issue_request(5'd8, 5'd8, 8'd0, 4'd5);
        issue_request(5'd8, 5'd8, 8'd0, 4'd6);
        issue_request(5'd8, 5'd8, 8'd0, 4'd7);
        issue_request(5'd8, 5'd8, 8'd0, 4'd8);
        issue_request(5'd8, 5'd8, 8'd63, 4'd0);
        issue_request(5'd8, 5'd8, 8'd63, 4'd1);
        issue_request(5'd8, 5'd8, 8'd63, 4'd2);
        issue_request(5'd8, 5'd8, 8'd63, 4'd3);
        issue_request(5'd8, 5'd8, 8'd63, 4'd4);
        issue_request(5'd8, 5'd8, 8'd63, 4'd5);
        issue_request(5'd8, 5'd8, 8'd63, 4'd6);
        issue_request(5'd8, 5'd8, 8'd63, 4'd7);
        issue_request(5'd8, 5'd8, 8'd63, 4'd8);
        finish_job;

        if (job_count != 2 || expected_issued != 26 ||
            mem_req_seen != expected_issued || resp_seen != expected_issued ||
            errors != 0 || protocol_error || mem_stall_count == 0 ||
            resp_stall_count == 0 || service_stall_count == 0) begin
            $display("V6_ADAPTER_STATS jobs=%0d issued=%0d requests=%0d responses=%0d errors=%0d mem_stall=%0d resp_stall=%0d service_stall=%0d protocol=%0d",
                     job_count, expected_issued, mem_req_seen, resp_seen,
                     errors, mem_stall_count, resp_stall_count, service_stall_count,
                     protocol_error);
            $fatal(1, "V6_ADAPTER_CONTRACT_FAIL");
        end
        $display("PASS edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter jobs=2 halo=K4+K5+K7+K8 interior=K0..K8 mem_stall=1 resp_stall=1 service_stall=1 requests=26 responses=26");
        $finish;
    end
endmodule

`default_nettype wire
