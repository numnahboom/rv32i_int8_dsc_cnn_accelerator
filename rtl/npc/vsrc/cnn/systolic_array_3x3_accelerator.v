`default_nettype none

module systolic_array_3x3_accelerator(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               load_weight,
    input  wire signed [71:0] weights,
    input  wire               valid_in,
    input  wire signed [23:0] pixels,
    output wire               busy,
    output wire               done,
    output wire  signed [31:0] result
);

    localparam PIPE_LATENCY = 5; // Systolic array latency in cycles

    reg [PIPE_LATENCY-1:0] pipeline_valid;

    wire array_load_weight;
    wire array_enable;
    wire array_valid_out;
    wire signed [31:0] array_result;

    assign accept            = valid_in && !load_weight;
    assign busy              = |pipeline_valid || accept;
    assign array_load_weight = load_weight && !busy;
    assign array_enable      = busy;
    assign done              = array_valid_out;
    assign result            = array_result;

    systolic_array_3x3 array_i(
        .clk(clk),
        .rst_n(rst_n),
        .load_weight(array_load_weight),
        .enable(array_enable),
        .valid_in(accept),
        .weights(weights),
        .pixels(pixels),
        .valid_out(array_valid_out),
        .result(array_result)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            pipeline_valid <= {PIPE_LATENCY{1'b0}};
        end else begin
            pipeline_valid <= {pipeline_valid[PIPE_LATENCY-2:0], accept};
        end
    end
endmodule

`default_nettype wire
