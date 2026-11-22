# clipmi-ios-native

FFmpeg 8.1.3 + libass untuk aplikasi ClipMI iOS, dibangun sebagai satu library statis `ClipMIFFmpeg.xcframework`
(iPhone arm64, iOS 16+).

- Konfigurasi sama dengan build Android ClipMI: LGPL, tanpa jaringan, hanya demuxer/decoder/filter yang dipakai render
  klip. Encoder video `h264_videotoolbox` (hardware iPhone).
- iOS tidak mengizinkan aplikasi menjalankan program lain, jadi `fftools/ffmpeg.c` dikompilasi sebagai fungsi:
  `clipmi_ffmpeg_run(argc, argv, directory, log_path)` dan `clipmi_ffmpeg_cancel()` ([src/clipmi_ffmpeg.h](src/clipmi_ffmpeg.h)).
  Patch-nya kecil dan ada di `patch_fftools` ([scripts/build-ios.sh](scripts/build-ios.sh)).
- Header FreeType ikut disertakan (pengukuran lebar teks).

| Komponen | Versi | Lisensi |
|---|---|---|
| FFmpeg | 8.1.3 | LGPL 2.1+ |
| libass | 0.17.5 | ISC |
| FreeType | 2.15.0 | FreeType License (FTL) |
| FriBidi | 1.0.18 | LGPL 2.1+ |
| HarfBuzz | 15.1.0 | MIT ("Old MIT") |

## Build

Di macOS dengan Xcode, `meson`, `ninja`, dan `pkg-config`:

```bash
bash scripts/build-ios.sh
```

Hasil: `dist/ClipMIFFmpeg.xcframework(.zip)`. GitHub Actions membangunnya di setiap push; tag `v*` membuat rilis.
Tarball sumber diunduh dari situs resmi masing-masing dan dicocokkan dengan SHA-256 di `scripts/sources.sh`.
