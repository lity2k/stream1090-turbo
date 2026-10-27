#!/bin/bash
# install.sh — build and install stream1090-turbo on the target board
#
# usage: bash install.sh [source-dir] [install-prefix]
#   source-dir      default: the repository root (this script's ..)
#   install-prefix  default /usr/local  ->  <prefix>/bin/stream1090
#
#   PRESETS=BenchPresets.hpp bash install.sh    # one preset (2.56 -> 12), lowest RAM
#   PRESETS=DefaultPresets.hpp bash install.sh  # all upstream combinations
#
# requires: g++ >= 11 with NEON support, librtlsdr-dev.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../src}
PREFIX=${2:-/usr/local}
PRESETS=${PRESETS:-BenchPresets.hpp}

command -v g++ >/dev/null 2>&1 || { echo "g++ not found: apt install -y g++" >&2; exit 1; }
[ -f /usr/include/rtl-sdr.h ] || { echo "rtl-sdr.h not found: apt install -y librtlsdr-dev" >&2; exit 1; }

Q='"'

# Build identity. Never silently blank: a binary whose --version says nothing
# cannot be told apart from a stock upstream build.
VER_STR=${STREAM1090_VERSION:-}
[ -n "$VER_STR" ] || VER_STR=$(bash "$HERE/version.sh" --src "$SRC" 2>/dev/null || true)
[ -n "$VER_STR" ] || VER_STR="stream1090-turbo $(tr -d ' \n' < "$HERE/../VERSION" 2>/dev/null || echo unknown)"

cd "$SRC"
g++ -O3 -ffast-math -std=c++20 \
    -mcpu=cortex-a7 -mtune=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard \
    -DSTATS_ENABLED=1 -DSTREAM1090_RSSI=1 \
    -DSTREAM1090_PREAMBLE_GATE=1 -DSTREAM1090_PREAMBLE_THRESHOLD=1.2 \
    -DSTREAM1090_MIN_SNR=2.5 -DSTREAM1090_HAS_LIB_RTLSDR \
    -DSTREAM1090_PRESETS_FILE="$Q$PRESETS$Q" \
    -DSTREAM1090_VERSION="$Q$VER_STR$Q" \
    -Iinclude -Ipresets main.cpp src/devices/RtlSdrDevice.cpp \
    -lrtlsdr -lpthread -o stream1090.build

install -d "$PREFIX/bin"
install -m 755 stream1090.build "$PREFIX/bin/stream1090"
rm -f stream1090.build
echo "version  : $VER_STR"
md5sum "$PREFIX/bin/stream1090"
echo "installed: $PREFIX/bin/stream1090"
