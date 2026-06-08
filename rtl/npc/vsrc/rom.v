module rom#(
	parameter DEPTH = 262144
)(
/* verilator lint_off UNUSEDSIGNAL */
	input wire[31:0] pc,	
/* verilator lint_on UNUSEDSIGNAL */	
	output wire[31:0] inst
);
	reg[31:0] rom_array[0:DEPTH-1];
	initial begin
		$readmemh("rom.hex", rom_array);
	end
	assign inst = rom_array[pc[$clog2(DEPTH)+1 : 2]];

endmodule
