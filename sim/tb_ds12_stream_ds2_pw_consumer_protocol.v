`timescale 1ns/1ps
`default_nettype none

// Focused DS2 PW ingress protocol test.  The configuration stream is supplied
// locally with zero coefficients because this test stops before a context is
// complete; it targets only the context ledger and its error/duplicate fence.
module tb_ds12_stream_ds2_pw_consumer_protocol;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg start;
    wire ready;
    wire cfg_rd_en;
    wire cfg_rd_bank;
    wire [15:0] cfg_rd_addr;
    reg cfg_rd_valid_r;
    wire [31:0] cfg_rd_data = 32'd0;
    reg cfg_active_valid = 1'b1;
    reg [1:0] cfg_active_layer = 2'd2;
    reg cfg_active_bank = 1'b0;
    reg [31:0] cfg_active_epoch = 32'd1;
    wire [15:0] config_index;
    wire [31:0] config_payload;

    reg dw_valid;
    wire dw_ready;
    reg [127:0] dw_data;
    reg [5:0] dw_row;
    reg [7:0] dw_pixel;
    reg dw_group;
    reg [1:0] dw_context;
    reg dw_owner;
    reg [31:0] dw_epoch;
    reg dw_last;

    wire sink_valid;
    reg sink_ready = 1'b0;
    wire [31:0] sink_addr, sink_data;
    wire [3:0] sink_strb;
    wire [5:0] sink_row;
    wire [7:0] sink_pixel;
    wire [3:0] sink_word_in_pixel;
    wire [1:0] sink_context;
    wire sink_owner;
    wire [31:0] sink_epoch;
    wire sink_last;
    wire busy, done, error;
    wire [7:0] error_code;
    wire [31:0] cfg_read_count, cfg_weight_read_count;
    wire [31:0] dw_vector_count, pw_token_count, pw_mac_count;
    wire [31:0] output_word_count;
    wire [3:0] partial_context_peak;

    // The DUT advances from CFG_ISSUE to CFG_WAIT before consuming a read.
    // Delay the response one clock so cfg_rd_valid is asserted in CFG_WAIT.
    always @(posedge clk) begin
        if (!rst_n)
            cfg_rd_valid_r <= 1'b0;
        else
            cfg_rd_valid_r <= cfg_rd_en;
    end

    ds12_stream_ds2_pw_consumer dut (
        .clk(clk), .rst_n(rst_n), .start(start), .ready(ready),
        .cfg_rd_en(cfg_rd_en), .cfg_rd_bank(cfg_rd_bank),
        .cfg_rd_addr(cfg_rd_addr), .cfg_rd_data(cfg_rd_data),
        .cfg_rd_valid(cfg_rd_valid_r), .cfg_active_valid(cfg_active_valid),
        .cfg_active_layer(cfg_active_layer), .cfg_active_bank(cfg_active_bank),
        .cfg_active_epoch(cfg_active_epoch), .config_index(config_index),
        .config_payload(config_payload),
        .dw_valid(dw_valid), .dw_ready(dw_ready), .dw_data(dw_data),
        .dw_row(dw_row), .dw_pixel(dw_pixel), .dw_group(dw_group),
        .dw_context(dw_context), .dw_owner(dw_owner), .dw_epoch(dw_epoch),
        .dw_last(dw_last),
        .sink_valid(sink_valid), .sink_ready(sink_ready),
        .sink_addr(sink_addr), .sink_data(sink_data), .sink_strb(sink_strb),
        .sink_row(sink_row), .sink_pixel(sink_pixel),
        .sink_word_in_pixel(sink_word_in_pixel), .sink_context(sink_context),
        .sink_owner(sink_owner), .sink_epoch(sink_epoch), .sink_last(sink_last),
        .busy(busy), .done(done), .error(error), .error_code(error_code),
        .cfg_read_count(cfg_read_count),
        .cfg_weight_read_count(cfg_weight_read_count),
        .dw_vector_count(dw_vector_count), .pw_token_count(pw_token_count),
        .pw_mac_count(pw_mac_count), .output_word_count(output_word_count),
        .partial_context_peak(partial_context_peak)
    );

    // phase 0: accept the first slice;
    // phase 1: present that same slice once more (must be ignored);
    // phase 2: present a new slice with a mismatched context/epoch (must be
    // rejected and report 8'h04);
    // phase 3: present the same slice with the correct tag (must be accepted).
    integer phase;
    integer cycles;
    integer errors;
    reg load_start_sent;
    reg run_start_sent;

    always @* begin
        start = 1'b0;
        if (!load_start_sent && ready)
            start = 1'b1;
        else if (load_start_sent && !run_start_sent &&
                 (cfg_read_count == 32'd704) && ready)
            start = 1'b1;

        dw_valid = 1'b0;
        dw_data = 128'd0;
        dw_row = 6'd0;
        dw_pixel = 8'd0;
        dw_group = 1'b0;
        dw_context = 2'd0;
        dw_owner = 1'b0;
        dw_epoch = 32'd1;
        dw_last = 1'b0;
        if ((dut.state == 3'd3) && (phase <= 3)) begin
            dw_valid = 1'b1;
            if (phase >= 2) begin
                dw_pixel = 8'd1;
                if (phase == 2) begin
                    dw_context = 2'd3;
                    dw_epoch = 32'hdead_beef;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            load_start_sent <= 1'b0;
            run_start_sent <= 1'b0;
            phase <= 0;
            cycles <= 0;
            errors <= 0;
        end else begin
            cycles <= cycles + 1;

            if (!load_start_sent && ready)
                load_start_sent <= 1'b1;
            if (load_start_sent && !run_start_sent &&
                (cfg_read_count == 32'd704) && ready)
                run_start_sent <= 1'b1;

            if (dut.state == 3'd3) begin
                case (phase)
                    0: begin
                        if (dw_valid && dw_ready)
                            phase <= 1;
                    end
                    1: begin
                        if (!dw_valid || dw_ready || (dw_vector_count != 32'd1)) begin
                            $display("duplicate protocol failure ready=%0d count=%0d", dw_ready, dw_vector_count);
                            errors <= errors + 1;
                        end
                        phase <= 2;
                    end
                    2: begin
                        if (!dw_valid || dw_ready) begin
                            $display("mismatched tag protocol failure ready=%0d", dw_ready);
                            errors <= errors + 1;
                        end
                        phase <= 3;
                    end
                    3: begin
                        if (dw_valid && dw_ready)
                            phase <= 4;
                    end
                    4: begin
                        // The phase-3 handshake and sticky error update are
                        // visible here after their nonblocking assignments.
                        if ((dw_vector_count == 32'd2) && error &&
                            ((error_code & 8'h04) != 8'd0)) begin
                            $display("DS12_DS2_PW_PROTOCOL_PASS duplicate_ignored=1 mismatched_tag_epoch_rejected=1 cfg_reads=%0d dw_vectors=%0d error_code=%02h", cfg_read_count, dw_vector_count, error_code);
                            $finish(0);
                        end
                    end
                    default: begin end
                endcase
            end

            if (cycles > 5000) begin
                $display("DS12_DS2_PW_PROTOCOL_FAIL timeout state=%0d cfg=%0d phase=%0d ready=%0d dw_ready=%0d dw_vectors=%0d error=%0d code=%02h errors=%0d", dut.state, cfg_read_count, phase, ready, dw_ready, dw_vector_count, error, error_code, errors);
                $fatal(2, "DS2 PW protocol test timeout");
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end
endmodule
`default_nettype wire
