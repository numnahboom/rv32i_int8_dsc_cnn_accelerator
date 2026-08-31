#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for args in \
  "-GTB_H=10 -GTB_W=10 -GTB_GROUPS=1 -GTB_STRIDE=1" \
  "-GTB_H=10 -GTB_W=10 -GTB_GROUPS=3 -GTB_STRIDE=1" \
  "-GTB_H=17 -GTB_W=17 -GTB_GROUPS=1 -GTB_STRIDE=2"; do
  tag="$(echo "$args" | tr ' =-' '__' | tr -s '_')"
  build="$root/build/verilator_ds_word_window_pingpong_shell${tag}"
  rm -rf "$build"
  mkdir -p "$build"
  # shellcheck disable=SC2086
  verilator --binary --timing --Wno-fatal -Wall \
    --top-module tb_ds_word_window_pingpong_shell $args \
    -f "$root/sim/filelist_ds_word_window_pingpong_shell.f" \
    -Mdir "$build" -o sim_ds_word_window_pingpong_shell
  "$build/sim_ds_word_window_pingpong_shell"
done
