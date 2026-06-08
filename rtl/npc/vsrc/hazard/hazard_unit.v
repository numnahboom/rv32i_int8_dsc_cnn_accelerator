module hazard_unit(
	input wire mem_r, is_jump,
	input wire[4:0] id_rs1, id_rs2, ex_rd,
	output reg flush, stall, pc_en
);

always@(*) begin
	if(is_jump) begin
		flush = 1;
	end
	else begin
		flush = 0;
	end

	if(mem_r && ((ex_rd == id_rs1) || (ex_rd == id_rs2)) && (ex_rd != 5'b0)) begin
		stall = 1;
		pc_en = 0;
	end
	else begin
		stall = 0;
		pc_en = 1;
	end
end

endmodule
