module pc_reg(
	input wire clk,
	input wire rst,
	input wire en,
	input wire[31:0] next_pc,
	output reg[31:0] pc
);
	always@(posedge clk) begin
		if(rst) begin
			pc <= 32'b0;
		end	
		else begin
			if(en) begin
				pc <= next_pc;
			end
		end
	end
endmodule
