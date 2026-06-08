# Architecture

第一版架构以可验证为优先：控制面 descriptor-driven，数据面固定 EdgeDSCNet-C10。DW3x3 使用 tile fusion，PW1x1 使用 8x8 int8 MAC array，feature SRAM A/B ping-pong。

```text
External memory
  | descriptors / weights / feature load-store
  v
cnn_top
  |-- control/status
  |-- feature SRAM A/B
  |-- DW tile buffer
  |-- engines
  `-- memory interface
```

详细时序和性能计数会随 `cnn_top` 阶段补齐。
