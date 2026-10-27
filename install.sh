#!/bin/bash
# install.sh — install stream1090-turbo on a Cortex-A7 board.
#
# Three sources, in order of cost:
#
#   default        install the bundled prebuilt binary (no compiler needed)
#   --build        build from the bundled src/ snapshot, then install
#   --upstream     fetch the latest official source, replay this project's
#                  change set, build, then install
#
# Usage:
#   sudo bash install.sh [options]
#
#   --prefix DIR      install prefix, default /usr/local -> DIR/bin/stream1090
#   --presets FILE    preset header for --build / --upstream, default BenchPresets.hpp
#   --upstream        fetch latest https://github.com/mgrone/stream1090 and merge
#   --build           compile from the bundled src/ instead of using the prebuilt
#   --prebuilt        force the prebuilt path (default)
#   --force           continue when the arch check fails or the target exists
#   --reproducible    drop the git build number, embed the bare semver only
#   --dry-run         print what would happen, change nothing
#   -h, --help        this text
#   -V, --version     print installer and prebuilt version
#
# Environment:
#   UPSTREAM_URL      override the official repository URL
#   PRESETS           same as --presets
#   STREAM1090_VERSION  pin the identity string embedded in the binary
#
# Every binary this script produces carries a version string that identifies
# the exact source state it came from:
#
#   stream1090-turbo 1.0.1.3+5a2b1c9.9f3a1c02be74
#                    ^semver ^build ^commit ^source fingerprint
#
# `stream1090 -h | head -1` prints it, so a stock upstream build and a turbo
# build can never be confused, and two turbo builds can always be told apart.
#
# Exit codes: 0 ok, 1 runtime failure, 2 usage error, 3 verification failed.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=/usr/local
PRESETS=${PRESETS:-BenchPresets.hpp}
MODE=prebuilt
FORCE=0
DRY=0
REPRO=0
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/mgrone/stream1090.git}
PATCH="$HERE/patches/0001-cortex-a7-neon-pipeline.patch"
VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo unknown)
TARGET_NAME=stream1090

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
    awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
    exit "${1:-0}"
}

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)     [ $# -ge 2 ] || die "--prefix needs a value" 2; PREFIX=$2; shift 2 ;;
        --prefix=*)   PREFIX=${1#*=}; shift ;;
        --presets)    [ $# -ge 2 ] || die "--presets needs a value" 2; PRESETS=$2; shift 2 ;;
        --presets=*)  PRESETS=${1#*=}; shift ;;
        --upstream)   MODE=upstream; shift ;;
        --build)      MODE=build; shift ;;
        --prebuilt)   MODE=prebuilt; shift ;;
        --force)      FORCE=1; shift ;;
        --reproducible) REPRO=1; shift ;;
        --dry-run)    DRY=1; shift ;;
        -V|--version)
            say "installer : stream1090-turbo $VERSION"
            mf="$HERE/prebuilt/MANIFEST"
            if [ -f "$mf" ]; then
                # built_version is what the packaged binary actually carries
                pb=$(sed -n 's/^built_version=//p' "$mf" | head -1)
                say "prebuilt  : ${pb:-not recorded}"
                say "md5       : $(sed -n 's/^md5=//p' "$mf" | head -1)"
            fi
            exit 0 ;;
        -h|--help)    usage 0 ;;
        *)            warn "unknown option: $1"; usage 2 ;;
    esac
done

# ---------------------------------------------------------------- helpers
md5_of() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -md5 "$1" | sed 's/.*= *//'
    else
        echo ""
    fi
}

# ELF e_machine (offset 18, 2 bytes LE): 40 = ARM, 62 = x86-64, 183 = AArch64
elf_machine_code() {
    [ -f "$1" ] || { echo ""; return; }
    od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n'
}

host_arch() { uname -m 2>/dev/null || echo unknown; }

# Does this board run ARMv7 binaries?
host_ok_for_prebuilt() {
    case "$(host_arch)" in
        armv7l|armv7|armv8l|arm) return 0 ;;
        *) return 1 ;;
    esac
}

need_root_or_writable_prefix() {
    local dir="$PREFIX/bin"
    while [ ! -d "$dir" ]; do dir=$(dirname "$dir"); done
    if [ -w "$dir" ]; then return 0; fi
    if [ "$(id -u)" = "0" ]; then return 0; fi
    die "$PREFIX is not writable; re-run with sudo, or pass --prefix \$HOME/.local"
}

install_binary() {
    local src=$1 origin=$2
    local dst="$PREFIX/bin/$TARGET_NAME"
    [ "$DRY" = 1 ] && { say "would install $src -> $dst"; return 0; }
    install -d "$PREFIX/bin"
    if [ -e "$dst" ] && [ "$(md5_of "$dst")" != "$(md5_of "$src")" ]; then
        cp -p "$dst" "$dst.prev"
        warn "existing binary kept as $dst.prev"
    fi
    install -m 755 "$src" "$dst"
    say ""
    say "installed : $dst"
    say "source    : $origin"
    say "md5       : $(md5_of "$dst")"
}

# ---------------------------------------------------------------- prebuilt
install_prebuilt() {
    local manifest="$HERE/prebuilt/MANIFEST"
    local bin file want_md5 have_md5 code

    [ -f "$manifest" ] || die "prebuilt/MANIFEST missing; use --build" 1
    mver=$(sed -n 's/^version=//p' "$manifest" | head -1)
    mbuilt=$(sed -n 's/^built_version=//p' "$manifest" | head -1)
    [ -z "$mver" ] || [ "$mver" = "$VERSION" ] || warn "prebuilt was built for v$mver, this package says v$VERSION"
    file=$(sed -n 's/^file=//p' "$manifest" | head -1)
    want_md5=$(sed -n 's/^md5=//p' "$manifest" | head -1)
    bin="$HERE/prebuilt/$file"

    step "verify bundled prebuilt (v$VERSION)"
    [ -f "$bin" ] || die "prebuilt binary missing: $bin (use --build)" 1
    say "file   : prebuilt/$file"
    say "size   : $(wc -c < "$bin") bytes (manifest $(sed -n 's/^size=//p' "$manifest" | head -1))"

    # 1. checksum
    have_md5=$(md5_of "$bin")
    if [ -n "$want_md5" ] && [ -n "$have_md5" ]; then
        if [ "$want_md5" != "$have_md5" ]; then
            die "checksum mismatch: manifest $want_md5, file $have_md5" 3
        fi
        say "md5    : $have_md5 (matches manifest)"
    else
        warn "md5 tool unavailable, checksum check skipped"
    fi

    # 1b. the identity string must really be inside the binary, not just in the
    #     manifest — that is the whole point of embedding it at compile time
    if [ -n "$mbuilt" ]; then
        # strings splits on NUL, so it returns the constant exactly as compiled;
        # the grep fallback uses a strict character class because a plain
        # [^"]* swallows the rest of .rodata when no quotes are present.
        embedded=""
        if command -v strings >/dev/null 2>&1; then
            embedded=$(strings -a "$bin" 2>/dev/null | grep -m1 '^stream1090-turbo ' || true)
        fi
        [ -n "$embedded" ] || embedded=$(grep -a -o 'stream1090-turbo [0-9][0-9A-Za-z._+-]*' "$bin" 2>/dev/null | head -1 || true)
        if [ -z "$embedded" ]; then
            warn "no build identity inside the binary; this prebuilt predates versioning"
        elif [ "$embedded" = "$mbuilt" ]; then
            say "build  : $embedded (matches manifest)"
        else
            die "identity mismatch: manifest '$mbuilt', binary '$embedded'" 3
        fi
    fi

    # 2. ELF machine + host compatibility
    code=$(elf_machine_code "$bin")
    case "$code" in
        40) say "elf    : ARM (e_machine 40)" ;;
        "") warn "cannot read ELF header, arch check skipped" ;;
        *)  die "unexpected ELF machine $code; this prebuilt is not an ARM binary" 3 ;;
    esac

    if ! host_ok_for_prebuilt; then
        if [ "$FORCE" = 1 ]; then
            warn "host arch $(host_arch) cannot run this binary; continuing because of --force"
        else
            die "host arch is $(host_arch), this prebuilt targets armv7l. Use --build, or --force to install anyway" 3
        fi
    fi

    # 3. shared library dependencies
    if command -v ldd >/dev/null 2>&1 && host_ok_for_prebuilt; then
        if ldd "$bin" 2>/dev/null | grep -q 'not found'; then
            ldd "$bin" 2>/dev/null | grep 'not found' >&2
            die "missing shared libraries; apt install -y librtlsdr0 libstdc++6" 3
        fi
        say "libs   : all resolved"
    fi

    # 4. smoke run: must not fail to start (empty stdin exits on its own).
    #    GitHub zip archives and Windows copies lose the exec bit, so test a
    #    755 copy when the packaged file is not executable.
    if host_ok_for_prebuilt; then
        runner="$bin"
        if [ ! -x "$bin" ]; then
            runner=$(mktemp "${TMPDIR:-/tmp}/stream1090.XXXXXX")
            cp "$bin" "$runner"
            chmod 755 "$runner"
            say "mode   : package lost the exec bit, testing a 755 copy"
        fi
        set +e
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 "$runner" </dev/null >/dev/null 2>&1
        else
            "$runner" </dev/null >/dev/null 2>&1
        fi
        rc=$?
        set -e
        [ "$runner" = "$bin" ] || rm -f "$runner"
        case "$rc" in
            124|126|127) die "prebuilt does not start (exit $rc); use --build" 3 ;;
            *) say "smoke  : started and exited with $rc" ;;
        esac
    fi

    need_root_or_writable_prefix
    install_binary "$bin" "prebuilt v$VERSION, upstream $(sed -n 's/^upstream_commit=//p' "$manifest" | cut -c1-12), $(sed -n 's/^preset_params=//p' "$manifest")"
}

# ---------------------------------------------------------------- build
check_build_deps() {
    command -v g++ >/dev/null 2>&1 || die "g++ not found: apt install -y g++" 1
    [ -f /usr/include/rtl-sdr.h ] || die "rtl-sdr.h not found: apt install -y librtlsdr-dev" 1
}

build_from_src() {
    local src=$1
    [ -d "$src" ] || die "source tree missing: $src" 1
    step "build from $src (presets: $PRESETS)"
    if [ "$REPRO" = 1 ]; then
        STREAM1090_VERSION=$(bash "$HERE/tools/version.sh" --frozen)
        export STREAM1090_VERSION
    fi
    if [ "$DRY" = 1 ]; then
        say "would run: PRESETS=$PRESETS bash tools/install.sh $src $PREFIX"
        if [ "$REPRO" = 1 ]; then
            say "version: $STREAM1090_VERSION (reproducible, git metadata dropped)"
        else
            say "version: $(bash "$HERE/tools/version.sh" --src "$src")"
        fi
        return 0
    fi
    check_build_deps
    PRESETS="$PRESETS" bash "$HERE/tools/install.sh" "$src" "$PREFIX"
    say ""
    say "installed : $PREFIX/bin/$TARGET_NAME"
    say "source    : local build from $(basename "$src")"
    say "md5       : $(md5_of "$PREFIX/bin/$TARGET_NAME")"
}

# ---------------------------------------------------------------- upstream
install_upstream() {
    local cache="$HERE/.cache/install-upstream"
    local sha suffix

    step "fetch latest official source"
    [ -f "$PATCH" ] || die "patch file missing: $PATCH" 1
    say "repo   : $UPSTREAM_URL"
    if [ "$DRY" = 1 ]; then
        say "would clone into .cache/install-upstream, replay patches/, build and install"
        return 0
    fi
    command -v git >/dev/null 2>&1 || die "git not found: apt install -y git" 1

    rm -rf "$cache"
    mkdir -p "$HERE/.cache"
    if ! git clone --depth 1 -q "$UPSTREAM_URL" "$cache"; then
        rm -rf "$cache"
        die "cannot fetch $UPSTREAM_URL — no network, blocked TLS, or a wrong URL.
       Use --build to compile the bundled tree, or set UPSTREAM_URL to a reachable mirror."
    fi
    sha=$(git -C "$cache" rev-parse HEAD)
    say "commit : $sha"

    if [ -f "$HERE/UPSTREAM_COMMIT" ]; then
        local known; known=$(tr -d ' \n' < "$HERE/UPSTREAM_COMMIT")
        [ "$known" = "$sha" ] || say "note   : this release was cut from ${known:0:12}; upstream has moved on"
    fi

    step "replay this project's change set"
    if ! patch -p1 --dry-run -d "$cache" < "$PATCH" >/dev/null 2>&1; then
        warn "the patch does not apply to upstream $sha"
        warn "upstream changed one of the 8 files this project rewrites."
        warn "Options:  --build   (use the bundled, already-merged src/ tree)"
        warn "          bash tools/sync_upstream.sh fetch && check && rebase, then regenerate the patch"
        exit 3
    fi
    patch -p1 -d "$cache" < "$PATCH" | sed 's/^/  /'
    rm -rf "$cache/.git"

    # identity: the binary is built from upstream sources, so mark it as such
    suffix="up${sha:0:7}"
    if [ "$REPRO" = 1 ]; then
        STREAM1090_VERSION=$(bash "$HERE/tools/version.sh" --frozen)
    else
        STREAM1090_VERSION=$(bash "$HERE/tools/version.sh" --suffix "$suffix")
    fi
    export STREAM1090_VERSION

    PRESETS="$PRESETS" bash "$HERE/tools/install.sh" "$cache" "$PREFIX"
    say ""
    say "installed : $PREFIX/bin/$TARGET_NAME"
    say "source    : upstream ${sha:0:12} + patches/0001"
    say "md5       : $(md5_of "$PREFIX/bin/$TARGET_NAME")"
    say ""
    say "Verify before trusting it: decoded output must stay byte-identical,"
    say "see docs/validation.md. tools/bench.sh measures it."
}

# ---------------------------------------------------------------- main
case "$MODE" in
    prebuilt) install_prebuilt ;;
    build)    build_from_src "$HERE/src" ;;
    upstream) install_upstream ;;
esac

say ""
say "done. Start with:"
say "  rtl_sdr -f 1090000000 -s 2560000 -g 19.7 - | $PREFIX/bin/$TARGET_NAME -s 2.56 -u 12 -q > messages.avr"
