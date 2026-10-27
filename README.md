# stream1090-turbo

English | [简体中文](README.zh-CN.md)

Hardware-specific optimisation of [stream1090](https://github.com/mgrone/stream1090)
for a 4× Cortex-A7 SBC (Allwinner sun8i class, 1.296 GHz, NEON + VFPv4, **no**
ARMv8 crypto/CRC extensions).

Target workload: `stream1090 -s 2.56 -u 12 -q` (2.56 Msps RTL-SDR input,
12 MHz upsampled streams, built-in IQ low-pass filter).

**Result: 2.20× throughput, decoded output byte-identical to upstream.**

| | upstream equivalent | this tree | speed-up |
|---|---|---|---|
| board A | 15.949 s | 7.240 s | 2.204× |
| board B | 15.963 s | 7.254 s | 2.201× |

Measured on a 10 s, 51.2 MB RTL-SDR capture replayed through stdin, performance
governor pinned, three runs per board. Message count (256) and AVR payload
(9154 bytes, md5 `e7bc7960e32d93d094c413300cd1227e`) are identical to upstream —
this is a pure speed change, not a behaviour change.

The same 10 s of live IQ now decodes in 7.25 s instead of 15.9 s, so the pipeline
runs comfortably faster than real time on this hardware instead of falling behind.

## What was changed

Eight files, all in the demodulation hot path. `main.cpp` and `src/` are untouched.

1. **NEON shift registers** (`include/ShiftRegisters.hpp`)
   The 12 bit-streams are processed as 3 groups of 4 lanes. The 128-bit message
   window is held in four `uint32_t` vectors (`w0` = bits 31..0 … `w3` = 127..96)
   instead of two 64-bit scalars, so one lane carries one stream and the whole
   group shifts, CRCs and frame-format check in parallel.

2. **Two-thread pipeline** (`include/SampleStream.hpp`, `include/BlockRing.hpp`)
   Producer (read → FIR → magnitude → upsample) and consumer (Manchester →
   shift-register update) run concurrently. `BlockRing::m_fullBlocks` became
   `std::atomic` so the ring can be shared across threads.

3. **Manchester comparison fused into the shift update**
   GCC does not vectorise the original `m_demodPos[j] > m_demodPos[j + NumStreams/2]`
   loop, it emits 12 scalar `ldr/cmp/ite/str` sequences. The comparison now happens
   inside the vector register compare, and the `m_newBits` scratch array is gone.

4. **`vsli` instead of `shl` + `orr`**
   `vsliq_n_u32(carry, w, 1)` does `(w << 1) | carry` in one instruction; used for
   both window shift and CRC shift.

5. **Smaller input blocks** (`include/Sampler.hpp`)
   `DesiredInputBufferSize` 8192 → 1024 (154 KB → 21 KB per block). Overridable via
   `-DSTREAM1090_INPUT_BUFFER_TARGET=`. Going below 1024 gives no further gain.

6. **Correct ring head-room**
   `NumFreeSampleBuffers` is `NumSampleBuffers - 2`, not `- 1`: the demodulator
   reaches back into the previous block (`lookBack` up to 1524 samples), and a
   writer one block ahead would overwrite it.

Full diff against upstream: `patches/0001-cortex-a7-neon-pipeline.patch`.

## Profile after the change

`perf record -F 2000` on board A, share of 15.26 G cycles:

| symbol | share | side |
|---|---|---|
| demod thread lambda (shift + Manchester, inlined) | 26.3 % | consumer |
| `DemodCore::dispatchHandled` | 21.7 % | consumer |
| `SampleStream::read` (read + FIR + magnitude) | 19.4 % | producer |
| `SamplerFunc<16,75,72>::sample` | 14.4 % | producer |
| `handleExtSquitterLongMessage` | 9.6 % | consumer |
| `handleDF11ShortMessage` | 2.6 % | consumer |

The consumer side is the critical path (~7.1 s of work vs ~4.0 s on the producer),
which is why further producer-side work no longer moves the total.

Directions that were measured and rejected are listed in `docs/benchmarks.md` §5
(dispatch on a third thread, per-stream parallel shifting, 64-bit CRC folding,
NEON upsampler). `docs/optimization.md` explains each change and why it helps on
this particular core.

## Install

The default path installs the bundled binary and never invokes a compiler:

```bash
sudo bash install.sh                    # -> /usr/local/bin/stream1090
sudo bash install.sh --prefix /opt/turbo
```

Before installing, it checks the prebuilt against `prebuilt/MANIFEST` (md5),
reads the ELF header (must be ARM), resolves shared libraries with `ldd`, and
runs the binary once against empty stdin. Any failure aborts with a hint instead
of leaving a broken `stream1090` behind. `--dry-run` prints the plan only.

| command | source of the binary | needs |
|---|---|---|
| `install.sh` | `prebuilt/stream1090-armv7l-cortexa7` | nothing but the package |
| `install.sh --build` | compiles the bundled `src/` | g++, `librtlsdr-dev` |
| `install.sh --upstream` | clones latest official source, replays `patches/`, compiles, installs | git, g++, `librtlsdr-dev` |

`--upstream` always takes the current `main` of `mgrone/stream1090`, records the
commit it used, and refuses to continue if the patch no longer applies — upstream
touched one of the eight files this project rewrites, so you should run
`tools/sync_upstream.sh check` and regenerate the patch rather than guess.

### Build identity

Every binary built from this tree carries a version string that pins it to the
source state it came from:

```text
stream1090-turbo 1.0.1.7+5a2b1c9.9f3a1c02be74
                 ^semver ^build ^commit ^source fingerprint
```

`stream1090 -h | head -1` prints it, and so does the start-up banner on stderr.
A stock upstream build shows upstream's date code there instead, so the two can
never be confused — and two turbo builds can always be told apart.

| part | comes from | changes when |
|---|---|---|
| `1.0.1` | `VERSION` | a human decides the contract changed |
| `7` | `git rev-list --count --first-parent HEAD` | every commit, automatically |
| `5a2b1c9` | `git rev-parse --short HEAD` | every commit |
| `9f3a1c02be74` | sha256 over the files that get compiled | any source edit |

`.dirty` is appended while `src/`, `VERSION` or `patches/` hold uncommitted
changes. The same source state always produces the same string, which is what
keeps the validation md5 meaningful. `install.sh --reproducible` drops the git
parts and embeds the bare semver instead.

`tools/version.sh` is the single generator and writes `BUILDINFO`, which ships
with the package so that zip downloads and shallow clones — where there is no
`.git` — still report a usable identity instead of failing.

## Build from source

Requires a C++20 compiler. No external dependencies; `src/thirdparty` carries the
RTL-SDR sources.

Native, on the target board (this is the build the numbers were measured with,
and what `install.sh --build` calls):

```bash
tools/install.sh                  # -> /usr/local/bin/stream1090
```

Or with CMake, which uses upstream's `DefaultPresets.hpp` and therefore needs
more RAM than a 512 MB board has — see `docs/build.md` before choosing this route:

```bash
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j2
```

Cross-compiling from an x86_64 host: `tools/crossbuild.sh` (see `docs/build.md`).

### Preset budget

`-s` / `-u` are template parameters instantiated at build time. `BenchPresets.hpp`
instantiates exactly one pair (2.56 → 12) because a single translation unit with
all 27 upstream instances needs more RAM than a 512 MB board has. On a larger
build host you can switch to the upstream `DefaultPresets.hpp`
(`-DSTREAM1090_PRESETS_FILE='"DefaultPresets.hpp"'`) and get every supported
combination in one binary — at the cost of an 8–19 % throughput loss measured on
this hardware (larger code, more I-cache pressure).

## Run

```bash
rtl_sdr -f 1090000000 -s 2560000 -g 19.7 - \
  | ./stream1090 -s 2.56 -u 12 -q > messages.avr
```

Stop any service holding the dongle first (`readsb`, `dump1090`, …).

`-q` enables the built-in IQ low-pass filter. Note that `LowPassTaps` only has
coefficients for 2.4 and 2.56 Msps; at 3.2 Msps it degrades to pass-through.

## Verify

```bash
tools/bench.sh <binary> <capture.bin> 3 /tmp/bench
```

Prints wall/user/sys time, message count and AVR size. Correctness check: run the
upstream binary and this one on the same capture and compare the AVR output with
`cmp` — it must be byte-identical. `docs/validation.md` has the acceptance run
(two boards × three runs) including the expected md5.

## Layout

```
src/              full source tree (upstream + this project's changes)
prebuilt/         ready-to-run binary + MANIFEST (md5, arch, upstream commit)
install.sh        installer: prebuilt (default), --build, --upstream
patches/          the 8-file diff against upstream, for review or upstreaming
tools/            bench.sh, install.sh, crossbuild.sh, sync_upstream.sh
docs/             optimization, benchmarks, build, validation (en + .zh-CN)
VERSION           release version of this package
UPSTREAM_COMMIT   upstream commit this tree is based on
```

## Keeping up with upstream

This repository is not a git fork, so upstream history is not an ancestor and a
merge would conflict on every file. `tools/sync_upstream.sh` implements the
alternative: snapshot upstream, then replay the 8 changed files.

```bash
bash tools/sync_upstream.sh fetch    # clone upstream main into .cache/
bash tools/sync_upstream.sh check    # list upstream changes and collisions
bash tools/sync_upstream.sh rebase   # rebuild src/, re-applying local changes
```

If `check` reports `CONFLICT`, upstream touched a file we also rewrote; the script
keeps the upstream version and leaves ours in `.cache/src-backup` for manual merge.
Always rebuild and re-run the comparison after a sync.

## Scope and caveats

- Tuned for Cortex-A7 specifically (`-mcpu=cortex-a7`). The NEON path needs a
  128-bit SIMD unit; it is not a generic ARM improvement.
- Only 2.56 → 12 is instantiated in the shipped preset file.
- Streaming throughput depends on the consumer thread; adding cores does not help.
- The 8-stream configuration (`-u 8`) takes the same code path but has not been
  bit-exactly validated — only `ShiftRegisters<12>` was checked against a scalar
  reference (`docs/validation.md`).

## License

GPL-3.0, inherited from upstream stream1090. See `LICENSE`.
Upstream copyright belongs to its authors; this tree only adds the optimisations
listed above.
