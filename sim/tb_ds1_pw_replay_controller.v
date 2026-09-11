`timescale 1ns/1ps
`default_nettype none

/*
 * Focused retained-bank controller regression.
 *
 * The scratch bank below is an external handshake model, not an
 * implementation detail of the controller.  It presents one committed
 * descriptor, applies randomized acquire/read ready, returns one registered
 * 8-pixel response per accepted read, and checks the final release.  The
 * controller's result ready is independently randomized to exercise output
 * hold behavior.
 */
module tb_ds1_pw_replay_controller;
    reg clk;
    reg rst_n;

    reg start_valid;
    wire start_ready;
    reg start_bank;
    reg [3:0] start_epoch;
    reg [7:0] start_tile;
    reg [5:0] start_row0_pixel_base;
    reg [5:0] start_row1_pixel_base;

    wire pw_acquire_valid;
    reg pw_acquire_ready;
    wire pw_acquire_bank;
    wire [3:0] pw_acquire_epoch;
    wire [7:0] pw_acquire_tile;

    wire pw_read_valid;
    reg pw_read_ready;
    wire [6:0] pw_read_channel_idx;
    wire [5:0] pw_read_pixel_base;

    reg pw_out_valid;
    wire pw_out_ready;
    reg [63:0] pw_out_data;
    reg [7:0] pw_out_lane_mask;

    wire weight_valid;
    wire [3:0] weight_k_index;
    wire [1:0] weight_cout_group;
    reg signed [63:0] weight_vec;

    wire out_valid;
    reg out_ready;
    wire out_row_idx;
    wire [1:0] out_cout_group;
    wire signed [2047:0] out_psum;

    wire pw_release_valid;
    reg pw_release_ready;
    wire pw_release_bank;
    wire [3:0] pw_release_epoch;
    wire [7:0] pw_release_tile;
    wire busy;
    wire done;

    reg [1:0] bank_owner;       /* 0 free, 1 committed, 2 PW-owned */
    reg read_pending;
    reg [3:0] pending_k;
    reg [5:0] pending_base;
    reg [15:0] accepted_reads;
    reg [15:0] response_count;
    reg [3:0] acquire_count;
    reg [3:0] release_count;
    reg [3:0] output_count;
    integer read_stall_count;
    integer output_stall_count;
    reg [31:0] lfsr;
    integer errors;
    integer cycles;
    integer i;
    integer lane;
    integer job;
    integer p;
    integer c;
    integer expected_value;
    integer actual_value;
    integer hold_job;
    reg hold_active;
    reg hold_row;
    reg [1:0] hold_group;
    reg signed [2047:0] hold_psum;

    ds1_pw_replay_controller dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_bank(start_bank), .start_epoch(start_epoch),
        .start_tile(start_tile),
        .start_row0_pixel_base(start_row0_pixel_base),
        .start_row1_pixel_base(start_row1_pixel_base),
        .pw_acquire_valid(pw_acquire_valid),
        .pw_acquire_ready(pw_acquire_ready),
        .pw_acquire_bank(pw_acquire_bank),
        .pw_acquire_epoch(pw_acquire_epoch),
        .pw_acquire_tile(pw_acquire_tile),
        .pw_read_valid(pw_read_valid), .pw_read_ready(pw_read_ready),
        .pw_read_channel_idx(pw_read_channel_idx),
        .pw_read_pixel_base(pw_read_pixel_base),
        .pw_out_valid(pw_out_valid), .pw_out_ready(pw_out_ready),
        .pw_out_data(pw_out_data), .pw_out_lane_mask(pw_out_lane_mask),
        .weight_valid(weight_valid), .weight_k_index(weight_k_index),
        .weight_cout_group(weight_cout_group), .weight_vec(weight_vec),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_row_idx(out_row_idx), .out_cout_group(out_cout_group),
        .out_psum(out_psum),
        .pw_release_valid(pw_release_valid),
        .pw_release_ready(pw_release_ready),
        .pw_release_bank(pw_release_bank),
        .pw_release_epoch(pw_release_epoch),
        .pw_release_tile(pw_release_tile),
        .busy(busy), .done(done)
    );

    always #5 clk = ~clk;

    function integer activation_value;
        input integer row;
        input integer pixel;
        input integer k;
        begin
            /* Small signed values keep all sums comfortably inside 32 bits. */
            activation_value = (((row * 5) + (pixel * 3) + (k * 2) + 1) % 13) - 6;
        end
    endfunction

    function integer weight_value;
        input integer group;
        input integer k;
        input integer cout;
        begin
            weight_value = (((group * 7) + (k * 3) + (cout * 2) + 2) % 9) - 4;
        end
    endfunction

    /* Weight lookup is intentionally external/combinational.  The DUT
     * samples this vector only with pw_read_valid && pw_read_ready. */
    always @* begin
        weight_vec = 64'sd0;
        for (lane = 0; lane < 8; lane = lane + 1)
            weight_vec[(lane*8) +: 8] = weight_value(weight_cout_group,
                                                     weight_k_index, lane);
    end

    /* Randomized ready signals are stable for each clock period.  The LFSR
     * advances only on a clock edge, so it cannot make a held valid payload
     * appear to change mid-transaction. */
    always @* begin
        pw_acquire_ready = (bank_owner == 2'd1) && (lfsr[1:0] != 2'b00);
        pw_read_ready = (bank_owner == 2'd2) && !read_pending &&
                        (!pw_out_valid || pw_out_ready) &&
                        (lfsr[4:2] != 3'b000);
        pw_release_ready = (bank_owner == 2'd2) && !read_pending &&
                           !pw_out_valid && (lfsr[7:5] != 3'b000);
        out_ready = (lfsr[10:8] != 3'b000);
    end

    wire acquire_fire = pw_acquire_valid && pw_acquire_ready;
    wire read_fire = pw_read_valid && pw_read_ready;
    wire response_fire = pw_out_valid && pw_out_ready;
    wire output_fire = out_valid && out_ready;
    wire release_fire = pw_release_valid && pw_release_ready;

    /* External committed-bank response model.  It has exactly one
     * outstanding registered response, matching the tagless bank ABI. */
    always @(posedge clk) begin
        if (!rst_n) begin
            bank_owner <= 2'd1; /* The test starts with a committed bank. */
            read_pending <= 1'b0;
            pending_k <= 4'd0;
            pending_base <= 6'd0;
            pw_out_valid <= 1'b0;
            pw_out_data <= 64'd0;
            pw_out_lane_mask <= 8'd0;
            accepted_reads <= 0;
            response_count <= 0;
            acquire_count <= 0;
            release_count <= 0;
        end else begin
            if (acquire_fire) begin
                if (bank_owner != 2'd1 || pw_acquire_bank !== start_bank ||
                    pw_acquire_epoch !== start_epoch ||
                    pw_acquire_tile !== start_tile)
                    errors = errors + 1;
                bank_owner <= 2'd2;
                acquire_count <= acquire_count + 1'b1;
            end

            if (pw_out_valid && pw_out_ready)
                pw_out_valid <= 1'b0;

            if (read_fire) begin
                if (read_pending || pw_read_channel_idx > 7'd15 ||
                    (pw_read_pixel_base !== 6'd0 &&
                     pw_read_pixel_base !== 6'd8))
                    errors = errors + 1;
                read_pending <= 1'b1;
                pending_k <= pw_read_channel_idx[3:0];
                pending_base <= pw_read_pixel_base;
                accepted_reads <= accepted_reads + 1'b1;
            end

            if (read_pending) begin
                pw_out_valid <= 1'b1;
                pw_out_lane_mask <= 8'hff;
                for (i = 0; i < 8; i = i + 1)
                    pw_out_data[(i*8) +: 8] <=
                        activation_value(pending_base[5:3],
                                          pending_base + i, pending_k);
                read_pending <= 1'b0;
                response_count <= response_count + 1'b1;
            end

            if (release_fire) begin
                if (bank_owner != 2'd2 || acquire_count != 1 ||
                    accepted_reads != 128 || response_count != 128 ||
                    pw_release_bank !== start_bank ||
                    pw_release_epoch !== start_epoch ||
                    pw_release_tile !== start_tile)
                    errors = errors + 1;
                bank_owner <= 2'd0;
                release_count <= release_count + 1'b1;
            end

            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^
                    lfsr[1] ^ lfsr[0]};

            if (pw_read_valid && !pw_read_ready)
                read_stall_count = read_stall_count + 1;
        end
    end

    /* Check output stability under randomized output backpressure and check
     * every row/group tag and all 64 signed psum lanes. */
    always @(posedge clk) begin
        if (!rst_n) begin
            hold_active <= 1'b0;
        end else begin
            if (hold_active) begin
                if (!out_valid || out_row_idx !== hold_row ||
                    out_cout_group !== hold_group || out_psum !== hold_psum)
                    errors = errors + 1;
            end
            if (out_valid && !out_ready) begin
                output_stall_count = output_stall_count + 1;
                hold_active <= 1'b1;
                hold_row <= out_row_idx;
                hold_group <= out_cout_group;
                hold_psum <= out_psum;
            end else begin
                hold_active <= 1'b0;
            end

            if (output_fire) begin
                job = output_count;
                if (out_row_idx !== (job / 4) ||
                    out_cout_group !== (job % 4))
                    errors = errors + 1;
                for (p = 0; p < 8; p = p + 1) begin
                    for (c = 0; c < 8; c = c + 1) begin
                        /* The activation function's pixel argument is the
                         * local 0..15 position in the two-row microgroup. */
                        expected_value = 0;
                        for (i = 0; i < 16; i = i + 1)
                            expected_value = expected_value +
                                activation_value(job / 4, (job / 4) * 8 + p, i) *
                                weight_value(job % 4, i, c);
                        actual_value = $signed(out_psum[((p*8+c)*32) +: 32]);
                        if (actual_value !== expected_value)
                            errors = errors + 1;
                    end
                end
                output_count <= output_count + 1'b1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start_valid = 1'b0;
        start_bank = 1'b1;
        start_epoch = 4'h9;
        start_tile = 8'h35;
        start_row0_pixel_base = 6'd0;
        start_row1_pixel_base = 6'd8;
        lfsr = 32'h1ace_b00c;
        errors = 0;
        cycles = 0;
        output_count = 0;
        read_stall_count = 0;
        output_stall_count = 0;
        hold_active = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        /* Descriptor is held until the controller accepts it. */
        @(negedge clk);
        start_valid = 1'b1;
        while (!start_ready)
            @(posedge clk);
        @(negedge clk);
        start_valid = 1'b0;

        while (!done && cycles < 200000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (!done) begin
            $display("FAIL tb_ds1_pw_replay_controller timeout state=%0d reads=%0d responses=%0d outputs=%0d acquire=%0d release=%0d errors=%0d",
                     dut.state, accepted_reads, response_count, output_count,
                     acquire_count, release_count, errors);
            $fatal;
        end
        if (acquire_count !== 1 || release_count !== 1 ||
            accepted_reads !== 128 || response_count !== 128 ||
            output_count !== 8 || errors != 0 ||
            read_stall_count == 0 || output_stall_count == 0 ||
            dut.sim_protocol_errors != 0) begin
            $display("FAIL tb_ds1_pw_replay_controller reads=%0d responses=%0d outputs=%0d acquire=%0d release=%0d read_stalls=%0d output_stalls=%0d errors=%0d dut_errors=%0d cycles=%0d",
                     accepted_reads, response_count, output_count,
                     acquire_count, release_count, read_stall_count,
                     output_stall_count, errors,
                     dut.sim_protocol_errors, cycles);
            $fatal;
        end
        $display("PASS tb_ds1_pw_replay_controller cycles=%0d reads=%0d responses=%0d outputs=%0d acquire=%0d release=%0d read_stalls=%0d output_stalls=%0d",
                 cycles, accepted_reads, response_count, output_count,
                 acquire_count, release_count, read_stall_count,
                 output_stall_count);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL tb_ds1_pw_replay_controller wall_timeout");
        $fatal;
    end
endmodule

`default_nettype wire
