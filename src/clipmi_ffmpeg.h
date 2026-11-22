// FFmpeg di dalam proses untuk aplikasi iOS (iOS tidak mengizinkan aplikasi menjalankan program lain).
// fftools/ffmpeg.c dikompilasi sebagai fungsi; argumen sama persis dengan baris perintah `ffmpeg`.
#ifndef CLIPMI_FFMPEG_H
#define CLIPMI_FFMPEG_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Menjalankan ffmpeg dengan argumen `argv` (tanpa nama program) di folder `directory` (chdir selama berjalan, supaya
 * filter bisa memakai nama file relatif seperti `ass=subs.ass:fontsdir=fonts`). Log FFmpeg ditulis ke `log_path`
 * (ditambahkan). Satu render pada satu waktu; panggilan kedua saat masih berjalan langsung gagal (-1).
 *
 * @return kode keluar ffmpeg (0 = berhasil, 255 = dibatalkan).
 */
int clipmi_ffmpeg_run(int argc, const char **argv, const char *directory, const char *log_path);

/** Membatalkan render yang sedang berjalan (seperti Ctrl+C); clipmi_ffmpeg_run mengembalikan 255. */
void clipmi_ffmpeg_cancel(void);

/** Versi FFmpeg (misalnya "8.1.3"). */
const char *clipmi_ffmpeg_version(void);

#ifdef __cplusplus
}
#endif

#endif
