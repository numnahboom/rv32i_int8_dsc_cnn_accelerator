# Known Limits and Next Optimizations

## Current Limits

- The current RTL is a functional v1 datapath for fixed EdgeDSCNet-C10 shapes. It is not a general CNN accelerator.
- External memory uses a simulation-friendly word-per-int8 layout for many tests. Packed NHWC byte layout is still a later memory pass.
- The CPU custom-instruction path is verified in simulation, but the copied NPC SoC top has not been fully replaced by a production SoC integration.
- The design is single-clock. There is no asynchronous CPU/accelerator clock boundary yet.
- `cnn_top` has full-network smoke coverage, but not yet formal verification or constrained-random stress for every memory backpressure pattern.
- The current PW array is an 8x8 broadcast-style MAC array. It is simple and correct, but may need control/data register replication for high FPGA frequency.
- Requant uses wide signed multiplication. It is bit-exact with Python golden, but resource sharing or deeper pipelining may be needed after timing closure.
- Feature SRAM and tile buffers are modeled as RTL arrays/wrappers. FPGA BRAM inference must be confirmed by a real synthesis tool.
- Model accuracy is good enough for functional validation, not final ML quality. The current trained checkpoint is around 50% float accuracy and below that for sampled int8 PTQ.
- Resource numbers in `resource_estimate.md` are static estimates, not post-synthesis implementation results.

## Follow-Up Optimizations

1. Run Yosys or Vivado synthesis on `cnn_top` and confirm memory inference, DSP usage, and timing.
2. Add FPGA-specific memory style pragmas or vendor RAM wrappers for `feature_sram_bank`, weight buffers, and tile buffers.
3. Pipeline or share the requant multiplier depending on DSP pressure and target frequency.
4. Register-replicate `valid`, `clear_acc`, and row/column data feeds in `pw_systolic_array_8x8`.
5. Evaluate DSBlock scheduling choices:
   - keep conservative DW-then-PW sequencing for minimum buffer risk;
   - add a small tile double buffer if PW backpressure dominates;
   - scale PW resources only if DSP budget allows.
6. Replace v1 word-per-int8 memory with packed NHWC byte addressing and aligned burst-friendly loaders.
7. Add multi-sample RTL regression to the default CI path once runtime is acceptable.
8. Add more realistic CPU memory stalls and accelerator memory contention tests.
9. Train a stronger checkpoint with calibration or QAT, then regenerate firmware headers.
10. Consider an async `acc_clk` only after single-clock timing reports prove the accelerator limits CPU frequency.

