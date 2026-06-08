`timescale 1ns/1ps
`default_nettype none

module cnn_top_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] layer_num,
    input  wire        desc_valid,
    input  wire [31:0] desc_op_type,
    input  wire        layer_done,
    input  wire        layer_error,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [7:0]  current_layer,
    output reg         fetch_start,
    output reg  [31:0] fetch_layer_index,
    output reg         layer_start
);
    localparam ST_IDLE = 2'd0;
    localparam ST_WAIT_DESC = 2'd1;
    localparam ST_EXEC = 2'd2;
    localparam ST_DONE = 2'd3;

    reg [1:0] state;
    wire is_last_layer;
    wire op_supported;

    assign is_last_layer = ({24'd0, current_layer} + 32'd1) >= layer_num;
    assign op_supported = (desc_op_type == 32'd0) ||
                          (desc_op_type == 32'd1) ||
                          (desc_op_type == 32'd2) ||
                          (desc_op_type == 32'd3);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            current_layer <= 8'd0;
            fetch_start <= 1'b0;
            fetch_layer_index <= 32'd0;
            layer_start <= 1'b0;
        end else begin
            done <= 1'b0;
            fetch_start <= 1'b0;
            layer_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        error <= 1'b0;
                        current_layer <= 8'd0;
                        fetch_layer_index <= 32'd0;
                        if (layer_num == 32'd0) begin
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            busy <= 1'b1;
                            fetch_start <= 1'b1;
                            state <= ST_WAIT_DESC;
                        end
                    end
                end

                ST_WAIT_DESC: begin
                    if (desc_valid) begin
                        if (!op_supported) begin
                            error <= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            layer_start <= 1'b1;
                            state <= ST_EXEC;
                        end
                    end
                end

                ST_EXEC: begin
                    if (layer_done || layer_error) begin
                        if (layer_error) begin
                            error <= 1'b1;
                        end
                        if (is_last_layer || error || layer_error) begin
                            state <= ST_DONE;
                        end else begin
                            current_layer <= current_layer + 8'd1;
                            fetch_layer_index <= {24'd0, current_layer + 8'd1};
                            fetch_start <= 1'b1;
                            state <= ST_WAIT_DESC;
                        end
                    end
                end

                ST_DONE: begin
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
