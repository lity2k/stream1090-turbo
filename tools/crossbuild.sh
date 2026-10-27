#!/bin/bash
# crossbuild.sh — cross-compile for a 32-bit ARMv7 Cortex-A7 board from x86_64
#
# usage: bash crossbuild.sh [source-dir] [presets] [output]
#   source-dir  default ../src relative to this script
#   presets     default BenchPresets.hpp   (one 2.56 -> 12 instance)
#               use DefaultPresets.hpp when the build host has plenty of RAM
#   output      default ./stream1090-armv7
#
# environment:
#   SYSROOT     root of the extracted ARM sysroot (default $HOME/xarm)
#   SYSARM      directory holding the board's librtlsdr / libusb / libudev
#               and their headers (default /tmp/sysarm)
#   CXX         cross compiler (default arm-linux-gnueabihf-g++-14)
#   GCCV        gcc major version used in the -B path (default 14)
#
# Use the same compiler major version as the board's native g++, otherwise the
# generated code is measurably slower (gcc-13 vs gcc-14: 13% on Cortex-A7).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../src}
PRESETS=${2:-BenchPresets.hpp}
OUT=${3:-$PWD/stream1090-armv7}
SYSROOT=${SYSROOT:-$HOME/xarm}
SYSARM=${SYSARM:-/tmp/sysarm}
CXX=${CXX:-arm-linux-gnueabihf-g++-14}
GCCV=${GCCV:-14}

export PATH=$SYSROOT/usr/bin:$PATH
export LD_LIBRARY_PATH=$SYSROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

cd "$SRC"
$CXX \
  --sysroot=$SYSROOT \
  -B$SYSROOT/usr/lib/gcc-cross/arm-linux-gnueabihf/$GCCV \
  -B$SYSROOT/usr/bin \
  -O3 -ffast-math -std=c++20 \
  -mcpu=cortex-a7 -mtune=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard \
  -DSTATS_ENABLED=1 -DSTREAM1090_RSSI=1 \
  -DSTREAM1090_PREAMBLE_GATE=1 -DSTREAM1090_PREAMBLE_THRESHOLD=1.2 \
  -DSTREAM1090_MIN_SNR=2.5 -DSTREAM1090_HAS_LIB_RTLSDR \
  -DSTREAM1090_PRESETS_FILE="\"$PRESETS\"" \
  -Iinclude -Ipresets -I$SYSARM/usr/include \
  main.cpp src/devices/RtlSdrDevice.cpp \
  -L$SYSARM/usr/lib/arm-linux-gnueabihf -lrtlsdr -lusb-1.0 -ludev -lpthread \
  -o "$OUT"

${CXX%-g++*}-strip "$OUT" 2>/dev/null || true
file "$OUT"
ls -la "$OUT"
md5sum "$OUT"
