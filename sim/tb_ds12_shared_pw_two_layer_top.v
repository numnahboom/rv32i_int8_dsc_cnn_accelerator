`timescale 1ns/1ps
`default_nettype none
module tb_ds12_shared_pw_two_layer_top;
    reg clk = 0, rst_n = 0, start = 0;
    always #5 clk = ~clk;
    reg [7:0] in_bytes [0:65535];
    reg [7:0] exp1 [0:32767];
    reg [7:0] exp2 [0:16383];
    reg [31:0] cfg [0:1179];
    integer fd, rc, ly, kd, idx, address, mask, dataw;
    integer j, cfg_seen, out1_seen, out2_seen, mismatches, wait_cycles;
    reg cfg_pending, in_pending;
    reg [31:0] cfg_pending_data, in_pending_addr;
    reg [31:0] cfg_lfsr, input_lfsr, output_lfsr;
    integer prev_sched_state;
`ifdef TB_RANDOM_BP
    wire cfg_allow = cfg_lfsr[0];
    wire input_allow = input_lfsr[0];
    wire output_allow = output_lfsr[0];
`else
    wire cfg_allow = 1'b1;
    wire input_allow = 1'b1;
    wire output_allow = 1'b1;
`endif

    wire cv, cr; wire [31:0] ca; wire [15:0] ci; wire [1:0] cl; wire [3:0] cs;
    reg cmv; reg [31:0] cmd;
    wire iv, ir, iw; wire [31:0] ia; wire [127:0] id; wire [15:0] is;
    wire [1:0] ic; wire io; wire [31:0] ie; reg imv; reg [127:0] imd;
    wire o1v, o2v; reg o1r, o2r;
    wire [31:0] o1a, o1d, o2a, o2d; wire [3:0] o1be, o2be;
    wire o1l, o2l, d1, d2, done, err; wire [7:0] ec;
    wire [31:0] cyc, d1dw, d1pw, d1out, d2dw, d2pw, d2out; wire atomic_swap;

    assign cr = !cfg_pending && !cmv && cfg_allow;
    assign ir = !in_pending && input_allow;
    assign o1r = output_allow;
    assign o2r = output_allow;

    always @(posedge clk) begin
        if (!rst_n) begin
            cmv <= 0; cmd <= 0; cfg_pending <= 0; cfg_pending_data <= 0;
            imv <= 0; imd <= 0; in_pending <= 0; in_pending_addr <= 0;
            cfg_lfsr <= 32'h13579bdf;
            input_lfsr <= 32'h2468ace1;
            output_lfsr <= 32'h9e3779b9;
        end else begin
            cfg_lfsr <= {cfg_lfsr[30:0], cfg_lfsr[31]^cfg_lfsr[21]^cfg_lfsr[1]^cfg_lfsr[0]};
            input_lfsr <= {input_lfsr[30:0], input_lfsr[31]^input_lfsr[21]^input_lfsr[1]^input_lfsr[0]};
            output_lfsr <= {output_lfsr[30:0], output_lfsr[31]^output_lfsr[21]^output_lfsr[1]^output_lfsr[0]};
            cmv <= 0; imv <= 0;
            if (cfg_pending) begin
                cmv <= 1; cmd <= cfg_pending_data; cfg_pending <= 0;
            end else if (cv && cr) begin
                cfg_seen = cfg_seen + 1;
                cfg_pending <= 1;
                cfg_pending_data <= cfg[(cl == 1) ? ci : (308 + ci)];
            end
            if (in_pending) begin
                imv <= 1;
                for (j = 0; j < 16; j = j + 1)
                    imd[j*8 +: 8] <= in_bytes[in_pending_addr+j];
                in_pending <= 0;
            end else if (iv && ir) begin
                in_pending <= 1;
                in_pending_addr <= ia;
            end
        end
    end

    always @(posedge clk) if (rst_n) begin
        if (o1v && o1r) begin
            out1_seen = out1_seen + 1;
            for (j = 0; j < 4; j = j + 1)
                if (o1d[j*8 +: 8] !== exp1[(o1a-32'h00100000)/4*4+j])
                    mismatches = mismatches + 1;
        end
        if (o2v && o2r) begin
            out2_seen = out2_seen + 1;
            for (j = 0; j < 4; j = j + 1)
                if (o2d[j*8 +: 8] !== exp2[(o2a-32'h00200000)/4*4+j])
                    mismatches = mismatches + 1;
        end
    end

    ds12_shared_pw_two_layer_top dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .cfg_mem_req_valid(cv), .cfg_mem_req_ready(cr), .cfg_mem_req_addr(ca),
        .cfg_mem_req_index(ci), .cfg_mem_req_layer(cl), .cfg_mem_req_strb(cs),
        .cfg_mem_resp_valid(cmv), .cfg_mem_resp_ready(), .cfg_mem_resp_data(cmd),
        .input_mem_req_valid(iv), .input_mem_req_ready(ir), .input_mem_req_write(iw),
        .input_mem_req_addr(ia), .input_mem_req_wdata(id), .input_mem_req_strb(is),
        .input_mem_req_context(ic), .input_mem_req_owner(io), .input_mem_req_epoch(ie),
        .input_mem_resp_valid(imv), .input_mem_resp_data(imd),
        .ds1_output_valid(o1v), .ds1_output_ready(o1r), .ds1_output_addr(o1a),
        .ds1_output_data(o1d), .ds1_output_be(o1be), .ds1_output_last(o1l),
        .ds2_output_valid(o2v), .ds2_output_ready(o2r), .ds2_output_addr(o2a),
        .ds2_output_data(o2d), .ds2_output_be(o2be), .ds2_output_last(o2l),
        .ds1_done(d1), .ds2_done(d2), .done(done), .error(err), .error_code(ec),
        .cycle_count(cyc), .ds1_dw_mac_count(d1dw), .ds1_pw_mac_count(d1pw),
        .ds1_output_word_count(d1out), .ds2_dw_mac_count(d2dw),
        .ds2_pw_mac_count(d2pw), .ds2_output_word_count(d2out), .atomic_swap(atomic_swap)
    );

    always @(posedge clk) if (rst_n && dut.scheduler.state != prev_sched_state) begin
        $display("STATE cycle=%0d sched=%0d service=%0d d1=%0d d2=%0d out1=%0d out2=%0d", wait_cycles,
                 dut.scheduler.state, dut.service.state, dut.ds1_adapter.state,
                 dut.ds2_adapter.state, out1_seen, out2_seen);
        prev_sched_state = dut.scheduler.state;
    end

    initial begin
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_input_i8.hex", in_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_output_i8.hex", exp1);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds2_output_i8.hex", exp2);
        fd = $fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex", "r");
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%d %d %d %h %h %h\n", ly, kd, idx, address, mask, dataw);
            if (rc == 6 && ly == 1) cfg[idx] = dataw;
            else if (rc == 6 && ly == 2) cfg[308+idx] = dataw;
        end
        $fclose(fd);
        cfg_seen = 0; out1_seen = 0; out2_seen = 0; mismatches = 0;
        prev_sched_state = -1;
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        wait_cycles = 0;
        while (!done && wait_cycles < 100000) begin
            @(posedge clk); wait_cycles = wait_cycles + 1;
        end
        $display("SHARED_PW_%s start_to_done=%0d cfg=%0d out1=%0d out2=%0d dw=%0d/%0d pw=%0d/%0d mismatches=%0d errors=%b ec=%h state=%0d svc_state=%0d d1state=%0d d2state=%0d",
                 (done && !err && mismatches == 0 && out1_seen == 8192 && out2_seen == 4096) ? "PASS" : "FAIL",
                 wait_cycles, cfg_seen, out1_seen, out2_seen, d1dw, d2dw, d1pw, d2pw, mismatches, err, ec,
                 dut.scheduler.state, dut.service.state, dut.ds1_adapter.state, dut.ds2_adapter.state);
        if (!done || err || mismatches != 0 || out1_seen != 8192 || out2_seen != 4096 ||
            d1pw != 32'd524288 || d2pw != 32'd524288 || d1dw != 32'd147456 || d2dw != 32'd73728)
            $fatal(1, "shared PW exact check failed");
        $finish;
    end
endmodule
`default_nettype wire
