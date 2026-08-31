# DS 4x8 / paired-scratch / packed-PW cycle ledger

This is a deterministic accounting model calibrated by real RTL timing probes; it is not full-top evidence.

## Calibration

| probe | measured |
|---|---:|
| 4x8 DW job, stride1 (288 tokens/128 writes) | 1767 cycles |
| 4x8 DW job, stride2 (288 tokens/128 writes) | 2232 cycles |
| source fill, 240 words / 3-cycle response | 247 cycles |
| source fill, 612 words / 3-cycle response | 619 cycles |
| packed PW job, Cin=16/48/128 | Cin + 62 cycles |
| packed PW job outputs | 32 two-lane beats, including row2 drain |

## Reproducible calibration runs

- `wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_ds_word_window_dw_tagless_stream4_4x8_timing.sh'`
  raw PASS: `nonzero_source=1 stride=1 words=240 fill_cycles=247 job_cycles=1767 total_cycles=2038 dw_writes=128 tokens=288`; `nonzero_source=1 stride=2 words=612 fill_cycles=619 job_cycles=2232 total_cycles=2875 dw_writes=128 tokens=288`.
- `wsl.exe bash -lc '/mnt/d/Stuff/Project/build/verilator_dw_pw_pair_scratch_rowbank2_packed_consumer_timing_48/sim_timing'`
  raw PASS: `cin=48 groups=6 words=96 job_cycles=130 total_cycles=370 outputs=32 packed_reads=48 activations=48` (nonzero deterministic source/weight data).

## Per-layer ledger

| layer | shape / s | DW cmds | source words / fill(init/work) | DW cfg | DW issue+drain | DW total | row lines | transfer read + commit | PW jobs | PW cfg/load | PW issue+drain | PW total | ideal overlap | overlap+transfer | serial | tail/fence | overlap? |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| DS1 | 32x32x16->32x32x32 / 1 | 32 | 7,680 / 247 init / 7,904 work | 9 | 56,544 | 56,800 | 128 | 1,536 + 384 | 512 | 0 / 128 | 39,936 | 41,984 | 56,800 | 56,800 | 98,784 | 0 / 384 | yes: max(DW,PW+transfer) |
| DS2 | 32x32x32->16x16x64 / 2 | 16 | 9,792 / 619 init / 9,904 work | 18 | 35,712 | 36,349 | 32 | 768 + 96 | 256 | 0 / 512 | 24,064 | 25,440 | 36,349 | 36,349 | 61,789 | 0 / 96 | yes: max(DW,PW+transfer) |
| DS3 | 16x16x64->16x16x64 / 1 | 32 | 7,680 / 247 init / 7,904 work | 36 | 56,544 | 56,827 | 32 | 1,536 + 96 | 256 | 0 / 1,024 | 32,256 | 34,912 | 56,827 | 56,827 | 91,739 | 0 / 96 | yes: max(DW,PW+transfer) |
| DS4 | 16x16x64->8x8x128 / 2 | 8 | 4,896 / 619 init / 4,952 work | 36 | 17,856 | 18,511 | 8 | 384 + 24 | 128 | 0 / 2,048 | 16,128 | 18,584 | 18,511 | 18,584 | 37,095 | 0 / 24 | yes: max(DW,PW+transfer) |
| DS5 | 8x8x128->8x8x128 / 1 | 16 | 3,840 / 247 init / 3,952 work | 72 | 28,272 | 28,591 | 8 | 768 + 24 | 128 | 0 / 4,096 | 24,320 | 29,208 | 28,591 | 29,208 | 57,799 | 0 / 24 | yes: max(DW,PW+transfer) |
| DS6 | 8x8x128->4x4x256 / 2 | 8 | 4,896 / 619 init / 4,952 work | 72 | 17,856 | 18,547 | 4 | 384 + 12 | 128 | 0 / 8,192 | 24,320 | 32,908 | 32,512 | 32,908 | 51,455 | 4 / 12 | yes: max(DW,PW+transfer) |

## Totals and interpretation

- True DS MACs: 497,664 DW + 4,194,304 PW = 4,691,968 MACs; the model does not reduce computation.
- Physical DW traffic: 32,256 tokens, 14,336 stream4 writes, and 38,784 source words.
- Packed PW load: 16,000 32-bit words; activation tokens: 73,728.
- Ideal double-bank overlap: 229,590 cycles; charging every scratch transfer: 230,676; serial comparison: 398,661.
- Overlap flag: yes, but only as a scheduler model (`max(DW service, PW service + transfer)`); no six-layer steady-state RTL measurement exists yet.
- `source_fill_total_cycles` is fill work for all producer commands; DW total charges one 247/619-cycle warm-up fill because subsequent inactive-bank fills are assumed hidden behind DW issue/drain. This is an optimistic lower bound, not an independently measured six-layer schedule.
- `pw_config_cycles=0` means no separate cycle is charged: the packed consumer captures job configuration on the one-cycle issue, and its measured `Cin+62` issue/drain term includes the fixed control/drain overhead.
- At 125 MHz and 0.27 W, DS-only overlap+transfer is 1.845 ms and would correspond to 20.62 GOPS/W if the full 5,136,896-MAC network finished in that many cycles.
- The max(DW,PW) result is a scheduler assumption, not a proved RTL result. The existing real-producer overlap test proves only a local simultaneous window, not six-layer steady state.
- Source bubbles, output backpressure, layer descriptors, runner fences, and tail-specific address handling add cycles beyond this no-backpressure service floor. The model therefore reports a lower/central estimate, not an acceptance claim.
- DS6 is charged at fixed 4x8 geometry (four invalid columns masked); a future native 4x4 producer can reduce its source traffic, but that optimization is not silently credited here.
