`timescale 1ns/1ps
`default_nettype none

/*
 * Randomized scalar-reference regression for ds1_final_requant_write's
 * four-byte commit interface.
 * The eight reference lanes are independent requant_activation_unit
 * instances, so every checked byte uses the production scalar arithmetic
 * rather than a testbench reimplementation of the fixed-point formula.
 */
module tb_ds1_final_requant_write;
    localparam integer BLOCKS = 24;
    localparam integer LANES = 8;

    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg signed [2047:0] psum_in;
    reg [9:0] pixel_base;
    reg [5:0] cout_base;
    reg signed [255:0] bias_vec;
    reg signed [255:0] multiplier_vec;
    reg [47:0] shift_vec;
    reg signed [31:0] output_zero_point_int32;
    reg signed [31:0] activation_min_int32;
    reg signed [31:0] activation_max_int32;
    wire valid_out_vec4;
    reg ready_out_vec4;
    wire signed [31:0] out_data_int8_vec4;
    wire [9:0] out_pixel_idx_vec4;
    wire [5:0] out_channel_idx_vec4;
    wire [15:0] out_byte_addr_vec4;
    wire [15:0] out_word_addr_vec4;
    wire [3:0] out_byte_en_vec4;
    wire busy;

    ds1_final_requant_write dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .psum_in(psum_in), .pixel_base(pixel_base), .cout_base(cout_base),
        .bias_vec(bias_vec), .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32),
        .valid_out_vec4(valid_out_vec4), .ready_out_vec4(ready_out_vec4),
        .out_data_int8_vec4(out_data_int8_vec4),
        .out_pixel_idx_vec4(out_pixel_idx_vec4),
        .out_channel_idx_vec4(out_channel_idx_vec4),
        .out_byte_addr_vec4(out_byte_addr_vec4),
        .out_word_addr_vec4(out_word_addr_vec4),
        .out_byte_en_vec4(out_byte_en_vec4),
        .busy(busy)
    );

    /* Independent scalar reference lanes. */
    reg ref_active;
    reg ref_issue_done;
    reg [2:0] ref_issue_pixel;
    reg signed [2047:0] ref_psum;
    reg [9:0] ref_pixel_base;
    reg [5:0] ref_cout_base;
    reg signed [255:0] ref_bias;
    reg signed [255:0] ref_multiplier;
    reg [47:0] ref_shift;
    reg signed [31:0] ref_zp;
    reg signed [31:0] ref_min;
    reg signed [31:0] ref_max;
    wire [LANES-1:0] ref_ready_in;
    wire [LANES-1:0] ref_valid_out;
    wire signed [7:0] ref_data [0:LANES-1];
    wire ref_valid_in = ref_active && !ref_issue_done;
    wire ref_issue_fire = ref_valid_in && (&ref_ready_in);
    wire [6:0] ref_pending;
    reg [6:0] ref_pending_reg;
    wire [6:0] ref_pending_next = {1'b0, ref_pending_reg} +
                                  (ref_issue_fire ? 7'd8 : 7'd0) -
                                  ((|ref_valid_out) ? 7'd1 : 7'd0);
    assign ref_pending = ref_pending_reg;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : gen_ref
            localparam integer LANE = g;
            wire signed [31:0] ref_acc =
                ref_psum[(((ref_issue_pixel * LANES) + LANE) * 32) +: 32];
            wire signed [31:0] ref_bias_lane = ref_bias[(LANE * 32) +: 32];
            wire signed [31:0] ref_multiplier_lane =
                ref_multiplier[(LANE * 32) +: 32];
            wire [5:0] ref_shift_lane = ref_shift[(LANE * 6) +: 6];
            requant_activation_unit u_ref (
                .clk(clk), .rst_n(rst_n), .valid_in(ref_valid_in),
                .ready_in(ref_ready_in[g]), .acc_int32(ref_acc),
                .bias_int32(ref_bias_lane),
                .multiplier_int32(ref_multiplier_lane),
                .shift(ref_shift_lane), .output_zero_point_int32(ref_zp),
                .activation_min_int32(ref_min), .activation_max_int32(ref_max),
                .ready_out(1'b1), .valid_out(ref_valid_out[g]),
                .output_int8(ref_data[g])
            );
        end
    endgenerate

    /* Reference values are collected by pixel/lane, then the DUT is checked
     * in its required pixel-major drain order. */
    reg signed [7:0] expected_data [0:7][0:7];
    reg expected_seen [0:7][0:7];
    reg [2:0] ref_out_pixel [0:7];

    reg [31:0] lfsr;
    integer errors;
    integer cycles;
    integer out_count;
    integer stall_count;
    integer block_count;
    integer i;
    integer p;
    integer lane;
    integer signed tmp;
    integer signed seed;
    integer expected_byte_addr;
    integer expected_pixel;
    integer expected_lane;
    reg hold_active;
    reg signed [31:0] hold_data;
    reg [9:0] hold_pixel;
    reg [5:0] hold_channel;
    reg [15:0] hold_addr;
    reg [15:0] hold_word_addr;
    reg [3:0] hold_byte_en;

    always #5 clk = ~clk;

    /* A deterministic pseudo-random source makes the test reproducible while
     * still creating long and short backpressure runs. */
    always @* begin
        ready_out_vec4 = lfsr[0] | lfsr[3];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 32'h1ace_b00c;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^
                    lfsr[1] ^ lfsr[0]};
            if (valid_out_vec4 && !ready_out_vec4)
                stall_count = stall_count + 1;
        end
    end

    /* Scalar reference lifecycle and capture. */
    always @(posedge clk) begin
        if (!rst_n) begin
            ref_active <= 1'b0;
            ref_issue_done <= 1'b0;
            ref_issue_pixel <= 3'd0;
            ref_psum <= 2048'sd0;
            ref_pixel_base <= 10'd0;
            ref_cout_base <= 6'd0;
            ref_bias <= 256'sd0;
            ref_multiplier <= 256'sd0;
            ref_shift <= 48'd0;
            ref_zp <= 32'sd0;
            ref_min <= -32'sd128;
            ref_max <= 32'sd127;
            ref_pending_reg <= 7'd0;
            for (i = 0; i < LANES; i = i + 1)
                ref_out_pixel[i] <= 3'd0;
            for (p = 0; p < 8; p = p + 1)
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    expected_data[p][lane] <= 8'sd0;
                    expected_seen[p][lane] <= 1'b0;
                end
        end else begin
            for (i = 0; i < LANES; i = i + 1) begin
                if (ref_valid_out[i]) begin
                    expected_data[ref_out_pixel[i]][i] <= ref_data[i];
                    expected_seen[ref_out_pixel[i]][i] <= 1'b1;
                    ref_out_pixel[i] <= ref_out_pixel[i] + 3'd1;
                end
            end
            if (valid_in && ready_in) begin
                ref_active <= 1'b1;
                ref_issue_done <= 1'b0;
                ref_issue_pixel <= 3'd0;
                ref_psum <= psum_in;
                ref_pixel_base <= pixel_base;
                ref_cout_base <= cout_base;
                ref_bias <= bias_vec;
                ref_multiplier <= multiplier_vec;
                ref_shift <= shift_vec;
                ref_zp <= output_zero_point_int32;
                ref_min <= activation_min_int32;
                ref_max <= activation_max_int32;
                ref_pending_reg <= 7'd0;
                for (i = 0; i < LANES; i = i + 1)
                    ref_out_pixel[i] <= 3'd0;
                for (p = 0; p < 8; p = p + 1)
                    for (lane = 0; lane < 8; lane = lane + 1)
                        expected_seen[p][lane] <= 1'b0;
            end else begin
                case ({ref_issue_fire, |ref_valid_out})
                    2'b10: ref_pending_reg <= ref_pending_reg + 7'd8;
                    2'b01: ref_pending_reg <= ref_pending_reg - 7'd1;
                    2'b11: ref_pending_reg <= ref_pending_reg + 7'd7;
                    default: ref_pending_reg <= ref_pending_reg;
                endcase
                if (ref_issue_fire) begin
                    if (ref_issue_pixel == 3'd7)
                        ref_issue_done <= 1'b1;
                    else
                        ref_issue_pixel <= ref_issue_pixel + 3'd1;
                end
                if (ref_active && ref_issue_done &&
                    (ref_pending_next == 7'd0))
                    ref_active <= 1'b0;
            end
        end
    end

    /* DUT output checking and elastic output stability. */
    always @(posedge clk) begin
        if (!rst_n) begin
            errors = 0;
            cycles = 0;
            out_count = 0;
            stall_count = 0;
            hold_active <= 1'b0;
        end else begin
            cycles = cycles + 1;
            if (hold_active) begin
                if (!valid_out_vec4 || out_data_int8_vec4 !== hold_data ||
                    out_pixel_idx_vec4 !== hold_pixel ||
                    out_channel_idx_vec4 !== hold_channel ||
                    out_byte_addr_vec4 !== hold_addr ||
                    out_word_addr_vec4 !== hold_word_addr ||
                    out_byte_en_vec4 !== hold_byte_en) begin
                    $display("DS1_RQ_ASSERT output_changed_under_stall t=%0d",
                             cycles);
                    errors = errors + 1;
                end
            end
            if (valid_out_vec4 && !ready_out_vec4) begin
                hold_active <= 1'b1;
                hold_data <= out_data_int8_vec4;
                hold_pixel <= out_pixel_idx_vec4;
                hold_channel <= out_channel_idx_vec4;
                hold_addr <= out_byte_addr_vec4;
                hold_word_addr <= out_word_addr_vec4;
                hold_byte_en <= out_byte_en_vec4;
            end else begin
                hold_active <= 1'b0;
            end

            if (valid_out_vec4 && ready_out_vec4) begin
                expected_pixel = out_pixel_idx_vec4 - ref_pixel_base;
                expected_lane = out_channel_idx_vec4 - ref_cout_base;
                expected_byte_addr = (out_pixel_idx_vec4 * 32) +
                                     out_channel_idx_vec4;
                if (expected_pixel < 0 || expected_pixel >= 8 ||
                    expected_lane < 0 || expected_lane > 4 ||
                    out_channel_idx_vec4[1:0] != 2'b00 ||
                    out_byte_addr_vec4 !== expected_byte_addr[15:0] ||
                    out_word_addr_vec4 !== (expected_byte_addr / 4) ||
                    out_byte_en_vec4 !== 4'b1111) begin
                    $display("DS1_RQ_ASSERT bad_tag pixel=%0d channel=%0d",
                             out_pixel_idx_vec4, out_channel_idx_vec4);
                    errors = errors + 1;
                end else begin
                    if (out_pixel_idx_vec4 !==
                        (ref_pixel_base + expected_pixel[9:0]) ||
                        out_channel_idx_vec4 !==
                        (ref_cout_base + expected_lane[5:0]))
                        errors = errors + 1;
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        if (!expected_seen[expected_pixel][expected_lane + lane]) begin
                            $display("DS1_RQ_ASSERT reference_not_ready p=%0d l=%0d",
                                     expected_pixel, expected_lane + lane);
                            errors = errors + 1;
                        end else if ($signed(out_data_int8_vec4[(lane*8) +: 8]) !==
                                     expected_data[expected_pixel][expected_lane + lane]) begin
                            $display("DS1_RQ_ASSERT data p=%0d l=%0d got=%0d exp=%0d",
                                 expected_pixel, expected_lane + lane,
                                 $signed(out_data_int8_vec4[(lane*8) +: 8]),
                                 expected_data[expected_pixel][expected_lane + lane]);
                            errors = errors + 1;
                        end
                    end
                end
                out_count = out_count + 1;
            end
        end
    end

    function integer signed rand_signed32;
        input integer signed x;
        begin
            rand_signed32 = x * 1103515245 + 12345;
        end
    endfunction

    /* Drive one held ready/valid block. */
    task automatic drive_block;
        input integer block_idx;
        integer q;
        integer signed rv;
        integer y;
        integer x;
        begin
            /* x=24 deliberately exercises the tail of every 32-pixel row;
             * y=31 and x=24 reaches the final global pixel 1023. */
            y = (block_idx * 7) % 32;
            x = ((block_idx * 11) % 4) * 8;
            if ((block_idx % 5) == 0) begin y = 31; x = 24; end
            pixel_base = y * 32 + x;
            cout_base = ((block_idx * 3) % 4) * 8;
            output_zero_point_int32 = ((block_idx % 5) == 0) ? -32'sd3 :
                                      ((block_idx * 17) % 23) - 11;
            case (block_idx % 4)
                0: begin activation_min_int32 = -32'sd128;
                   activation_max_int32 = 32'sd127; end
                1: begin activation_min_int32 = 32'sd0;
                   activation_max_int32 = 32'sd127; end
                2: begin activation_min_int32 = -32'sd128;
                   activation_max_int32 = 32'sd0; end
                default: begin activation_min_int32 = -32'sd17;
                         activation_max_int32 = 32'sd23; end
            endcase
            for (q = 0; q < 8; q = q + 1) begin
                rv = rand_signed32(block_idx * 97 + q * 13);
                bias_vec[(q*32) +: 32] = rv;
                rv = rand_signed32(block_idx * 193 + q * 29 + 5);
                multiplier_vec[(q*32) +: 32] = rv;
                shift_vec[q*6 +: 6] = (block_idx * 9 + q * 7) % 64;
            end
            for (q = 0; q < 64; q = q + 1) begin
                rv = rand_signed32(block_idx * 313 + q * 41 + 19);
                /* Add exact boundary values on several blocks. */
                if ((block_idx % 6) == 0 && q == 0) rv = 32'sh7fff_ffff;
                if ((block_idx % 6) == 1 && q == 7) rv = -32'sh8000_0000;
                psum_in[(q*32) +: 32] = rv;
            end
            valid_in = 1'b1;
            @(posedge clk);
            while (!ready_in) @(posedge clk);
            @(negedge clk);
            valid_in = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid_in = 1'b0;
        psum_in = 2048'sd0;
        pixel_base = 10'd0;
        cout_base = 6'd0;
        bias_vec = 256'sd0;
        multiplier_vec = 256'sd0;
        shift_vec = 48'd0;
        output_zero_point_int32 = 32'sd0;
        activation_min_int32 = -32'sd128;
        activation_max_int32 = 32'sd127;
        block_count = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        for (block_count = 0; block_count < BLOCKS; block_count = block_count + 1)
            drive_block(block_count);
        valid_in = 1'b0;
        /* Every reference lane is drained with ready_out=1.  The reference
         * bookkeeping intentionally need not mirror the DUT's serial
         * drain-count fence: all expected lane values are captured before
         * their corresponding DUT byte can be checked. */
        wait (!busy);
        repeat (30) @(posedge clk);
        if (out_count != BLOCKS * 16) begin
            $display("FAIL tb_ds1_final_requant_write outputs=%0d expected=%0d errors=%0d",
                     out_count, BLOCKS * 16, errors);
            $fatal(1);
        end else if (errors != 0 || stall_count == 0) begin
            $display("FAIL tb_ds1_final_requant_write outputs=%0d errors=%0d stalls=%0d",
                     out_count, errors, stall_count);
            $fatal(1);
        end else begin
            $display("PASS tb_ds1_final_requant_write blocks=%0d vec4_writes=%0d bytes=%0d stalls=%0d cycles=%0d",
                     BLOCKS, out_count, out_count * 4, stall_count, cycles);
            $finish;
        end
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "WATCHDOG tb_ds1_final_requant_write busy=%b ref_active=%b out_count=%0d block=%0d collected=%0d",
               busy, ref_active, out_count, block_count, dut.collected_count);
    end
endmodule

`default_nettype wire
