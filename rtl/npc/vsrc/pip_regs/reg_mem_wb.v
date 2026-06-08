module reg_mem_wb(
	input wire clk, rst,
	input wire[31:0] in_reg_wdata,
	input wire[4:0] in_rd,
	input wire in_reg_wen,
	input wire in_halt,
	output reg[31:0] out_reg_wdata, 
	output reg[4:0] out_rd,
	output reg out_reg_wen,
	output reg out_halt
);

	always@(posedge clk) begin
		if(rst) begin
			out_reg_wdata <= 32'b0;
			out_rd <= 5'b0;
			out_reg_wen <= 1'b0;
			out_halt <= 1'b0;
		end
		else begin
			out_reg_wdata <= in_reg_wdata;
			out_rd <= in_rd;
			out_reg_wen <= in_reg_wen;
			out_halt <= in_halt;
		end
	end

endmodule
