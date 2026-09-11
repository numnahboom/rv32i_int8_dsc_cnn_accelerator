`timescale 1ns/1ps
`default_nettype none

/*
 * Protocol/precision test for the two-credit local DW requant adapter.
 * It deliberately drives more than two bundles, randomizes both stream
 * directions, inserts a long output stall, and resets only at an idle fence
 * between two batches.  The combinational scalar reference is sampled at
 * each real input handshake, so the expected queue follows the DUT ABI.
 */
module tb_ds_dw_requant_stream4_write_adapter_local_decoupled;
    localparam integer BUNDLES = 24;
    localparam integer MID_BATCH = 8;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg valid_in = 1'b0;
    wire ready_in;
    reg [5:0] pixel_idx_in = 6'd0;
    reg [15:0] lane_mask_in = 16'd0;
    reg signed [511:0] raw_vec_in = 512'sd0;
    reg signed [511:0] multiplier_vec_in = 512'sd0;
    reg [95:0] shift_vec_in = 96'd0;
    reg signed [31:0] output_zero_point = 32'sd0;
    reg signed [31:0] activation_min = -128;
    reg signed [31:0] activation_max = 127;
    reg ready_out = 1'b0;
    wire valid_out;
    wire [5:0] pixel_idx_out;
    wire [1:0] lane_base_out;
    wire [31:0] data_out;
    wire [3:0] lane_mask_out;
    wire busy;

    ds_dw_requant_stream4_write_adapter_local dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .pixel_idx_in(pixel_idx_in), .lane_mask_in(lane_mask_in),
        .raw_vec_in(raw_vec_in), .multiplier_vec_in(multiplier_vec_in),
        .shift_vec_in(shift_vec_in), .output_zero_point(output_zero_point),
        .activation_min(activation_min), .activation_max(activation_max),
        .valid_out(valid_out), .ready_out(ready_out),
        .pixel_idx_out(pixel_idx_out), .lane_base_out(lane_base_out),
        .data_out(data_out), .lane_mask_out(lane_mask_out), .busy(busy)
    );

    wire signed [63:0] ref_product [0:15];
    wire signed [7:0] ref_data [0:15];
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : gen_ref
        assign ref_product[g] =
            $signed({{32{raw_vec_in[(g*32)+31]}}, raw_vec_in[(g*32) +: 32]}) *
            $signed({{32{multiplier_vec_in[(g*32)+31]}},
                     multiplier_vec_in[(g*32) +: 32]});
        requant_activation_core u_ref (
            .product_int64(ref_product[g]),
            .shift(shift_vec_in[(g*6) +: 6]),
            .output_zero_point_int32(output_zero_point),
            .activation_min_int32(activation_min),
            .activation_max_int32(activation_max),
            .output_int8(ref_data[g])
        );
    end endgenerate

    reg signed [511:0] raw_cases [0:BUNDLES-1];
    reg signed [511:0] mul_cases [0:BUNDLES-1];
    reg [95:0] shift_cases [0:BUNDLES-1];
    reg [15:0] mask_cases [0:BUNDLES-1];
    reg [5:0] pixel_cases [0:BUNDLES-1];
    reg signed [31:0] zp_cases [0:BUNDLES-1];
    reg signed [31:0] min_cases [0:BUNDLES-1];
    reg signed [31:0] max_cases [0:BUNDLES-1];

    reg [31:0] exp_data [0:BUNDLES*4-1];
    reg [5:0] exp_pixel [0:BUNDLES*4-1];
    reg [1:0] exp_base [0:BUNDLES*4-1];
    reg [3:0] exp_mask [0:BUNDLES*4-1];

    integer accepted_bundles;
    integer produced_beats;
    integer errors;
    integer cycles;
    integer simultaneous_fires;
    integer reset_count;
    integer seed;
    integer b;
    integer l;
    integer q;
    integer idle_cycles;
    reg held;
    reg [5:0] held_pixel;
    reg [1:0] held_base;
    reg [3:0] held_mask;
    reg [31:0] held_data;

    always @(posedge clk) begin
        if (!rst_n) begin
            cycles = 0;
            held = 1'b0;
        end else begin
            cycles = cycles + 1;
            if (valid_in && ready_in) begin
                for (q = 0; q < 4; q = q + 1) begin
                    exp_data[(accepted_bundles*4)+q] =
                        {ref_data[q*4+3], ref_data[q*4+2],
                         ref_data[q*4+1], ref_data[q*4+0]};
                    exp_pixel[(accepted_bundles*4)+q] = pixel_idx_in;
                    exp_base[(accepted_bundles*4)+q] = q[1:0];
                    exp_mask[(accepted_bundles*4)+q] = lane_mask_in[(q*4) +: 4];
                end
                accepted_bundles = accepted_bundles + 1;
            end
            if (valid_in && ready_in && valid_out && ready_out)
                simultaneous_fires = simultaneous_fires + 1;

            if (held) begin
                if (!valid_out || pixel_idx_out !== held_pixel ||
                    lane_base_out !== held_base || lane_mask_out !== held_mask ||
                    data_out !== held_data)
                    errors = errors + 1;
                if (ready_out)
                    held = 1'b0;
            end
            if (valid_out && !ready_out) begin
                held = 1'b1;
                held_pixel = pixel_idx_out;
                held_base = lane_base_out;
                held_mask = lane_mask_out;
                held_data = data_out;
            end
            if (valid_out && ready_out) begin
                if ((produced_beats >= (accepted_bundles*4)) ||
                    pixel_idx_out !== exp_pixel[produced_beats] ||
                    lane_base_out !== exp_base[produced_beats] ||
                    lane_mask_out !== exp_mask[produced_beats] ||
                    data_out !== exp_data[produced_beats]) begin
                    $display("DECOUPLED_MISMATCH n=%0d got pix=%0d base=%0d mask=%h data=%h exp pix=%0d base=%0d mask=%h data=%h",
                             produced_beats, pixel_idx_out, lane_base_out,
                             lane_mask_out, data_out,
                             exp_pixel[produced_beats], exp_base[produced_beats],
                             exp_mask[produced_beats], exp_data[produced_beats]);
                    errors = errors + 1;
                end
                produced_beats = produced_beats + 1;
            end
        end
    end

    /* Deterministic random output backpressure with a deliberately long
     * contiguous stall early in each run. */
    always @(negedge clk) begin
        if (!rst_n)
            ready_out <= 1'b0;
        else if ((cycles >= 30) && (cycles < 52))
            ready_out <= 1'b0;
        else begin
            seed = {seed[30:0], seed[31] ^ seed[21] ^ seed[1] ^ seed[0]};
            ready_out <= (seed[2:0] != 3'd0);
        end
    end

    task send_bundle;
        input integer bi;
        reg fired;
        begin
            @(negedge clk);
            valid_in = 1'b0;
            idle_cycles = (bi * 3) % 4;
            repeat (idle_cycles) @(negedge clk);
            raw_vec_in = raw_cases[bi];
            multiplier_vec_in = mul_cases[bi];
            shift_vec_in = shift_cases[bi];
            lane_mask_in = mask_cases[bi];
            pixel_idx_in = pixel_cases[bi];
            output_zero_point = zp_cases[bi];
            activation_min = min_cases[bi];
            activation_max = max_cases[bi];
            valid_in = 1'b1;
            fired = 1'b0;
            while (!fired) begin
                @(posedge clk);
                if (ready_in)
                    fired = 1'b1;
            end
            @(negedge clk);
            valid_in = 1'b0;
        end
    endtask

    initial begin
        errors = 0;
        accepted_bundles = 0;
        produced_beats = 0;
        simultaneous_fires = 0;
        reset_count = 0;
        cycles = 0;
        held = 1'b0;
        seed = 32'h2d5a_2026;

        for (b = 0; b < BUNDLES; b = b + 1) begin
            raw_cases[b] = 512'sd0;
            mul_cases[b] = 512'sd0;
            shift_cases[b] = 96'd0;
            mask_cases[b] = $urandom(seed);
            pixel_cases[b] = (b * 5 + 3) & 63;
            zp_cases[b] = (b * 17) - 160;
            min_cases[b] = -128 + (b % 31);
            max_cases[b] = min_cases[b] + 35 + (b % 47);
            if (max_cases[b] > 127) max_cases[b] = 127;
            for (l = 0; l < 16; l = l + 1) begin
                raw_cases[b][l*32 +: 32] = ($urandom(seed) % 4000001) - 2000000;
                mul_cases[b][l*32 +: 32] = ($urandom(seed) % 2000000001) - 1000000000;
                shift_cases[b][l*6 +: 6] = (b * 11 + l * 5) & 63;
            end
        end
        /* Include zeros, extremes, and a sparse mask in addition to random
         * values so tail/mask and signed rounding paths are exercised. */
        raw_cases[0] = 0; mul_cases[0] = 0; mask_cases[0] = 16'hffff;
        zp_cases[0] = 0; min_cases[0] = -128; max_cases[0] = 127;
        raw_cases[1][31:0] = 32'sh7fff_ffff;
        mul_cases[1][31:0] = 32'sh4000_0000;
        mask_cases[1] = 16'h8001;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        reset_count = reset_count + 1;
        for (b = 0; b < MID_BATCH; b = b + 1)
            send_bundle(b);
        while ((produced_beats < MID_BATCH*4) && (cycles < 20000))
            @(posedge clk);

        /* A second reset is taken only after all prior results retired; this
         * is the adapter's explicit flush fence, not a silent data drop. */
        @(negedge clk);
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        reset_count = reset_count + 1;
        for (b = MID_BATCH; b < BUNDLES; b = b + 1)
            send_bundle(b);
        while ((produced_beats < BUNDLES*4) && (cycles < 40000))
            @(posedge clk);

        if ((accepted_bundles != BUNDLES) ||
            (produced_beats != BUNDLES*4) || (errors != 0) ||
            (simultaneous_fires == 0) || (reset_count != 2)) begin
            $display("FAIL decoupled adapter accepted=%0d produced=%0d errors=%0d simultaneous=%0d resets=%0d cycles=%0d",
                     accepted_bundles, produced_beats, errors,
                     simultaneous_fires, reset_count, cycles);
            $fatal(1);
        end
        $display("PASS tb_ds_dw_requant_stream4_write_adapter_local_decoupled bundles=%0d beats=%0d simultaneous=%0d resets=%0d cycles=%0d",
                 BUNDLES, produced_beats, simultaneous_fires, reset_count, cycles);
        $finish;
    end
endmodule

`default_nettype wire
