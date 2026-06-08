# Custom ISA

Custom instruction proposal:

- `cnn.start rs1, rs2`: `rs1` is descriptor base address, `rs2` is number of layers.
- `cnn.poll rd`: returns status bits.
- `cnn.stat rd`: returns cycle counter or error code.

The first RTL wrapper uses a decoded opcode field so CPU integration can proceed before compiler support is added.

The existing `D:\Stuff\npc` core already exposes a simpler CNN custom port:

- `cnn_cmd_valid`
- `cnn_cmd_funct3`
- `cnn_cmd_rs1`
- `cnn_cmd_rs2`
- `cnn_cmd_rdata`

`rtl/cpu_if/npc_cnn_custom_bridge.v` adapts that port to the new accelerator command/status style without changing the five-stage pipeline internals.
