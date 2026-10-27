# Building

English | [简体中文](build.zh-CN.md)

Four routes, in order of how well they perform on the target:

| route | where it runs | throughput | when to use |
|---|---|---|---|
| `install.sh` (prebuilt) | nowhere, it unpacks | 7.23 s (fastest) | default: no compiler on the board |
| native `install.sh --build` | on the board | 7.23 s | you want the binary built from this tree |
| `install.sh --upstream` | on the board | depends on upstream | you want the latest official source |
| `cmake` | on the board | slower, all presets | you want upstream's build system |
| `tools/crossbuild.sh` | on an x86_64 host | 7.82 s single / 8.62 s all presets | board cannot hold the compiler |

## Installer

`install.sh` is the entry point. Default mode installs `prebuilt/`:

```bash
sudo bash install.sh                     # verify + install, no compiler
sudo bash install.sh --prefix /opt/turbo
sudo bash install.sh --dry-run           # print the plan, touch nothing
```

Verification before anything is written to `$PREFIX/bin`:

| check | failure mode |
|---|---|
| `md5sum` against `prebuilt/MANIFEST` | abort, exit 3 |
| ELF `e_machine` == 40 (ARM) | abort, exit 3 |
| `uname -m` is armv7l/armv8l | abort unless `--force`, exit 3 |
| `ldd` reports no `not found` | abort, lists the missing libraries |
| one start-up run against empty stdin | abort on exit 124/126/127 |

If a different `stream1090` is already installed, it is kept as
`$PREFIX/bin/stream1090.prev` rather than silently replaced.

Zip archives and Windows copies drop the executable bit; the installer detects
that, runs the smoke test from a temporary 755 copy, and installs with `755`
either way.

`--build` compiles the bundled `src/` via `tools/install.sh`; `--upstream` does
the online path:

```bash
sudo bash install.sh --upstream
# == fetch latest official source
# repo   : https://github.com/mgrone/stream1090.git
# commit : <sha>
# == replay this project's change set
# patching file include/ShiftRegisters.hpp
# ...
```

It clones depth 1 into `.cache/install-upstream`, records the commit, runs
`patch -p1 --dry-run` first, and only then applies and builds. If the dry run
fails, it stops and tells you to use `--build` (bundled tree) or to rebase with
`tools/sync_upstream.sh` and regenerate the patch — it never compiles a
half-applied tree. The resulting binary is *not* the one the benchmarks were
taken on, so re-validate the AVR md5 (`docs/validation.md`).

Environment: `UPSTREAM_URL` overrides the repository, `PRESETS` equals
`--presets`.

### Build identity and the release sequence

`tools/version.sh` is the only place that decides what identity string a binary
carries:

```text
stream1090-turbo <semver>.<build-num>+<commit>[.dirty].<fingerprint>
stream1090-turbo 1.0.1.7+5a2b1c9.9f3a1c02be74
```

| part | source | notes |
|---|---|---|
| `1.0.1` | `VERSION` | bumped by hand when the contract changes |
| `7` | `git rev-list --count --first-parent HEAD` | monotonic, no state file to maintain |
| `5a2b1c9` | `git rev-parse --short HEAD` | `.dirty` while `src/ VERSION patches/` are modified |
| `9f3a1c02be74` | sha256 over the compiled sources | identical trees give identical strings |

No state file is involved: the build number comes from git, the fingerprint from
the sources, so the same tree always yields the same string — and therefore the
same md5. `install.sh --reproducible` embeds the bare semver for anyone who has
to rebuild on another machine and still match bit for bit.

The order matters. This is the fixed sequence for cutting a release:

1. commit the source change, so `build-num` and `commit` are final;
2. build the prebuilt binary with `STREAM1090_VERSION="$(tools/version.sh)"`,
   which works across a cross-compile because the string is computed on the host;
3. write that same string into `prebuilt/MANIFEST` as `built_version`, then run
   `tools/version.sh --write` to refresh `BUILDINFO`;
4. `git tag v<semver>` and push.

`install.sh` compares `built_version` in the manifest with the string actually
found inside the binary and aborts with exit 3 on a mismatch, so the manifest
cannot drift away from the artifact it describes.

## Native build

Requires g++ (11 or newer) and `librtlsdr-dev`.

```bash
PRESETS=BenchPresets.hpp tools/install.sh            # -> /usr/local/bin/stream1090
tools/install.sh . /opt/turbo                        # custom prefix
```

One preset is the default on purpose: a translation unit with all 27 upstream
instances is OOM-killed on a 512 MB board. `install.sh` uses the exact flag set the
benchmarks were taken with, so the resulting binary has md5
`f91f3d70436e46c48fdac40251a0277c`.

Do not add or remove `-DSTREAM1090_*` flags when comparing against the published
numbers; some of them change code generation even where the guarded code is not
reached.

## CMake

```bash
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j2
```

Note that `src/CMakeLists.txt` hard-codes `DefaultPresets.hpp`, so this builds
**all** upstream combinations. On a 512 MB board that is likely to be OOM-killed,
and where it does build it is ~19% slower than the single-preset binary. Use CMake
if you want the upstream build layout, `install.sh` if you want the fast binary.

## Cross build

Everything the cross compiler needs beyond its own sysroot is the board's
`librtlsdr`, `libusb-1.0` and `libudev` plus their headers. Put them in one
directory and point `SYSARM` at it:

```bash
mkdir -p /tmp/sysarm/usr/{include,lib/arm-linux-gnueabihf}
# copy from the board:
#   /usr/include/rtl-sdr.h /usr/include/rtl-sdr_export.h /usr/include/libusb-1.0/
#   /usr/lib/arm-linux-gnueabihf/librtlsdr.so* libusb-1.0.so* libudev.so*
ln -sf librtlsdr.so.2.0.1   /tmp/sysarm/usr/lib/arm-linux-gnueabihf/librtlsdr.so
ln -sf libusb-1.0.so.0.5.0  /tmp/sysarm/usr/lib/arm-linux-gnueabihf/libusb-1.0.so
ln -sf libudev.so.1.7.10    /tmp/sysarm/usr/lib/arm-linux-gnueabihf/libudev.so

SYSROOT=$HOME/xarm SYSARM=/tmp/sysarm \
  tools/crossbuild.sh src BenchPresets.hpp ./stream1090-armv7
```

Requirements for the toolchain directory (`SYSROOT`):

- the cross `g++-14` (not `g++`, and not gcc-13 — see `docs/benchmarks.md` §6),
- `--sysroot` must point at the directory *containing* `usr/`, otherwise the
  linker cannot find libc,
- `LD_LIBRARY_PATH` must include the host-side `libbfd`, or `as` fails at start-up.

`crossbuild.sh` sets all three, strips the result, and prints its md5.

## Presets and memory

`-s` and `-u` are template parameters. Each supported pair is instantiated at
compile time, and the binary can only accept pairs that were compiled in.

| preset file | instances | RAM needed | result |
|---|---|---|---|
| `BenchPresets.hpp` | 1 (2.56 → 12) | ~350 MB | builds on a 512 MB board |
| `DefaultPresets.hpp` | 27 | > 1 GB | OOM-killed on a 512 MB board |

Adding a pair means adding one line to a preset header:

```cpp
ADD_PRESET(RtlSdr, 2.4, 8)
```

Constraints enforced by `static_assert`: `-u` must be a multiple of 2 MHz and at
least `-s`. Note that `LowPassTaps` only carries coefficients for 2.4 and
2.56 Msps — at 3.2 Msps `-q` degrades to pass-through, and you need `-f <taps>`.

## Running

```bash
rtl_sdr -f 1090000000 -s 2560000 -g 19.7 - | stream1090 -s 2.56 -u 12 -q > messages.avr
```

Stop anything else holding the dongle first (`readsb`, `dump1090`, …).

## Keeping the tree in sync with upstream

This repository is not a git fork: the full source tree lives under `src/`, so
upstream history is not an ancestor and a merge would conflict on every file.
`tools/sync_upstream.sh` implements the alternative — snapshot upstream, then
replay the eight changed files on top.

```bash
bash tools/sync_upstream.sh fetch    # clone upstream main into .cache/
bash tools/sync_upstream.sh check    # what changed upstream, what collides with us
bash tools/sync_upstream.sh rebase   # rebuild src/ and replay our files
```

`check` prints `CONFLICT` when upstream touched a file this project also rewrote.
In that case `rebase` keeps the upstream version and leaves ours in
`.cache/src-backup` for a manual merge. Always rebuild and re-check the AVR md5
after a sync — an upstream decode change would show up there first.
