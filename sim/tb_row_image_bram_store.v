`timescale 1ns/1ps
`default_nettype none

module tb_row_image_bram_store;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg         wr_valid;
    wire        wr_ready;
    reg [7:0]   wr_addr;
    reg [2:0]   wr_word_sel;
    reg [35:0]  wr_data36;

    reg         rd_req_valid;
    wire        rd_req_ready;
    reg [7:0]   rd_addr;
    wire        rd_valid;
    reg         rd_ready;
    wire [255:0] rd_data;
    wire [31:0] rd_mask;

    row_image_bram_store dut (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_addr(wr_addr),
        .wr_word_sel(wr_word_sel), .wr_data36(wr_data36),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
        .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_ready(rd_ready),
        .rd_data(rd_data), .rd_mask(rd_mask)
    );

    reg [35:0] expected [0:255][0:7];
    integer errors = 0;
    integer checks = 0;
    integer i, j, addr_i, sel_i, stall_i, stall_j;
    reg [35:0] data_i;
    reg [31:0] rng_state = 32'h1bad_f00d;
    reg [255:0] expected_data;
    reg [31:0] expected_mask;

    task automatic random_step;
        begin
            rng_state = {rng_state[30:0],
                         rng_state[31] ^ rng_state[21] ^ rng_state[1] ^ rng_state[0]};
        end
    endtask

    function automatic [7:0] make_addr;
        input integer row_i;
        input integer group_i;
        input integer half_i;
        begin
            make_addr = {row_i[2:0], group_i[3:0], half_i[0]};
        end
    endfunction

    task automatic drive_defaults;
        begin
            wr_valid = 1'b0;
            wr_addr = 8'd0;
            wr_word_sel = 3'd0;
            wr_data36 = 36'd0;
            rd_req_valid = 1'b0;
            rd_addr = 8'd0;
            rd_ready = 1'b0;
        end
    endtask

    task automatic write_one;
        input integer a;
        input integer s;
        input [35:0] d;
        begin
            @(negedge clk);
            wr_addr = a[7:0];
            wr_word_sel = s[2:0];
            wr_data36 = d;
            wr_valid = 1'b1;
            if (!wr_ready) begin
                $display("FAIL wr_ready unexpectedly low");
                errors = errors + 1;
            end
            @(posedge clk);
            #1;
            wr_valid = 1'b0;
            expected[a][s] = d;
        end
    endtask

    task automatic form_expected;
        input integer a;
        begin
            expected_data = 256'd0;
            expected_mask = 32'd0;
            for (j = 0; j < 8; j = j + 1) begin
                expected_data[(j*32) +: 32] = expected[a][j][31:0];
                expected_mask[(j*4) +: 4] = expected[a][j][35:32];
            end
        end
    endtask

    task automatic check_output;
        input integer a;
        begin
            form_expected(a);
            checks = checks + 1;
            if (rd_data !== expected_data || rd_mask !== expected_mask) begin
                $display("FAIL read addr=%0d data=%h/%h mask=%h/%h",
                         a, rd_data, expected_data, rd_mask, expected_mask);
                errors = errors + 1;
            end
        end
    endtask

    task automatic read_one;
        input integer a;
        begin
            while (!rd_req_ready) begin
                @(negedge clk);
                rd_ready = 1'b1;
                @(posedge clk);
                #1;
                rd_ready = 1'b0;
            end
            @(negedge clk);
            rd_addr = a[7:0];
            rd_req_valid = 1'b1;
            rd_ready = 1'b0;
            @(posedge clk);
            #1;
            rd_req_valid = 1'b0;
            /* The registered response must arrive exactly one edge later. */
            if (!rd_valid) begin
                $display("FAIL missing one-cycle read response addr=%0d", a);
                errors = errors + 1;
            end
            check_output(a);
            random_step();
            stall_i = rng_state % 5;
            for (stall_j = 0; stall_j < stall_i; stall_j = stall_j + 1) begin
                @(negedge clk);
                rd_ready = 1'b0;
                @(posedge clk);
                #1;
                if (!rd_valid) begin
                    $display("FAIL response dropped under backpressure addr=%0d", a);
                    errors = errors + 1;
                end
                check_output(a);
            end
            @(negedge clk);
            rd_ready = 1'b1;
            @(posedge clk);
            #1;
            rd_ready = 1'b0;
            if (rd_valid) begin
                $display("FAIL response did not retire addr=%0d", a);
                errors = errors + 1;
            end
        end
    endtask

    task automatic collision_read_first;
        input integer a;
        input integer s;
        input [35:0] new_d;
        reg [35:0] old_d;
        begin
            old_d = expected[a][s];
            form_expected(a);
            expected_data[(s*32) +: 32] = old_d[31:0];
            expected_mask[(s*4) +: 4] = old_d[35:32];
            @(negedge clk);
            wr_addr = a[7:0];
            wr_word_sel = s[2:0];
            wr_data36 = new_d;
            wr_valid = 1'b1;
            rd_addr = a[7:0];
            rd_req_valid = 1'b1;
            rd_ready = 1'b0;
            @(posedge clk);
            #1;
            wr_valid = 1'b0;
            rd_req_valid = 1'b0;
            expected[a][s] = new_d;
            if (!rd_valid) begin
                $display("FAIL collision response missing");
                errors = errors + 1;
            end
            checks = checks + 1;
            if (rd_data !== expected_data || rd_mask !== expected_mask) begin
                $display("FAIL collision is not READ_FIRST addr=%0d sel=%0d", a, s);
                errors = errors + 1;
            end
            @(negedge clk);
            rd_ready = 1'b1;
            @(posedge clk);
            #1;
            rd_ready = 1'b0;
        end
    endtask

    initial begin
        $display("START row_image_bram_store");
        drive_defaults();
        /* Reset never writes the array; this is an abstract ownership fence. */
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        /* No store request is presented before ownership is granted here. */
        repeat (3) @(posedge clk);

        /* Exercise every row/group/half address and all eight planes. */
        for (i = 0; i < 4096; i = i + 1) begin
            random_step();
            addr_i = make_addr((i + (rng_state & 7)) & 7,
                               ((i*13) + ((rng_state >> 3) & 15)) & 15,
                               (i + (rng_state >> 8)) & 1);
            sel_i = (i + (rng_state >> 16)) & 7;
            data_i = {((i*37 + sel_i*11 + rng_state[7:0]) & 8'hf),
                      ((i*17 + addr_i*3 + rng_state) & 32'hffff_ffff)};
            write_one(addr_i, sel_i, data_i);
            if ((i % 512) == 511) $display("writes=%0d", i + 1);
        end

        /* Same-cycle write/read has an explicit and checked collision contract. */
        collision_read_first(8'hd3, 3'd5, 36'h5_cafe1234);
        collision_read_first(8'h00, 3'd0, 36'ha_12345678);

        /* Thousands of gathers with arbitrary row/group/half and output stalls. */
        for (i = 0; i < 3000; i = i + 1) begin
            random_step();
            addr_i = make_addr(rng_state[2:0], rng_state[6:3], rng_state[7]);
            read_one(addr_i);
            if ((i % 512) == 511) $display("reads=%0d", i + 1);
        end

        @(negedge clk);
        if (errors == 0)
            $display("PASS row_image_bram_store checks=%0d writes=4098 reads=3002", checks);
        else
            $display("FAIL row_image_bram_store errors=%0d checks=%0d", errors, checks);
        $finish;
    end
endmodule

`default_nettype wire
