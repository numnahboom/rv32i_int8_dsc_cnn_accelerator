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
    localparam ST_DONE = 2'd2;

    (* ram_style = "distributed" *)
    reg signed [7:0] input_mem [0:255];
    reg signed [31:0] acc_mem [0:9];
    reg signed [31:0] bias_mem [0:9];
    reg signed [31:0] multiplier_mem [0:9];
    reg [5:0] shift_mem [0:9];
    reg signed [7:0] output_mem [0:9];

    reg [1:0] state;
    reg [3:0] class_idx;
    reg signed [31:0] output_zero_point_reg;
    reg signed [31:0] activation_min_reg;
    reg signed [31:0] activation_max_reg;

    wire [3:0] weight_class;
    wire [7:0] weight_input;
    wire signed [7:0] cfg_weight;
    wire signed [15:0] cfg_product;
    integer clear_i;

    assign cfg_ready = !busy;
    assign weight_class = cfg_index[11:8];
    assign weight_input = cfg_index[7:0];
    assign cfg_weight = cfg_data[7:0];
    assign cfg_product = input_mem[weight_input] * cfg_weight;
    assign out_rd_data =
        (out_rd_index < 4'd10) ? output_mem[out_rd_index] : 8'sd0;

    function signed [63:0] round_shift_s64;
        input signed [63:0] value;
        input [5:0] shift_amount;
        reg signed [63:0] abs_value;
        reg signed [63:0] rounded_abs;
        reg signed [63:0] offset;
        begin
            if (shift_amount == 6'd0) begin
                round_shift_s64 = value;
            end else begin
                offset = 64'sd1 <<< (shift_amount - 6'd1);
                if (value >= 64'sd0) begin
                    round_shift_s64 = (value + offset) >>> shift_amount;
                end else begin
                    abs_value = -value;
                    rounded_abs = (abs_value + offset) >>> shift_amount;
                    round_shift_s64 = -rounded_abs;
                end
            end
        end
    endfunction

    function signed [7:0] requant_fc;
        input [3:0] co;
        reg signed [63:0] x;
        reg signed [63:0] product;
        reg signed [63:0] act_min_ext;
        reg signed [63:0] act_max_ext;
        begin
            x = {{32{acc_mem[co][31]}}, acc_mem[co]} +
                {{32{bias_mem[co][31]}}, bias_mem[co]};
            product = x *
                {{32{multiplier_mem[co][31]}}, multiplier_mem[co]};
            x = round_shift_s64(product, 6'd31);
            x = x >>> shift_mem[co];
            x = x +
                {{32{output_zero_point_reg[31]}}, output_zero_point_reg};
            if (x > 64'sd127) begin
                x = 64'sd127;
            end else if (x < -64'sd128) begin
                x = -64'sd128;
            end
            act_min_ext = {{32{activation_min_reg[31]}}, activation_min_reg};
            act_max_ext = {{32{activation_max_reg[31]}}, activation_max_reg};
            if (x < act_min_ext) begin
                x = act_min_ext;
            end else if (x > act_max_ext) begin
                x = act_max_ext;
            end
            requant_fc = x[7:0];
        end
    endfunction

    always @(posedge clk) begin
        if (cfg_wr_en && cfg_ready) begin
            case (cfg_target)
                CFG_INPUT: begin
                    if (cfg_index < 16'd256) begin
                        input_mem[cfg_index[7:0]] <= cfg_data[7:0];
                    end
                    if (cfg_index == 16'd0) begin
                        for (clear_i = 0; clear_i < 10; clear_i = clear_i + 1) begin
                            acc_mem[clear_i] <= 32'sd0;
                        end
                    end
                end
                CFG_WEIGHT: begin
                    if ((cfg_index < 16'd2560) &&
                        (weight_class < 4'd10)) begin
                        acc_mem[weight_class] <=
                            acc_mem[weight_class] +
                            {{16{cfg_product[15]}}, cfg_product};
                    end
                end
                CFG_BIAS: begin
                    if (cfg_index < 16'd10) begin
                        bias_mem[cfg_index[3:0]] <= cfg_data;
                    end
                end
                CFG_MUL: begin
                    if (cfg_index < 16'd10) begin
                        multiplier_mem[cfg_index[3:0]] <= cfg_data;
                    end
                end
                CFG_SHIFT: begin
                    if (cfg_index < 16'd10) begin
                        shift_mem[cfg_index[3:0]] <= cfg_data[5:0];
                    end
                end
                default: begin
                end
            endcase
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
                        state <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    output_mem[class_idx] <= requant_fc(class_idx);
                    if (class_idx == 4'd9) begin
                        state <= ST_DONE;
                    end else begin
                        class_idx <= class_idx + 4'd1;
                    end
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
