// Pembungkus fftools/ffmpeg.c yang sudah di-patch scripts/build-ios.sh: main() menjadi clipmi_ffmpeg_main(), dan
// variabel sinyal tidak lagi static supaya bisa direset sebelum setiap render dan dipakai untuk membatalkan.
#include "clipmi_ffmpeg.h"

#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libavutil/ffversion.h"
#include "libavutil/log.h"

int clipmi_ffmpeg_main(int argc, char **argv);

// Dari fftools/ffmpeg.c (FFmpeg 8.1). ffmpeg_cleanup() membebaskan array ini tetapi tidak mengembalikan jumlahnya ke 0,
// jadi tanpa reset render kedua memakai jumlah lama dengan array NULL.
typedef struct InputFile InputFile;
typedef struct OutputFile OutputFile;
typedef struct FilterGraph FilterGraph;
typedef struct Decoder Decoder;
typedef struct AVIOContext AVIOContext;
extern InputFile **input_files;
extern int nb_input_files;
extern OutputFile **output_files;
extern int nb_output_files;
extern FilterGraph **filtergraphs;
extern int nb_filtergraphs;
extern Decoder **decoders;
extern int nb_decoders;
extern AVIOContext *progress_avio;
extern atomic_uint nb_output_dumped;
extern volatile int received_sigterm;
extern volatile int received_nb_signals;
extern atomic_int transcode_init_done;
extern volatile int ffmpeg_exited;

static pthread_mutex_t run_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *log_file = NULL;
static atomic_int running = 0;

static void log_callback(void *avcl, int level, const char *fmt, va_list vl) {
    if (level > av_log_get_level()) return;
    static int print_prefix = 1;
    char line[2048];
    pthread_mutex_lock(&log_lock);
    av_log_format_line2(avcl, level, fmt, vl, line, sizeof(line), &print_prefix);
    if (log_file) {
        fputs(line, log_file);
        fflush(log_file);
    }
    pthread_mutex_unlock(&log_lock);
}

int clipmi_ffmpeg_run(int argc, const char **argv, const char *directory, const char *log_path) {
    if (pthread_mutex_trylock(&run_lock) != 0) return -1;
    atomic_store(&running, 1);

    char previous[4096];
    int changed = 0;
    if (directory && getcwd(previous, sizeof(previous)) && chdir(directory) == 0) changed = 1;

    pthread_mutex_lock(&log_lock);
    log_file = log_path ? fopen(log_path, "a") : NULL;
    pthread_mutex_unlock(&log_lock);
    av_log_set_level(AV_LOG_INFO);
    av_log_set_callback(log_callback);
    // Penulisan ke pipe yang tertutup tidak boleh menghentikan aplikasi.
    signal(SIGPIPE, SIG_IGN);

    input_files = NULL;
    nb_input_files = 0;
    output_files = NULL;
    nb_output_files = 0;
    filtergraphs = NULL;
    nb_filtergraphs = 0;
    decoders = NULL;
    nb_decoders = 0;
    progress_avio = NULL;
    atomic_store(&nb_output_dumped, 0);
    received_sigterm = 0;
    received_nb_signals = 0;
    atomic_store(&transcode_init_done, 0);
    ffmpeg_exited = 0;

    char **args = calloc((size_t) argc + 2, sizeof(char *));
    args[0] = strdup("ffmpeg");
    for (int i = 0; i < argc; i++) args[i + 1] = strdup(argv[i]);
    int ret = clipmi_ffmpeg_main(argc + 1, args);
    for (int i = 0; i <= argc; i++) free(args[i]);
    free(args);

    av_log_set_callback(av_log_default_callback);
    pthread_mutex_lock(&log_lock);
    if (log_file) {
        fprintf(log_file, "== clipmi_ffmpeg_run selesai: %d\n", ret);
        fclose(log_file);
        log_file = NULL;
    }
    pthread_mutex_unlock(&log_lock);
    if (changed) chdir(previous);

    atomic_store(&running, 0);
    pthread_mutex_unlock(&run_lock);
    return ret;
}

void clipmi_ffmpeg_cancel(void) {
    if (!atomic_load(&running)) return;
    // Sama dengan sigterm_handler ffmpeg.c tanpa exit(): transcode berhenti di loop berikutnya.
    received_sigterm = SIGTERM;
    received_nb_signals++;
}

const char *clipmi_ffmpeg_version(void) {
    return FFMPEG_VERSION;
}
