`timescale 1ns/1ps
`default_nettype none

/*
 * Independent D4 MBConv block-level hardware candidate.
 *
 * This shell is intentionally below the production runner boundary.  It is a
 * complete, exact block transaction for the two real D4 blocks used by the
 * first integration gate:
 *
 *   block_id=0: mb32       32x32x16 -> 32x32x16, stride 1, residual
 *   block_id=1: mb16_down   32x32x16 -> 16x16x32, stride 2, no residual
 *
 * Configuration is a byte-addressed loader for signed INT8 operands and
 * folded INT32 bias/requant parameters.  A single 128-MAC PW array is reused
 * for expand and project.  A single 16-lane DW array performs one 3x3 tap per
 * cycle.  The two local scratch images have explicit FREE/FILL/READY/ACTIVE
 * ownership and epoch fences: bank0 holds expanded activations and bank1
 * holds depthwise output.  No complete expansion is written to global SRAM.
 *
 * The implementation is a deterministic block shell, rather than an
 * optimistic cycle-model stub: every PW/DW product, SAME halo zero, stride,
 * tail lane and (for mb32) common-scale residual add is evaluated in RTL.
 * The selected shell schedule is intentionally serialized at this gate; the
 * overlap counter remains zero until an independently verified dual-issue
 * scheduler is integrated.  Thus a reported overlap value can never be
 * mistaken for fabricated concurrency evidence.
 */
module edgembconv_hwacandidate_d4_block_shell #(
    parameter integer MAX_PIXELS = 1024,
    parameter integer MAX_CHANNELS = 32,
    parameter integer CFG_ADDR_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,

    input wire cfg_valid,
    output wire cfg_ready,
    input wire [2:0] cfg_kind,
    input wire [CFG_ADDR_WIDTH-1:0] cfg_addr,
    input wire [31:0] cfg_data,

    input wire start_valid,
    output wire start_ready,
    input wire start_block_id,
    input wire [3:0] start_epoch,
    output reg done_valid,
    input wire done_ready,
    output reg done_block_id,
    output reg [3:0] done_epoch,

    output wire out_valid,
    input wire out_ready,
    output wire [15:0] out_index,
    output wire signed [7:0] out_data,
    output wire out_bank,

    output wire busy,
    output wire [1:0] scratch0_state,
    output wire [1:0] scratch1_state,
    output wire [3:0] active_epoch,
    output reg [31:0] cycle_count,
    output reg [31:0] pw_mac_count,
    output reg [31:0] dw_mac_count,
    output reg [31:0] overlap_cycles,
    output reg [31:0] protocol_errors
);
    localparam integer INPUT_BYTES = MAX_PIXELS * MAX_CHANNELS;
    localparam integer PW_BYTES = 4 * MAX_CHANNELS * MAX_CHANNELS;
    localparam integer DW_BYTES = 2 * MAX_CHANNELS * 9;

    localparam [2:0] CFG_INPUT = 3'd0;
    localparam [2:0] CFG_PW_WEIGHT = 3'd1;
    localparam [2:0] CFG_DW_WEIGHT = 3'd2;
    localparam [2:0] CFG_BIAS = 3'd3;
    localparam [2:0] CFG_MULTIPLIER = 3'd4;
    localparam [2:0] CFG_SHIFT = 3'd5;
    localparam [2:0] CFG_RESIDUAL = 3'd6;

    localparam [1:0] BANK_FREE = 2'd0;
    localparam [1:0] BANK_FILL = 2'd1;
    localparam [1:0] BANK_READY = 2'd2;
    localparam [1:0] BANK_ACTIVE = 2'd3;

    localparam [3:0] ST_IDLE = 4'd0;
    localparam [3:0] ST_PW_EXP = 4'd1;
    localparam [3:0] ST_PW_EXP_STORE = 4'd2;
    localparam [3:0] ST_DW = 4'd3;
    localparam [3:0] ST_DW_STORE = 4'd4;
    localparam [3:0] ST_PW_PROJ = 4'd5;
    localparam [3:0] ST_PW_PROJ_STORE = 4'd6;
    localparam [3:0] ST_RESIDUAL = 4'd7;
    localparam [3:0] ST_OUTPUT = 4'd8;
    localparam [3:0] ST_DONE = 4'd9;
    localparam [3:0] ST_DW_ACQUIRE = 4'd10;
    localparam [3:0] ST_PW_PROJ_ACQUIRE = 4'd11;

    /* Byte-addressed configuration memories.  The two scratch arrays are
     * separate ownership domains and are inferred as local block storage by
     * implementation wrappers when this candidate is synthesized. */
    (* ram_style = "block" *) reg signed [7:0] input_mem [0:INPUT_BYTES-1];
    (* ram_style = "block" *) reg signed [7:0] pw_weight_mem [0:PW_BYTES-1];
    (* ram_style = "block" *) reg signed [7:0] dw_weight_mem [0:DW_BYTES-1];
    (* ram_style = "block" *) reg signed [7:0] scratch0 [0:INPUT_BYTES-1];
    (* ram_style = "block" *) reg signed [7:0] scratch1 [0:INPUT_BYTES-1];
    (* ram_style = "block" *) reg signed [7:0] output_mem [0:INPUT_BYTES-1];
    /* 0..127 are PW operation parameter slots; 128..191 are the two DW
     * operation slots. */
    reg signed [31:0] bias_mem [0:191];
    reg signed [31:0] multiplier_mem [0:191];
    reg [7:0] shift_mem [0:191];

    reg signed [31:0] residual_a_multiplier;
    reg signed [31:0] residual_b_multiplier;
    reg [7:0] residual_a_shift, residual_b_shift;

    reg [3:0] state;
    reg block_id_reg;
    reg [3:0] epoch_reg;
    reg [1:0] bank0_state_reg, bank1_state_reg;

    reg [1:0] pw_op;
    reg pw_src_scratch1;
    reg pw_dst_output;
    reg [5:0] pw_cin, pw_cout;
    reg [5:0] pw_h, pw_w;
    reg [5:0] pw_src_w;
    reg [5:0] pw_tile_y, pw_tile_x;
    reg [1:0] pw_tile_group;
    reg [5:0] pw_k;
    reg signed [31:0] pw_acc [0:7][0:15];

    reg [5:0] dw_h, dw_w;
    reg [1:0] dw_group;
    reg [5:0] dw_y, dw_x;
    reg [3:0] dw_tap;
    reg [1:0] dw_op;
    reg [1:0] dw_stride;
    reg signed [31:0] dw_acc [0:15];

    reg [31:0] cursor;
    reg [31:0] residual_cursor;
    reg signed [7:0] residual_a_q, residual_b_q;

    integer i, j, iy, ix, source_index, weight_index, param_index;
    integer qvalue;

    function signed [31:0] mul8_term;
        input signed [7:0] a;
        input signed [7:0] b;
        reg signed [15:0] p;
        begin
            p = a * b;
            mul8_term = {{16{p[15]}}, p};
        end
    endfunction

    function integer pw_src_addr;
        input integer y; input integer x; input integer k;
        input integer cin; input integer width;
        begin pw_src_addr = (y * width + x) * cin + k; end
    endfunction

    function integer pw_pixel_x;
        input integer tile_x; input integer lane;
        /* pw_tile_x is already the pixel-space start (0,8,16,24). */
        begin pw_pixel_x = tile_x + lane; end
    endfunction

    function integer pw_weight_addr;
        input integer op; input integer group; input integer k;
        input integer cin;
        begin pw_weight_addr = op * 1024 + (group * 16) * cin + k; end
    endfunction

    function integer pw_store_addr;
        input integer y; input integer x; input integer channel;
        input integer cout; input integer width;
        begin pw_store_addr = (y * width + x) * cout + channel; end
    endfunction

    function integer dw_store_addr;
        input integer y; input integer x; input integer channel;
        input integer cout; input integer width;
        begin dw_store_addr = (y * width + x) * cout + channel; end
    endfunction

    function signed [31:0] requant32;
        input signed [31:0] acc;
        input signed [31:0] multiplier;
        input [7:0] shift;
        input integer qmin;
        input integer qmax;
        reg signed [63:0] product;
        reg signed [63:0] magnitude;
        reg signed [63:0] rounded;
        reg signed [63:0] q;
        begin
            product = acc * multiplier;
            if (product < 0) begin
                magnitude = -product;
                rounded = (magnitude + (64'sd1 <<< (shift - 1))) >>> shift;
                q = -rounded;
            end else begin
                rounded = (product + (64'sd1 <<< (shift - 1))) >>> shift;
                q = rounded;
            end
            if (q < qmin) requant32 = qmin;
            else if (q > qmax) requant32 = qmax;
            else requant32 = q[31:0];
        end
    endfunction

    function signed [7:0] scale8;
        input signed [7:0] value;
        input signed [31:0] multiplier;
        input [7:0] shift;
        reg signed [31:0] wide;
        begin
            wide = requant32({{24{value[7]}}, value}, multiplier, shift, -128, 127);
            scale8 = wide[7:0];
        end
    endfunction

    function signed [7:0] residual_sum;
        input signed [7:0] a;
        input signed [7:0] b;
        reg signed [31:0] aa, bb, ss;
        begin
            aa = scale8(a, residual_a_multiplier, residual_a_shift);
            bb = scale8(b, residual_b_multiplier, residual_b_shift);
            ss = aa + bb;
            if (ss < -128) residual_sum = -128;
            else if (ss > 127) residual_sum = 127;
            else residual_sum = ss[7:0];
        end
    endfunction

    assign cfg_ready = rst_n && (state == ST_IDLE) && !done_valid;
    assign start_ready = rst_n && (state == ST_IDLE) && !done_valid;
    assign busy = rst_n && (state != ST_IDLE) && (state != ST_DONE);
    assign scratch0_state = bank0_state_reg;
    assign scratch1_state = bank1_state_reg;
    assign active_epoch = epoch_reg;
    assign out_valid = (state == ST_OUTPUT);
    assign out_index = cursor[15:0];
    assign out_data = output_mem[cursor];
    assign out_bank = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            block_id_reg <= 1'b0;
            epoch_reg <= 4'd0;
            done_valid <= 1'b0;
            done_block_id <= 1'b0;
            done_epoch <= 4'd0;
            bank0_state_reg <= BANK_FREE;
            bank1_state_reg <= BANK_FREE;
            pw_op <= 2'd0;
            pw_src_scratch1 <= 1'b0;
            pw_dst_output <= 1'b0;
            pw_cin <= 6'd0;
            pw_cout <= 6'd0;
            pw_h <= 6'd0;
            pw_w <= 6'd0;
            pw_src_w <= 6'd0;
            pw_tile_y <= 6'd0;
            pw_tile_x <= 6'd0;
            pw_tile_group <= 2'd0;
            pw_k <= 6'd0;
            dw_h <= 6'd0;
            dw_w <= 6'd0;
            dw_group <= 2'd0;
            dw_y <= 6'd0;
            dw_x <= 6'd0;
            dw_tap <= 4'd0;
            dw_op <= 2'd0;
            dw_stride <= 2'd1;
            cursor <= 32'd0;
            residual_cursor <= 32'd0;
            residual_a_multiplier <= 32'sd0;
            residual_b_multiplier <= 32'sd0;
            residual_a_shift <= 8'd0;
            residual_b_shift <= 8'd0;
            cycle_count <= 32'd0;
            pw_mac_count <= 32'd0;
            dw_mac_count <= 32'd0;
            overlap_cycles <= 32'd0;
            protocol_errors <= 32'd0;
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 16; j = j + 1)
                    pw_acc[i][j] = 32'sd0;
            for (i = 0; i < 16; i = i + 1)
                dw_acc[i] = 32'sd0;
        end else begin
            if (done_valid && done_ready)
                done_valid <= 1'b0;

            if (busy)
                cycle_count <= cycle_count + 1'b1;

            /* Configuration is intentionally impossible during a live
             * transaction.  Each kind has an explicit address range; reject
             * malformed writes instead of silently corrupting a bank. */
            if (cfg_valid && cfg_ready) begin
                case (cfg_kind)
                    CFG_INPUT: begin
                        if (cfg_addr < INPUT_BYTES) begin
                            input_mem[cfg_addr] <= cfg_data[7:0];
                        end else protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_PW_WEIGHT: begin
                        if (cfg_addr < PW_BYTES) pw_weight_mem[cfg_addr] <= cfg_data[7:0];
                        else protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_DW_WEIGHT: begin
                        if (cfg_addr < DW_BYTES) dw_weight_mem[cfg_addr] <= cfg_data[7:0];
                        else protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_BIAS: begin
                        if (cfg_addr < 192) bias_mem[cfg_addr] <= cfg_data;
                        else protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_MULTIPLIER: begin
                        if (cfg_addr < 192) multiplier_mem[cfg_addr] <= cfg_data;
                        else protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_SHIFT: begin
                        if (cfg_addr < 192) shift_mem[cfg_addr] <= cfg_data[7:0];
                        else protocol_errors <= protocol_errors + 1'b1;
                    end
                    CFG_RESIDUAL: begin
                        case (cfg_addr)
                            0: residual_a_multiplier <= cfg_data;
                            1: residual_a_shift <= cfg_data[7:0];
                            2: residual_b_multiplier <= cfg_data;
                            3: residual_b_shift <= cfg_data[7:0];
                            default: protocol_errors <= protocol_errors + 1'b1;
                        endcase
                    end
                    default: protocol_errors <= protocol_errors + 1'b1;
                endcase
            end

            if (start_valid && start_ready) begin
                block_id_reg <= start_block_id;
                epoch_reg <= start_epoch;
                done_block_id <= start_block_id;
                done_epoch <= start_epoch;
                bank0_state_reg <= BANK_FILL;
                bank1_state_reg <= BANK_FREE;
                pw_src_scratch1 <= 1'b0;
                pw_dst_output <= 1'b0;
                pw_tile_y <= 6'd0;
                pw_tile_x <= 6'd0;
                pw_tile_group <= 2'd0;
                pw_k <= 6'd0;
                pw_op <= start_block_id ? 2'd2 : 2'd0;
                pw_cin <= 6'd16;
                pw_cout <= 6'd32;
                pw_h <= 6'd32;
                pw_w <= 6'd32;
                pw_src_w <= 6'd32;
                dw_op <= start_block_id ? 2'd1 : 2'd0;
                dw_stride <= start_block_id ? 2'd2 : 2'd1;
                dw_h <= start_block_id ? 6'd16 : 6'd32;
                dw_w <= start_block_id ? 6'd16 : 6'd32;
                dw_group <= 2'd0;
                dw_y <= 6'd0;
                dw_x <= 6'd0;
                dw_tap <= 4'd0;
                cursor <= 32'd0;
                residual_cursor <= 32'd0;
                state <= ST_PW_EXP;
            end else begin
                case (state)
                    ST_PW_EXP: begin
                        /* One complete 8-pixel x 16-Cout tile.  The same
                         * 128 cells are reused for every K token and both
                         * expand/project operations. */
                        for (i = 0; i < 8; i = i + 1) begin
                            for (j = 0; j < 16; j = j + 1) begin
                                /* i is the eight-pixel tile lane; j is Cout.
                                 * The tile's x offset is part of this single
                                 * flat NHWC address. */
                                source_index = pw_src_addr(pw_tile_y, pw_pixel_x(pw_tile_x, i), pw_k, pw_cin, pw_src_w);
                                /* Deployment PW arrays are output-major
                                 * [Cout][Cin], while the issue loop is
                                 * reduction-major. */
                                weight_index = pw_weight_addr(pw_op, pw_tile_group, pw_k, pw_cin) + j * pw_cin;
                                param_index = pw_op * 32 + pw_tile_group * 16 + j;
                                if (pw_src_scratch1)
                                    pw_acc[i][j] = (pw_k == 0) ?
                                        mul8_term(scratch1[source_index], pw_weight_mem[weight_index]) + bias_mem[param_index] :
                                        pw_acc[i][j] + mul8_term(scratch1[source_index], pw_weight_mem[weight_index]);
                                else
                                    pw_acc[i][j] = (pw_k == 0) ?
                                        mul8_term(input_mem[source_index], pw_weight_mem[weight_index]) + bias_mem[param_index] :
                                        pw_acc[i][j] + mul8_term(input_mem[source_index], pw_weight_mem[weight_index]);
                            end
                        end
                        pw_mac_count <= pw_mac_count + 128;
                        if (pw_k == pw_cin - 1) begin
                            state <= ST_PW_EXP_STORE;
                        end else begin
                            pw_k <= pw_k + 1'b1;
                        end
                    end

                    ST_PW_EXP_STORE: begin
                        for (i = 0; i < 8; i = i + 1) begin
                            for (j = 0; j < 16; j = j + 1) begin
                                weight_index = pw_op * 1024 + pw_cin * pw_tile_group * 16 + 0;
                                param_index = pw_op * 32 + pw_tile_group * 16 + j;
                                scratch0[pw_store_addr(pw_tile_y, pw_pixel_x(pw_tile_x, i), pw_tile_group * 16 + j, pw_cout, pw_w)] =
                                    requant32(pw_acc[i][j], multiplier_mem[param_index], shift_mem[param_index], 0, 127);
`ifndef SYNTHESIS
                                if ((pw_store_addr(pw_tile_y, pw_pixel_x(pw_tile_x, i), pw_tile_group * 16 + j, pw_cout, pw_w) == 0) && !(pw_tile_y == 0 && pw_tile_x == 0 && pw_tile_group == 0 && i == 0 && j == 0))
                                    $display("D4_SHELL_DBG_ALIAS y=%0d x=%0d i=%0d j=%0d cout=%0d w=%0d", pw_tile_y, pw_tile_x, i, j, pw_cout, pw_w);
`endif
                            end
                        end
                        if (pw_tile_group == 1) begin
                            if ((pw_tile_x + 8) >= pw_w) begin
                                pw_tile_x <= 6'd0;
                                if ((pw_tile_y + 1) >= pw_h) begin
                                    bank0_state_reg <= BANK_READY;
                                    bank1_state_reg <= BANK_FILL;
                                    dw_y <= 6'd0;
                                    dw_x <= 6'd0;
                                    dw_group <= 2'd0;
                                    dw_tap <= 4'd0;
                                    state <= ST_DW_ACQUIRE;
                                end else begin
                                    pw_tile_y <= pw_tile_y + 1;
                                    pw_tile_group <= 2'd0;
                                    pw_k <= 6'd0;
                                    state <= ST_PW_EXP;
                                end
                            end else begin
                                pw_tile_x <= pw_tile_x + 8;
                                pw_tile_group <= 2'd0;
                                pw_k <= 6'd0;
                                state <= ST_PW_EXP;
                            end
                        end else begin
                            pw_tile_group <= 2'd1;
                            pw_k <= 6'd0;
                            state <= ST_PW_EXP;
                        end
                    end

                    ST_DW_ACQUIRE: begin
                        /* READY -> ACTIVE is a visible read-acquire fence;
                         * the producer must never read a bank still marked
                         * FILL. */
                        if (bank0_state_reg == BANK_READY) begin
                            bank0_state_reg <= BANK_ACTIVE;
                            state <= ST_DW;
                        end else begin
                            protocol_errors <= protocol_errors + 1'b1;
                        end
                    end

                    ST_DW: begin
                        for (i = 0; i < 16; i = i + 1) begin
                            /* Do the subtraction after assignment to an
                             * integer.  Subtracting one while dw_tap is an
                             * unsigned packed vector wraps halo coordinates
                             * to 15 instead of producing -1. */
                            iy = dw_y * dw_stride + (dw_tap / 3);
                            ix = dw_x * dw_stride + (dw_tap % 3);
                            iy = iy - 1;
                            ix = ix - 1;
                            if ((iy < 0) || (ix < 0) || (iy >= 32) || (ix >= 32)) begin
                                if (dw_tap == 0)
                                    dw_acc[i] = bias_mem[128 + dw_op * 32 + dw_group * 16 + i];
                                else
                                    dw_acc[i] = dw_acc[i];
                            end else begin
                                source_index = (iy * 32 + ix) * 32 + dw_group * 16 + i;
                                weight_index = dw_op * 288 + (dw_group * 16 + i) * 9 + dw_tap;
                                if (dw_tap == 0)
                                    dw_acc[i] = mul8_term(scratch0[source_index], dw_weight_mem[weight_index]) + bias_mem[128 + dw_op * 32 + dw_group * 16 + i];
                                else
                                    dw_acc[i] = dw_acc[i] + mul8_term(scratch0[source_index], dw_weight_mem[weight_index]);
                            end
                        end
                        dw_mac_count <= dw_mac_count + 16;
                        if (dw_tap == 8)
                            state <= ST_DW_STORE;
                        else
                            dw_tap <= dw_tap + 1'b1;
                    end

                    ST_DW_STORE: begin
                        for (i = 0; i < 16; i = i + 1) begin
                            param_index = 128 + dw_op * 32 + dw_group * 16 + i;
                            scratch1[dw_store_addr(dw_y, dw_x, dw_group * 16 + i, 32, dw_w)] =
                                requant32(dw_acc[i], multiplier_mem[param_index], shift_mem[param_index], 0, 127);
                        end
                        dw_tap <= 4'd0;
                        if (dw_group == 1) begin
                            if ((dw_x + 1) >= dw_w) begin
                                dw_x <= 6'd0;
                                if ((dw_y + 1) >= dw_h) begin
                                    bank0_state_reg <= BANK_FREE;
                                    bank1_state_reg <= BANK_READY;
                                    pw_op <= block_id_reg ? 2'd3 : 2'd1;
                                    pw_src_scratch1 <= 1'b1;
                                    pw_dst_output <= 1'b1;
                                    pw_cin <= 6'd32;
                                    pw_cout <= block_id_reg ? 6'd32 : 6'd16;
                                    pw_h <= dw_h;
                                    pw_w <= dw_w;
                                    pw_src_w <= dw_w;
                                    pw_tile_y <= 6'd0;
                                    pw_tile_x <= 6'd0;
                                    pw_tile_group <= 2'd0;
                                    pw_k <= 6'd0;
                                    state <= ST_PW_PROJ_ACQUIRE;
                                end else begin
                                    dw_y <= dw_y + 1'b1;
                                    dw_group <= 2'd0;
                                    state <= ST_DW;
                                end
                            end else begin
                                dw_x <= dw_x + 1'b1;
                                dw_group <= 2'd0;
                                state <= ST_DW;
                            end
                        end else begin
                            dw_group <= 2'd1;
                            state <= ST_DW;
                        end
                    end

                    ST_PW_PROJ_ACQUIRE: begin
                        /* The project PW cannot consume scratch1 until the
                         * DW commit fence has made the complete image READY. */
                        if (bank1_state_reg == BANK_READY) begin
                            bank1_state_reg <= BANK_ACTIVE;
                            state <= ST_PW_PROJ;
                        end else begin
                            protocol_errors <= protocol_errors + 1'b1;
                        end
                    end

                    ST_PW_PROJ: begin
                        for (i = 0; i < 8; i = i + 1) begin
                            for (j = 0; j < 16; j = j + 1) begin
                                source_index = pw_src_addr(pw_tile_y, pw_pixel_x(pw_tile_x, i), pw_k, pw_cin, pw_src_w);
                                weight_index = pw_weight_addr(pw_op, pw_tile_group, pw_k, pw_cin) + j * pw_cin;
                                param_index = pw_op * 32 + pw_tile_group * 16 + j;
                                pw_acc[i][j] = (pw_k == 0) ?
                                    mul8_term(scratch1[source_index], pw_weight_mem[weight_index]) + bias_mem[param_index] :
                                    pw_acc[i][j] + mul8_term(scratch1[source_index], pw_weight_mem[weight_index]);
                            end
                        end
                        pw_mac_count <= pw_mac_count + 128;
                        if (pw_k == pw_cin - 1)
                            state <= ST_PW_PROJ_STORE;
                        else
                            pw_k <= pw_k + 1'b1;
                    end

                    ST_PW_PROJ_STORE: begin
                        for (i = 0; i < 8; i = i + 1) begin
                            for (j = 0; j < 16; j = j + 1) begin
                                param_index = pw_op * 32 + pw_tile_group * 16 + j;
                                if (pw_tile_group * 16 + j < pw_cout)
                                    output_mem[pw_store_addr(pw_tile_y, pw_pixel_x(pw_tile_x, i), pw_tile_group * 16 + j, pw_cout, pw_w)] =
                                        requant32(pw_acc[i][j], multiplier_mem[param_index], shift_mem[param_index], -128, 127);
                            end
                        end
                        if (pw_tile_group == ((pw_cout / 16) - 1)) begin
                            if ((pw_tile_x + 8) >= pw_w) begin
                                pw_tile_x <= 6'd0;
                                if ((pw_tile_y + 1) >= pw_h) begin
                                    bank1_state_reg <= BANK_FREE;
                                    if (block_id_reg) begin
                                        cursor <= 32'd0;
                                        state <= ST_OUTPUT;
                                    end else begin
                                        residual_cursor <= 32'd0;
                                        state <= ST_RESIDUAL;
                                    end
                                end else begin
                                    pw_tile_y <= pw_tile_y + 1;
                                    pw_tile_group <= 2'd0;
                                    pw_k <= 6'd0;
                                    state <= ST_PW_PROJ;
                                end
                            end else begin
                                pw_tile_x <= pw_tile_x + 8;
                                pw_tile_group <= 2'd0;
                                pw_k <= 6'd0;
                                state <= ST_PW_PROJ;
                            end
                        end else begin
                            pw_tile_group <= pw_tile_group + 1'b1;
                            pw_k <= 6'd0;
                            state <= ST_PW_PROJ;
                        end
                    end

                    ST_RESIDUAL: begin
                        residual_a_q = input_mem[residual_cursor];
                        residual_b_q = output_mem[residual_cursor];
                        output_mem[residual_cursor] <= residual_sum(residual_a_q, residual_b_q);
                        if (residual_cursor == (32 * 32 * 16 - 1)) begin
                            cursor <= 32'd0;
                            state <= ST_OUTPUT;
                        end else begin
                            residual_cursor <= residual_cursor + 1'b1;
                        end
                    end

                    ST_OUTPUT: begin
                        if (out_ready) begin
                            if (cursor == ((block_id_reg ? 16 * 16 * 32 : 32 * 32 * 16) - 1)) begin
                                state <= ST_DONE;
                                done_valid <= 1'b1;
                            end else begin
                                cursor <= cursor + 1'b1;
                            end
                        end
                    end

                    ST_DONE: begin
                        if (done_valid && done_ready) begin
                            bank0_state_reg <= BANK_FREE;
                            bank1_state_reg <= BANK_FREE;
                            state <= ST_IDLE;
                        end
                    end
                    default: state <= ST_IDLE;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
