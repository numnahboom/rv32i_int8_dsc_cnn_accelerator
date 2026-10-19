# Prototype 125 MHz oscillator and receiver contract; no board integration is claimed.
create_clock -name physical_clk -period 8.000 [get_ports clk]
set_input_jitter [get_clocks physical_clk] 0.050
set_clock_uncertainty 0.200 [get_clocks -include_generated_clocks physical_clk]
set_input_delay -clock physical_clk -max 1.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay -clock physical_clk -min 0.200 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock physical_clk -max 1.000 [all_outputs]
set_output_delay -clock physical_clk -min -0.200 [all_outputs]
set_property IOSTANDARD LVCMOS33 [get_ports *]
set_load 5.000 [all_outputs]
