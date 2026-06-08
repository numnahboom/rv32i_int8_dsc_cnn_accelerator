`default_nettype none

module systolic_pe(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               load_weight,
    input  wire               enable,
    input  wire               valid_in,
    input  wire signed [7:0]  weight_in,
    input  wire signed [7:0]  pixel_in,
    output  reg signed [7:0]  pixel_out,
    input  wire signed [31:0] psum_in,
    output reg                valid_out,
    output reg  signed [31:0] psum_out
);
    reg signed [7:0] weight;

    wire signed [15:0] product;
    wire signed [31:0] product_ext;

    assign product     = pixel_in * weight;
    assign product_ext = {{16{product[15]}}, product};

    always @(posedge clk) begin
        if (!rst_n) begin
            weight    <= 8'sd0;
            valid_out <= 1'b0;
            psum_out  <= 32'sd0;
            pixel_out <= 8'sd0;
        end else if (enable) begin
            if (load_weight) begin 
                weight <= weight_in;
            end
            valid_out <= valid_in;
            if (valid_in) begin
                psum_out <= psum_in + product_ext;
                pixel_out <= pixel_in;
            end else begin
                psum_out <= 32'sd0;
                pixel_out <= 8'sd0;
            end
        end
    end
endmodule

`default_nettype wire
