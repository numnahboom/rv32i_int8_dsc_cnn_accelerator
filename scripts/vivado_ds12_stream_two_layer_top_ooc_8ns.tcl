set part xc7z020clg400-1
read_verilog [list rtl/cnn/ds12_stream_vector_lane_bank.v rtl/cnn/ds12_stream_dual_vector_activation_store.v rtl/cnn/ds12_stream_two_layer_top.v]
synth_design -top ds12_stream_two_layer_top -part $part -mode out_of_context
create_clock -period 8.000 -name clk [get_ports clk]
report_utilization -file build/ds12_stream_two_layer_top_ooc_util.rpt
report_timing_summary -file build/ds12_stream_two_layer_top_ooc_timing.rpt
report_power -file build/ds12_stream_two_layer_top_ooc_power.rpt
