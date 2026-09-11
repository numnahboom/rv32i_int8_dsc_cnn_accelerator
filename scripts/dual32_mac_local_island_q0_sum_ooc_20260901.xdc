create_clock -name clk -period 8.000 [get_ports clk]
set_input_delay -clock clk 0.000 [all_inputs]
set_output_delay -clock clk 0.000 [all_outputs]
