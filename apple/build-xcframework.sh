#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
WORK=${WORK:-$HERE/build}
JOBS=${JOBS:-4}
NICE=${NICE:-19}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

NAME=FFmpegAudio
BUNDLE_ID=io.github.thirdshift-sh.FFmpegAudio
XROS_MIN=2.0
MACOS_MIN=13.0
VERSION=$(cat "$SRC/RELEASE")

COMMON=(
    --disable-everything
    --disable-gpl
    --disable-nonfree
    --disable-autodetect
    --disable-programs
    --disable-doc
    --disable-network
    --disable-avdevice
    --disable-avformat
    --disable-avfilter
    --disable-swresample
    --disable-swscale
    --enable-pic
    --enable-decoder=dca
    --enable-decoder=truehd
    --enable-decoder=mlp
    --enable-decoder=ac3
    --enable-decoder=eac3
    --enable-parser=dca
    --enable-parser=mlp
    --enable-parser=ac3
)

EXCLUDED_HEADERS=(
    libavutil/hwcontext_*.h
    libavcodec/d3d11va.h
    libavcodec/d3d12va*.h
    libavcodec/dxva2.h
    libavcodec/jni.h
    libavcodec/mediacodec.h
    libavcodec/qsv.h
    libavcodec/vdpau.h
    libavcodec/videotoolbox.h
)

slice_args() {
    case $1 in
    xros)
        SDK=xros
        TARGET=arm64-apple-xros$XROS_MIN
        PLATFORM_ARGS=(--enable-cross-compile --arch=aarch64 --target-os=darwin)
        ;;
    xrsimulator)
        SDK=xrsimulator
        TARGET=arm64-apple-xros$XROS_MIN-simulator
        PLATFORM_ARGS=(--enable-cross-compile --arch=aarch64 --target-os=darwin)
        ;;
    macos)
        SDK=macosx
        TARGET=arm64-apple-macos$MACOS_MIN
        PLATFORM_ARGS=(--arch=aarch64 --target-os=darwin)
        ;;
    *)
        echo "unknown slice: $1 (expected xros, xrsimulator or macos)" >&2
        exit 2
        ;;
    esac
    PLATFORM_ARGS+=(
        "--cc=xcrun -sdk $SDK clang"
        "--extra-cflags=-target $TARGET"
        "--extra-ldflags=-target $TARGET"
    )
}

build_libs() {
    local slice=$1 dir=$WORK/$1
    slice_args "$slice"
    rm -rf "$dir"
    mkdir -p "$dir"
    (
        cd "$dir"
        nice -n "$NICE" "$SRC/configure" "${COMMON[@]}" "${PLATFORM_ARGS[@]}" >configure.log 2>&1 ||
            { tail -40 configure.log >&2; exit 1; }
        nice -n "$NICE" make -j"$JOBS" REVISION="$VERSION" >make.log 2>&1 || { tail -40 make.log >&2; exit 1; }
        make install-headers DESTDIR="$dir/stage" >/dev/null
    )
}

headers() {
    local include=$1 out=$2
    mkdir -p "$out"
    cp -R "$include/libavcodec" "$include/libavutil" "$out/"
    (
        cd "$out"
        for pattern in "${EXCLUDED_HEADERS[@]}"; do
            rm -f $pattern
        done
    )
    find "$out" -name '*.h' -exec sed -i '' -E 's#^([[:space:]]*\#[[:space:]]*include[[:space:]]+)"(libav(codec|util))/#\1"../\2/#' {} +
    (cd "$out" && find libavutil libavcodec -name '*.h' | sort | sed 's#.*#\#include "&"#') >"$out/$NAME.h"
}

plist() {
    local slice=$1 out=$2 platform minkey min
    case $slice in
    xros) platform=XROS minkey=MinimumOSVersion min=$XROS_MIN ;;
    xrsimulator) platform=XRSimulator minkey=MinimumOSVersion min=$XROS_MIN ;;
    macos) platform=MacOSX minkey=LSMinimumSystemVersion min=$MACOS_MIN ;;
    esac
    cat >"$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$platform</string>
	</array>
	<key>$minkey</key>
	<string>$min</string>
</dict>
</plist>
EOF
}

framework() {
    local slice=$1 dir=$WORK/$1 fw install_name bin root
    slice_args "$slice"
    fw=$dir/$NAME.framework
    rm -rf "$fw"
    if [ "$slice" = macos ]; then
        root=$fw/Versions/A
        mkdir -p "$root/Resources"
        install_name=@rpath/$NAME.framework/Versions/A/$NAME
    else
        root=$fw
        mkdir -p "$root"
        install_name=@rpath/$NAME.framework/$NAME
    fi
    bin=$root/$NAME
    xcrun -sdk "$SDK" clang -target "$TARGET" -dynamiclib \
        -install_name "$install_name" \
        -current_version "$VERSION" -compatibility_version "${VERSION%%.*}.0" \
        -Wl,-force_load,"$dir/libavcodec/libavcodec.a" \
        -Wl,-force_load,"$dir/libavutil/libavutil.a" \
        -Wl,-exported_symbols_list,"$HERE/exported_symbols.txt" \
        -Wl,-dead_strip \
        -Wl,-S \
        -o "$bin"
    xcrun -sdk "$SDK" strip -x "$bin"
    headers "$dir/stage/usr/local/include" "$root/Headers"
    mkdir -p "$root/Modules"
    cp "$HERE/module.modulemap" "$root/Modules/"
    if [ "$slice" = macos ]; then
        plist "$slice" "$root/Resources/Info.plist"
        ln -s A "$fw/Versions/Current"
        for f in $NAME Headers Modules Resources; do ln -s "Versions/Current/$f" "$fw/$f"; done
    else
        plist "$slice" "$root/Info.plist"
    fi
}

SLICES=("$@")
[ ${#SLICES[@]} -gt 0 ] || SLICES=(xros xrsimulator macos)
mkdir -p "$WORK"

for s in "${SLICES[@]}"; do
    echo "== $s: configure and build"
    build_libs "$s"
    echo "== $s: framework"
    framework "$s"
done

if [ -d "$WORK/xros/$NAME.framework" ] && [ -d "$WORK/xrsimulator/$NAME.framework" ] &&
    [ -d "$WORK/macos/$NAME.framework" ]; then
    rm -rf "$WORK/$NAME.xcframework"
    xcrun xcodebuild -create-xcframework \
        -framework "$WORK/xros/$NAME.framework" \
        -framework "$WORK/xrsimulator/$NAME.framework" \
        -framework "$WORK/macos/$NAME.framework" \
        -output "$WORK/$NAME.xcframework" >/dev/null
    (
        cd "$WORK/$NAME.xcframework"
        shasum -a 256 \
            "xros-arm64/$NAME.framework/$NAME" \
            "xros-arm64-simulator/$NAME.framework/$NAME" \
            "macos-arm64/$NAME.framework/Versions/A/$NAME"
    ) >"$WORK/SHA256SUMS"
    for s in xros xrsimulator macos; do
        printf '%s\t%s\n' "$s" "$(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' "$WORK/$s/config.h")"
    done >"$WORK/configure-lines.txt"
    echo "== $WORK/$NAME.xcframework"
    cat "$WORK/SHA256SUMS"
fi
