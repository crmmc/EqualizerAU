#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
EAUM1_METRIC_PREFIX=M10_RUNTIME_METRIC \
EAUM1_RUN_PREFIX=M10_RUNTIME_RUN \
  "$root/scripts/measure-m6-runtime.zsh" 432000 8192
