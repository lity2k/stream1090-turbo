# What was changed, and why it works

English | [简体中文](optimization.zh-CN.md)

Eight files change; `main.cpp` and `src/` do not. Everything below is either in
`include/` or in `presets/BenchPresets.hpp`.

The full diff is `patches/0001-cortex-a7-neon-pipeline.patch`.

## The shape of the original problem

`stream1090` does not look for a preamble. It keeps a 112-bit shift register per
stream and tests CRC on every bit clock, so the work per input sample is fixed and
independent of how many messages arrive. With `-s 2.56 -u 12` there are
`NumStreams = 12` parallel bit streams at 12 MHz, i.e. 12 million shift-register
updates per second, each one a 112-bit shift plus two CRC folds plus a
downlink-format test.

Upstream does this with two `uint64_t` per stream and a scalar loop over the 12
streams. On Cortex-A7 that is ~15.9 s of CPU for 10 s of IQ: the decoder cannot
keep up with the dongle.

Relevant hardware facts (all measured on the target):

- Cortex-A7, 4 cores, 1.296 GHz, 32 KB L1D per core, 256 KB L2 shared.
- NEON is the 64-bit-datapath variant: a 128-bit Q operation issues as two
  64-bit halves, so a `vshlq` costs 2 cycles, not 1. Still 4× the scalar width.
- No ARMv8 CRC32 or crypto extensions, so CRC must be folded by hand.

## 1. NEON shift registers

Twelve streams split into three groups of four. One lane carries one stream:

| vector | holds |
|---|---|
| `w0` | bits 31..0 of each stream |
| `w1` | bits 63..32 |
| `w2` | bits 95..64 |
| `w3` | bits 127..96 |

Instead of shifting two 64-bit halves per stream, a group shifts as a whole:
`carry` out of `w0` feeds `w1`, and so on. `vsliq_n_u32(carry, w, 1)` does
`(w << 1) | carry` in a single instruction, replacing the usual `shl` + `orr`
pair — this is used both for the window shift and for the CRC fold.

The same pass computes:

- two CRC folds (`crc_56`, `crc_112`) with `veor` / `vshl` / `vor` against the
  polynomial,
- the downlink-format field (`w3 >> 27`),
- whether the format is one this build handles,
- and whether this stream produced a hit.

Hits are packed into a `uint64_t` bitmask, one bit per stream, and the mask is
returned to the caller. On a normal call it is zero and the dispatcher is never
entered — that is the common case, and keeping it branch-free matters.

**The bug that cost an afternoon**: `vbsl`/`vand` need an all-ones mask, not a
0/1 value. The first version built the per-lane hit mask as `0/1` and then used it
directly as a bitmask, so only lane 0 ever contributed; the message count fell
from 256 to 26 while every individual lane still reported a hit. Fixed by
converting with `vceqq_u32(x, one)`. `docs/validation.md` describes the bit-exact
test that now guards this.

## 2. Two-thread pipeline

Input-side and demodulation-side work are independent across a block boundary, so
they moved onto two threads:

- **producer** — read IQ, DC removal, IQ low-pass FIR, magnitude (`sqrt`), upsample
  2.56 → 12 MHz;
- **consumer** — Manchester comparison and shift-register update.

`BlockRing::m_fullBlocks` became `std::atomic` so the ring can be shared. The
producer is throttled by `m_produced - m_consumed < NumFreeSampleBuffers`, using a
condition variable rather than a spin.

Result: 15.87 s → 9.13 s with the NEON shifter in place, at 1.57 cores of
effective parallelism. The consumer is the critical path, so more threads would
not help.

## 3. Manchester fused into the shift update

The original loop

```cpp
m_newBits[j] = m_demodPos[j] > m_demodPos[j + (NumStreams >> 1)];
```

is not vectorised by GCC — it emits twelve scalar `ldr / cmp / ite / str`
sequences per 12 bits. The comparison now happens inside the vector registers,
against the half-symbol offset, and feeds the shift directly. The `m_newBits`
scratch array is gone entirely: the bit never reaches memory.

## 4. Ring head-room (correctness, not speed)

`NumFreeSampleBuffers` is `NumSampleBuffers - 2`, not `- 1`. The demodulator
reaches back into the previous block for confidence/RSSI/preamble data
(`lookBack` up to 1524 samples). With a single buffer of head-room the writer
would overwrite exactly that region while the consumer was reading it — a
data race that would only show up as rare wrong decodes under load. This was
present in the two-thread draft and fixed before any benchmark was trusted.

## 5. Input block size

`DesiredInputBufferSize` 8192 → 1024 drops each hand-off block from 154 KB to
21 KB, which brings the producer→consumer hand-off into the cache-resident
range.
8.43 s → 7.25 s. Going to 576 (14 KB) changes nothing measurable.

Overridable at build time:

```bash
-DSTREAM1090_INPUT_BUFFER_TARGET=1024
```

## 6. Preset instantiation

`-s` and `-u` are template parameters; every supported pair is a separate
instantiation, and upstream's `DefaultPresets.hpp` expands to 27 of them. One
translation unit with all 27 needs more RAM than a 512 MB board has — `cc1plus`
is OOM-killed. `presets/BenchPresets.hpp` instantiates exactly one pair, 2.56 → 12.

This is a build-configuration choice, not a hard-coded rate: the algorithms are
all parameterised on `NumStreams`. It also happens to be faster (190 KB vs 722 KB
of code, 19% better on this hardware). On a machine with enough RAM, switch back
to `DefaultPresets.hpp` and every upstream combination is available in one binary.

## 7. Cross-core prefetch (v1.0.3)

The magnitude ring lives on the producer side of the pipeline boundary. It is
86 KB — wider than the 32 KB L1D — and every line in it was written by the
other core, so the consumer misses L1 on every access and the in-order
Cortex-A7 sits idle until the shared 256 KB L2 answers. At ~1 M bit periods per
second and six cache lines per period, that latency is a large share of the
consumer's ~7.1 s.

The fix is earlier loads, not fewer: `consumeOneBlock` issues a prefetch
(`pld`) for the lines the Manchester/shift loop is about to touch, a few bit
periods ahead. The distance is `STREAM1090_PREFETCH_DIST` in
`include/Global.hpp`. The L2 latency then overlaps shift work already in
flight instead of stalling it.

Measured back-to-back against a control re-run of the previous build in the
same session: 7.42 s → 7.28 s (−1.9 %), AVR output byte-identical.

## What this is not

- Not a generic ARM speed-up. `-mcpu=cortex-a7` and the 128-bit NEON assumption
  are explicit; the code will build elsewhere but the tuning does not transfer.
- Not a decoder change. Message count, payload bytes and AVR md5 are identical to
  upstream on every capture tested.
- Not finished. The consumer still spends 21.7% in `dispatchHandled` and 9.6% in
  `handleExtSquitterLongMessage`; both were inspected and no profitable
  restructuring was found on this ISA. One measured gain from after the
  v1.0.2 benchmarks — the cross-core prefetch (§7) — is included in
  v1.0.3. See `docs/benchmarks.md` §5 for what was measured and rejected.
