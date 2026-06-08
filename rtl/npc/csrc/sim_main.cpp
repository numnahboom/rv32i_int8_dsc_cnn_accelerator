#include <Vsoc_top.h>
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vsoc_top.h"
#include "Vsoc_top___024root.h" 
#include <iostream>
#include <string>

int main(int argc, char **argv){
	VerilatedContext *contextp = new VerilatedContext;
	contextp->commandArgs(argc, argv);
	Vsoc_top *top = new Vsoc_top{contextp};

	bool enable_trace = false;
	for (int i = 1; i < argc; i++) {
		if (std::string(argv[i]) == "+trace") enable_trace = true;
	}

	VerilatedVcdC* tfp = nullptr;
	if (enable_trace) {
		contextp->traceEverOn(true);
		tfp = new VerilatedVcdC;
		top->trace(tfp, 99);
		tfp->open("wave.vcd");
	}

	top->clk = 0;
	top->rst = 1;

	const vluint64_t max_time = 200000000ULL;
	while(!contextp->gotFinish() && contextp->time() < max_time){
		contextp->timeInc(1);
		
		top->clk = !top->clk;

		if(!top->clk){
			if(contextp->time() > 10) top->rst = 0;
		}
	
		top->eval();
		if (tfp) tfp->dump(contextp->time());
	}

	auto &rf = top->rootp->soc_top__DOT__u_core__DOT__u_reg_file__DOT__rf;
	if (!contextp->gotFinish()) {
		std::cout << "Simulation timeout at time " << contextp->time()
		          << ", correct x10 = " << rf[10]
		          << ", last prediction x12 = " << rf[12]
		          << ", last cycles x11 = " << rf[11] << std::endl;
		top->final();
		if (tfp) {
			tfp->close();
			delete tfp;
		}
		delete top;
		delete contextp;
		return 1;
	}

	std::cout << "CNN correct x10 = " << rf[10] << " / 16"
	          << ", last prediction x12 = " << rf[12]
	          << ", last cycles x11 = " << rf[11] << std::endl;
	std::cout << "CNN accuracy = " << (rf[10] * 100 / 16) << "%" << std::endl;
	top->final();
	std::cout << "Finished.\n";
	
	if (tfp) {
		tfp->close();
		delete tfp;
	}
	delete top;
	delete contextp;
	return 0;

	
}
