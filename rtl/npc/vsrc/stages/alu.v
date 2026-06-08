`include "defines.vh"

module alu(
	input wire[31:0] a, b,
	input wire[3:0] ctrl,
	output reg[31:0] result
);
	always@(*) begin
		case(ctrl)
			`ALU_ADD:  result = a + b;
			`ALU_SUB:  result = a - b;  
			`ALU_SLL:  result = a << b[4:0];
      `ALU_SLT:  result = ($signed(a) < $signed(b)) ? 32'b1 : 32'b0;
      `ALU_SLTU: result = (a < b) ? 32'b1 : 32'b0;
			`ALU_XOR:  result = a ^ b;
			`ALU_SRL:  result = a >> b[4:0];
			`ALU_SRA:  result = $signed(a) >>> b[4:0];
			`ALU_OR:   result = a | b;
			`ALU_AND:  result = a & b;
      default:   result = 32'b0;	
		endcase
	end
endmodule
