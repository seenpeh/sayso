#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/.build"
app_path="${1:-$project_dir/Sayso.app}"
framework="$build_dir/whisper.framework"
version="v1.8.4"
archive_sha="1c7a93bd20fe4e57e0af12051ddb34b7a434dfc9acc02c8313393150b6d1821f"

mkdir -p "$build_dir"
if [[ ! -f "$framework/whisper" || ! -f "$build_dir/whisper-LICENSE" ]]; then
    url="https://github.com/ggml-org/whisper.cpp/releases/download/$version/whisper-$version-xcframework.zip"
    curl -fLsS --retry 2 -o "$build_dir/whisper.zip" "$url"
    printf '%s  %s\n' "$archive_sha" "$build_dir/whisper.zip" | shasum -a 256 -c
    unzip -q -o "$build_dir/whisper.zip" \
        'build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework/*' -d "$build_dir"
    curl -fLsS --retry 2 -o "$build_dir/whisper-LICENSE" \
        "https://raw.githubusercontent.com/ggml-org/whisper.cpp/$version/LICENSE"
    ditto "$build_dir/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework" "$framework"
fi

sdk="${VOICEKEY_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
arch="$(uname -m)"
if [[ -n "${VOICEKEY_ZIG:-}" ]]; then
    compiler=("$VOICEKEY_ZIG" cc)
    if [[ "$arch" == arm64 ]]; then arch=aarch64; fi
    target="$arch-macos.14.0"
    export ZIG_GLOBAL_CACHE_DIR="$build_dir/zig-cache"
    export ZIG_LOCAL_CACHE_DIR="$build_dir/zig-local-cache"
else
    compiler=(xcrun --sdk macosx clang)
    target="$arch-apple-macos14.0"
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/voicekey-build.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Sayso.app"
mkdir -p "$bundle/Contents/"{MacOS,Frameworks,Resources}
cp -RPX "$framework" "$bundle/Contents/Frameworks/whisper.framework"
cp "$build_dir/whisper-LICENSE" "$bundle/Contents/Resources/Whisper-LICENSE.txt"
cp "$project_dir/Resources/"* "$bundle/Contents/Resources/"
mv "$bundle/Contents/Resources/Info.plist" "$bundle/Contents/Info.plist"
plutil -lint "$bundle/Contents/Info.plist"

"${compiler[@]}" -target "$target" -isysroot "$sdk" -fobjc-arc -O2 \
    -iframework "$sdk/System/Library/Frameworks" -F"$sdk/System/Library/Frameworks" \
    -isystem "$sdk/usr/include" -L"$sdk/usr/lib" \
    -Wall -Wextra -Wno-unused-parameter -F"$build_dir" -framework whisper \
    -framework Foundation -framework AppKit -framework AVFoundation -framework Carbon \
    -framework ApplicationServices -framework QuartzCore -framework CoreGraphics -framework Metal -framework AudioToolbox -framework ServiceManagement -lobjc \
    -Wl,-rpath,@executable_path/../Frameworks \
    "$project_dir/Sources/"*.m \
    -o "$bundle/Contents/MacOS/VoiceKey"

xattr -cr "$bundle"
codesign --force --sign - "$bundle/Contents/Frameworks/whisper.framework"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
if [[ "$app_path" == *.zip ]]; then
    ditto -c -k --norsrc --noextattr --keepParent "$bundle" "$app_path"
else
    ditto --norsrc --noextattr "$bundle" "$app_path"
fi
printf 'Built %s\n' "$app_path"
