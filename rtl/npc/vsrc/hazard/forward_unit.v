module forward_unit(
	input wire[4:0] ex_rs1, ex_rs2, mem_rd, wb_rd,
	input wire mem_wen, wb_wen,
	output reg[1:0] for_sel1, for_sel2
);

	always@(*) begin
		if(mem_wen && (mem_rd == ex_rs1) && (mem_rd != 5'b0)) begin
			for_sel1 = 2'b10;
		end
		else if(wb_wen && (wb_rd == ex_rs1) && (wb_rd != 5'b0)) begin
			for_sel1 = 2'b01;
		end
		else begin
			for_sel1 = 2'b00;
		end
		if(mem_wen && (mem_rd == ex_rs2) && (mem_rd != 5'b0)) begin
			for_sel2 = 2'b10;
		end
		else if(wb_wen && (wb_rd == ex_rs2) && (wb_rd != 5'b0)) begin
			for_sel2 = 2'b01;
		end
		else begin
			for_sel2 = 2'b00;
		end
	end

endmodule
