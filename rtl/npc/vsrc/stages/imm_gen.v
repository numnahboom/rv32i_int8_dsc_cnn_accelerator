`include "defines.vh"

module imm_gen(
	input wire[31:0] inst,
	output reg[31:0] imm
);
	always@(*) begin
		case(inst[6:0])
			`OP_I_TYPE, `OP_JALR, `OP_LOAD:
				imm = {{20{inst[31]}}, inst[31:20]};
			`OP_STORE:
				imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};
			`OP_BRANCH:
				imm = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
			`OP_LUI, `OP_AUIPC:
				imm = {inst[31:12],12'b0};
			`OP_JAL:
				imm = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
			default:
				imm = 32'b0;
		endcase
	end

endmodule
