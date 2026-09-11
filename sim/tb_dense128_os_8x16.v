`timescale 1ns/1ps
`default_nettype none

/* Real C1 stem trace for dense128_os_8x16.  The exporter supplies official
 * CIFAR-10 input-derived tokens and the frozen ResNet-20 INT8 deployment
 * weights; no random or reduced-difficulty data is used here. */
module tb_dense128_os_8x16;
    localparam integer TILE_COUNT = 128;
    localparam integer K_PER_TILE = 27;
    localparam integer TOKEN_COUNT = TILE_COUNT * K_PER_TILE;
    localparam integer LANES_PER_TILE = 8 * 16;
    localparam integer TOTAL_LANES = TILE_COUNT * LANES_PER_TILE;

    reg clk, rst_n, valid_in, first_k, last_k, ready_out;
    reg [7:0] k_idx, pixel_mask;
    reg [15:0] cout_mask;
    reg signed [63:0] act_vec, wgt_vec_lo, wgt_vec_hi;
    wire ready_in, valid_out;
    wire signed [4095:0] psum_out;
    wire [127:0] lane_mask_out;

    reg [255:0] token_mem [0:TOKEN_COUNT-1];
    reg [31:0] expected_psum [0:TOTAL_LANES-1];
    reg [7:0] expected_output [0:TOTAL_LANES-1];
    integer errors, accepted_tokens, cycle_counter, start_cycles;
    integer token_ptr, tile, lane, idx, stable;
    integer tile_cycles, full_start_cycles;
    integer signed actual_psum;
    reg [4095:0] held_psum;
    reg [127:0] held_mask;

    dense128_os_8x16 dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .pixel_mask(pixel_mask), .cout_mask(cout_mask), .act_vec(act_vec),
        .wgt_vec_lo(wgt_vec_lo), .wgt_vec_hi(wgt_vec_hi),
        .ready_out(ready_out), .valid_out(valid_out), .psum_out(psum_out),
        .lane_mask_out(lane_mask_out)
    );

    always #5 clk <= ~clk;
    always @(posedge clk) if (rst_n) cycle_counter <= cycle_counter + 1;

    task send_token;
        input integer token_index;
        begin
            @(negedge clk);
            act_vec = token_mem[token_index][63:0];
            wgt_vec_lo = token_mem[token_index][127:64];
            wgt_vec_hi = token_mem[token_index][191:128];
            k_idx = token_mem[token_index][199:192];
            first_k = token_mem[token_index][200];
            last_k = token_mem[token_index][201];
            pixel_mask = 8'hff;
            cout_mask = 16'hffff;
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
            act_vec = 64'sd0;
            wgt_vec_lo = 64'sd0;
            wgt_vec_hi = 64'sd0;
        end
    endtask

    task check_output;
        input integer tile_index;
        begin
            while (!valid_out)
                @(posedge clk);
            /* Exercise an actual output backpressure window and verify that
             * the complete output-stationary block, including lane masks,
             * remains stable while stalled. */
            held_psum = psum_out;
            held_mask = lane_mask_out;
            ready_out = 1'b0;
            for (stable = 0; stable < 3; stable = stable + 1) begin
                @(posedge clk);
                if (!valid_out || psum_out !== held_psum || lane_mask_out !== held_mask)
                    errors = errors + 1;
            end
            for (lane = 0; lane < LANES_PER_TILE; lane = lane + 1) begin
                actual_psum = $signed(psum_out[(lane*32) +: 32]);
                idx = tile_index * LANES_PER_TILE + lane;
                if (actual_psum !== $signed(expected_psum[idx])) begin
                    $display("DENSE128_PSUM_MISMATCH tile=%0d lane=%0d exp=%0d got=%0d",
                             tile_index, lane, $signed(expected_psum[idx]), actual_psum);
                    errors = errors + 1;
                end
                if (!lane_mask_out[lane]) begin
                    $display("DENSE128_MASK_MISMATCH tile=%0d lane=%0d", tile_index, lane);
                    errors = errors + 1;
                end
            end
            ready_out = 1'b1;
            @(posedge clk);
            if (valid_out)
                errors = errors + 1;
        end
    endtask

    initial begin
        $readmemh("build/dense128_c1_vectors/dense128_c1_tokens.mem", token_mem);
        $readmemh("build/dense128_c1_vectors/dense128_c1_psum.mem", expected_psum);
        $readmemh("build/dense128_c1_vectors/dense128_c1_output.mem", expected_output);
        clk = 1'b0;
        rst_n = 1'b0;
        valid_in = 1'b0;
        first_k = 1'b0;
        last_k = 1'b0;
        k_idx = 8'd0;
        pixel_mask = 8'd0;
        cout_mask = 16'd0;
        act_vec = 64'sd0;
        wgt_vec_lo = 64'sd0;
        wgt_vec_hi = 64'sd0;
        ready_out = 1'b1;
        errors = 0;
        accepted_tokens = 0;
        cycle_counter = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        /* First tile is the directed acceptance/sideband/backpressure check. */
        start_cycles = cycle_counter;
        full_start_cycles = start_cycles;
        for (idx = 0; idx < K_PER_TILE; idx = idx + 1)
            send_token(idx);
        check_output(0);
        tile_cycles = cycle_counter - start_cycles;
        if (accepted_tokens != K_PER_TILE)
            errors = errors + 1;

        /* Full 32x32 C1 stem: every output element is checked against the
         * exporter golden.  The accepted MAC count is separately reported as
         * 128 products per token, without padding K beyond 27. */
        for (tile = 1; tile < TILE_COUNT; tile = tile + 1) begin
            for (idx = 0; idx < K_PER_TILE; idx = idx + 1)
                send_token(tile * K_PER_TILE + idx);
            check_output(tile);
        end

        if (accepted_tokens != TOKEN_COUNT)
            errors = errors + 1;
        if (errors == 0) begin
            $display("PASS dense128_os_8x16 tiles=%0d pixels=%0d K=%0d Cout=%0d",
                     TILE_COUNT, TILE_COUNT*8, K_PER_TILE, 16);
            $display("DENSE128_EVIDENCE semantic_macs=%0d ideal_mac_cycles=%0d accepted_tokens=%0d",
                     TILE_COUNT*8*16*K_PER_TILE, TILE_COUNT*8*16*K_PER_TILE/128,
                     accepted_tokens);
            $display("DENSE128_EVIDENCE cycles_first_tile=%0d cycles_full_128_tiles=%0d",
                     tile_cycles, cycle_counter - full_start_cycles);
        end else begin
            $display("FAIL dense128_os_8x16 errors=%0d accepted_tokens=%0d", errors, accepted_tokens);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
