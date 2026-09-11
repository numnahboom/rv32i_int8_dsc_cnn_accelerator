`timescale 1ns/1ps
`default_nettype none

/*
 * Streaming fully-connected tail.
 *
 * Inputs are retained in a small LUTRAM.  The 10x256 weights are consumed
 * during configuration and accumulated immediately, eliminating the packed
 * 20 Kbit weight register and the 256-MAC combinational datapath.
 */
module fc_unit_new (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               cfg_wr_en,
    output wire               cfg_ready,
    input  wire [3:0]         cfg_target,
    input  wire [15:0]        cfg_index,
    input  wire [31:0]        cfg_data,

    input  wire               start,
    output reg                busy,
    output reg                done,
    output reg                error,
    input  wire signed [31:0] output_zero_point,
    input  wire signed [31:0] activation_min,
    input  wire signed [31:0] activation_max,

    input  wire [3:0]         out_rd_index,
    output wire signed [7:0]  out_rd_data
);
    localparam CFG_INPUT  = 4'd0;
    localparam CFG_WEIGHT = 4'd5;
    localparam CFG_BIAS   = 4'd6;
    localparam CFG_MUL    = 4'd7;
    localparam CFG_SHIFT  = 4'd8;

    localparam ST_IDLE = 2'd0;
    localparam ST_RUN  = 2'd1;
    localparam ST_DRAIN_PRODUCT = 3'd2;
    localparam ST_DRAIN_REQUANT = 3'd3;
    localparam ST_DONE = 3'd4;
    localparam ST_ISSUE_PRODUCT = 3'd5;
    // A start may arrive on the cycle in which the final configuration word
    // is draining through the registered configuration boundary.  Hold the
    // engine here until both config stages have committed; this is a real
    // cycle boundary, not a combinational assumption about the runner.
    localparam ST_CONFIG_COMMIT = 3'd6;

    (* ram_style = "distributed" *)
    reg signed [7:0] input_mem [0:255];
    reg signed [31:0] acc_mem [0:9];
    reg signed [31:0] bias_mem [0:9];
    reg signed [31:0] multiplier_mem [0:9];
    reg [5:0] shift_mem [0:9];
    reg signed [7:0] output_mem [0:9];

    reg [2:0] state;
    reg [3:0] class_idx;
    reg signed [31:0] output_zero_point_reg;
    reg signed [31:0] activation_min_reg;
    reg signed [31:0] activation_max_reg;
    // Requantization is split across two cycles.  The full 64-bit product is
    // retained so the following round/shift stage has exactly the same
    // arithmetic inputs as the original combinational function.
    reg signed [63:0] product_reg;
    // Descriptor-local pre-add register.  Keeping the accumulator+bias carry
    // chain in the cycle before the DSP product removes class-index/LUTRAM
    // selection from the critical product-register path.
    reg signed [32:0] sum_reg;
    reg [3:0] sum_class_reg;
    // Read the class multiplier into a local register one cycle before the
    // DSP product.  Without this boundary, sum_class_reg drives the
    // multiplier LUTRAM address and its output feeds the same-cycle DSP
    // product register (RAMD32 -> DSP48E1).  The class-indexed read still
    // accepts one class per cycle, while the registered operand keeps that
    // memory delay out of the product-register setup path.
    reg signed [31:0] multiplier_operand_reg;
    reg [3:0] product_class_reg;
    reg [5:0] product_shift_reg;
    reg product_valid;
    // Keep the carry-heavy rounding/saturation result out of the LUTRAM
    // write path.  The output memory is read only after done, so this extra
    // local drain cycle does not alter any request, response, or ready/stall
    // transaction.
    (* keep = "true" *)
    reg [3:0] drain_count;

    // Configuration enters through two registered stages.  The first stage
    // cuts the runner's aux_cfg_index/data fanout from the accumulator D
    // pins; the second stage computes the input*weight product before the
    // indexed accumulator update.  Both stages accept one word per cycle.
    reg        cfg_stage0_valid;
    reg [3:0]  cfg_stage0_target;
    reg [15:0] cfg_stage0_index;
    reg [31:0] cfg_stage0_data;
    reg        cfg_stage1_valid;
    reg [3:0]  cfg_stage1_target;
    reg [15:0] cfg_stage1_index;
    reg [31:0] cfg_stage1_data;
    reg signed [15:0] cfg_stage1_product;
    wire [7:0] cfg_stage0_weight_input;
    wire signed [7:0] cfg_stage0_weight;
    wire [3:0] cfg_stage1_weight_class;
    wire cfg_stage_pending;
    wire cfg_accept;
    wire signed [7:0] requant_core_out;
    wire requant_core_valid;
    wire [3:0] requant_core_class;
    integer clear_i;
`ifndef SYNTHESIS
    /* Simulation-only semantic ledger: one accepted FC weight write accounts
     * for one input/output product in the 10x256 tail. */
    integer sim_config_weight_count;
`endif

    assign cfg_ready = !busy;
    assign cfg_stage0_weight_input = cfg_stage0_index[7:0];
    assign cfg_stage0_weight = cfg_stage0_data[7:0];
    assign cfg_stage1_weight_class = cfg_stage1_index[11:8];
    assign cfg_stage_pending = cfg_stage0_valid || cfg_stage1_valid;
    assign cfg_accept = cfg_wr_en && cfg_ready;
    assign out_rd_data =
        (out_rd_index < 4'd10) ? output_mem[out_rd_index] : 8'sd0;

    requant_product_pipeline u_requant_core (
        .clk(clk), .rst_n(rst_n), .valid_in(product_valid),
        .product_int64(product_reg),
        .shift(product_shift_reg),
        .output_zero_point_int32(output_zero_point_reg),
        .activation_min_int32(activation_min_reg),
        .activation_max_int32(activation_max_reg),
        .tag_in(product_class_reg), .valid_out(requant_core_valid),
        .tag_out(requant_core_class), .output_int8(requant_core_out)
    );

    always @(posedge clk) begin
`ifndef SYNTHESIS
        if (!rst_n)
            sim_config_weight_count <= 0;
        else if (cfg_accept && (cfg_target == CFG_WEIGHT) &&
                 (cfg_index < 16'd2560) && (cfg_index[11:8] < 4'd10))
            sim_config_weight_count <= sim_config_weight_count + 1;
`endif

        if (!rst_n) begin
            cfg_stage0_valid <= 1'b0;
            cfg_stage0_target <= 4'd0;
            cfg_stage0_index <= 16'd0;
            cfg_stage0_data <= 32'd0;
            cfg_stage1_valid <= 1'b0;
            cfg_stage1_target <= 4'd0;
            cfg_stage1_index <= 16'd0;
            cfg_stage1_data <= 32'd0;
            cfg_stage1_product <= 16'sd0;
        end else begin
            // Stage 2 consumes the already-registered stage-1 command.  A
            // stage-0 capture may occur on the same edge, preserving one
            // accepted configuration word per cycle.
            cfg_stage1_valid <= cfg_stage0_valid;
            if (cfg_stage0_valid) begin
                cfg_stage1_target <= cfg_stage0_target;
                cfg_stage1_index <= cfg_stage0_index;
                cfg_stage1_data <= cfg_stage0_data;
                if (cfg_stage0_target == CFG_WEIGHT)
                    cfg_stage1_product <=
                        input_mem[cfg_stage0_weight_input] *
                        cfg_stage0_weight;
                else
                    cfg_stage1_product <= 16'sd0;
            end

            cfg_stage0_valid <= cfg_accept;
            if (cfg_accept) begin
                cfg_stage0_target <= cfg_target;
                cfg_stage0_index <= cfg_index;
                cfg_stage0_data <= cfg_data;
            end

            if (cfg_stage1_valid) begin
                case (cfg_stage1_target)
                CFG_INPUT: begin
                    if (cfg_stage1_index < 16'd256) begin
                        input_mem[cfg_stage1_index[7:0]] <=
                            cfg_stage1_data[7:0];
                    end
                    if (cfg_stage1_index == 16'd0) begin
                        for (clear_i = 0; clear_i < 10; clear_i = clear_i + 1) begin
                            acc_mem[clear_i] <= 32'sd0;
                        end
                    end
                end
                CFG_WEIGHT: begin
                    if ((cfg_stage1_index < 16'd2560) &&
                        (cfg_stage1_weight_class < 4'd10)) begin
                        acc_mem[cfg_stage1_weight_class] <=
                            acc_mem[cfg_stage1_weight_class] +
                            {{16{cfg_stage1_product[15]}},
                             cfg_stage1_product};
                    end
                end
                CFG_BIAS: begin
                    if (cfg_stage1_index < 16'd10) begin
                        bias_mem[cfg_stage1_index[3:0]] <= cfg_stage1_data;
                    end
                end
                CFG_MUL: begin
                    if (cfg_stage1_index < 16'd10) begin
                        multiplier_mem[cfg_stage1_index[3:0]] <=
                            cfg_stage1_data;
                    end
                end
                CFG_SHIFT: begin
                    if (cfg_stage1_index < 16'd10) begin
                        shift_mem[cfg_stage1_index[3:0]] <=
                            cfg_stage1_data[5:0];
                    end
                end
                default: begin
                end
                endcase
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            class_idx <= 4'd0;
            output_zero_point_reg <= 32'sd0;
            activation_min_reg <= -32'sd128;
            activation_max_reg <= 32'sd127;
            product_reg <= 64'sd0;
            sum_reg <= 33'sd0;
            sum_class_reg <= 4'd0;
            multiplier_operand_reg <= 32'sd0;
            product_class_reg <= 4'd0;
            product_shift_reg <= 6'd0;
            product_valid <= 1'b0;
            drain_count <= 4'd0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        error <= 1'b0;
                        class_idx <= 4'd0;
                        output_zero_point_reg <= output_zero_point;
                        activation_min_reg <= activation_min;
                        activation_max_reg <= activation_max;
                        product_valid <= 1'b0;
                        if (cfg_stage_pending || cfg_accept)
                            state <= ST_CONFIG_COMMIT;
                        else
                            state <= ST_RUN;
                    end
                end

                ST_CONFIG_COMMIT: begin
                    // The config pipeline owns the final write for this
                    // transaction.  Do not let the first accumulator/bias
                    // read bypass an in-flight stage-0 or stage-1 command.
                    if (!cfg_stage_pending)
                        state <= ST_RUN;
                end

                ST_RUN: begin
                    // Advance the product/requant/writeback pipeline while
                    // forming the next class product.  Each class result is
                    // written exactly once, in class order.
                    if (requant_core_valid) begin
                        output_mem[requant_core_class] <= requant_core_out;
                    end
                    sum_reg <=
                        ({{32{acc_mem[class_idx][31]}}, acc_mem[class_idx]} +
                         {{32{bias_mem[class_idx][31]}}, bias_mem[class_idx]});
                    sum_class_reg <= class_idx;
                    multiplier_operand_reg <= multiplier_mem[class_idx];
                    product_valid <= 1'b0;
                    state <= ST_ISSUE_PRODUCT;
                end

                ST_ISSUE_PRODUCT: begin
                    if (requant_core_valid) begin
                        output_mem[requant_core_class] <= requant_core_out;
                    end
                    product_reg <=
                        {{31{sum_reg[32]}}, sum_reg} *
                        {{32{multiplier_operand_reg[31]}}, multiplier_operand_reg};
                    product_class_reg <= sum_class_reg;
                    product_shift_reg <= shift_mem[sum_class_reg];
                    product_valid <= 1'b1;
                    if (sum_class_reg == 4'd9) begin
                        state <= ST_DRAIN_PRODUCT;
                    end else begin
                        class_idx <= class_idx + 4'd1;
                        state <= ST_RUN;
                    end
                end

                ST_DRAIN_PRODUCT: begin
                    product_valid <= 1'b0;
                    drain_count <= 4'd0;
                    state <= ST_DRAIN_REQUANT;
                end

                ST_DRAIN_REQUANT: begin
                    if (requant_core_valid) begin
                        output_mem[requant_core_class] <= requant_core_out;
                    end
                    if (drain_count == 4'd7) state <= ST_DONE;
                    else drain_count <= drain_count + 4'd1;
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    error <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
