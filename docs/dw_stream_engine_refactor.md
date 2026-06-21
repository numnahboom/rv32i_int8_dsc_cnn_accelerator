# Streaming DW Engine Refactor

## Scope

This refactor adds a synthesis-oriented depthwise tile path without replacing
the existing full-network DW implementation yet.

Implemented modules:

- `rtl/cnn/requant_activation_pipeline.v`
- `rtl/cnn/dw_line_buffer.v` coordinate metadata extension
- `rtl/cnn/dw_tile_fusion_engine_new.v`

The existing `dw_tile_fusion_engine.v` and `ds_block_tile_engine.v` remain the
active full-network path until a streaming tile loader is connected above the
new engine.

## Data Flow

```text
16-channel padded pixel stream
  -> dw_line_buffer
  -> stride window filter
  -> channel-vector to lane-major transpose
  -> dw_mac_lanes
  -> 16-accumulator holding register
  -> one-lane-per-cycle serializer
  -> requant_activation_pipeline
  -> 16-entry tagged output FIFO
  -> scalar ready/valid DW output stream
```

The caller must send every padded input pixel in raster order. Padding pixels
must already contain `input_zero_point`. Stride does not skip input pixels;
the engine discards unselected 3x3 windows after the line buffer.

## Requant Pipeline

`requant_activation_pipeline` is a fixed-latency, valid-only pipeline. It uses
16-bit partial products to construct the signed 33x32-bit multiply result.
Its arithmetic matches `python/golden_int8.py`:

1. Add int32 accumulator and bias.
2. Multiply by the signed Q31 multiplier.
3. Round the Q31 shift half away from zero.
4. Apply the configured arithmetic right shift without a second rounding.
5. Add output zero point.
6. Saturate to int8 and clamp to the activation range.

There is deliberately no combinational ready chain across the pipeline.
Backpressure is absorbed by the new engine's 16-entry output FIFO.

## Engine Interface Contract

Input transaction:

- A pixel is accepted on `valid_in && ready_in`.
- `x_idx/y_idx` describe the padded raster coordinate.
- `pixel_vec_in` contains 16 int8 channels.
- Weight and quantization vectors describe the current 16-channel tile and
  must remain stable until `done`.
- Every channel tile contains exactly 16 valid channels. EdgeDSCNet-C10 uses
  only channel counts that are multiples of 16.
- `stride` supports only 1 and 2.

Output transaction:

- An output transfers on `valid_out && ready_out`.
- Each output contains one int8 value plus `out_pixel_idx` and
  `out_channel_idx`.
- Output ordering is pixel-major, then ascending active lane.
- `done` pulses when the final output element is accepted.

Internal buffering:

- Line storage: 2 x 32 x 128 bits.
- Registered 3x3 window: 9 x 128 bits.
- One 16-lane int32 MAC result register.
- Ten stages of requant data and tag pipeline state.
- Output FIFO: 16 entries containing int8 data and pixel/channel tags.

## Current Throughput

One MAC transaction produces 16 accumulators after three compute cycles. A
single requant pipeline accepts one active lane per cycle, so a full channel
tile requires 16 issue cycles. Only one MAC/requant batch is currently allowed
in flight. This is intentionally conservative and guarantees that 16 FIFO
entries can absorb every result even when the downstream stalls.

Future throughput options:

- Instantiate four requant pipelines to approach the current MAC production
  rate.
- Add a second accumulator holding register and overlap MAC with serialization.
- Replace the output FIFO admission rule with credit tracking.

## Verification

The following tests pass:

```text
tb_requant_activation_unit       100 cases
tb_requant_activation_pipeline   100 cases
tb_dw_line_buffer                 50 cycle checks
tb_dw_mac_lanes                    4 cases / 10 checks
tb_dw_tile_fusion_engine           3 cases / 832 checks
tb_dw_tile_fusion_engine_new       3 streaming cases
tb_ds_block_tile_engine            3 cases / 1792 checks
```

`tb_dw_tile_fusion_engine_new` covers:

- stride 1 and stride 2;
- padded borders;
- three different 16-channel tiles and non-zero channel bases;
- non-zero channel bases;
- activation clamps;
- long initial output stalls and periodic backpressure.

Vectors are generated in
`python/generate_test_vectors.py::generate_dw_stream_engine_cases` and written
to `tests/vectors/dw_stream_engine_cases.hex`.

## Remaining Integration Work

1. Add a DSBlock-side streaming loader that reads the padded activation tile
   and presents 16-channel raster vectors to the new engine.
2. Slice DW weight and quant parameters into 16-channel tiles.
3. Convert the scalar DW output stream into `dw_tile_buffer` writes in the
   DSBlock controller.
4. Iterate over channel tiles when `Cin > 16`.
5. Run the existing DSBlock and full-network golden comparisons using the new
   path.
6. Only then retire the synthesis-proof packed-vector DW engine.
