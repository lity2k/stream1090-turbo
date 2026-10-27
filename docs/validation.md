# Validation

English | [简体中文](validation.zh-CN.md)

The rule this project was held to: **if the decoded output is not byte-identical
to upstream, the change is a regression, no matter how fast it is.** Everything
below exists to enforce that.

## 1. Reference capture

One capture is used for every comparison:

| property | value |
|---|---|
| source | RTL-SDR, 1090 MHz, 2.56 Msps, gain 19.7 |
| length | 10 s |
| size | 51,200,000 bytes (uint8 interleaved IQ) |
| decode result | 256 messages, 9154 bytes AVR |
| AVR md5 | `e7bc7960e32d93d094c413300cd1227e` |

Message count and md5 must match for both binaries. They do, on both boards,
across all runs.

The capture itself is not shipped in this repository (51 MB); regenerate one with
`rtl_sdr -f 1090000000 -s 2560000 -g 19.7 -n 25600000 capture.bin`. Any capture
works for the comparison as long as both binaries see the same bytes.

## 2. Two boards, three runs each

| board | binary | real (s) | messages | AVR bytes | AVR md5 |
|---|---|---|---|---|---|
| A | upstream | 15.947 / 15.997 / 15.903 | 256 | 9154 | `e7bc7960…` |
| A | this tree | 7.212 / 7.300 / 7.208 | 256 | 9154 | `e7bc7960…` |
| B | upstream | 15.985 / 15.996 / 15.909 | 256 | 9154 | `e7bc7960…` |
| B | this tree | 7.257 / 7.257 / 7.247 | 256 | 9154 | `e7bc7960…` |

The two boards produce the same md5 as each other, which also rules out
board-specific behaviour in the decoder.

## 3. Live-capture check

Benchmarking on a stored file can hide an input-path regression, so one run used a
capture taken on the spot rather than the reference file:

- 51,200,000 bytes captured live, decoded by both binaries
- upstream 15.920 s, this tree 7.250 s
- both produce 150 messages and AVR md5 `ed7cc6959614145ec6b792f9a3080306`
- `cmp` reports the two outputs identical

## 4. End-to-end, live dongle

Stored-file runs measure decode speed in isolation. The question that actually
matters is whether the pipeline keeps up with the dongle in real time:

| binary | wall time for 10 s of live IQ | verdict |
|---|---|---|
| upstream | 16.9 s | falls behind, backlog grows without bound |
| this tree | 11.1 s | 7.25 s of work inside a 10 s window, keeps up |

The remaining 3.8 s are capture start-up and pipe latency, not decode.

## 5. Bit-exact unit test for the shift registers

The NEON shifter is the most intricate change, so it is tested against a scalar
reference rather than only end-to-end.

Two test programs (not shipped — they depend on the internal test harness) drive
`shiftInNewBits` with 5000 random bit sequences and compare, per stream:

- the returned hit mask,
- `crc_56` and `crc_112`,
- the extracted downlink format,
- the extracted 56-bit and 112-bit frames.

Both the bit-input entry point and the sample-input entry point (which includes
the fused Manchester comparison) must print `ALL OK`.

This test is what caught the `vbsl` all-ones-mask bug described in
`docs/optimization.md` §1: end-to-end message counts had already dropped 10×, but
the per-lane state still looked correct. A single-lane check would have passed.

## 6. Coverage limit

The bit-exact test covers `ShiftRegisters<12>`, i.e. `-u 12`. The 8-stream path
(`-u 8`) uses the same template and the same code, and end-to-end it produces the
same 225 messages as upstream on the reference capture, but it has **not** been
run through the bit-exact test. Treat `-u 8` as verified-by-inspection only.

## 7. Rebuild reproducibility

Rebuilding from a fresh checkout of this repository with `tools/install.sh`
produces a binary with md5 `f91f3d70436e46c48fdac40251a0277c`, identical to the
binary all the numbers above were measured on. That is checked after every change
to the tree, and after every upstream sync.
