# Retained DS1 runner integration evidence

Date: 2026-09-01

The complete-network SRAM testbench was run with
`USE_DS1_RETAINED_ORCHESTRATOR=1`.  The strict predicate selected the retained
path for layer 1 only; the other eight descriptors remained on the existing
runner path.

## Result

- XSim: `PASS tb_cnn_top_fullnet_sram_datapath cases=1 checks=10`
- Full-network cycles: **863,921**
- Final logits: 10/10 exact byte matches, 0 mismatches; software and RTL
  argmax both 2.  Exact output bytes (hardware = golden) were
  `fb fd 08 fd 02 f5 fe fe 04 f5`.
- Layer 1 retained DS1: 89,333 cycles, 800 parameter reads, 9,424 SRAM word
  reads, 8,192 vec4 output writes (32,768 output bytes)
- Full-network operation count: **5,136,896 MACs** (442,368 Stem + 497,664
  DW + 4,194,304 PW + 2,560 FC)

The focused runner-level zero-parameter test independently passed with
`cycles=89,331`, `cfg_reads=800`, `source_words=9424`, `output_writes=8192`,
and `bytes=32768`; every emitted byte matched `0x07`.

The retained adapter uses the existing phase-loader DS configuration writes,
the existing feature-SRAM word response port, and the existing vec4 output
write port.  Its source address is generated as
`input_base + source_pixel*16 + q*4`; no descriptor external `mem_resp` is
connected to the retained source path.

For regression safety, the unparameterized full-network test was also rerun and
passed with the historical 873,289-cycle result.
