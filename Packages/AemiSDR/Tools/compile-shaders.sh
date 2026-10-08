#!/bin/sh
# Rebuilds the precompiled metallibs in Sources/AemiSDR/Resources from Sources/AemiSDR/Shaders.
#
# Upstream AemiSDR compiles these with a SwiftPM build-tool plugin on every build. The vendored copy
# ships the compiled libraries instead, so the app builds without plugin trust prompts and without
# Xcode's separately downloaded Metal toolchain. Run this after editing a .metal file; it needs the
# toolchain (`xcodebuild -downloadComponent MetalToolchain`). The flags match upstream's
# MetalCompilerTool: `.ci.metal` files are Core Image kernels (-fcikernel / -cikernel).
set -eu

cd "$(dirname "$0")/.."
SHADERS=Sources/AemiSDR/Shaders
OUT=Sources/AemiSDR/Resources
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

compile() { # source, base name, platform label, sdk, min-version flag, ci (yes/no)
    src=$1; base=$2; label=$3; sdk=$4; minflag=$5; ci=$6
    air="$TMP/$base.$label.air"
    if [ "$ci" = yes ]; then
        xcrun --sdk "$sdk" metal -c -fcikernel -fmodules=none "$minflag" "$src" -o "$air"
        xcrun --sdk "$sdk" metallib -cikernel "$air" -o "$OUT/$base.$label.metallib"
    else
        xcrun --sdk "$sdk" metal -c -fmodules=none "$minflag" "$src" -o "$air"
        xcrun --sdk "$sdk" metallib "$air" -o "$OUT/$base.$label.metallib"
    fi
}

for src in "$SHADERS"/*.metal; do
    name=$(basename "$src" .metal)
    case "$name" in
        *.ci) base=${name%.ci}; ci=yes ;;
        *) base=$name; ci=no ;;
    esac
    compile "$src" "$base" iOS iphoneos -mios-version-min=14.0 "$ci"
    compile "$src" "$base" iOSSimulator iphonesimulator -mios-simulator-version-min=14.0 "$ci"
    compile "$src" "$base" macOS macosx -mmacos-version-min=11.0 "$ci"
done

ls -l "$OUT"
