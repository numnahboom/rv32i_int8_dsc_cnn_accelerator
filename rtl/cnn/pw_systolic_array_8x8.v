`timescale 1ns/1ps
`default_nettype none

/*
 * Eight-pixel by eight-output-channel pointwise block.
 *
 * The external transaction is one K token per accepted cycle.  The physical
 * array has four output columns, so the token stream is consumed once by the
 * lower half (Cout 0..3) and replayed once by the upper half (Cout 4..7).
 * Lower-half accumulation starts as soon as a token is accepted.  A
 * reduction may therefore be split into several K groups without a group
 * fence clearing the accumulator:
 *
 *   first_k : first token of the complete reduction
 *   last_k  : last token of the complete reduction
 *   k_group : group number (monotonic, contiguous)
 *   k_count : number of tokens in that group (repeated on each token)
 *
 * Only first_k (or legacy clear_acc) clears the lower accumulator.  Only
 * last_k (or legacy k_last) closes the input transaction and starts the upper
 * replay.  No group boundary generates an output or requantization event.
 * The completed lower-half PE values are captured into first_psum immediately
 * before replay; the upper half keeps using the existing PE psum registers.
 * This explicit phase fence is important: replacing k_last with a per-group
 * group_last would publish a partial result and lose the following groups.
 *
 * The legacy clear_acc/k_last ports remain for existing users.  A non-zero
 * k_count selects the tagged contract; k_count==0 selects the legacy one.
 */
module pw_systolic_array_8x8 (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 valid_in,
    output wire                 ready_in,
    input  wire                 first_k,
    input  wire                 last_k,
    input  wire [7:0]           k_group,
    input  wire [7:0]           k_count,
    input  wire                 clear_acc,
    input  wire                 k_last,
    input  wire signed [63:0]   act_vec,
    input  wire signed [63:0]   wgt_vec,

    input  wire                 ready_out,
    output reg                  valid_out,
    output reg  signed [2047:0] psum_out
);
    localparam integer MAX_K = 128;

    reg                 streaming;
    reg                 upper_active;
    reg                 replay_valid;
    reg [7:0]           input_count;
    reg [7:0]           total_k_count;
    reg [7:0]           replay_idx;
    reg                 replay_prefetch_valid;
    reg signed [127:0]  replay_operand_reg;
`ifdef SYNTHESIS
    /* XPM BRAM is read-first on port B; retain the fence token for the
     * one-token prefetch/write collision so the logical replay remains
     * write-first for that boundary case. */
    reg                 replay_prefetch_bypass_valid;
`endif
    wire input_fire = valid_in && ready_in;

`ifndef SYNTHESIS
    /* In a four-state simulation an unconnected tagged port is Z.  Treat that
     * as legacy mode; production instantiations connect these ports. */
    wire token_mode = (k_count !== 8'd0) &&
                      ((first_k === 1'b0) || (first_k === 1'b1)) &&
                      ((last_k === 1'b0) || (last_k === 1'b1));
`else
    wire token_mode = (k_count != 8'd0);
`endif
    wire token_first = token_mode ? first_k : clear_acc;
    wire token_last  = token_mode ? last_k  : k_last;

    /* Hold exactly the accepted lower-half token stream.  The write happens
     * while the lower PE fabric consumes the same token.  A registered read
     * feeds the upper replay and avoids a RAM-address-to-DSP combinational
     * path. */
    /* Keep the accepted token as one 128-bit x 128 replay bank.  The former
     * pair of independent 64-bit memories was treated as LUTRAM by Vivado
     * even with ram_style="block".  The synthesis implementation below uses
     * XPM explicitly so this bank is realized by BRAM primitives.  Its output
     * is a registered read, exactly matching the one-cycle replay operand
     * boundary that the old array-reference implementation provided:
     *
     *   replay_mem[k][63:0]   = act_vec[k]
     *   replay_mem[k][127:64] = wgt_vec[k]
     *
     * The physical upper replay consumes only replay_mem[k][127:96], the
     * former wgt_mem[k][63:32].  The lower half consumes the live input token.
     */
    wire signed [127:0] replay_mem_dout;
    /* Read one token ahead of the PE issue.  The final lower token can start
     * the read of replay entry zero on the same edge that commits it; this
     * leaves room for a local operand register without adding a replay cycle.
     * During replay, replay_idx names the token consumed on the current PE
     * edge, hence the BRAM address is two entries ahead (one in dout and one
     * in replay_operand_reg). */
    wire replay_prefetch_issue = input_fire && token_last;
    wire replay_stream_issue = upper_active &&
                               (!replay_valid ?
                                (replay_prefetch_valid &&
                                 (total_k_count > 8'd1)) :
                                (({1'b0, replay_idx} + 9'd2) <
                                 {1'b0, total_k_count}));
    wire replay_read_issue = replay_prefetch_issue || replay_stream_issue;
    wire [7:0] replay_read_index = replay_prefetch_issue ? 8'd0 :
                                    (!replay_valid ? 8'd1 :
                                     (replay_idx + 8'd2));

`ifdef SYNTHESIS
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(7), .ADDR_WIDTH_B(7),
        .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8),
        .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(16384),
        .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(128),
        .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
        /* Simple-dual-port block RAM only permits read-first on port B.
         * The one-token prefetch/write collision is handled explicitly by
         * replay_operand_reg below, preserving the logical write-first
         * behavior without asking XPM for an illegal primitive mode. */
        .WRITE_DATA_WIDTH_A(128), .WRITE_MODE_B("read_first")
    ) u_replay_mem (
        .clka(clk), .clkb(clk),
        .ena(input_fire), .wea({16{input_fire}}),
        .addra(input_count[6:0]), .dina({wgt_vec, act_vec}),
        .addrb(replay_read_index[6:0]), .enb(replay_read_issue),
        .doutb(replay_mem_dout), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
`else
    (* ram_style = "block" *) reg signed [127:0] replay_mem [0:MAX_K-1];
    reg signed [127:0] replay_mem_dout_reg;
    assign replay_mem_dout = replay_mem_dout_reg;
    always @(posedge clk) begin
        if (!rst_n) begin
            replay_mem_dout_reg <= 128'sd0;
        end else begin
            if (input_fire)
                replay_mem[input_count] <= {wgt_vec, act_vec};
            if (replay_read_issue) begin
                /* Explicitly model XPM write-first behavior for the one-token
                 * reduction whose prefetch read and final write share entry 0. */
                if (replay_prefetch_issue &&
                    (replay_read_index == input_count))
                    replay_mem_dout_reg <= {wgt_vec, act_vec};
                else
                    replay_mem_dout_reg <= replay_mem[replay_read_index];
            end
        end
    end
`endif

    reg                 lower_valid;
    reg [7:0]           pe_issue_row;
    reg                 capture_lower_pending;
    reg                 capture_lower_after;
    /* This CE fans into the 2048-bit output capture bank.  Let Vivado make
     * local copies when this island is composed with scratch/control logic;
     * a single global CE net otherwise becomes a routing-only critical path. */
    (* max_fanout = 64 *) reg capture_output_pending;
    reg signed [63:0]   act_lower_reg;
    reg signed [31:0]   wgt_lower_reg;
    reg                 lower_clear_reg;
    reg signed [63:0]   exec_act_reg;
    reg signed [31:0]   exec_wgt_reg;
    reg                 exec_clear_reg;

    reg signed [31:0] first_psum [0:7][0:3];
    wire signed [31:0] pe_psum [0:7][0:3];
    wire pe_valid [0:7][0:3];
    wire signed [7:0] unused_act [0:7][0:3];
    wire signed [7:0] unused_wgt [0:7][0:3];

`ifndef SYNTHESIS
    /* Simulation-only protocol monitors. */
    integer sim_token_errors;
    integer sim_token_count;
    integer sim_group_pos;
    integer sim_group_expected;
    reg [7:0] sim_group_id;
    integer sim_mac_count;
    integer sim_output_count;
`endif

    wire upper_pe_fire = upper_active && replay_valid;
    /* The replay bank output is captured in a local operand register before
     * each PE issue.  This keeps BRAM fanout and the long row operand route out
     * of the DSP input timing path; during the lower stream the live operand
     * registers remain unchanged. */
    wire signed [63:0] pe_act_operand = upper_pe_fire ?
                                         replay_operand_reg[63:0] : exec_act_reg;
    wire signed [31:0] pe_wgt_operand = upper_pe_fire ?
                                         replay_operand_reg[127:96] : exec_wgt_reg;
    /* The issue bit is registered alongside the selected operand.  Splitting
     * it by row limits the valid/clock-enable fanout to four PEs per bit;
     * lower_valid and the phase state therefore do not form a global PE data
     * cone. */
    wire pe_fire = |pe_issue_row;

    /* Input is stopped exactly at the whole-reduction fence and remains
     * stopped while the upper half replays and while output is held. */
    /* `streaming` is cleared on last_k before valid_out is raised, so
     * valid_out need not sit in this ready/data cone.  Keeping the output
     * register out of the operand mux is important for timing: otherwise its
     * fanout is replicated into every PE input bit. */
    assign ready_in = streaming && (input_count < MAX_K);

    genvar r;
    genvar c;
    generate
        for (r = 0; r < 8; r = r + 1) begin : gen_rows
            for (c = 0; c < 4; c = c + 1) begin : gen_cols
                systolic_pe u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .valid_in(pe_issue_row[r]),
                    .clear_acc(exec_clear_reg),
                    .act_in(pe_act_operand[(r*8) +: 8]),
                    .wgt_in(pe_wgt_operand[(c*8) +: 8]),
                    .valid_out(pe_valid[r][c]),
                    .act_out(unused_act[r][c]),
                    .wgt_out(unused_wgt[r][c]),
                    .psum_out(pe_psum[r][c])
                );
            end
        end
    endgenerate

    integer i;
    integer j;
    always @(posedge clk) begin
        if (!rst_n) begin
            streaming <= 1'b1;
            upper_active <= 1'b0;
            replay_valid <= 1'b0;
            lower_valid <= 1'b0;
            pe_issue_row <= 8'd0;
            capture_lower_pending <= 1'b0;
            capture_lower_after <= 1'b0;
            capture_output_pending <= 1'b0;
            input_count <= 8'd0;
            total_k_count <= 8'd0;
            replay_idx <= 8'd0;
            replay_prefetch_valid <= 1'b0;
            replay_operand_reg <= 128'sd0;
`ifdef SYNTHESIS
            replay_prefetch_bypass_valid <= 1'b0;
`endif
            act_lower_reg <= 64'sd0;
            wgt_lower_reg <= 32'sd0;
            lower_clear_reg <= 1'b0;
            exec_act_reg <= 64'sd0;
            exec_wgt_reg <= 32'sd0;
            exec_clear_reg <= 1'b0;
            valid_out <= 1'b0;
            psum_out <= 2048'sd0;
`ifndef SYNTHESIS
            sim_token_errors <= 0;
            sim_token_count <= 0;
            sim_group_pos <= 0;
            sim_group_expected <= 0;
            sim_group_id <= 8'd0;
            sim_mac_count <= 0;
            sim_output_count <= 0;
`endif
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 4; j = j + 1)
                    first_psum[i][j] <= 32'sd0;
        end else begin
`ifndef SYNTHESIS
            if (pe_fire)
                sim_mac_count <= sim_mac_count + 32;
            if (input_fire) begin
                sim_token_count <= sim_token_count + 1;
                if ($test$plusargs("TRACE_PW_PARTIAL") &&
                    (token_first || token_last))
                    $display("PW_TOKEN t=%0t idx=%0d first=%b last=%b group=%0d count=%0d",
                             $time,
                             input_count, token_first, token_last,
                             k_group, k_count);
                if (token_mode) begin
                    if (input_count == 8'd0) begin
                        if (!token_first) begin
                            $display("PW_ASSERT missing_first_k");
                            sim_token_errors <= sim_token_errors + 1;
                        end
                        sim_group_id <= k_group;
                        sim_group_expected <= k_count;
                        sim_group_pos <= 1;
                    end else if (k_group != sim_group_id) begin
                        if ((sim_group_expected != 0) &&
                            (sim_group_pos != sim_group_expected)) begin
                            $display("PW_ASSERT group_fence pos=%0d expected=%0d",
                                     sim_group_pos, sim_group_expected);
                            sim_token_errors <= sim_token_errors + 1;
                        end
                        sim_group_id <= k_group;
                        sim_group_expected <= k_count;
                        sim_group_pos <= 1;
                    end else begin
                        if ((sim_group_expected != 0) &&
                            (sim_group_pos >= sim_group_expected)) begin
                            $display("PW_ASSERT group_overrun id=%0d", k_group);
                            sim_token_errors <= sim_token_errors + 1;
                        end
                        sim_group_pos <= sim_group_pos + 1;
                    end
                    if ((input_count != 8'd0) && token_first) begin
                        $display("PW_ASSERT unexpected_first_k idx=%0d", input_count);
                        sim_token_errors <= sim_token_errors + 1;
                    end
                    if (token_last && (k_count != 0) &&
                        (((k_group != sim_group_id) ? 1 : (sim_group_pos + 1))
                         != k_count)) begin
                        $display("PW_ASSERT final_group pos=%0d expected=%0d",
                                 ((k_group != sim_group_id) ? 1 :
                                  (sim_group_pos + 1)), k_count);
                        sim_token_errors <= sim_token_errors + 1;
                    end
                end
            end
`endif

            /* Output is a one-entry elastic transaction. */
            if (valid_out && ready_out) begin
                valid_out <= 1'b0;
                streaming <= 1'b1;
                input_count <= 8'd0;
`ifndef SYNTHESIS
                sim_mac_count <= 0;
                sim_token_count <= 0;
                sim_group_pos <= 0;
                sim_group_expected <= 0;
`endif
            end

            /* The lower PE update for the final token occurred on the prior
             * edge. Capture the complete lower accumulator before allowing
             * the upper replay to issue its first (clearing) token. */
            /* capture_lower_pending is observed in the cycle in which the
             * final lower token is being consumed by the PE.  Because the PE
             * is a registered accumulator, its new psum is available one
             * edge later. */
            if (capture_lower_pending && lower_valid) begin
                capture_lower_pending <= 1'b0;
                capture_lower_after <= 1'b1;
            end else if (capture_lower_after) begin
                for (i = 0; i < 8; i = i + 1)
                    for (j = 0; j < 4; j = j + 1)
                        first_psum[i][j] <= pe_psum[i][j];
                capture_lower_after <= 1'b0;
            end

            /* Final upper PE update occurred on the preceding edge. The
             * lower seed and upper live psum are now both stable. */
            if (capture_output_pending) begin
                for (i = 0; i < 8; i = i + 1) begin
                    for (j = 0; j < 4; j = j + 1) begin
                        psum_out[((i*8 + j)*32) +: 32] <= first_psum[i][j];
                        psum_out[((i*8 + j + 4)*32) +: 32] <= pe_psum[i][j];
                    end
                end
                valid_out <= 1'b1;
                capture_output_pending <= 1'b0;
`ifndef SYNTHESIS
                sim_output_count <= sim_output_count + 1;
`endif
            end

            /* Lower-half streaming path. Group metadata is deliberately not
             * used as a clear or a fence: the PE psum registers span all K
             * groups, and only token_last closes the complete reduction. */
            lower_valid <= input_fire;
            pe_issue_row <= 8'd0;
            /* Capture the already-returned BRAM word one cycle before the PE
             * issue edge.  This register removes the wide BRAM-to-PE fanout
             * path while retaining one token per replay cycle. */
            if (upper_active) begin
`ifdef SYNTHESIS
                if (!(replay_prefetch_bypass_valid && replay_prefetch_valid &&
                      (total_k_count == 8'd1)))
                    replay_operand_reg <= replay_mem_dout;
`else
                replay_operand_reg <= replay_mem_dout;
`endif
            end
            if (input_fire) begin
                act_lower_reg <= act_vec;
                wgt_lower_reg <= wgt_vec[31:0];
                lower_clear_reg <= token_first && (input_count == 8'd0);
                exec_act_reg <= act_vec;
                exec_wgt_reg <= wgt_vec[31:0];
                exec_clear_reg <= token_first && (input_count == 8'd0);
                pe_issue_row <= 8'hff;
                if (token_last) begin
`ifdef SYNTHESIS
                    replay_prefetch_bypass_valid <= 1'b1;
                    replay_operand_reg <= {wgt_vec, act_vec};
`endif
                    total_k_count <= input_count + 8'd1;
                    streaming <= 1'b0;
                    upper_active <= 1'b1;
                    replay_valid <= 1'b0;
                    replay_prefetch_valid <= 1'b1;
                    replay_idx <= 8'd0;
                    capture_lower_pending <= 1'b1;
                end else begin
                    input_count <= input_count + 8'd1;
                end
            end

            /* Registered read, then one replay issue per cycle. The first
             * replay token clears the PE fabric so it becomes the upper four
             * output channels; later replay tokens, including tokens crossing
             * every group boundary, retain the upper psum. */
            if (upper_active && !replay_valid) begin
                exec_clear_reg <= (replay_idx == 8'd0);
                pe_issue_row <= 8'hff;
                replay_valid <= 1'b1;
                replay_prefetch_valid <= 1'b0;
            end else if (upper_pe_fire) begin
                if (({1'b0, replay_idx} + 9'd1) >= {1'b0, total_k_count}) begin
                    upper_active <= 1'b0;
                    replay_valid <= 1'b0;
                    pe_issue_row <= 8'd0;
                    capture_output_pending <= 1'b1;
                end else begin
                    replay_idx <= replay_idx + 8'd1;
                    exec_clear_reg <= 1'b0;
                    pe_issue_row <= 8'hff;
                end
            end
        end
    end
endmodule

`default_nettype wire
