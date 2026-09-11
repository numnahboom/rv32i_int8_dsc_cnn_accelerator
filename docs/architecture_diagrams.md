# Architecture and Verification Diagrams

> **Snapshot (2026-09-11)**: The first diagrams show the C0 production/frozen
> control path. D4 is a separate network mainline and currently exists only as
> software-frozen plus standalone/OOC vstream RTL; it has not replaced
> `cnn_top`. See [`project_evolution_20260911.md`](project_evolution_20260911.md)
> and [`reports/README.md`](reports/README.md).

This note keeps the project diagrams in text form so they can be versioned, reviewed, and copied into reports or slides.

## Accelerator Architecture

```mermaid
flowchart LR
    CPU[RV32I five-stage CPU] --> CUSTOM[Custom instruction decode<br/>cnn.start / cnn.poll / cnn.stat]
    CUSTOM --> BRIDGE[rv_cnn_custom_if<br/>npc_cnn_custom_bridge]
    BRIDGE --> TOP[cnn_top]

    DESC_MEM[(Descriptor memory<br/>32 words per layer)] --> FETCH[descriptor_fetch]
    EXT_MEM[(External memory<br/>input / weights / quant / logits)] <--> TOP

    TOP --> FETCH
    TOP --> CTRL[cnn_top_ctrl]
    TOP --> RUNNER[cnn_layer_runner]
    TOP --> STATUS[status_counter]

    FETCH --> CTRL
    CTRL --> RUNNER
    RUNNER <--> SRAM[feature_sram_pingpong<br/>SRAM A / SRAM B]

    RUNNER --> STEM[conv3x3_stem_engine]
    RUNNER --> DW[dw_tile_fusion_engine]
    DW --> DWTB[dw_tile_buffer<br/>64 pixels x 128 channels]
    DWTB --> PW[pw_systolic_array_8x8]
    RUNNER --> GAP[gap_unit]
    RUNNER --> FC[fc_unit]

    STEM --> SRAM
    PW --> SRAM
    GAP --> SRAM
    FC --> EXT_MEM

    STATUS --> BRIDGE
```

Key point: DW3x3 intermediate data is not written back to external memory. The DW tile output is kept in `dw_tile_buffer`, then consumed by PW1x1.

## D4 retained standalone/OOC architecture

```mermaid
flowchart LR
    CFG[D4 mb16 shape/config] --> CTRL[v6 mb16 controller]
    CTRL --> SCHED[v6 scheduler]
    ACT[(Banked activation)] --> FETCH[Synchronous fetch pair]
    WGT[(Banked weights)] --> FETCH
    FETCH --> DP[Shared v2 datapath<br/>PW/RQ arithmetic]
    SCHED --> DP
    DP --> DWREQ[DW request adapter]
    DWREQ --> DWTILE[DW16 stream tile]
    DWTILE --> RQ[Elastic RQ/pool reg-in]
    RQ --> FIFO[16-lane BRAM raw FIFO]
    FIFO --> SINK[32-bit output sink<br/>valid/ready]
```

This block has exact no-BP/random/final-stall/two-epoch regressions and a
fully routed OOC wrapper. It does not include all D4 shapes, GAP, FC, complete
logits, firmware or a D4 full-top.

## Datapath View

```mermaid
flowchart TD
    IN[Input image<br/>32 x 32 x 3 int8] --> STEM[Conv3x3 Stem<br/>3 to 16, ReLU6]
    STEM --> SA[Feature SRAM A]
    SA --> DS1[DSBlock tile loop]

    subgraph DS[Depthwise separable block]
        LOAD[Load input tile + halo] --> DWF[DW3x3 fusion<br/>padding = input zero point]
        DWF --> TB[DW tile buffer]
        TB --> PW[PW1x1 8x8 array]
        PW --> REQ[Bias + requant + ReLU6]
    end

    DS1 --> SB[Feature SRAM B]
    SB --> PINGPONG[Next layers use SRAM ping-pong]
    PINGPONG --> GAP[Global average pool]
    GAP --> FC[FC 256 to 10]
    FC --> LOGITS[Logits in memory<br/>word-per-int8 v1 layout]
```

## Verification Closure

```mermaid
flowchart LR
    TORCH[PyTorch / Numpy training] --> EXPORT[quantize_export.py<br/>int8 weights, bias, qparams]
    EXPORT --> GOLDEN[golden_int8.py<br/>bit-exact software model]
    GOLDEN --> VEC[generate_test_vectors.py<br/>descriptor + memory image + expected]
    VEC --> RTL[RTL testbenches]
    RTL --> VERILATOR[Verilator simulation]
    VERILATOR --> CMP[logits compare<br/>expected vs actual]
    CMP --> FW[Firmware / CPU joint sim<br/>custom start, poll, stat]
    FW --> REPORT[accuracy + cycle reports]
    REPORT --> IMPL[XC7Z020 synth / place / route]
    IMPL --> PPA[timing + resources + power]
    PPA --> ENERGY[same-source latency / energy / GOPS/W]
```

Current C0 full-network checks compare all 10 logits element by element, then
check the CPU-observed argmax path. D4 has not yet reached the full-network,
firmware or full-top nodes in this closure graph.
