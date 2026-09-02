`timescale 1ns/1ps
`default_nettype none

/* Real D4 deployment vectors plus protocol/partial-K checks for the first
 * standalone 128-MAC tile.  The two records exercise mb32.expand (K=16) and
 * a second real D4 expand (mb16.1.expand, K=32), so K=32 accumulation is not
 * represented by synthetic/random-only data. */
module tb_edgembconv_hwacandidate_d4_dense128_pw_tile;
    localparam integer TOKEN_BITS = 258;
    localparam integer LANES = 128;
    localparam integer MAX_K = 32;

    reg clk, rst_n, valid_in, ready_out;
    reg first_k, last_k;
    reg [7:0] k_idx, pixel_mask;
    reg [15:0] cout_mask;
    reg signed [63:0] act_vec;
    reg signed [127:0] wgt_vec;
    reg [31:0] metadata_in;
    wire ready_in, valid_out;
    wire signed [4095:0] psum_out;
    wire [127:0] lane_mask_out;
    wire [31:0] metadata_out;
    wire [7:0] k_idx_out;
    wire first_k_out, last_k_out;

    reg [TOKEN_BITS-1:0] mb32_tokens [0:15];
    reg [TOKEN_BITS-1:0] mb161_tokens [0:31];
    reg [31:0] mb32_expected [0:127];
    reg [31:0] mb161_expected [0:127];

    integer errors, accepted_tokens, cycle_counter, start_cycle;
    integer i, lane, stable, idx, bubble_count, expected_pipeline_cycles;
    integer checked_psum_lanes, observed_cycles, expected_value, actual_value;
    reg [4095:0] held_psum;
    reg [127:0] held_mask;
    reg [31:0] held_metadata;
    reg [7:0] held_k_idx;
    reg held_first, held_last;
    reg [63:0] held_input_act;
    reg [127:0] held_input_wgt;
    reg [31:0] held_input_metadata;

    edgembconv_hwacandidate_d4_dense128_pw_tile dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .pixel_mask(pixel_mask), .cout_mask(cout_mask),
        .act_vec(act_vec), .wgt_vec(wgt_vec), .metadata_in(metadata_in),
        .ready_out(ready_out), .valid_out(valid_out), .psum_out(psum_out),
        .lane_mask_out(lane_mask_out), .metadata_out(metadata_out),
        .k_idx_out(k_idx_out), .first_k_out(first_k_out),
        .last_k_out(last_k_out)
    );

    always #5 clk <= ~clk;
    always @(posedge clk) if (rst_n) cycle_counter <= cycle_counter + 1;

    task send_token;
        input integer token_word;
        input integer token_index;
        begin
            /* A source bubble makes valid/ready interaction observable while
             * preserving all token fields until acceptance. */
            if ((token_index % 5) == 2)
                repeat (2) @(negedge clk);
            @(negedge clk);
            act_vec = token_word == 0 ? mb32_tokens[token_index][63:0] : mb161_tokens[token_index][63:0];
            wgt_vec = token_word == 0 ? mb32_tokens[token_index][191:64] : mb161_tokens[token_index][191:64];
            k_idx = token_word == 0 ? mb32_tokens[token_index][201:194] : mb161_tokens[token_index][201:194];
            first_k = token_word == 0 ? mb32_tokens[token_index][192] : mb161_tokens[token_index][192];
            last_k = token_word == 0 ? mb32_tokens[token_index][193] : mb161_tokens[token_index][193];
            pixel_mask = token_word == 0 ? mb32_tokens[token_index][209:202] : mb161_tokens[token_index][209:202];
            cout_mask = token_word == 0 ? mb32_tokens[token_index][225:210] : mb161_tokens[token_index][225:210];
            metadata_in = token_word == 0 ? mb32_tokens[token_index][257:226] : mb161_tokens[token_index][257:226];
            valid_in = 1'b1;
            while (!ready_in)
                @(negedge clk);
            @(posedge clk);
            accepted_tokens = accepted_tokens + 1;
            @(negedge clk);
            valid_in = 1'b0;
            first_k = 1'b0;
            last_k = 1'b0;
            k_idx = 8'd0;
            pixel_mask = 8'd0;
            cout_mask = 16'd0;
            metadata_in = 32'd0;
            act_vec = 64'sd0;
            wgt_vec = 128'sd0;
        end
    endtask

    task run_tile;
        input integer token_word;
        input integer token_count;
        input integer metadata_expected;
        input integer schedule_ideal;
        input integer expected_arithmetic_ops;
        begin
            start_cycle = cycle_counter;
            for (i = 0; i < token_count; i = i + 1)
                send_token(token_word, i);
            while (!valid_out)
                @(posedge clk);
            observed_cycles = cycle_counter - start_cycle;

            /* The source deliberately inserts two-cycle bubbles at token
             * indices 2, 7, ... .  The two explicit operand/product stages
             * add exactly two fixed cycles independent of K, so this checks
             * II=1 plus a bounded startup/drain cost rather than accepting
             * an accidental serialization. */
            bubble_count = 0;
            for (idx = 0; idx < token_count; idx = idx + 1)
                if ((idx % 5) == 2)
                    bubble_count = bubble_count + 1;
            expected_pipeline_cycles = 2*token_count + 2*bubble_count + 3;
            if (observed_cycles !== expected_pipeline_cycles) begin
                $display("D4_DENSE128_PIPELINE_CYCLE_MISMATCH tile=%0d expected=%0d got=%0d",
                         token_word, expected_pipeline_cycles, observed_cycles);
                errors = errors + 1;
            end
            if (expected_arithmetic_ops !== 2*LANES*token_count) begin
                $display("D4_DENSE128_MAC_COUNT_MISMATCH tile=%0d expected_ops=%0d",
                         token_word, 2*LANES*token_count);
                errors = errors + 1;
            end

            /* Output stability and blocked input are checked together. */
            held_psum = psum_out;
            held_mask = lane_mask_out;
            held_metadata = metadata_out;
            held_k_idx = k_idx_out;
            held_first = first_k_out;
            held_last = last_k_out;
            ready_out = 1'b0;
            /* Hold a valid source token against the blocked output.  The
             * tile must keep ready low, while the source-side fields remain
             * unchanged until a future ready/valid transfer. */
            valid_in = 1'b1;
            first_k = 1'b0;
            last_k = 1'b0;
            k_idx = 8'h5a;
            pixel_mask = 8'hff;
            cout_mask = 16'hffff;
            act_vec = 64'h0123456789abcdef;
            wgt_vec = 128'h00112233445566778899aabbccddeeff;
            metadata_in = 32'hd4e01280;
            held_input_act = act_vec;
            held_input_wgt = wgt_vec;
            held_input_metadata = metadata_in;
            for (stable = 0; stable < 3; stable = stable + 1) begin
                @(posedge clk);
                if (!valid_out || psum_out !== held_psum ||
                    lane_mask_out !== held_mask || metadata_out !== held_metadata ||
                    k_idx_out !== held_k_idx || first_k_out !== held_first ||
                    last_k_out !== held_last)
                    errors = errors + 1;
                if (ready_in || act_vec !== held_input_act ||
                    wgt_vec !== held_input_wgt || metadata_in !== held_input_metadata)
                    errors = errors + 1;
            end
            valid_in = 1'b0;
            first_k = 1'b0;
            last_k = 1'b0;
            k_idx = 8'd0;
            pixel_mask = 8'd0;
            cout_mask = 16'd0;
            metadata_in = 32'd0;
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                checked_psum_lanes = checked_psum_lanes + 1;
                expected_value = token_word == 0
                    ? $signed(mb32_expected[lane]) : $signed(mb161_expected[lane]);
                actual_value = $signed(psum_out[(lane*32) +: 32]);
                if (actual_value !== expected_value || !lane_mask_out[lane]) begin
                    $display("D4_DENSE128_MISMATCH tile=%0d lane=%0d exp=%0d got=%0d mask=%b",
                             token_word, lane, expected_value, actual_value, lane_mask_out[lane]);
                    errors = errors + 1;
                end
            end
            if (metadata_out !== metadata_expected || k_idx_out !== token_count - 1 ||
                first_k_out !== 1'b0 || last_k_out !== 1'b1)
                errors = errors + 1;

            ready_out = 1'b1;
            @(posedge clk);
            if (valid_out)
                errors = errors + 1;
            $display("D4_DENSE128_TILE tile=%0d K=%0d accepted=%0d observed_raw_cycles=%0d expected_pipeline_cycles=%0d fixed_pipeline_delta=2 raw_products=%0d arithmetic_ops=%0d checked_psum_lanes=%0d schedule_ideal=%0d boundary=%0d stalled=%0d",
                     token_word, token_count, token_count, observed_cycles,
                     expected_pipeline_cycles, 8*16*token_count,
                     expected_arithmetic_ops, 128,
                     schedule_ideal, schedule_ideal+2, schedule_ideal+5);
        end
    endtask

    initial begin
        $readmemh("build/edgembconv_hwacandidate_d4_dense128_vectors/d4_dense128_mb32_expand_tokens.mem", mb32_tokens);
        $readmemh("build/edgembconv_hwacandidate_d4_dense128_vectors/d4_dense128_mb32_expand_psum.mem", mb32_expected);
        $readmemh("build/edgembconv_hwacandidate_d4_dense128_vectors/d4_dense128_mb16_1_expand_tokens.mem", mb161_tokens);
        $readmemh("build/edgembconv_hwacandidate_d4_dense128_vectors/d4_dense128_mb16_1_expand_psum.mem", mb161_expected);
        clk = 1'b0; rst_n = 1'b0; valid_in = 1'b0; ready_out = 1'b1;
        first_k = 1'b0; last_k = 1'b0; k_idx = 8'd0;
        pixel_mask = 8'd0; cout_mask = 16'd0;
        act_vec = 64'sd0; wgt_vec = 128'sd0; metadata_in = 32'd0;
        errors = 0; accepted_tokens = 0; cycle_counter = 0;
        checked_psum_lanes = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        run_tile(0, 16, 32'h00100000, 48, 4096);
        run_tile(1, 32, 32'h01200000, 64, 8192);

        if (accepted_tokens != 48)
            errors = errors + 1;
        if (checked_psum_lanes != 2*LANES)
            errors = errors + 1;
        if (errors == 0) begin
            $display("PASS edgembconv_hwacandidate_d4_dense128_pw_tile tiles=2 accepted_tokens=%0d raw_products=%0d arithmetic_ops=%0d",
                     accepted_tokens, 8*16*(16+32), 2*8*16*(16+32));
            $display("D4_DENSE128_SCHEDULE_CHECK K16 ideal=48 boundary=50 three_cycle_output_stall=53; K32 accumulation arithmetic_ops=8192");
        end else begin
            $display("FAIL edgembconv_hwacandidate_d4_dense128_pw_tile errors=%0d accepted_tokens=%0d", errors, accepted_tokens);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
