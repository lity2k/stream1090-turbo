#!/bin/bash
# bench.sh — offline throughput benchmark (replay a fixed IQ capture on stdin)
#
# usage: bench.sh [binary] [iqfile] [repeats] [outprefix]
#   binary     default /tmp/stream1090
#   iqfile     default /tmp/capture.bin  (uint8 interleaved IQ, 2.56 Msps)
#   repeats    how often to replay the file (lengthens the measurement, default 1)
#   outprefix  default /tmp/bench
#
# writes <out>.time (real/user/sys), <out>.err (stderr + stats table),
#        <out>.avr (decoded AVR), <out>.io (pipe-only baseline)
#
# Pin every core to the performance governor first, otherwise ondemand frequency
# scaling adds several percent of noise to the result.
BIN=${1:-/tmp/stream1090}
IQ=${2:-/tmp/capture.bin}
REP=${3:-1}
OUT=${4:-/tmp/bench}
ARGS=${S1090_ARGS:--s 2.56 -u 12 -q}

CORES=$(nproc 2>/dev/null || echo 4)
for g in $(seq 0 $((CORES - 1))); do
  echo performance > /sys/devices/system/cpu/cpu$g/cpufreq/scaling_governor 2>/dev/null
done
sleep 1

# warm-up: get the file pages and instruction cache into steady state
cat "$IQ" | "$BIN" $ARGS > /dev/null 2>/dev/null

# pipe-only baseline: same data through cat, no decoding
{
  time (
    for i in $(seq 1 "$REP"); do cat "$IQ"; done | cat > /dev/null
  )
} 2> "$OUT.io"

{
  time (
    for i in $(seq 1 "$REP"); do cat "$IQ"; done | "$BIN" $ARGS > "$OUT.avr" 2> "$OUT.err"
  )
} 2> "$OUT.time"

echo "--- IO BASELINE ---"
cat "$OUT.io"
echo "--- DECODE ---"
cat "$OUT.time"
echo "--- STATS ---"
grep -E "Messages Total|^\\| Total|iterations" "$OUT.err" | tail -5
echo "--- AVR BYTES ---"
stat -c %s "$OUT.avr"
