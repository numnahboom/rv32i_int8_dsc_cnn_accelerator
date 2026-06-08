module reg_file(
	input wire clk,
	input wire[4:0] rs1, rs2, rd,
	input wire wen,
	input wire[31:0] wdata,
	output wire[31:0] rdata1, rdata2
);
	reg[31:0] rf[0:31];
	always @(posedge clk) begin
		if(wen && (rd != 5'b0))
			rf[rd] <= wdata;
	end
	assign rdata1 = (rs1 == 5'b0) ? 32'b0: 
		((rs1 == rd) && wen) ? wdata : rf[rs1];
	assign rdata2 = (rs2 == 5'b0) ? 32'b0: 
		((rs2 == rd) && wen) ? wdata : rf[rs2];
endmodule
