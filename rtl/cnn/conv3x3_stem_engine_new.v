`timescale 1ns/1ps
`default_nettype none

/*
 * Resource-oriented 3x3 stem.
 *
 * Input/parameter payloads are written through a scalar configuration port.
 * Three signed 8x8 MACs process the three input channels in parallel.  The
 * datapath therefore needs nine cycles per output instead of 27 while still
 * avoiding the original 27-way combinational expansion.
 */
module conv3x3_stem_engine_new (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               cfg_wr_en,
    output wire               cfg_ready,
    input  wire [3:0]         cfg_target,
    input  wire [15:0]        cfg_index,
    input  wire [31:0]        cfg_data,
    input  wire               cfg_vec4_wr_en,
    input  wire [15:0]        cfg_vec4_index,
    input  wire [31:0]        cfg_vec4_data,

    input  wire               start,
    output reg                busy,
    output reg                done,
    output reg                error,

    input  wire [3:0]         out_h,
    input  wire [3:0]         out_w,
    input  wire signed [31:0] output_zero_point,
    input  wire signed [31:0] activation_min,
    input  wire signed [31:0] activation_max,

    output reg                out_wr_en,
    output reg [5:0]          out_wr_pixel_idx,
    output reg [3:0]          out_wr_channel_idx,
    output reg signed [7:0]   out_wr_data_int8
);
    localparam CFG_INPUT     = 4'd0;
    localparam CFG_WEIGHT    = 4'd1;
    localparam CFG_BIAS      = 4'd2;
    localparam CFG_MUL       = 4'd3;
    localparam CFG_SHIFT     = 4'd4;

    localparam ST_IDLE       = 4'd0;
    localparam ST_MAC        = 4'd1;
    // Capture the MAC result and its independent bias/parameters before
    // issuing the shared, registered-input requantizer.  The unit itself
    // forms the signed 33-bit accumulator+bias sum; keeping these operands
    // separate avoids truncating that sum at the Stem boundary.
    localparam ST_RQ_SUM     = 4'd2;
    localparam ST_RQ_ISSUE   = 4'd3;
    localparam ST_RQ_DRAIN   = 4'd4;
    localparam ST_DONE       = 4'd5;
    localparam ST_ERROR      = 4'd6;
    // Register the three-product sum before the carry-save compressor.  This
    // removes the operand/multiplier/product adder cone from the accumulator
    // register's timing path while retaining one MAC tap per ST_MAC cycle.
    localparam ST_CSA_DRAIN  = 4'd7;
    localparam ST_CSA_DRAIN2 = 4'd9;
    // Read the distributed-RAM operands in a separate cycle.  This keeps the
    // high-fanout cursor/address net out of the accumulator's MAC adder path.
    // First read is issued here.  Subsequent reads are issued from ST_MAC
    // while the preceding registered operand is consumed, so the tap stream
    // has II=1 after the one-cycle fill.
    localparam ST_OPERAND     = 4'd8;

    // The three byte positions of each input/weight triplet are independent
    // synchronous-read banks.  Cursors are in triplet words (not byte
    // addresses), avoiding a dynamic divide in the timing-critical read
    // address path.  The explicit output registers below also make this
    // implementation portable to inferred RAM/LUTRAM and XPM replacements.
    (* ram_style = "distributed" *)
    reg signed [7:0] input_mem_lane0 [0:99];
    (* ram_style = "distributed" *)
    reg signed [7:0] input_mem_lane1 [0:99];
    (* ram_style = "distributed" *)
    reg signed [7:0] input_mem_lane2 [0:99];
    (* ram_style = "distributed" *)
    reg signed [7:0] weight_mem_lane0 [0:143];
    (* ram_style = "distributed" *)
    reg signed [7:0] weight_mem_lane1 [0:143];
    (* ram_style = "distributed" *)
    reg signed [7:0] weight_mem_lane2 [0:143];
    reg signed [31:0] bias_mem [0:15];
    reg signed [31:0] multiplier_mem [0:15];
    reg [5:0] shift_mem [0:15];

    reg [3:0] state;
    reg [3:0] out_h_reg;
    reg [3:0] out_w_reg;
    reg signed [31:0] output_zero_point_reg;
    reg signed [31:0] activation_min_reg;
    reg signed [31:0] activation_max_reg;
    reg [5:0] pixel_idx;
    reg [3:0] channel_idx;
    reg [3:0] out_y_idx;
    reg [3:0] out_x_idx;
    reg [1:0] kernel_y_idx;
    reg [1:0] kernel_x_idx;
    // Registered triplet-word cursors.  input_pixel_base remains at the
    // top-left triplet for the current output pixel; input_addr_cursor and
    // weight_addr_cursor walk input and weight triplets respectively.
    reg [8:0] input_pixel_base;
    reg [8:0] input_addr_cursor;
    reg [8:0] weight_addr_cursor;
    // Carry-save accumulator for the nine tap sums.  The two registers
    // encode the exact two's-complement value as
    //   acc_csa_sum_reg + acc_csa_carry_reg
    // where carry_reg[0] is always zero.  Keeping the carry shifted by one
    // bit makes every MAC update a local 3:2 compression (no carry chain).
    // The binary value is reconstructed only at the requant handoff.
    reg [31:0] acc_csa_sum_reg;
    reg [31:0] acc_csa_carry_reg;
    reg signed [17:0] product_sum_acc_reg;
    reg               product_sum_valid_q;
    // Product registers isolate the 8x8 operand multiply network from the
    // three-product adder.  The latter is then registered before entering
    // the CSA, leaving each timing arc to one arithmetic stage.
    reg signed [15:0] product_value_0_acc_reg;
    reg signed [15:0] product_value_1_acc_reg;
    reg signed [15:0] product_value_2_acc_reg;
    reg               product_stage_valid_q;
    // Synchronous-read output registers and their valid/coordinate tag.
    reg signed [7:0] operand_act_0_q;
    reg signed [7:0] operand_act_1_q;
    reg signed [7:0] operand_act_2_q;
    reg signed [7:0] operand_weight_0_q;
    reg signed [7:0] operand_weight_1_q;
    reg signed [7:0] operand_weight_2_q;
    reg              operand_valid_q;
    reg              operand_last_q;
    reg [5:0]        operand_pixel_q;
    reg [3:0]        operand_channel_q;
    reg signed [31:0] rq_acc_reg;
    reg signed [31:0] rq_bias_reg;
    reg signed [31:0] rq_multiplier_reg;
    reg [5:0] rq_shift_reg;
    reg signed [31:0] rq_zero_point_reg;
    reg signed [31:0] rq_activation_min_reg;
    reg signed [31:0] rq_activation_max_reg;
    reg [5:0] rq_pixel_idx_reg;
    reg [3:0] rq_channel_idx_reg;
    reg [5:0] last_pixel_idx_reg;

    // The shared requantizer is throughput-one and is never backpressured in
    // this engine.  A ten-entry tag pipe follows valid_in exactly, preserving
    // pixel/channel ordering while the next channel's MAC is already active.
    wire rq_valid_in;
    wire rq_unit_ready_in;
    wire rq_ready_out;
    wire rq_valid_out;
    wire signed [7:0] rq_data_out;
    reg [5:0] rq_tag_pixel [0:9];
    reg [3:0] rq_tag_channel [0:9];
`ifndef SYNTHESIS
    /* Simulation-only semantic ledger: one registered tap group contains the
     * three input-channel products of one 3x3 stem tap. */
    integer sim_mac_count;
`endif

    wire signed [7:0] act_value_0 = operand_act_0_q;
    wire signed [7:0] act_value_1 = operand_act_1_q;
    wire signed [7:0] act_value_2 = operand_act_2_q;
    wire signed [7:0] weight_value_0 = operand_weight_0_q;
    wire signed [7:0] weight_value_1 = operand_weight_1_q;
    wire signed [7:0] weight_value_2 = operand_weight_2_q;
    wire signed [15:0] product_value_0;
    wire signed [15:0] product_value_1;
    wire signed [15:0] product_value_2;
    wire signed [17:0] product_sum;
    wire [31:0] product_sum_ext;
    wire [31:0] product_sum_acc_ext;
    wire signed [17:0] product_sum_from_regs;
    wire [31:0] acc_csa_majority;
    wire [31:0] acc_csa_sum_next;
    wire [31:0] acc_csa_carry_next;
    wire signed [31:0] acc_csa_exact;
    wire [8:0] row_wrap_increment;

    integer cfg_addr;
    integer i;

    // Configuration writes arrive while the runner is streaming the source
    // tensor.  Register the ingress payload before decoding its bank/address;
    // this keeps the wide runner-side cfg_index fanout off the distributed
    // memory write enables while retaining one scalar and one vector write per
    // cycle.  The pending slots are drained and refilled on the same edge.
    reg        cfg_pending;
    reg [3:0]  cfg_pending_target;
    reg [15:0] cfg_pending_index;
    reg [31:0] cfg_pending_data;
    reg        cfg_vec4_pending;
    reg [15:0] cfg_vec4_pending_index;
    reg [31:0] cfg_vec4_pending_data;
    // Decode the byte-linear vector address at ingress.  The pending write
    // retires one cycle later, so retaining the word/lane fields removes the
    // divide/modulo cone from the cfg_vec4_pending_index -> input-memory
    // write boundary without changing the one-write-per-cycle contract.
    reg [8:0]  cfg_vec4_pending_word;
    reg [1:0]  cfg_vec4_pending_lane;
    reg        cfg_vec4_pending_valid;

    assign cfg_ready = !busy;
    assign rq_valid_in = (state == ST_RQ_ISSUE) && rq_unit_ready_in;
    // The output is consumed every cycle, so the elastic unit remains in its
    // normal no-stall mode.  This also makes the overlap contract explicit.
    assign rq_ready_out = 1'b1;
    // In triplet words, a row is ten words wide for the 10x10 stem input.
    assign row_wrap_increment = 9'd10 - ({5'd0, out_w_reg} - 9'd1);
    assign product_value_0 = act_value_0 * weight_value_0;
    assign product_value_1 = act_value_1 * weight_value_1;
    assign product_value_2 = act_value_2 * weight_value_2;
    assign product_sum = {{2{product_value_0[15]}}, product_value_0} +
                         {{2{product_value_1[15]}}, product_value_1} +
                         {{2{product_value_2[15]}}, product_value_2};
    // All nine signed 8x8 products fit comfortably in 32 bits.  Explicit
    // sign extension is important here: the CSA is bitwise and does not
    // carry signedness metadata through its compressor.
    assign product_sum_ext = {{14{product_sum[17]}}, product_sum};
    assign product_sum_acc_ext = {{14{product_sum_acc_reg[17]}},
                                  product_sum_acc_reg};
    assign product_sum_from_regs =
        {{2{product_value_0_acc_reg[15]}}, product_value_0_acc_reg} +
        {{2{product_value_1_acc_reg[15]}}, product_value_1_acc_reg} +
        {{2{product_value_2_acc_reg[15]}}, product_value_2_acc_reg};
    assign acc_csa_majority = (acc_csa_sum_reg & acc_csa_carry_reg) |
                              (acc_csa_sum_reg & product_sum_acc_ext) |
                              (acc_csa_carry_reg & product_sum_acc_ext);
    assign acc_csa_sum_next = acc_csa_sum_reg ^ acc_csa_carry_reg ^
                              product_sum_acc_ext;
    // Bit zero is the implicit zero carry-in.  A top carry is discarded as
    // normal 32-bit two's-complement modular arithmetic; the stem's maximum
    // nine-tap sum is only +/-435,483, so no mathematical overflow occurs.
    assign acc_csa_carry_next = {acc_csa_majority[30:0], 1'b0};
    assign acc_csa_exact = $signed(acc_csa_sum_reg) +
                           $signed(acc_csa_carry_reg);
    requant_activation_unit u_stem_requant (
        .clk(clk), .rst_n(rst_n),
        .valid_in(rq_valid_in), .ready_in(rq_unit_ready_in),
        .acc_int32(rq_acc_reg), .bias_int32(rq_bias_reg),
        .multiplier_int32(rq_multiplier_reg), .shift(rq_shift_reg),
        .output_zero_point_int32(rq_zero_point_reg),
        .activation_min_int32(rq_activation_min_reg),
        .activation_max_int32(rq_activation_max_reg),
        .ready_out(rq_ready_out), .valid_out(rq_valid_out),
        .output_int8(rq_data_out)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_pending <= 1'b0;
            cfg_pending_target <= 4'd0;
            cfg_pending_index <= 16'd0;
            cfg_pending_data <= 32'd0;
            cfg_vec4_pending <= 1'b0;
            cfg_vec4_pending_index <= 16'd0;
            cfg_vec4_pending_data <= 32'd0;
            cfg_vec4_pending_word <= 9'd0;
            cfg_vec4_pending_lane <= 2'd0;
            cfg_vec4_pending_valid <= 1'b0;
        end else begin
            // Retire the previously captured scalar write.  The ingress
            // registers, rather than the runner's live cfg bus, drive all
            // address arithmetic and memory enables in this block.
            if (cfg_pending) begin
                cfg_addr = cfg_pending_index;
                case (cfg_pending_target)
                    CFG_INPUT: begin
                        if (cfg_addr < 300) begin
                            case (cfg_addr % 3)
                                0: input_mem_lane0[cfg_addr / 3] <= cfg_pending_data[7:0];
                                1: input_mem_lane1[cfg_addr / 3] <= cfg_pending_data[7:0];
                                default: input_mem_lane2[cfg_addr / 3] <= cfg_pending_data[7:0];
                            endcase
                        end
                    end
                    CFG_WEIGHT: begin
                        if (cfg_addr < 432) begin
                            case (cfg_addr % 3)
                                0: weight_mem_lane0[cfg_addr / 3] <= cfg_pending_data[7:0];
                                1: weight_mem_lane1[cfg_addr / 3] <= cfg_pending_data[7:0];
                                default: weight_mem_lane2[cfg_addr / 3] <= cfg_pending_data[7:0];
                            endcase
                        end
                    end
                    CFG_BIAS: begin
                        if (cfg_addr < 16)
                            bias_mem[cfg_addr] <= cfg_pending_data;
                    end
                    CFG_MUL: begin
                        if (cfg_addr < 16)
                            multiplier_mem[cfg_addr] <= cfg_pending_data;
                    end
                    CFG_SHIFT: begin
                        if (cfg_addr < 16)
                            shift_mem[cfg_addr] <= cfg_pending_data[5:0];
                    end
                    default: begin
                    end
                endcase
            end

            if (cfg_vec4_pending) begin
                if (cfg_vec4_pending_valid) begin
                    // A four-byte write can cross up to four banks.  The
                    // vector loader uses byte-linear indices, so spell out
                    // the three possible starting lanes exactly as before.
                    // The word/lane decode was committed with the pending
                    // payload; no variable divide remains on this write edge.
                    case (cfg_vec4_pending_lane)
                        0: begin
                            input_mem_lane0[cfg_vec4_pending_word] <= cfg_vec4_pending_data[7:0];
                            input_mem_lane1[cfg_vec4_pending_word] <= cfg_vec4_pending_data[15:8];
                            input_mem_lane2[cfg_vec4_pending_word] <= cfg_vec4_pending_data[23:16];
                            input_mem_lane0[cfg_vec4_pending_word + 9'd1] <= cfg_vec4_pending_data[31:24];
                        end
                        1: begin
                            input_mem_lane1[cfg_vec4_pending_word] <= cfg_vec4_pending_data[7:0];
                            input_mem_lane2[cfg_vec4_pending_word] <= cfg_vec4_pending_data[15:8];
                            input_mem_lane0[cfg_vec4_pending_word + 9'd1] <= cfg_vec4_pending_data[23:16];
                            input_mem_lane1[cfg_vec4_pending_word + 9'd1] <= cfg_vec4_pending_data[31:24];
                        end
                        default: begin
                            input_mem_lane2[cfg_vec4_pending_word] <= cfg_vec4_pending_data[7:0];
                            input_mem_lane0[cfg_vec4_pending_word + 9'd1] <= cfg_vec4_pending_data[15:8];
                            input_mem_lane1[cfg_vec4_pending_word + 9'd1] <= cfg_vec4_pending_data[23:16];
                            input_mem_lane2[cfg_vec4_pending_word + 9'd1] <= cfg_vec4_pending_data[31:24];
                        end
                    endcase
                end
            end

            // Clear after retirement, then let a same-cycle accepted write
            // refill the slot.  This gives the ingress an II of one even when
            // scalar/vector writes arrive on consecutive cycles.
            cfg_pending <= 1'b0;
            cfg_vec4_pending <= 1'b0;
            if (cfg_wr_en && cfg_ready) begin
                cfg_pending <= 1'b1;
                cfg_pending_target <= cfg_target;
                cfg_pending_index <= cfg_index;
                cfg_pending_data <= cfg_data;
            end
            if (cfg_vec4_wr_en && cfg_ready) begin
                cfg_vec4_pending <= 1'b1;
                cfg_vec4_pending_index <= cfg_vec4_index;
                cfg_vec4_pending_data <= cfg_vec4_data;
                cfg_vec4_pending_word <= cfg_vec4_index / 16'd3;
                cfg_vec4_pending_lane <= cfg_vec4_index % 16'd3;
                cfg_vec4_pending_valid <= (cfg_vec4_index < 16'd297);
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            out_h_reg <= 4'd0;
            out_w_reg <= 4'd0;
            output_zero_point_reg <= 32'sd0;
            activation_min_reg <= -32'sd128;
            activation_max_reg <= 32'sd127;
            pixel_idx <= 6'd0;
            channel_idx <= 4'd0;
            out_y_idx <= 4'd0;
            out_x_idx <= 4'd0;
            kernel_y_idx <= 2'd0;
            kernel_x_idx <= 2'd0;
            input_pixel_base <= 9'd0;
            input_addr_cursor <= 9'd0;
            weight_addr_cursor <= 9'd0;
            acc_csa_sum_reg <= 32'd0;
            acc_csa_carry_reg <= 32'd0;
            product_sum_acc_reg <= 18'sd0;
            product_sum_valid_q <= 1'b0;
            product_value_0_acc_reg <= 16'sd0;
            product_value_1_acc_reg <= 16'sd0;
            product_value_2_acc_reg <= 16'sd0;
            product_stage_valid_q <= 1'b0;
            operand_act_0_q <= 8'sd0;
            operand_act_1_q <= 8'sd0;
            operand_act_2_q <= 8'sd0;
            operand_weight_0_q <= 8'sd0;
            operand_weight_1_q <= 8'sd0;
            operand_weight_2_q <= 8'sd0;
            operand_valid_q <= 1'b0;
            operand_last_q <= 1'b0;
            operand_pixel_q <= 6'd0;
            operand_channel_q <= 4'd0;
            rq_acc_reg <= 32'sd0;
            rq_bias_reg <= 32'sd0;
            rq_multiplier_reg <= 32'sd0;
            rq_shift_reg <= 6'd0;
            rq_zero_point_reg <= 32'sd0;
            rq_activation_min_reg <= -32'sd128;
            rq_activation_max_reg <= 32'sd127;
            rq_pixel_idx_reg <= 6'd0;
            rq_channel_idx_reg <= 4'd0;
            last_pixel_idx_reg <= 6'd0;
            for (i = 0; i < 10; i = i + 1) begin
                rq_tag_pixel[i] <= 6'd0;
                rq_tag_channel[i] <= 4'd0;
            end
            out_wr_en <= 1'b0;
            out_wr_pixel_idx <= 6'd0;
            out_wr_channel_idx <= 4'd0;
            out_wr_data_int8 <= 8'sd0;
`ifndef SYNTHESIS
            sim_mac_count <= 0;
`endif
        end else begin
            done <= 1'b0;
            out_wr_en <= 1'b0;

            // Unit latency is ten registered stages.  Shift tags in the
            // same clocked process as the unit's valid pipeline.  Since the
            // unit is always ready, bubbles need no valid tag bit: unit
            // valid_out gates the write and stale tags are harmless.
            for (i = 1; i < 10; i = i + 1) begin
                rq_tag_pixel[i] <= rq_tag_pixel[i-1];
                rq_tag_channel[i] <= rq_tag_channel[i-1];
            end
            if (rq_valid_in) begin
                rq_tag_pixel[0] <= rq_pixel_idx_reg;
                rq_tag_channel[0] <= rq_channel_idx_reg;
            end

            // Output writes are independent of the MAC FSM.  This is the
            // actual overlap: the ten-stage unit drains while the next
            // channel's nine MAC taps are being consumed.
            if (rq_valid_out) begin
                out_wr_en <= 1'b1;
                out_wr_pixel_idx <= rq_tag_pixel[9];
                out_wr_channel_idx <= rq_tag_channel[9];
                out_wr_data_int8 <= rq_data_out;
            end
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        if ((out_h == 4'd0) || (out_w == 4'd0) ||
                            ((out_h * out_w) > 8'd64)) begin
                            busy <= 1'b1;
                            error <= 1'b1;
                            state <= ST_ERROR;
                        end else begin
                            busy <= 1'b1;
                            error <= 1'b0;
                            out_h_reg <= out_h;
                            out_w_reg <= out_w;
                            output_zero_point_reg <= output_zero_point;
                            activation_min_reg <= activation_min;
                            activation_max_reg <= activation_max;
                            pixel_idx <= 6'd0;
                            channel_idx <= 4'd0;
                            out_y_idx <= 4'd0;
                            out_x_idx <= 4'd0;
                            kernel_y_idx <= 2'd0;
                            kernel_x_idx <= 2'd0;
                            input_pixel_base <= 9'd0;
                            input_addr_cursor <= 9'd0;
                            weight_addr_cursor <= 9'd0;
                            acc_csa_sum_reg <= 32'd0;
                            acc_csa_carry_reg <= 32'd0;
                            product_sum_acc_reg <= 18'sd0;
                            product_sum_valid_q <= 1'b0;
                            product_value_0_acc_reg <= 16'sd0;
                            product_value_1_acc_reg <= 16'sd0;
                            product_value_2_acc_reg <= 16'sd0;
                            product_stage_valid_q <= 1'b0;
                            last_pixel_idx_reg <= (out_h * out_w) - 6'd1;
                            operand_valid_q <= 1'b0;
                            state <= ST_OPERAND;
                        end
                    end
                end

                ST_OPERAND: begin
                    // Synchronous registered read.  This is the one-cycle
                    // pipeline fill; ST_MAC consumes these operands and
                    // issues the next address in the same clock edge.
                    operand_act_0_q <= input_mem_lane0[input_addr_cursor];
                    operand_act_1_q <= input_mem_lane1[input_addr_cursor];
                    operand_act_2_q <= input_mem_lane2[input_addr_cursor];
                    operand_weight_0_q <= weight_mem_lane0[weight_addr_cursor];
                    operand_weight_1_q <= weight_mem_lane1[weight_addr_cursor];
                    operand_weight_2_q <= weight_mem_lane2[weight_addr_cursor];
                    operand_valid_q <= 1'b1;
                    operand_last_q <= (kernel_y_idx == 2'd2) &&
                                      (kernel_x_idx == 2'd2);
                    operand_pixel_q <= pixel_idx;
                    operand_channel_q <= channel_idx;
                    state <= ST_MAC;
                end

                ST_MAC: begin
                    // Consume the registered operands.  The product/sum is
                    // formed and accumulated once per tap; the operand
                    // registers are refilled for the following tap in the
                    // same edge, preserving one tap per cycle after fill.
                    if (operand_valid_q) begin
`ifndef SYNTHESIS
                        sim_mac_count <= sim_mac_count + 3;
`endif
                        // The registered product sum is consumed one cycle
                        // later.  The first tap fills this stage; subsequent
                        // taps both consume and refill it (II=1).
                        product_value_0_acc_reg <= product_value_0;
                        product_value_1_acc_reg <= product_value_1;
                        product_value_2_acc_reg <= product_value_2;
                        product_stage_valid_q <= 1'b1;
                        if (product_stage_valid_q) begin
                            product_sum_acc_reg <= product_sum_from_regs;
                            product_sum_valid_q <= 1'b1;
                        end
                        if (product_sum_valid_q) begin
                            acc_csa_sum_reg <= acc_csa_sum_next;
                            acc_csa_carry_reg <= acc_csa_carry_next;
                        end
                    end
                    if (operand_last_q) begin
                        operand_valid_q <= 1'b0;
                        state <= ST_CSA_DRAIN;
                    end else begin
                        if (kernel_x_idx == 2'd2) begin
                            kernel_x_idx <= 2'd0;
                            kernel_y_idx <= kernel_y_idx + 2'd1;
                            input_addr_cursor <= input_addr_cursor + 9'd8;
                            operand_act_0_q <= input_mem_lane0[input_addr_cursor + 9'd8];
                            operand_act_1_q <= input_mem_lane1[input_addr_cursor + 9'd8];
                            operand_act_2_q <= input_mem_lane2[input_addr_cursor + 9'd8];
                        end else begin
                            kernel_x_idx <= kernel_x_idx + 2'd1;
                            input_addr_cursor <= input_addr_cursor + 9'd1;
                            operand_act_0_q <= input_mem_lane0[input_addr_cursor + 9'd1];
                            operand_act_1_q <= input_mem_lane1[input_addr_cursor + 9'd1];
                            operand_act_2_q <= input_mem_lane2[input_addr_cursor + 9'd1];
                        end
                        weight_addr_cursor <= weight_addr_cursor + 9'd1;
                        operand_weight_0_q <= weight_mem_lane0[weight_addr_cursor + 9'd1];
                        operand_weight_1_q <= weight_mem_lane1[weight_addr_cursor + 9'd1];
                        operand_weight_2_q <= weight_mem_lane2[weight_addr_cursor + 9'd1];
                        operand_last_q <= (kernel_y_idx == 2'd2) &&
                                          (kernel_x_idx == 2'd1);
                        operand_pixel_q <= pixel_idx;
                        operand_channel_q <= channel_idx;
                    end
                end

                ST_CSA_DRAIN: begin
                    // Consume the ninth and final registered product before
                    // reconstructing the exact accumulator in ST_RQ_SUM.
                    if (product_sum_valid_q) begin
                        acc_csa_sum_reg <= acc_csa_sum_next;
                        acc_csa_carry_reg <= acc_csa_carry_next;
                    end
                    // The final tap is still in the product registers.  Form
                    // and register its three-product sum while consuming the
                    // preceding sum, then use ST_CSA_DRAIN2 for the final
                    // carry-save update.
                    if (product_stage_valid_q) begin
                        product_sum_acc_reg <= product_sum_from_regs;
                        product_sum_valid_q <= 1'b1;
                        product_stage_valid_q <= 1'b0;
                    end
                    state <= ST_CSA_DRAIN2;
                end

                ST_CSA_DRAIN2: begin
                    if (product_sum_valid_q) begin
                        acc_csa_sum_reg <= acc_csa_sum_next;
                        acc_csa_carry_reg <= acc_csa_carry_next;
                        product_sum_valid_q <= 1'b0;
                    end
                    state <= ST_RQ_SUM;
                end

                ST_RQ_SUM: begin
                    // Capture accumulator and bias independently.  The
                    // requant unit performs their signed 33-bit addition;
                    // never pre-add/truncate the sum to 32 bits here.
                    rq_acc_reg <= acc_csa_exact;
                    rq_bias_reg <= bias_mem[channel_idx];
                    rq_multiplier_reg <= multiplier_mem[channel_idx];
                    rq_shift_reg <= shift_mem[channel_idx];
                    rq_zero_point_reg <= output_zero_point_reg;
                    rq_activation_min_reg <= activation_min_reg;
                    rq_activation_max_reg <= activation_max_reg;
                    rq_pixel_idx_reg <= operand_pixel_q;
                    rq_channel_idx_reg <= operand_channel_q;
                    state <= ST_RQ_ISSUE;
                end

                ST_RQ_ISSUE: begin
                    // valid_in is asserted combinationally in this state;
                    // at this edge the unit accepts the captured operands.
                    kernel_y_idx <= 2'd0;
                    kernel_x_idx <= 2'd0;
                    acc_csa_sum_reg <= 32'd0;
                    acc_csa_carry_reg <= 32'd0;
                    product_sum_acc_reg <= 18'sd0;
                    product_sum_valid_q <= 1'b0;
                    product_value_0_acc_reg <= 16'sd0;
                    product_value_1_acc_reg <= 16'sd0;
                    product_value_2_acc_reg <= 16'sd0;
                    product_stage_valid_q <= 1'b0;
                    if (rq_channel_idx_reg == 4'd15) begin
                        channel_idx <= 4'd0;
                        if ((out_y_idx + 4'd1 >= out_h_reg) &&
                            (out_x_idx + 4'd1 >= out_w_reg)) begin
                            // The final output is still inside the unit.
                            // Drain by tag before dropping busy/done.
                            state <= ST_RQ_DRAIN;
                        end else begin
                            pixel_idx <= pixel_idx + 6'd1;
                            if ((out_x_idx + 4'd1) >= out_w_reg) begin
                                out_x_idx <= 4'd0;
                                out_y_idx <= out_y_idx + 4'd1;
                                input_pixel_base <= input_pixel_base + row_wrap_increment;
                                input_addr_cursor <= input_pixel_base + row_wrap_increment;
                            end else begin
                                out_x_idx <= out_x_idx + 4'd1;
                                input_pixel_base <= input_pixel_base + 9'd1;
                                input_addr_cursor <= input_pixel_base + 9'd1;
                            end
                            weight_addr_cursor <= 9'd0;
                            state <= ST_OPERAND;
                        end
                    end else begin
                        channel_idx <= channel_idx + 4'd1;
                        input_addr_cursor <= input_pixel_base;
                        // The completed channel ended at tap group +8;
                        // advance one group to the next channel's base.
                        weight_addr_cursor <= weight_addr_cursor + 9'd1;
                        state <= ST_OPERAND;
                    end
                end

                ST_RQ_DRAIN: begin
                    // The unit preserves issue order.  Waiting for the
                    // final pixel/channel tag guarantees every preceding
                    // output pulse has also been emitted.
                    if (rq_valid_out &&
                        (rq_tag_pixel[9] == last_pixel_idx_reg) &&
                        (rq_tag_channel[9] == 4'd15)) begin
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
