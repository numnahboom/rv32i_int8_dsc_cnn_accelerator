`timescale 1ns/1ps
`default_nettype none

/*
 * Resource-oriented 3x3 stem.
 *
 * Input/parameter payloads are written through a scalar configuration port.
 * One signed 8x8 MAC is reused across the 27 kernel terms of every output,
 * removing the packed-vector write network and 27-way combinational datapath.
 */
module conv3x3_stem_engine_new (
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

    localparam ST_IDLE = 2'd0;
    localparam ST_MAC  = 2'd1;
    localparam ST_DONE = 2'd2;
    localparam ST_ERROR = 2'd3;

    (* ram_style = "distributed" *)
    reg signed [7:0] input_mem [0:299];
    (* ram_style = "distributed" *)
    reg signed [7:0] weight_mem [0:431];
    reg signed [31:0] bias_mem [0:15];
    reg signed [31:0] multiplier_mem [0:15];
    reg [5:0] shift_mem [0:15];

    reg [1:0] state;
    reg [3:0] out_h_reg;
    reg [3:0] out_w_reg;
    reg signed [31:0] output_zero_point_reg;
    reg signed [31:0] activation_min_reg;
    reg signed [31:0] activation_max_reg;
    reg [5:0] pixel_idx;
    reg [3:0] channel_idx;
    reg [4:0] kernel_idx;
    reg signed [31:0] acc_reg;

    wire [3:0] out_y;
    wire [3:0] out_x;
    wire [1:0] kernel_y;
    wire [1:0] kernel_x;
    wire [1:0] kernel_c;
    wire [8:0] input_addr;
    wire [8:0] weight_addr;
    wire signed [7:0] act_value;
    wire signed [7:0] weight_value;
    wire signed [15:0] product_value;
    wire signed [31:0] acc_next;
    wire [7:0] output_pixels;

    integer cfg_addr;

    assign cfg_ready = !busy;
    assign output_pixels = out_h_reg * out_w_reg;
    assign out_y = (out_w_reg == 4'd0) ? 4'd0 : (pixel_idx / out_w_reg);
    assign out_x = (out_w_reg == 4'd0) ? 4'd0 : (pixel_idx % out_w_reg);
    assign kernel_y = kernel_idx / 5'd9;
    assign kernel_x = (kernel_idx / 5'd3) % 3;
    assign kernel_c = kernel_idx % 3;
    assign input_addr = (((out_y + kernel_y) * 10) +
                         (out_x + kernel_x)) * 3 + kernel_c;
    assign weight_addr = (channel_idx * 27) + kernel_idx;
    assign act_value = input_mem[input_addr];
    assign weight_value = weight_mem[weight_addr];
    assign product_value = act_value * weight_value;
    assign acc_next = acc_reg + {{16{product_value[15]}}, product_value};

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

    function signed [7:0] requant_stem;
        input signed [31:0] acc;
        input [3:0] co;
        reg signed [63:0] x;
        reg signed [63:0] product;
        reg signed [63:0] act_min_ext;
        reg signed [63:0] act_max_ext;
        begin
            x = {{32{acc[31]}}, acc} +
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
            requant_stem = x[7:0];
        end
    endfunction

    always @(posedge clk) begin
        if (cfg_wr_en && cfg_ready) begin
            cfg_addr = cfg_index;
            case (cfg_target)
                CFG_INPUT: begin
                    if (cfg_addr < 300) begin
                        input_mem[cfg_addr] <= cfg_data[7:0];
                    end
                end
                CFG_WEIGHT: begin
                    if (cfg_addr < 432) begin
                        weight_mem[cfg_addr] <= cfg_data[7:0];
                    end
                end
                CFG_BIAS: begin
                    if (cfg_addr < 16) begin
                        bias_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_MUL: begin
                    if (cfg_addr < 16) begin
                        multiplier_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_SHIFT: begin
                    if (cfg_addr < 16) begin
                        shift_mem[cfg_addr] <= cfg_data[5:0];
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
            out_h_reg <= 4'd0;
            out_w_reg <= 4'd0;
            output_zero_point_reg <= 32'sd0;
            activation_min_reg <= -32'sd128;
            activation_max_reg <= 32'sd127;
            pixel_idx <= 6'd0;
            channel_idx <= 4'd0;
            kernel_idx <= 5'd0;
            acc_reg <= 32'sd0;
            out_wr_en <= 1'b0;
            out_wr_pixel_idx <= 6'd0;
            out_wr_channel_idx <= 4'd0;
            out_wr_data_int8 <= 8'sd0;
        end else begin
            done <= 1'b0;
            out_wr_en <= 1'b0;
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
                            kernel_idx <= 5'd0;
                            acc_reg <= 32'sd0;
                            state <= ST_MAC;
                        end
                    end
                end

                ST_MAC: begin
                    if (kernel_idx == 5'd26) begin
                        out_wr_en <= 1'b1;
                        out_wr_pixel_idx <= pixel_idx;
                        out_wr_channel_idx <= channel_idx;
                        out_wr_data_int8 <= requant_stem(acc_next, channel_idx);
                        kernel_idx <= 5'd0;
                        acc_reg <= 32'sd0;
                        if (channel_idx == 4'd15) begin
                            channel_idx <= 4'd0;
                            if (({2'd0, pixel_idx} + 8'd1) >= output_pixels) begin
                                state <= ST_DONE;
                            end else begin
                                pixel_idx <= pixel_idx + 6'd1;
                            end
                        end else begin
                            channel_idx <= channel_idx + 4'd1;
                        end
                    end else begin
                        acc_reg <= acc_next;
                        kernel_idx <= kernel_idx + 5'd1;
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
