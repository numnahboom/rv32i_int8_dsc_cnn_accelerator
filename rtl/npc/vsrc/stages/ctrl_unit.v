`include "defines.vh"

module ctrl_unit(
	input wire[6:0] op,
	input wire[2:0] f3,
/* verilator lint_off UNUSEDSIGNAL */
	input wire[6:0] f7,	
/* verilator lint_on UNUSEDSIGNAL */
	output reg reg_wen,
	output reg alu_src_a,
	output reg alu_src_b,
	output reg[3:0] alu_ctrl,
	output reg mem_wen,
	output reg[1:0] wb_sel,
	output reg is_branch,
	output reg is_jal, is_jalr,
	output reg mem_ren,
	output reg is_cnn,
	output reg halt
);
	always@(*) begin
		halt = 1'b0;
		is_cnn = 1'b0;
		mem_ren = 1'b0;
		reg_wen = 1'b0;
		mem_wen = 1'b0;
		is_branch = 1'b0;
		is_jal = 1'b0;
		is_jalr = 1'b0;
		wb_sel = 2'b00;
		alu_src_a = 1'b0;
		alu_src_b = 1'b0;
		alu_ctrl = 4'b0000;
		case(op)
			`OP_R_TYPE:begin
				reg_wen = 1'b1;
				wb_sel = 2'b00;
				alu_src_a = 1'b0;
				alu_src_b = 1'b0;
				alu_ctrl = {f7[5], f3};
			end	
			
			`OP_I_TYPE:begin
				reg_wen = 1'b1;
				wb_sel = 2'b00;
				alu_src_a = 1'b0;
				alu_src_b = 1'b1;
				if((f3 == 3'b001) || (f3 == 3'b101))
					alu_ctrl = {f7[5], f3};
				else
					alu_ctrl = {1'b0, f3};
			end

			`OP_LOAD:begin
				reg_wen = 1'b1;
				wb_sel = 2'b01;
				alu_src_a = 1'b0;
				alu_src_b = 1'b1;
				alu_ctrl = `ALU_ADD;
				mem_ren = 1'b1;
			end

			`OP_STORE:begin
				mem_wen = 1'b1;
				alu_src_a = 1'b0;
				alu_src_b = 1'b1;
				alu_ctrl = `ALU_ADD;
			end

			`OP_BRANCH:begin
				is_branch = 1'b1;
				alu_src_a = 1'b1;
				alu_src_b = 1'b1;
				alu_ctrl = `ALU_ADD;
			end

			`OP_JAL:begin
				is_jal = 1'b1;
				reg_wen = 1'b1;
				alu_src_a = 1'b1;
				alu_src_b = 1'b1;
				alu_ctrl = `ALU_ADD;
				wb_sel = 2'b10;
			end

			`OP_JALR:begin
				reg_wen = 1'b1;
				alu_src_a = 1'b0;
				alu_src_b = 1'b1;
				alu_ctrl = `ALU_ADD;
				wb_sel = 2'b10;
				is_jalr = 1'b1;
			end

			`OP_LUI:begin
				reg_wen = 1'b1;
				wb_sel = 2'b11;
			end

			`OP_AUIPC:begin
				reg_wen = 1'b1;
				wb_sel = 2'b00;
				alu_src_a = 1'b1;
				alu_src_b = 1'b1;
				alu_ctrl = `ALU_ADD;
			end

			`OP_SYSTEM:begin
				halt = 1'b1;
			end

			`OP_CUSTOM0:begin
				is_cnn = 1'b1;
				reg_wen = 1'b1;
				wb_sel = 2'b00;
			end

			default:
				;
		endcase
	end
endmodule
