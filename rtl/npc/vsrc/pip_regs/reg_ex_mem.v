module reg_ex_mem(
	input wire clk, rst,
	input wire[31:0] in_alu_result, in_rdata2,
	input wire[4:0] in_rd,
	input wire in_reg_wen, in_mem_wen, in_mem_ren,
	input wire[2:0] in_mem_width,
	input wire in_halt,
	output reg[31:0] out_alu_result, out_rdata2,
	output reg[4:0] out_rd,
	output reg out_reg_wen, out_mem_wen, out_mem_ren,
	output reg[2:0] out_mem_width,
	output reg out_halt
);

always@(posedge clk)begin
	if(rst) begin
		out_alu_result <= 32'b0;
		out_rdata2 <= 32'b0;
		out_rd <= 5'b0;
		out_reg_wen <= 1'b0;
		out_mem_wen <= 1'b0;
		out_mem_ren <= 1'b0;
		out_mem_width <= 3'b0;
		out_halt <= in_halt;
	end
	else begin
		out_alu_result <= in_alu_result;
		out_rdata2 <= in_rdata2;
		out_rd <= in_rd;
		out_reg_wen <= in_reg_wen;
		out_mem_wen <= in_mem_wen;
		out_mem_ren <= in_mem_ren;
		out_mem_width <= in_mem_width;
		out_halt <= in_halt;
	end
end

endmodule
