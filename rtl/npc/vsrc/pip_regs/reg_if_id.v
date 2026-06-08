module reg_if_id(
	input wire clk, rst, stall, flush, 
	input wire[31:0] in_pc, in_inst,
	output reg[31:0] out_pc, out_inst
);

always@(posedge clk)begin
	if(rst | flush) begin
		out_pc <= 32'b0;
		out_inst <= 32'h13;
	end
	else begin
		if(!stall) begin
			out_pc <= in_pc;
			out_inst <= in_inst;
		end

	end
end

endmodule
