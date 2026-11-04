#!/bin/bash
# Build NootedRed.kext without xmake, as a fallback for machines that only have
# the Xcode Command Line Tools (no full Xcode, so `xcodebuild` is unavailable).
#
# Usage: tools/build-manual.sh
#        AppleForgePath=/path/to/AppleForge tools/build-manual.sh
#        NRED_BUILD_BRANCH=my-test tools/build-manual.sh
#
# This reproduces what the AppleForge LiluPlugIn rule does: compile every source
# with the kext flags, generate KModInfo.c, link against MacKernelSDK's kmod
# stubs, render Info.plist, ad-hoc sign. Artifacts land under the same per-branch
# layout that tools/build-branch.sh produces, so either path yields:
#   build/branches/<branch>/macosx/x86_64/release/NootedRed.kext
#
# Requires: Xcode CLT (clang, xcrun), python3, and an AppleForge checkout that
# contains Lilu/ and MacKernelSDK/ (git clone --recurse-submodules).
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FORGE=${AppleForgePath:-$HOME/Desktop/AppleForge}

die() { echo "error: $*" >&2; exit 1; }

# --- toolchain ------------------------------------------------------------
command -v xcrun >/dev/null 2>&1 || die "xcrun not found; install Xcode Command Line Tools"
CC=$(xcrun --find clang 2>/dev/null) || die "clang not found"
CXX=$(xcrun --find clang++ 2>/dev/null) || die "clang++ not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

[ -d "$FORGE/Lilu/Lilu" ] || die "Lilu not found under $FORGE
clone the build dependency first:
  git clone --depth 1 --recurse-submodules https://git.chefkiss.dev/AppleHax/AppleForge.git $FORGE
or point AppleForgePath at an existing checkout"
[ -d "$FORGE/MacKernelSDK/Headers" ] || die "MacKernelSDK not found under $FORGE/MacKernelSDK"
[ -d "$FORGE/MacKernelSDK/Library/universal" ] || die "MacKernelSDK prebuilt kmod stubs missing"

# --- identity -------------------------------------------------------------
NAME=NootedRed
BUNDLE_ID=${NRED_BUNDLE_ID:-org.ChefKiss.NootedRed}

# Single source of truth for the version is xmake.lua; do not duplicate it here.
VERSION=$(sed -n 's/^[[:space:]]*set_version("\([^"]*\)").*/\1/p' "$ROOT/xmake.lua" | head -1)
[ -n "$VERSION" ] || die "could not read set_version() from xmake.lua"

# --- per-branch artifact directory (same rules as tools/build-branch.sh) ---
if [ -n "${NRED_BUILD_BRANCH:-}" ]; then
    BRANCH=$NRED_BUILD_BRANCH
else
    BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
        BRANCH=detached-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
    fi
fi
BRANCH=$(printf '%s' "$BRANCH" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
[ -n "$BRANCH" ] || BRANCH=unknown
OUT="$ROOT/build/branches/$BRANCH/macosx/x86_64/release"
OBJ="$ROOT/build/manual/$BRANCH/obj"
GEN="$ROOT/build/manual/$BRANCH/gen"

MIN_OS=11.0
MIN_OS_NUM=110000

echo "branch:   $BRANCH"
echo "version:  $VERSION"
echo "AppleForge: $FORGE"
echo "artifacts: $OUT"
echo

rm -rf "$OBJ" "$GEN"
mkdir -p "$OBJ" "$GEN" "$OUT"

COMMON=(
    "--target=x86_64-apple-macos${MIN_OS}"
    -nostdinc
    -fno-builtin
    -fno-exceptions
    -fno-rtti
    -fno-common
    -fno-non-call-exceptions
    -fno-asynchronous-unwind-tables
    -mno-red-zone -mmmx -msse -msse2 -msse3 -mfpmath=sse -mssse3
    -fapple-kext
    -O2
    -w
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
    -DMAC_OS_X_VERSION_MIN_REQUIRED=$MIN_OS_NUM
    -D__MAC_OS_X_VERSION_MIN_REQUIRED=$MIN_OS_NUM
    "-DMODULE_VERSION=$VERSION"
    "-DPRODUCT_NAME=$NAME"
    -I "$ROOT/NootedRed"
    -isystem "$FORGE/Lilu/Lilu"
    -isystem "$FORGE/MacKernelSDK/Headers"
)

echo "==> generating KModInfo.c"
cat > "$GEN/KModInfo.c" <<EOF
#include <libkern/libkern.h>
#include <mach/mach_types.h>
#include <mach/kmod.h>

__private_extern__ kern_return_t ${NAME}_kern_start(kmod_info_t *ki, void *d);
__private_extern__ kern_return_t ${NAME}_kern_stop(kmod_info_t *ki, void *d);

__private_extern__ kern_return_t _start(kmod_info_t *ki, void *d);
__private_extern__ kern_return_t _stop(kmod_info_t *ki, void *d);

__attribute__((visibility("default")))
KMOD_EXPLICIT_DECL(${BUNDLE_ID}, "${VERSION}", _start, _stop)

__private_extern__ kmod_start_func_t *_realmain = ${NAME}_kern_start;
__private_extern__ kmod_stop_func_t *_antimain = ${NAME}_kern_stop;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
EOF

SOURCES=()
while IFS= read -r src; do SOURCES+=("$src"); done < <(find "$ROOT/NootedRed" -name '*.cpp' | sort)
EXTRA=(
    "$FORGE/Lilu/Lilu/Library/plugin_start.cpp"
    "$FORGE/MacKernelSDK/Library/kmod/c_start.c"
    "$FORGE/MacKernelSDK/Library/kmod/c_stop.c"
    "$GEN/KModInfo.c"
)

# Compiled serially on purpose: the file list contains paths under both $ROOT and
# $FORGE, and serial build keeps failure attribution obvious.
echo "==> compiling ${#SOURCES[@]} sources"
FAILED=()
for src in "${SOURCES[@]}" "${EXTRA[@]}"; do
    base=$(printf '%s' "$src" | sed "s|$ROOT/||; s|$FORGE/|forge_|; s|/|_|g; s|\.\(cpp\|c\)$||")
    obj="$OBJ/$base.o"
    drv=$CXX
    std=(-std=c++23)
    case "$src" in
        *.c) drv=$CC; std=(-std=c11) ;;
    esac
    if ! "$drv" -c "$src" -o "$obj" "${std[@]}" "${COMMON[@]}" 2>"$OBJ/$base.err"; then
        echo "FAILED: ${src#"$ROOT/"}"
        sed -n '1,20p' "$OBJ/$base.err"
        FAILED+=("$src")
    fi
done

if [ ${#FAILED[@]} -ne 0 ]; then
    echo "error: ${#FAILED[@]} file(s) failed to compile" >&2
    exit 1
fi

echo "==> linking"
"$CXX" -o "$OBJ/$NAME" "$OBJ"/*.o \
    "${COMMON[@]}" \
    -static -nostdlib -nostdlib++ -Wl,-kext \
    -L "$FORGE/MacKernelSDK/Library/universal" -lkmod -lkmodc++

echo "==> packaging kext"
KEXT="$OUT/$NAME.kext"
rm -rf "$KEXT"
mkdir -p "$KEXT/Contents/MacOS"
cp "$OBJ/$NAME" "$KEXT/Contents/MacOS/$NAME"
# strip writes to a separate file; replacing in place trips hardened-runtime
# write protection on some systems.
if strip -x -o "$OBJ/$NAME.stripped" "$OBJ/$NAME" 2>/dev/null; then
    cp "$OBJ/$NAME.stripped" "$KEXT/Contents/MacOS/$NAME"
else
    echo "warning: strip failed, shipping unstripped binary" >&2
fi

python3 - "$ROOT/NootedRed/Info.plist" "$KEXT/Contents/Info.plist" "$NAME" "$BUNDLE_ID" "$VERSION" <<'PY'
import sys

src, dst, name, bundle_id, version = sys.argv[1:6]
text = open(src).read()
values = {
    "EXECUTABLE_NAME": name,
    "PRODUCT_NAME": name,
    "PRODUCT_NAME:rfc1034identifier": name,
    "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
    "MODULE_VERSION": version,
    "MARKETING_VERSION": version,
    "CURRENT_PROJECT_VERSION": version,
}
# Longest key first so "PRODUCT_NAME" cannot eat "PRODUCT_NAME:rfc1034identifier".
for key in sorted(values, key=len, reverse=True):
    text = text.replace("$(%s)" % key, values[key]).replace("${%s}" % key, values[key])
open(dst, "w").write(text)
PY

# Ad-hoc signing is optional: OpenCore injects unsigned kexts fine. But a failed
# codesign leaves a .cstemp next to the binary and a _CodeSignature that no longer
# matches it, which is worse than no signature at all -- so clean up on failure.
if ! codesign -f -s - "$KEXT" 2>/dev/null; then
    rm -f "$KEXT/Contents/MacOS/$NAME.cstemp"
    rm -rf "$KEXT/Contents/_CodeSignature"
    echo "warning: ad-hoc codesign failed; shipping unsigned kext (fine for OpenCore injection)" >&2
fi

echo
echo "done: $KEXT"
lipo -info "$KEXT/Contents/MacOS/$NAME" 2>/dev/null || file "$KEXT/Contents/MacOS/$NAME"
