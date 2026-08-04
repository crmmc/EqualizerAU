#!/bin/zsh
# M11: measure scaled Graphic EQ FIR lengths as Runtime convolution cost.
# Tap counts match ADR-0020 N(Fs) at 48 / 96 / 192 kHz.
set -euo pipefail

root=${0:A:h:h}
log=${1:-"$root/.build/m11-release-performance.log"}
mkdir -p "$root/.build"

: > "$log"
for taps in 16384 32768 65536; do
  print "=== M11 taps=$taps ===" | tee -a "$log"
  EAUM1_METRIC_PREFIX=M11_RUNTIME_METRIC \
  EAUM1_RUN_PREFIX=M11_RUNTIME_RUN \
    "$root/scripts/measure-m6-runtime.zsh" "$taps" 2000 2>&1 | tee -a "$log"
done

print "M11_RUNTIME_LOG=$log"
