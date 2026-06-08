`include "defines.vh"

module branch_cond(
	input wire[31:0] rdata1, rdata2,
	input wire[2:0] cond,
	output reg taken
);
	always @(*)	begin
		case(cond)
			`BR_BEQ: taken = (rdata1 == rdata2);
			`BR_BNE: taken = (rdata1 != rdata2);
			`BR_BLT: taken = ($signed(rdata1) < $signed(rdata2));
			`BR_BGE: taken = ($signed(rdata1) >= $signed(rdata2));
			`BR_BLTU: taken = (rdata1 < rdata2);
			`BR_BGEU: taken = (rdata1 >= rdata2);
			default: taken = 1'b0;
		endcase
	end

endmodule
