# Benchmarks

English | [简体中文](benchmarks.zh-CN.md)

All numbers below come from replaying one fixed capture through stdin, so they
measure the decoder only — no USB, no dongle, no scheduler jitter from a live
device. Two identical boards were used (board A, board B); both are 4× Cortex-A7
at 1.296 GHz with 512 MB RAM, running the same kernel and toolchain.

Workload: `stream1090 -s 2.56 -u 12 -q` on a 10 s, 51,200,000 byte uint8 IQ
capture (2.56 Msps).

Method for every run:

```bash
tools/bench.sh <binary> capture.bin 1 /tmp/bench
```

which pins all cores to the `performance` governor, warms the file pages with one
un-timed pass, measures a pipe-only baseline, then times the decode. Three runs
per binary per board; the table shows all three plus their mean.

## 1. Baseline vs. this tree

| board | upstream (s) | mean | this tree (s) | mean | speed-up |
|---|---|---|---|---|---|
| A | 15.947 / 15.997 / 15.903 | 15.95 | 7.212 / 7.300 / 7.208 | 7.24 | **2.20×** |
| B | 15.985 / 15.996 / 15.909 | 15.96 | 7.257 / 7.257 / 7.247 | 7.25 | **2.20×** |

"Upstream" means the same source revision compiled with the same flags — it is a
build of `mgrone/stream1090` at the commit recorded in `UPSTREAM_COMMIT`, not a
prebuilt distribution binary.

Pipe-only baseline: 0.41–0.42 s for the same 51 MB, i.e. I/O is 2.6% of the
optimised run time and never the bottleneck.

Output identity: 256 messages, 9154 bytes of AVR, md5
`e7bc7960e32d93d094c413300cd1227e` — byte-identical for both binaries on both
boards.

v1.0.3 adds a cross-core prefetch on the consumer side (see §4). Measured
back-to-back in one session against a control re-run of the v1.0.2 build
(7.427 / 7.376 / 7.444, mean 7.42), it brings the same board to
7.327 / 7.278 / 7.269 (mean 7.28, −1.9 %); the shipped release binary measures
7.231 / 7.304 / 7.278 s. Output stays byte-identical.

## 2. Where the time went

Each row is a separate build; the deltas are the isolated contribution of one
change (same capture, same flags, board A).

| build | real (s) | note |
|---|---|---|
| upstream | 15.87 | reference |
| `-DSTREAM1090_NO_DEMOD` | 5.07 | Manchester + shift + dispatch removed |
| `-DSTREAM1090_NO_SQRT` | 15.08 | magnitude replaced by `I²+Q²` |
| NEON shift registers + 2 threads | 9.13 | step 1 + 2 |
| … + Manchester fused into the shift | 8.43 | step 3 + 4 |
| … + input block 8192 → 1024 | 7.25 | step 5 |
| … + input block 1024 → 576 | 7.24 | no further gain |
| … + cross-core prefetch (v1.0.3) | 7.28 | step 6; the v1.0.2 build re-ran at 7.42 in the same session |

Each session drifts by ±0.1 s (thermal, /tmp state), which is why the prefetch
row is quoted against a control re-run measured minutes before it, not against
the 7.25 above.

Two conclusions that shaped the rest of the work:

- The demodulation side is 68% of the original run time (15.87 − 5.07 s). On
  arithmetic alone, an optimisation that does not touch `DemodCore` keeps the
  overall gain near 1.5× even in the ideal case.
- Removing `sqrt` saves only 0.8 s, so the magnitude stage is not worth
  vectorising.

## 3. Effect of the input block size

`DesiredInputBufferSize` controls `NumBlocks` in `Sampler`, hence the size of each
block handed from the producer to the demodulator thread.

| bytes | real (s) | L1 pressure |
|---|---|---|
| 8192 (154 KB blocks) | 8.43 | blocks do not fit, every hand-off misses |
| 1024 (21 KB blocks) | **7.25** | fits comfortably |
| 576 (14 KB blocks) | 7.24 | no gain, more sync overhead |

The gain is not from smaller I/O — it is cache locality across the thread
boundary. 1024 is the sweet spot; the value is overridable at build time with
`-DSTREAM1090_INPUT_BUFFER_TARGET=`.

## 4. Profile of the final build

`perf record -F 2000`, share of 15.26 G cycles, board A:

| symbol | share | side |
|---|---|---|
| demod thread lambda (Manchester + shift, inlined) | 26.3% | consumer |
| `DemodCore::dispatchHandled` | 21.7% | consumer |
| `SampleStream::read` (read + FIR + magnitude) | 19.4% | producer |
| `SamplerFunc<16,75,72>::sample` | 14.4% | producer |
| `handleExtSquitterLongMessage` | 9.6% | consumer |
| `handleDF11ShortMessage` | 2.6% | consumer |

Consumer work is ~7.1 s of the 7.25 s wall time, producer work ~4.0 s. They run
concurrently, so the wall time is the consumer's. That is why further
producer-side optimisation no longer moves the total.

v1.0.3 attacks the memory side of that consumer time. The magnitude ring is
86 KB — wider than the 32 KB L1D — and every line in it was written by the
producer core, so the consumer misses L1 on every access and the in-order
Cortex-A7 stalls until the shared L2 answers. The consumer now issues
prefetches a few bit periods ahead (`STREAM1090_PREFETCH_DIST`), letting the
L2 latency overlap shift work already in flight: 7.42 → 7.28 s in the
same-session measurement quoted in §2.

## 5. What was tried and rejected

Every item below was implemented or measured, then dropped. They are recorded so
the same ground is not covered twice.

| Direction | Why it failed |
|---|---|
| Dispatch on a third thread | The dispatcher mutates shift-register state; handing it off requires a snapshot of all 12 streams (~1.1 GB/s at this rate), more than the work saved. |
| Split the 12 streams across 2–3 threads | `phaseDupCheck` couples stream order; the synchronisation costs more than the parallelism gains. |
| Fold both CRCs into 64-bit lanes | NEON has no 64-bit variable shift; the emulation is more instructions than two 32-bit folds. |
| NEON upsampler (`SamplerFunc<16,75,72>`) | 14% of cycles but on the producer side, which is not the critical path — zero wall-time gain. |
| `-ffast-math` + `sqrtf` vectorisation | Already enabled; the magnitude loop is memory-bound, not compute-bound. |
| Reduce `-u` to 8 | Fewer streams, but changes the decoded output (225 vs 256 messages); not a drop-in optimisation. |
| Full preset set (9 combinations) in one binary | 19% slower on this hardware: 190 KB → 722 KB of code, I-cache pressure in the consumer. |

## 6. Cross-compiled builds

Built on an x86_64 host with `arm-linux-gnueabihf-g++-14`, same flags, measured on
board A:

| build | presets | real (s) | vs. native |
|---|---|---|---|
| native g++ 14.2 | 1 | 7.23 | — |
| cross gcc 14.2 | 1 | 7.82 | +8% |
| cross gcc 14.2 | 9 | 8.62 | +19% |
| cross gcc 13.3 | 9 | 8.40 | +16% |

The cross build spends *less* user time but more wall time, which points at the
consumer thread: its code generation is slightly worse, and the consumer sets the
wall clock. Native compilation on the board remains the fastest option; cross
compilation is the practical one when the board cannot hold the compiler in RAM.
