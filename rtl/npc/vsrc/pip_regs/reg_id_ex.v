module reg_id_ex(
	input wire clk, rst, stall, flush,
	input wire[31:0] in_pc, in_imm, in_rdata1, in_rdata2,
	input wire[4:0] in_rs1, in_rs2, in_rd,
	input wire in_reg_wen, in_alu_src_a, in_alu_src_b, in_mem_wen, in_is_branch, in_is_jal, in_is_jalr, in_mem_ren,
	input wire in_is_cnn,
	input wire[3:0] in_alu_ctrl,
	input wire[1:0] in_wb_sel,
	input wire[2:0] in_f3,
	input wire in_halt,
	output reg[31:0] out_pc, out_imm, out_rdata1, out_rdata2,
	output reg[4:0] out_rs1, out_rs2, out_rd,
	output reg out_reg_wen, out_alu_src_a, out_alu_src_b, out_mem_wen, out_is_branch, out_is_jal, out_is_jalr, out_mem_ren,
	output reg out_is_cnn,
	output reg[3:0] out_alu_ctrl,
	output reg[1:0] out_wb_sel,
	output reg[2:0] out_f3,
	output reg out_halt
);

	always@(posedge clk) begin
		if(rst | stall | flush) begin
			out_pc <= 32'b0;
			out_imm <= 32'b0;
			out_rdata1 <= 32'b0;
			out_rdata2 <= 32'b0;
			out_rs1 <= 5'b0;
			out_rs2 <= 5'b0;
			out_rd <= 5'b0;
			out_reg_wen <= 1'b0;
			out_alu_src_a <= 1'b0;
			out_alu_src_b <= 1'b0;
			out_mem_wen <= 1'b0;
			out_is_branch <= 1'b0;
			out_is_jal <= 1'b0;
			out_is_jalr <= 1'b0;
			out_is_cnn <= 1'b0;
			out_alu_ctrl <= 4'b0;
			out_wb_sel <= 2'b0;
			out_mem_ren <= 1'b0;
			out_f3 <= 3'b0;
			out_halt <= 1'b0;
		end
		else begin
			out_pc <= in_pc;
			out_imm <= in_imm;
			out_rdata1 <= in_rdata1;
			out_rdata2 <= in_rdata2;
			out_rs1 <= in_rs1;
			out_rs2 <= in_rs2;
			out_rd <= in_rd;
			out_reg_wen <= in_reg_wen;
			out_alu_src_a <= in_alu_src_a;
			out_alu_src_b <= in_alu_src_b;
			out_mem_wen <= in_mem_wen;
			out_is_branch <= in_is_branch;
			out_is_jal <= in_is_jal;
			out_is_jalr <= in_is_jalr;
			out_is_cnn <= in_is_cnn;
			out_alu_ctrl <= in_alu_ctrl;
			out_wb_sel <= in_wb_sel;
			out_mem_ren <= in_mem_ren;
			out_f3 <= in_f3;
			out_halt <= in_halt;
		end
	end

endmodule
