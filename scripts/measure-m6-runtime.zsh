#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
products="$root/.build/M6ReleaseProbeProducts"
intermediates="$root/.build/M6ReleaseProbeIntermediates"
binary="$root/.build/m6-runtime-probe"

xcodebuild \
  -project "$root/EqualizerAU.xcodeproj" \
  -target EqualizerAUM1Runtime \
  -configuration Release \
  SYMROOT="$products" \
  OBJROOT="$intermediates" \
  build \
  CODE_SIGNING_ALLOWED=NO >/dev/null

runtime_library=$(find "$products" -name libEqualizerAUM1Runtime.a -print -quit)
[[ -n "$runtime_library" ]]

clang++ \
  -std=c++17 \
  -O3 \
  -I "$root/EqualizerAUM1Runtime/include" \
  "$root/scripts/m6-runtime-probe.cpp" \
  "$runtime_library" \
  -o "$binary"

for run in 1 2 3 4 5; do
  print "M6_RUNTIME_RUN run=$run"
  "$binary"
done
