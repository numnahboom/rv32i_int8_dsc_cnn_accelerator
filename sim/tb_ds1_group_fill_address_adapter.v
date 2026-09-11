`timescale 1ns/1ps
`default_nettype none

module tb_ds1_group_fill_address_adapter;
    reg clk = 0;
    always #1 clk = ~clk;
    reg rst_n = 0;
    reg context_valid = 0;
    wire context_ready;
    reg [31:0] linear_base = 32'h0040_0000;
    reg [31:0] input_base = 32'h0010_0000;
    reg [5:0] global_y = 0, global_x = 0;
    reg [7:0] zero_point = 8'h81;
    reg context_complete = 0;
    reg producer_req_valid = 0;
    wire producer_req_ready;
    reg [31:0] producer_req_addr = 0;
    wire producer_resp_valid;
    wire [31:0] producer_resp_data;
    wire mem_req_valid;
    reg mem_req_ready = 1;
    wire [31:0] mem_req_addr;
    reg mem_resp_valid = 0;
    reg [31:0] mem_resp_data = 0;
    wire error;

    ds1_group_fill_address_adapter dut (
        .clk(clk), .rst_n(rst_n), .context_valid(context_valid),
        .context_ready(context_ready), .context_linear_base(linear_base),
        .context_input_base(input_base), .context_global_y(global_y),
        .context_global_x(global_x), .context_input_zero_point(zero_point),
        .context_complete(context_complete), .producer_req_valid(producer_req_valid),
        .producer_req_ready(producer_req_ready), .producer_req_addr(producer_req_addr),
        .producer_resp_valid(producer_resp_valid), .producer_resp_data(producer_resp_data),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .error(error)
    );

    integer errors = 0;
    integer request_index = 0;
    integer response_index = 0;
    integer expected_addr;
    reg [31:0] physical_q [0:7];
    integer qwr = 0, qrd = 0, qcount = 0;

    /* In-order two-cycle external source.  Its word data encodes the
     * requested address, so the response-side order is independently checked. */
    reg [31:0] pipe_addr0 = 0, pipe_addr1 = 0;
    reg pipe_v0 = 0, pipe_v1 = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            pipe_v0 <= 0; pipe_v1 <= 0; mem_resp_valid <= 0;
            qwr = 0; qrd = 0; qcount = 0;
        end else begin
            mem_resp_valid <= pipe_v0;
            mem_resp_data <= pipe_addr0;
            pipe_v0 <= pipe_v1;
            pipe_addr0 <= pipe_addr1;
            pipe_v1 <= 0;
            if (mem_req_valid && mem_req_ready) begin
                pipe_v1 <= 1;
                pipe_addr1 <= mem_req_addr;
            end
        end
    end

    task issue_word;
        input integer idx;
        begin
            @(negedge clk);
            producer_req_addr = linear_base + idx*4;
            producer_req_valid = 1;
            #0;
            while (!producer_req_ready) @(posedge clk);
            /* Capture the externally visible address before the request edge. */
            if (idx == 44 && (!mem_req_valid || mem_req_addr !== input_base)) begin
                $display("FIRST_PHYSICAL_MISMATCH valid=%b addr=%h", mem_req_valid, mem_req_addr);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            producer_req_valid = 0;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && producer_resp_valid) begin
            /* For top-left microgroup, source words before index44 are top/
             * left padding.  Subsequent response values either carry the
             * physical mapped address or the zero-point fill. */
            if (response_index < 44) begin
                if (producer_resp_data !== 32'h81818181) begin
                    $display("PAD_RESPONSE_MISMATCH idx=%0d data=%h", response_index, producer_resp_data);
                    errors = errors + 1;
                end
            end else if (response_index == 44) begin
                if (producer_resp_data !== input_base) begin
                    $display("PHYSICAL_RESPONSE_MISMATCH data=%h", producer_resp_data);
                    errors = errors + 1;
                end
            end
            response_index = response_index + 1;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        context_valid = 1;
        while (!context_ready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        context_valid = 0;

        /* Include a long padding prefix, a physical word, and a next-row
         * padding word.  Delay physical responses while synthetic responses
         * are retiring to exercise FIFO ordering. */
        for (request_index = 0; request_index < 81; request_index = request_index + 1)
            issue_word(request_index);
        while (response_index < 81) @(posedge clk);
        @(negedge clk);
        context_complete = 1;
        @(posedge clk);
        @(negedge clk);
        context_complete = 0;
        if (error) errors = errors + 1;
        if (errors == 0)
            $display("PASS ds1_group_fill_address_adapter responses=%0d", response_index);
        else begin
            $display("FAIL ds1_group_fill_address_adapter errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end
    initial begin
        repeat (4000) @(posedge clk);
        $fatal(1, "WATCHDOG");
    end
endmodule

`default_nettype wire
