`default_nettype none

/* verilator lint_off WIDTH */
/* verilator lint_off BLKSEQ */

module cnn_accelerator #(
    parameter IMAGE_COUNT = 16
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cmd_valid,
    input  wire [2:0]  cmd_funct3,
    input  wire [31:0] cmd_rs1,
    input  wire [31:0] cmd_rs2,
    output reg  [31:0] cmd_rdata,
    output wire [31:0] img_addr0,
    output wire [31:0] img_addr1,
    output wire [31:0] img_addr2,
    output wire [31:0] img_addr3,
    output wire [31:0] img_addr4,
    output wire [31:0] img_addr5,
    output wire [31:0] img_addr6,
    output wire [31:0] img_addr7,
    output wire [31:0] img_addr8,
    input  wire signed [7:0] img_data0,
    input  wire signed [7:0] img_data1,
    input  wire signed [7:0] img_data2,
    input  wire signed [7:0] img_data3,
    input  wire signed [7:0] img_data4,
    input  wire signed [7:0] img_data5,
    input  wire signed [7:0] img_data6,
    input  wire signed [7:0] img_data7,
    input  wire signed [7:0] img_data8
);
    localparam IN_H       = 28;
    localparam IN_W       = 28;
    localparam CONV1_OC   = 16;
    localparam CONV1_H    = 26;
    localparam CONV1_W    = 26;
    localparam POOL1_H    = 13;
    localparam POOL1_W    = 13;
    localparam CONV2_OC   = 32;
    localparam CONV2_IC   = 16;
    localparam CONV2_H    = 11;
    localparam CONV2_W    = 11;
    localparam POOL2_H    = 5;
    localparam POOL2_W    = 5;
    localparam FC_IN      = 800;
    localparam FC_OUT     = 10;
    localparam SHIFT      = 20;

    localparam CMD_START  = 3'b000;
    localparam CMD_STATUS = 3'b001;
    localparam CMD_RESULT = 3'b010;
    localparam CMD_CYCLES = 3'b011;

    localparam S_IDLE       = 5'd0;
    localparam S_CONV1_LOAD = 5'd1;
    localparam S_CONV1_RUN  = 5'd2;
    localparam S_CONV1_WAIT = 5'd3;
    localparam S_POOL1      = 5'd4;
    localparam S_CONV2_LOAD = 5'd5;
    localparam S_CONV2_RUN  = 5'd6;
    localparam S_CONV2_WAIT = 5'd7;
    localparam S_POOL2      = 5'd8;
    localparam S_FC         = 5'd9;
    localparam S_DONE       = 5'd10;

    reg [4:0] state;
    reg busy;
    reg done;
    reg [3:0] prediction;
    reg signed [7:0] best_score;
    reg [31:0] cycle_count;
    reg [31:0] image_base;

    reg [4:0] oc;
    reg [4:0] ic;
    reg [4:0] oh;
    reg [4:0] ow;
    reg [9:0] fc_i;
    reg [3:0] fc_o;
    reg signed [31:0] conv_acc;
    reg signed [31:0] fc_acc;

    reg signed [7:0] conv1_out [0:CONV1_OC*CONV1_H*CONV1_W-1];
    reg signed [7:0] pool1_out [0:CONV1_OC*POOL1_H*POOL1_W-1];
    reg signed [7:0] conv2_out [0:CONV2_OC*CONV2_H*CONV2_W-1];
    reg signed [7:0] pool2_out [0:CONV2_OC*POOL2_H*POOL2_W-1];

    reg signed [7:0] conv1_w [0:CONV1_OC*9-1];
    reg signed [31:0] conv1_mul [0:CONV1_OC-1];
    reg signed [31:0] conv1_bias [0:CONV1_OC-1];
    reg signed [7:0] conv2_w [0:CONV2_OC*CONV2_IC*9-1];
    reg signed [31:0] conv2_mul [0:CONV2_OC-1];
    reg signed [31:0] conv2_bias [0:CONV2_OC-1];
    reg signed [7:0] fc_w [0:FC_OUT*FC_IN-1];
    reg signed [31:0] fc_mul [0:FC_OUT-1];
    reg signed [31:0] fc_bias [0:FC_OUT-1];

    reg dot_load_weight;
    reg dot_start;
    reg signed [71:0] dot_weights;
    reg signed [71:0] dot_pixels;
    wire dot_busy;
    wire dot_done;
    wire signed [31:0] dot_result;

    wire signed [31:0] conv2_acc_next;
    wire signed [15:0] fc_product;
    wire signed [31:0] fc_product_ext;
    wire signed [31:0] fc_acc_next;
    wire signed [7:0] fc_q_next;
    wire signed [7:0] pool1_max;
    wire signed [7:0] pool2_max;
    wire unused_cmd_rs2;

    initial begin
        $readmemh("cnn_conv1_w.hex", conv1_w);
        $readmemh("cnn_conv1_mul.hex", conv1_mul);
        $readmemh("cnn_conv1_bias.hex", conv1_bias);
        $readmemh("cnn_conv2_w.hex", conv2_w);
        $readmemh("cnn_conv2_mul.hex", conv2_mul);
        $readmemh("cnn_conv2_bias.hex", conv2_bias);
        $readmemh("cnn_fc_w.hex", fc_w);
        $readmemh("cnn_fc_mul.hex", fc_mul);
        $readmemh("cnn_fc_bias.hex", fc_bias);
    end

    assign img_addr0 = image_addr(oh, ow, 0, 0);
    assign img_addr1 = image_addr(oh, ow, 0, 1);
    assign img_addr2 = image_addr(oh, ow, 0, 2);
    assign img_addr3 = image_addr(oh, ow, 1, 0);
    assign img_addr4 = image_addr(oh, ow, 1, 1);
    assign img_addr5 = image_addr(oh, ow, 1, 2);
    assign img_addr6 = image_addr(oh, ow, 2, 0);
    assign img_addr7 = image_addr(oh, ow, 2, 1);
    assign img_addr8 = image_addr(oh, ow, 2, 2);

    assign unused_cmd_rs2 = |cmd_rs2;
    assign conv2_acc_next = conv_acc + dot_result;
    assign fc_product     = pool2_out[idx_pool2(fc_i / 25, (fc_i % 25) / 5, fc_i % 5)] *
                            fc_w[(fc_o * FC_IN) + fc_i];
    assign fc_product_ext = {{16{fc_product[15]}}, fc_product};
    assign fc_acc_next    = fc_acc + fc_product_ext;
    assign fc_q_next      = requant_s8(fc_acc_next, fc_mul[fc_o], fc_bias[fc_o]);

    assign pool1_max = max4(
        read_conv1(oc, oh * 2,     ow * 2),
        read_conv1(oc, oh * 2,     ow * 2 + 1),
        read_conv1(oc, oh * 2 + 1, ow * 2),
        read_conv1(oc, oh * 2 + 1, ow * 2 + 1)
    );

    assign pool2_max = max4(
        read_conv2(oc, oh * 2,     ow * 2),
        read_conv2(oc, oh * 2,     ow * 2 + 1),
        read_conv2(oc, oh * 2 + 1, ow * 2),
        read_conv2(oc, oh * 2 + 1, ow * 2 + 1)
    );

    systolic_array_3x3_accelerator u_dot(
        .clk(clk),
        .rst_n(~rst),
        .load_weight(dot_load_weight),
        .weights(dot_weights),
        .start(dot_start),
        .pixels(dot_pixels),
        .busy(dot_busy),
        .done(dot_done),
        .result(dot_result)
    );

    always @(*) begin
        case (cmd_funct3)
            CMD_STATUS: cmd_rdata = {19'd0, dot_busy, prediction, 5'd0, done, busy, 1'b0};
            CMD_RESULT: cmd_rdata = {28'd0, prediction};
            CMD_CYCLES: cmd_rdata = cycle_count;
            default:    cmd_rdata = {31'd0, unused_cmd_rs2};
        endcase
    end

    function [31:0] image_addr;
        input [31:0] row;
        input [31:0] col;
        input [31:0] kh;
        input [31:0] kw;
        begin
            image_addr = image_base + ((row + kh) * IN_W) + col + kw;
        end
    endfunction

    function integer idx_conv1;
        input integer c;
        input integer h;
        input integer w;
        begin
            idx_conv1 = (c * CONV1_H * CONV1_W) + (h * CONV1_W) + w;
        end
    endfunction

    function integer idx_pool1;
        input integer c;
        input integer h;
        input integer w;
        begin
            idx_pool1 = (c * POOL1_H * POOL1_W) + (h * POOL1_W) + w;
        end
    endfunction

    function integer idx_conv2;
        input integer c;
        input integer h;
        input integer w;
        begin
            idx_conv2 = (c * CONV2_H * CONV2_W) + (h * CONV2_W) + w;
        end
    endfunction

    function integer idx_pool2;
        input integer c;
        input integer h;
        input integer w;
        begin
            idx_pool2 = (c * POOL2_H * POOL2_W) + (h * POOL2_W) + w;
        end
    endfunction

    function signed [7:0] read_conv1;
        input integer c;
        input integer h;
        input integer w;
        begin
            if ((c >= 0) && (c < CONV1_OC) &&
                (h >= 0) && (h < CONV1_H) &&
                (w >= 0) && (w < CONV1_W)) begin
                read_conv1 = conv1_out[idx_conv1(c, h, w)];
            end else begin
                read_conv1 = 8'sd0;
            end
        end
    endfunction

    function signed [7:0] read_conv2;
        input integer c;
        input integer h;
        input integer w;
        begin
            if ((c >= 0) && (c < CONV2_OC) &&
                (h >= 0) && (h < CONV2_H) &&
                (w >= 0) && (w < CONV2_W)) begin
                read_conv2 = conv2_out[idx_conv2(c, h, w)];
            end else begin
                read_conv2 = 8'sd0;
            end
        end
    endfunction

    function signed [31:0] round_shift_right;
        input signed [63:0] value;
        reg signed [63:0] rounded;
        begin
            if (value >= 0) begin
                rounded = value + (64'sd1 <<< (SHIFT - 1));
                round_shift_right = rounded >>> SHIFT;
            end else begin
                rounded = -value + (64'sd1 <<< (SHIFT - 1));
                round_shift_right = -(rounded >>> SHIFT);
            end
        end
    endfunction

    function signed [7:0] clamp_s8;
        input signed [31:0] value;
        begin
            if (value > 32'sd127) begin
                clamp_s8 = 8'sd127;
            end else if (value < -32'sd127) begin
                clamp_s8 = -8'sd127;
            end else begin
                clamp_s8 = value[7:0];
            end
        end
    endfunction

    function signed [7:0] clamp_relu_s8;
        input signed [31:0] value;
        begin
            if (value > 32'sd127) begin
                clamp_relu_s8 = 8'sd127;
            end else if (value < 32'sd0) begin
                clamp_relu_s8 = 8'sd0;
            end else begin
                clamp_relu_s8 = value[7:0];
            end
        end
    endfunction

    function signed [7:0] requant_relu_s8;
        input signed [31:0] acc;
        input signed [31:0] multiplier;
        input signed [31:0] bias;
        reg signed [63:0] scaled;
        begin
            scaled = acc * multiplier;
            requant_relu_s8 = clamp_relu_s8(round_shift_right(scaled) + bias);
        end
    endfunction

    function signed [7:0] requant_s8;
        input signed [31:0] acc;
        input signed [31:0] multiplier;
        input signed [31:0] bias;
        reg signed [63:0] scaled;
        begin
            scaled = acc * multiplier;
            requant_s8 = clamp_s8(round_shift_right(scaled) + bias);
        end
    endfunction

    function signed [7:0] max4;
        input signed [7:0] a;
        input signed [7:0] b;
        input signed [7:0] c;
        input signed [7:0] d;
        reg signed [7:0] m;
        begin
            m = (a > b) ? a : b;
            m = (m > c) ? m : c;
            max4 = (m > d) ? m : d;
        end
    endfunction

    task advance_conv1;
        begin
            if (ow == CONV1_W - 1) begin
                ow <= 5'd0;
                if (oh == CONV1_H - 1) begin
                    oh <= 5'd0;
                    if (oc == CONV1_OC - 1) begin
                        oc <= 5'd0;
                        state <= S_POOL1;
                    end else begin
                        oc <= oc + 5'd1;
                        state <= S_CONV1_LOAD;
                    end
                end else begin
                    oh <= oh + 5'd1;
                    state <= S_CONV1_RUN;
                end
            end else begin
                ow <= ow + 5'd1;
                state <= S_CONV1_RUN;
            end
        end
    endtask

    task advance_pool1;
        begin
            if (ow == POOL1_W - 1) begin
                ow <= 5'd0;
                if (oh == POOL1_H - 1) begin
                    oh <= 5'd0;
                    if (oc == CONV1_OC - 1) begin
                        oc <= 5'd0;
                        ic <= 5'd0;
                        conv_acc <= 32'sd0;
                        state <= S_CONV2_LOAD;
                    end else begin
                        oc <= oc + 5'd1;
                    end
                end else begin
                    oh <= oh + 5'd1;
                end
            end else begin
                ow <= ow + 5'd1;
            end
        end
    endtask

    task advance_conv2_output;
        begin
            ic <= 5'd0;
            conv_acc <= 32'sd0;
            if (ow == CONV2_W - 1) begin
                ow <= 5'd0;
                if (oh == CONV2_H - 1) begin
                    oh <= 5'd0;
                    if (oc == CONV2_OC - 1) begin
                        oc <= 5'd0;
                        state <= S_POOL2;
                    end else begin
                        oc <= oc + 5'd1;
                        state <= S_CONV2_LOAD;
                    end
                end else begin
                    oh <= oh + 5'd1;
                    state <= S_CONV2_LOAD;
                end
            end else begin
                ow <= ow + 5'd1;
                state <= S_CONV2_LOAD;
            end
        end
    endtask

    task advance_pool2;
        begin
            if (ow == POOL2_W - 1) begin
                ow <= 5'd0;
                if (oh == POOL2_H - 1) begin
                    oh <= 5'd0;
                    if (oc == CONV2_OC - 1) begin
                        oc <= 5'd0;
                        fc_o <= 4'd0;
                        fc_i <= 10'd0;
                        fc_acc <= 32'sd0;
                        best_score <= 8'sh80;
                        prediction <= 4'd0;
                        state <= S_FC;
                    end else begin
                        oc <= oc + 5'd1;
                    end
                end else begin
                    oh <= oh + 5'd1;
                end
            end else begin
                ow <= ow + 5'd1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state           <= S_IDLE;
            busy            <= 1'b0;
            done            <= 1'b0;
            prediction      <= 4'd0;
            best_score      <= 8'sh80;
            cycle_count     <= 32'd0;
            image_base      <= 32'd0;
            oc              <= 5'd0;
            ic              <= 5'd0;
            oh              <= 5'd0;
            ow              <= 5'd0;
            fc_i            <= 10'd0;
            fc_o            <= 4'd0;
            conv_acc        <= 32'sd0;
            fc_acc          <= 32'sd0;
            dot_load_weight <= 1'b0;
            dot_start       <= 1'b0;
            dot_weights     <= 72'sd0;
            dot_pixels      <= 72'sd0;
        end else begin
            dot_load_weight <= 1'b0;
            dot_start       <= 1'b0;
            if (busy) begin
                cycle_count <= cycle_count + 32'd1;
            end

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (cmd_valid && (cmd_funct3 == CMD_START)) begin
                        done        <= 1'b0;
                        busy        <= 1'b1;
                        cycle_count <= 32'd0;
                        image_base  <= (cmd_rs1 % IMAGE_COUNT) * (IN_H * IN_W);
                        oc          <= 5'd0;
                        ic          <= 5'd0;
                        oh          <= 5'd0;
                        ow          <= 5'd0;
                        state       <= S_CONV1_LOAD;
                    end
                end

                S_CONV1_LOAD: begin
                    dot_weights[0*8 +: 8] <= conv1_w[oc * 9 + 0];
                    dot_weights[1*8 +: 8] <= conv1_w[oc * 9 + 1];
                    dot_weights[2*8 +: 8] <= conv1_w[oc * 9 + 2];
                    dot_weights[3*8 +: 8] <= conv1_w[oc * 9 + 3];
                    dot_weights[4*8 +: 8] <= conv1_w[oc * 9 + 4];
                    dot_weights[5*8 +: 8] <= conv1_w[oc * 9 + 5];
                    dot_weights[6*8 +: 8] <= conv1_w[oc * 9 + 6];
                    dot_weights[7*8 +: 8] <= conv1_w[oc * 9 + 7];
                    dot_weights[8*8 +: 8] <= conv1_w[oc * 9 + 8];
                    dot_load_weight <= 1'b1;
                    state <= S_CONV1_RUN;
                end

                S_CONV1_RUN: begin
                    dot_pixels[0*8 +: 8] <= img_data0;
                    dot_pixels[1*8 +: 8] <= img_data1;
                    dot_pixels[2*8 +: 8] <= img_data2;
                    dot_pixels[3*8 +: 8] <= img_data3;
                    dot_pixels[4*8 +: 8] <= img_data4;
                    dot_pixels[5*8 +: 8] <= img_data5;
                    dot_pixels[6*8 +: 8] <= img_data6;
                    dot_pixels[7*8 +: 8] <= img_data7;
                    dot_pixels[8*8 +: 8] <= img_data8;
                    dot_start <= 1'b1;
                    state <= S_CONV1_WAIT;
                end

                S_CONV1_WAIT: begin
                    if (dot_done) begin
                        conv1_out[idx_conv1(oc, oh, ow)] <=
                            requant_relu_s8(dot_result, conv1_mul[oc], conv1_bias[oc]);
                        advance_conv1();
                    end
                end

                S_POOL1: begin
                    pool1_out[idx_pool1(oc, oh, ow)] <= pool1_max;
                    advance_pool1();
                end

                S_CONV2_LOAD: begin
                    dot_weights[0*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 0];
                    dot_weights[1*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 1];
                    dot_weights[2*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 2];
                    dot_weights[3*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 3];
                    dot_weights[4*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 4];
                    dot_weights[5*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 5];
                    dot_weights[6*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 6];
                    dot_weights[7*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 7];
                    dot_weights[8*8 +: 8] <= conv2_w[((oc * CONV2_IC) + ic) * 9 + 8];
                    dot_load_weight <= 1'b1;
                    state <= S_CONV2_RUN;
                end

                S_CONV2_RUN: begin
                    dot_pixels[0*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 0, ow + 0)];
                    dot_pixels[1*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 0, ow + 1)];
                    dot_pixels[2*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 0, ow + 2)];
                    dot_pixels[3*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 1, ow + 0)];
                    dot_pixels[4*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 1, ow + 1)];
                    dot_pixels[5*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 1, ow + 2)];
                    dot_pixels[6*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 2, ow + 0)];
                    dot_pixels[7*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 2, ow + 1)];
                    dot_pixels[8*8 +: 8] <= pool1_out[idx_pool1(ic, oh + 2, ow + 2)];
                    dot_start <= 1'b1;
                    state <= S_CONV2_WAIT;
                end

                S_CONV2_WAIT: begin
                    if (dot_done) begin
                        if (ic == CONV2_IC - 1) begin
                            conv2_out[idx_conv2(oc, oh, ow)] <=
                                requant_relu_s8(conv2_acc_next, conv2_mul[oc], conv2_bias[oc]);
                            advance_conv2_output();
                        end else begin
                            conv_acc <= conv2_acc_next;
                            ic <= ic + 5'd1;
                            state <= S_CONV2_LOAD;
                        end
                    end
                end

                S_POOL2: begin
                    pool2_out[idx_pool2(oc, oh, ow)] <= pool2_max;
                    advance_pool2();
                end

                S_FC: begin
                    if (fc_i == FC_IN - 1) begin
                        if ((fc_o == 4'd0) || (fc_q_next > best_score)) begin
                            best_score <= fc_q_next;
                            prediction <= fc_o;
                        end

                        if (fc_o == FC_OUT - 1) begin
                            state <= S_DONE;
                        end else begin
                            fc_o <= fc_o + 4'd1;
                            fc_i <= 10'd0;
                            fc_acc <= 32'sd0;
                        end
                    end else begin
                        fc_acc <= fc_acc_next;
                        fc_i <= fc_i + 10'd1;
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                    busy <= 1'b0;
                end
            endcase
        end
    end
endmodule

/* verilator lint_on WIDTH */
/* verilator lint_on BLKSEQ */
`default_nettype wire
