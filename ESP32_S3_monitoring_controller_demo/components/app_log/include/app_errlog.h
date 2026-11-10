#ifndef APP_ERRLOG_H
#define APP_ERRLOG_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_log.h"

#ifdef __cplusplus
extern "C" {
#endif

#define APP_ERRLOG_TEXT_LEN 104U

typedef struct {
    uint32_t seq;
    uint16_t boot;          /* boot number, increases by one per start-up */
    char level;             /* 'E', 'W' or 'I' */
    uint32_t uptime_ms;
    uint32_t epoch_s;       /* 0 while the clock was not synchronised */
    char text[APP_ERRLOG_TEXT_LEN + 1U];
} app_errlog_entry_t;

/*
 * Opens the "errlog" partition, stores what the previous run left in RTC memory, records the boot
 * (with the crash summary when the core dump belongs to it) and starts capturing every ESP_LOGW and
 * ESP_LOGE line. Call first in app_main.
 */
esp_err_t app_errlog_init(void);

/* Stores a warning or error that is not printed because console logging is switched off. */
void app_errlog_writev(esp_log_level_t level, const char *tag, const char *format, va_list args);
void app_errlog_writef(esp_log_level_t level, const char *tag, const char *format, ...)
    __attribute__((format(printf, 3, 4)));

/*
 * Copies up to max stored entries with seq >= start_seq, oldest first. *next_seq is the seq to ask
 * for next and *more tells whether newer entries remain. Returns the number of entries copied.
 */
size_t app_errlog_read(uint32_t start_seq, app_errlog_entry_t *out, size_t max,
                       uint32_t *next_seq, bool *more);

#ifdef __cplusplus
}
#endif

#endif
