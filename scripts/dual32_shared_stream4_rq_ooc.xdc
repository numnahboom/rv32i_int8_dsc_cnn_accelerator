create_clock -name clk -period 8.000 [get_ports clk]
set_clock_uncertainty -setup 0.15 [get_clocks clk]
set_clock_uncertainty -hold 0.05 [get_clocks clk]
