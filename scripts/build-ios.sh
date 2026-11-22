#!/usr/bin/env bash
# Membangun FFmpeg + libass (FreeType, FriBidi, HarfBuzz) untuk iPhone (arm64, iOS 16+) menjadi satu library statis
# ClipMIFFmpeg.xcframework. Konfigurasi sama dengan build Android ClipMI (LGPL, komponen terpilih), kecuali encoder
# video memakai VideoToolbox. fftools/ffmpeg.c ikut dikompilasi sebagai fungsi clipmi_ffmpeg_run() (src/), karena iOS
# tidak mengizinkan aplikasi menjalankan program lain.
#
# Dijalankan di macOS dengan Xcode, meson, ninja, dan pkg-config: scripts/build-ios.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
SRC="$WORK/src"
BUILD="$WORK/build"
PREFIX="$WORK/prefix"
DIST="$ROOT/dist"

FREETYPE=freetype-2.15.0
FRIBIDI=fribidi-1.0.18
HARFBUZZ=harfbuzz-15.1.0
LIBASS=libass-0.17.5
FFMPEG=ffmpeg-8.1.3

MIN_IOS=16.0
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
AR="$(xcrun --sdk iphoneos -f ar)"
RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
STRIP="$(xcrun --sdk iphoneos -f strip)"
ARCH_FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
COMMON_CFLAGS="$ARCH_FLAGS -O2 -fPIC"

mkdir -p "$SRC" "$BUILD" "$PREFIX" "$DIST"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""

fetch() { # fetch <nama file> <url> <sha256>
    local file="$SRC/$1"
    [ -f "$file" ] || curl -fsSL --retry 3 -o "$file" "$2"
    echo "$3  $file" | shasum -a 256 -c -
}

unpack() { # unpack <nama>
    [ -d "$BUILD/$1" ] || tar -xf "$SRC/$1.tar.xz" -C "$BUILD"
}

CROSS="$BUILD/ios-arm64.ini"
quoted() { local out=""; for f in $1; do out+="'$f', "; done; echo "$out"; }
cat > "$CROSS" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'

[built-in options]
c_args = [$(quoted "$COMMON_CFLAGS")]
cpp_args = [$(quoted "$COMMON_CFLAGS")]
c_link_args = [$(quoted "$ARCH_FLAGS")]
cpp_link_args = [$(quoted "$ARCH_FLAGS")]

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

meson_build() { # meson_build <nama> <opsi meson...>
    local name=$1; shift
    unpack "$name"
    rm -rf "$BUILD/$name/_ios"
    meson setup "$BUILD/$name/_ios" "$BUILD/$name" --cross-file "$CROSS" --prefix="$PREFIX" --libdir lib \
        --buildtype release --default-library static -Db_staticpic=true -Db_ndebug=true "$@"
    meson compile -C "$BUILD/$name/_ios"
    meson install -C "$BUILD/$name/_ios"
}

step_sources() {
    fetch $FREETYPE.tar.xz https://download.savannah.gnu.org/releases/freetype/$FREETYPE.tar.xz "${SHA_FREETYPE}"
    fetch $FRIBIDI.tar.xz https://github.com/fribidi/fribidi/releases/download/v1.0.18/$FRIBIDI.tar.xz "${SHA_FRIBIDI}"
    fetch $HARFBUZZ.tar.xz https://github.com/harfbuzz/harfbuzz/releases/download/15.1.0/$HARFBUZZ.tar.xz "${SHA_HARFBUZZ}"
    fetch $LIBASS.tar.xz https://github.com/libass/libass/releases/download/0.17.5/$LIBASS.tar.xz "${SHA_LIBASS}"
    fetch $FFMPEG.tar.xz https://ffmpeg.org/releases/$FFMPEG.tar.xz "${SHA_FFMPEG}"
}

step_freetype() {
    meson_build $FREETYPE -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled \
        -Dzlib=disabled -Dtests=disabled -Dmmap=enabled
}

step_fribidi() {
    unpack $FRIBIDI
    (
        cd "$BUILD/$FRIBIDI"
        make distclean >/dev/null 2>&1 || true
        ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" --enable-static --disable-shared \
            --disable-docs --disable-deprecated \
            CC="$CC $ARCH_FLAGS" AR="$AR" RANLIB="$RANLIB" CFLAGS="$COMMON_CFLAGS -DNDEBUG"
        make -C lib
        make -C lib install
        make install-pkgconfigDATA
    )
}

step_harfbuzz() {
    meson_build $HARFBUZZ -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dchafa=disabled -Dpng=disabled -Dzlib=disabled -Dicu=disabled -Dgraphite=disabled \
        -Dfontations=disabled -Dgdi=disabled -Ddirectwrite=disabled -Dcoretext=disabled -Dharfrust=disabled \
        -Dkbts=disabled -Dwasm=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled \
        -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Ddoc_tests=false \
        -Dutilities=disabled -Dbenchmark=disabled
}

step_libass() {
    meson_build $LIBASS -Dfontconfig=disabled -Ddirectwrite=disabled -Dcoretext=disabled \
        -Drequire-system-font-provider=false -Dlibunibreak=disabled -Dasm=enabled \
        -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled
}

# Filter sama dengan native/ffmpeg-config.sh ClipMI Android.
FILTERS=(
    scale crop overlay boxblur split setsar setdar format colorchannelmixer ass subtitles pad null copy fps
    geq drawbox drawtext tile select loop setpts trim concat xfade color nullsrc alphamerge fade tpad
    hflip vflip transpose unsharp gblur avgblur
    anull acopy highpass afftdn loudnorm aresample aformat atrim asetpts aselect anullsrc amix afade acrossfade
    apad volume pan volumedetect silencedetect
)

# main() ffmpeg.c menjadi fungsi; variabel sinyal tidak static. Gagal bila pola tidak ditemukan (versi FFmpeg lain).
patch_fftools() {
    local file="$BUILD/$FFMPEG/fftools/ffmpeg.c"
    grep -q '^int clipmi_ffmpeg_main(' "$file" && return
    for pattern in '^int main(int argc, char \*\*argv)$' '^static volatile int received_sigterm = 0;$' \
        '^static volatile int received_nb_signals = 0;$' '^static atomic_int transcode_init_done = 0;$' \
        '^static volatile int ffmpeg_exited = 0;$'; do
        grep -q "$pattern" "$file" || { echo "Pola tidak ditemukan di ffmpeg.c: $pattern" >&2; exit 1; }
    done
    sed -i '' \
        -e 's/^int main(int argc, char \*\*argv)$/int clipmi_ffmpeg_main(int argc, char **argv)/' \
        -e 's/^static volatile int received_sigterm = 0;$/volatile int received_sigterm = 0;/' \
        -e 's/^static volatile int received_nb_signals = 0;$/volatile int received_nb_signals = 0;/' \
        -e 's/^static atomic_int transcode_init_done = 0;$/atomic_int transcode_init_done = 0;/' \
        -e 's/^static volatile int ffmpeg_exited = 0;$/volatile int ffmpeg_exited = 0;/' \
        "$file"
    # Prototipe (FFmpeg memakai -Werror=missing-prototypes).
    perl -pi -e 's{^int clipmi_ffmpeg_main\(int argc, char \*\*argv\)$}{int clipmi_ffmpeg_main(int argc, char **argv);\nint clipmi_ffmpeg_main(int argc, char **argv)}' "$file"
    # Program ffmpeg tetap bisa ditaut (memastikan semua objek lengkap) lewat main kecil di file terpisah, yang
    # tidak ikut masuk library (aplikasi punya main sendiri).
    printf 'int clipmi_ffmpeg_main(int argc, char **argv);\nint main(int argc, char **argv) { return clipmi_ffmpeg_main(argc, argv); }\n' \
        > "$BUILD/$FFMPEG/fftools/clipmi_main.c"
    perl -pi -e 's{^(\s+)fftools/ffmpeg_dec\.o(\s+\\)$}{$1fftools/clipmi_main.o$2\n$1fftools/ffmpeg_dec.o$2}' \
        "$BUILD/$FFMPEG/fftools/Makefile"
    grep -q 'clipmi_main.o' "$BUILD/$FFMPEG/fftools/Makefile" || { echo "Gagal menambah clipmi_main.o" >&2; exit 1; }
}

step_ffmpeg() {
    unpack $FFMPEG
    patch_fftools
    local out="$BUILD/$FFMPEG/_ios"
    rm -rf "$out"
    mkdir -p "$out"
    (
        cd "$out"
        ../configure \
            --prefix="$PREFIX" \
            --target-os=darwin --arch=aarch64 --enable-cross-compile \
            --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --sysroot="$SDK" \
            --pkg-config=pkg-config --pkg-config-flags=--static \
            --extra-cflags="$COMMON_CFLAGS" --extra-cxxflags="$COMMON_CFLAGS" --extra-ldflags="$ARCH_FLAGS" \
            --extra-libs="-lc++" \
            --enable-pic --enable-static --disable-shared \
            --disable-debug --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
            --disable-autodetect --disable-network --disable-everything \
            --disable-ffplay --disable-ffprobe --enable-ffmpeg \
            --disable-avdevice \
            --enable-videotoolbox \
            --enable-zlib \
            --enable-libass --enable-libfreetype --enable-libharfbuzz --enable-libfribidi \
            --enable-protocol=file,pipe \
            --enable-demuxer=mov,matroska,image2,ass,concat,wav,mp3,aac \
            --enable-muxer=mp4,mov,ipod,null,image2,wav \
            --enable-parser=h264,hevc,aac,png,mjpeg \
            --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata,h264_metadata \
            --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,png,mjpeg \
            --enable-encoder=h264_videotoolbox,aac,png,mjpeg,pcm_s16le \
            --enable-filter="$(IFS=,; echo "${FILTERS[*]}")"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
}

step_package() {
    local out="$BUILD/$FFMPEG/_ios"
    local pkg="$BUILD/package"
    rm -rf "$pkg" "$DIST/ClipMIFFmpeg.xcframework" "$DIST/ClipMIFFmpeg.xcframework.zip"
    mkdir -p "$pkg/obj" "$pkg/include"

    "$CC" $COMMON_CFLAGS -I"$PREFIX/include" -c "$ROOT/src/clipmi_ffmpeg.c" -o "$pkg/obj/clipmi_ffmpeg.o"
    # Objek program ffmpeg (fftools, termasuk sumber daya yang dibuat saat build) tanpa main kecil.
    find "$out/fftools" -name '*.o' ! -name 'clipmi_main.o' -print > "$pkg/fftools.txt"
    cat "$pkg/fftools.txt"
    "$AR" rcs "$pkg/libfftools.a" $(cat "$pkg/fftools.txt") "$pkg/obj/clipmi_ffmpeg.o"

    libtool -static -o "$pkg/libClipMIFFmpeg.a" "$pkg/libfftools.a" \
        "$PREFIX"/lib/libavfilter.a "$PREFIX"/lib/libavformat.a "$PREFIX"/lib/libavcodec.a \
        "$PREFIX"/lib/libswscale.a "$PREFIX"/lib/libswresample.a "$PREFIX"/lib/libavutil.a \
        "$PREFIX"/lib/libass.a "$PREFIX"/lib/libharfbuzz.a "$PREFIX"/lib/libfribidi.a "$PREFIX"/lib/libfreetype.a

    # Header: API pembungkus dan FreeType (dipakai aplikasi untuk mengukur lebar teks seperti ClipMI Android).
    cp "$ROOT/src/clipmi_ffmpeg.h" "$pkg/include/"
    cp -R "$PREFIX/include/freetype2/." "$pkg/include/"
    cat > "$pkg/include/module.modulemap" <<'EOF'
module ClipMIFFmpeg {
    header "clipmi_ffmpeg.h"
    export *
}
EOF
    xcodebuild -create-xcframework -library "$pkg/libClipMIFFmpeg.a" -headers "$pkg/include" \
        -output "$DIST/ClipMIFFmpeg.xcframework"
    cp "$ROOT/LICENSE.md" "$DIST/ClipMIFFmpeg.xcframework/" 2>/dev/null || true
    (cd "$DIST" && ditto -c -k --keepParent ClipMIFFmpeg.xcframework ClipMIFFmpeg.xcframework.zip)
    shasum -a 256 "$DIST/ClipMIFFmpeg.xcframework.zip" | tee "$DIST/ClipMIFFmpeg.xcframework.zip.sha256"
    du -sh "$DIST/ClipMIFFmpeg.xcframework" "$pkg/libClipMIFFmpeg.a"
}

# Checksum tarball sumber (sama dengan yang dipakai build Android ClipMI).
source "$ROOT/scripts/sources.sh"

STEPS=("$@")
[ ${#STEPS[@]} -gt 0 ] || STEPS=(sources freetype fribidi harfbuzz libass ffmpeg package)
for s in "${STEPS[@]}"; do
    echo "=== $s ==="
    "step_$s"
done
echo "Selesai: $DIST"
