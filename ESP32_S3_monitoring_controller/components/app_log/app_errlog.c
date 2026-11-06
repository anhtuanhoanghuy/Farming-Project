#include "app_errlog.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "esp_attr.h"
#include "esp_core_dump.h"
#include "esp_partition.h"
#include "esp_rom_crc.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#define PARTITION_LABEL "errlog"
#define PARTITION_SUBTYPE ((esp_partition_subtype_t)0x40)
#define RECORD_SIZE 128U
#define RECORD_MAGIC 0xE10AU
#define SECTOR_SIZE 4096U
#define RECORDS_PER_SECTOR (SECTOR_SIZE / RECORD_SIZE)
#define RING_LEN 24U
#define RING_MAGIC 0x45524C47U
#define LOG_LINE_MAX 144U
#define RATE_SITES 16U
#define RATE_WINDOW_US (10LL * 60LL * 1000000LL)
#define RATE_BURST 5U
#define EPOCH_VALID_S 1700000000LL
#define WRITER_PERIOD_MS 1000U
#define WRITER_STACK 3072U
#define WRITER_PRIORITY 2U

typedef struct {
    uint16_t magic;
    uint8_t level;
    uint8_t text_len;
    uint32_t seq;
    uint16_t boot;
    uint16_t reserved;
    uint32_t uptime_ms;
    uint32_t epoch_s;
    char text[APP_ERRLOG_TEXT_LEN];
    uint32_t crc;
} record_t;
_Static_assert(sizeof(record_t) == RECORD_SIZE, "errlog record must stay 128 bytes");
_Static_assert(SECTOR_SIZE % RECORD_SIZE == 0U, "records must not straddle flash sectors");

/* Lines not yet in flash; RTC memory keeps them through a panic or watchdog reset. */
typedef struct {
    uint32_t magic;
    uint32_t head;
    uint32_t count;
    uint32_t dropped;
    record_t rec[RING_LEN];
} ring_t;

typedef struct {
    const void *site;
    int64_t window_start_us;
    uint16_t count;
    uint16_t suppressed;
} rate_entry_t;

typedef struct {
    char text[APP_ERRLOG_TEXT_LEN];
    size_t len;
} twdt_msg_t;

static RTC_NOINIT_ATTR ring_t s_ring;
static portMUX_TYPE s_ring_lock = portMUX_INITIALIZER_UNLOCKED;
static portMUX_TYPE s_rate_lock = portMUX_INITIALIZER_UNLOCKED;
static rate_entry_t s_rate[RATE_SITES];
static uint8_t s_rate_next;
static const esp_partition_t *s_part;
static SemaphoreHandle_t s_flash_lock;
static uint32_t s_sectors;
static uint32_t s_slots;
static uint32_t s_write_slot;
static uint32_t s_next_seq = 1U;
static uint16_t s_boot = 1U;
static volatile bool s_ready;
static vprintf_like_t s_prev_vprintf;
static twdt_msg_t s_twdt_msg;
static record_t s_twdt_rec;

/* ---- Records ------------------------------------------------------------------------------- */

static uint32_t record_crc(const record_t *rec)
{
    return esp_rom_crc32_le(0U, (const uint8_t *)rec, offsetof(record_t, crc));
}

static bool record_valid(const record_t *rec)
{
    return rec->magic == RECORD_MAGIC && rec->text_len <= APP_ERRLOG_TEXT_LEN &&
           rec->crc == record_crc(rec);
}

static size_t clamp_len(int n, size_t cap)
{
    if (n <= 0) return 0U;
    return (size_t)n < cap ? (size_t)n : cap - 1U;
}

/* Length that does not end inside a multi-byte UTF-8 character. */
static size_t utf8_cut(const char *s, size_t len)
{
    size_t i = len;
    size_t tail = 0U;
    while (i > 0U && tail < 3U && ((unsigned char)s[i - 1U] & 0xC0U) == 0x80U) {
        i--;
        tail++;
    }
    if (i == 0U) return len;
    unsigned char lead = (unsigned char)s[i - 1U];
    size_t need = lead >= 0xF0U ? 3U : lead >= 0xE0U ? 2U : lead >= 0xC0U ? 1U : 0U;
    return (need == 0U || tail >= need) ? len : i - 1U;
}

static void fill_record(record_t *rec, char level, uint32_t skipped, const char *text, size_t len,
                        bool from_isr)
{
    memset(rec, 0, sizeof(*rec));
    size_t used = 0U;
    if (skipped > 0U) {
        used = clamp_len(snprintf(rec->text, sizeof(rec->text), "[+%lu skipped] ",
                                  (unsigned long)skipped), sizeof(rec->text));
    }
    size_t room = APP_ERRLOG_TEXT_LEN - used;
    if (len > room) len = utf8_cut(text, room);
    memcpy(rec->text + used, text, len);
    rec->magic = RECORD_MAGIC;
    rec->level = (uint8_t)level;
    rec->text_len = (uint8_t)(used + len);
    rec->boot = s_boot;
    rec->uptime_ms = (uint32_t)(esp_timer_get_time() / 1000LL);
    if (!from_isr) {
        time_t now = time(NULL);
        if ((int64_t)now >= EPOCH_VALID_S) rec->epoch_s = (uint32_t)now;
    }
    rec->crc = record_crc(rec);
}

static void ring_push(const record_t *rec)
{
    portENTER_CRITICAL_SAFE(&s_ring_lock);
    if (s_ring.count >= RING_LEN) {
        s_ring.dropped++;
    } else {
        s_ring.rec[(s_ring.head + s_ring.count) % RING_LEN] = *rec;
        s_ring.count++;
    }
    portEXIT_CRITICAL_SAFE(&s_ring_lock);
}

static bool ring_valid(void)
{
    return s_ring.magic == RING_MAGIC && s_ring.head < RING_LEN && s_ring.count <= RING_LEN;
}

static void push_text(char level, const char *text, int n)
{
    record_t rec;
    fill_record(&rec, level, 0U, text, clamp_len(n, APP_ERRLOG_TEXT_LEN + 1U), false);
    ring_push(&rec);
}

/* A call site that repeats keeps its first lines; the rest are counted, not stored. */
static bool rate_allow(const void *site, uint32_t *skipped)
{
    int64_t now = esp_timer_get_time();
    bool allow = true;
    *skipped = 0U;
    portENTER_CRITICAL_SAFE(&s_rate_lock);
    rate_entry_t *entry = NULL;
    for (size_t i = 0; i < RATE_SITES; i++) {
        if (s_rate[i].site == site) {
            entry = &s_rate[i];
            break;
        }
    }
    if (entry == NULL) {
        entry = &s_rate[s_rate_next];
        s_rate_next = (uint8_t)((s_rate_next + 1U) % RATE_SITES);
        entry->site = site;
        entry->window_start_us = now;
        entry->count = 0U;
        entry->suppressed = 0U;
    }
    if (now - entry->window_start_us >= RATE_WINDOW_US) {
        *skipped = entry->suppressed;
        entry->window_start_us = now;
        entry->count = 0U;
        entry->suppressed = 0U;
    }
    if (entry->count < RATE_BURST) {
        entry->count++;
    } else {
        if (entry->suppressed < UINT16_MAX) entry->suppressed++;
        allow = false;
    }
    portEXIT_CRITICAL_SAFE(&s_rate_lock);
    return allow;
}

static void store_line(char level, const void *site, const char *text, size_t len)
{
    while (len > 0U && (text[len - 1U] == '\n' || text[len - 1U] == '\r' || text[len - 1U] == ' ')) {
        len--;
    }
    uint32_t skipped;
    if (len == 0U || !rate_allow(site, &skipped)) return;
    record_t rec;
    fill_record(&rec, level, skipped, text, len, false);
    ring_push(&rec);
}

/* ---- Log capture --------------------------------------------------------------------------- */

static char format_level(const char *fmt)
{
    while (*fmt == '\033') {
        fmt = strchr(fmt, 'm');
        if (fmt == NULL) return '\0';
        fmt++;
    }
    return *fmt;
}

/* Keeps "tag: message" of an esp_log line, without colours and the "W (uptime) " prefix. */
static void capture_line(char level, const void *site, const char *fmt, va_list args)
{
    char line[LOG_LINE_MAX];
    size_t len = clamp_len(vsnprintf(line, sizeof(line), fmt, args), sizeof(line));
    const char *text = line;
    const char *end = line + len;
    while (text < end && *text == '\033') {
        const char *m = memchr(text, 'm', (size_t)(end - text));
        if (m == NULL) return;
        text = m + 1;
    }
    if (end - text > 3 && text[0] == level && text[1] == ' ' && text[2] == '(') {
        const char *close = strstr(text, ") ");
        if (close != NULL) text = close + 2;
    }
    const char *esc = memchr(text, '\033', (size_t)(end - text));
    store_line(level, site, text, (size_t)((esc != NULL ? esc : end) - text));
}

static int log_hook(const char *fmt, va_list args)
{
    char level = format_level(fmt);
    if (level == 'E' || level == 'W') {
        va_list copy;
        va_copy(copy, args);
        capture_line(level, fmt, fmt, copy);
        va_end(copy);
    }
    /* The hook can run before esp_log_set_vprintf() has returned the previous writer. */
    vprintf_like_t prev = s_prev_vprintf;
    return prev != NULL ? prev(fmt, args) : vprintf(fmt, args);
}

void app_errlog_writev(esp_log_level_t level, const char *tag, const char *format, va_list args)
{
    if (!s_ready || format == NULL || level == ESP_LOG_NONE || level > ESP_LOG_WARN) return;
    char line[LOG_LINE_MAX];
    size_t head = clamp_len(snprintf(line, sizeof(line), "%s: ", tag != NULL ? tag : "?"),
                            sizeof(line));
    size_t body = clamp_len(vsnprintf(line + head, sizeof(line) - head, format, args),
                            sizeof(line) - head);
    store_line(level == ESP_LOG_ERROR ? 'E' : 'W', format, line, head + body);
}

void app_errlog_writef(esp_log_level_t level, const char *tag, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    app_errlog_writev(level, tag, format, args);
    va_end(args);
}

static void twdt_collect(void *opaque, const char *msg)
{
    twdt_msg_t *out = opaque;
    if (strncmp(msg, "Task watchdog", 13) == 0) return;
    if (strcmp(msg, "\n - ") == 0) msg = " ";
    size_t n = strlen(msg);
    size_t room = sizeof(out->text) - out->len;
    if (n > room) n = room;
    memcpy(out->text + out->len, msg, n);
    out->len += n;
}

/* Runs in the task watchdog ISR before the panic, so the culprit tasks reach the RTC buffer. */
void esp_task_wdt_isr_user_handler(void)
{
    if (!s_ready) return;
    static const char prefix[] = "task_wdt: not reset by";
    memcpy(s_twdt_msg.text, prefix, sizeof(prefix) - 1U);
    s_twdt_msg.len = sizeof(prefix) - 1U;
    (void)esp_task_wdt_print_triggered_tasks(twdt_collect, &s_twdt_msg, NULL);
    fill_record(&s_twdt_rec, 'E', 0U, s_twdt_msg.text, s_twdt_msg.len, true);
    ring_push(&s_twdt_rec);
}

/* ---- Flash ring ---------------------------------------------------------------------------- */

static bool slot_blank(uint32_t slot)
{
    uint32_t words[RECORD_SIZE / sizeof(uint32_t)];
    if (esp_partition_read(s_part, slot * RECORD_SIZE, words, sizeof(words)) != ESP_OK) return false;
    for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
        if (words[i] != UINT32_MAX) return false;
    }
    return true;
}

static uint32_t sector_start(uint32_t sector)
{
    return (sector % s_sectors) * RECORDS_PER_SECTOR;
}

static esp_err_t scan(void)
{
    uint8_t *buf = malloc(SECTOR_SIZE);
    if (buf == NULL) return ESP_ERR_NO_MEM;
    bool found = false;
    uint32_t best_seq = 0U;
    uint32_t best_slot = 0U;
    uint16_t max_boot = 0U;
    for (uint32_t sector = 0; sector < s_sectors; sector++) {
        if (esp_partition_read(s_part, sector * SECTOR_SIZE, buf, SECTOR_SIZE) != ESP_OK) continue;
        for (uint32_t i = 0; i < RECORDS_PER_SECTOR; i++) {
            const record_t *rec = (const record_t *)(buf + i * RECORD_SIZE);
            if (!record_valid(rec)) continue;
            if (!found || rec->seq > best_seq) {
                found = true;
                best_seq = rec->seq;
                best_slot = sector * RECORDS_PER_SECTOR + i;
            }
            if (rec->boot > max_boot) max_boot = rec->boot;
        }
    }
    free(buf);

    if (found) {
        s_next_seq = best_seq + 1U;
        s_write_slot = (best_slot + 1U) % s_slots;
        /* A write torn by a power loss leaves a dirty slot; continue in the next sector. */
        if (s_write_slot % RECORDS_PER_SECTOR != 0U && !slot_blank(s_write_slot)) {
            s_write_slot = sector_start(s_write_slot / RECORDS_PER_SECTOR + 1U);
        }
    }
    s_boot = (uint16_t)(max_boot + 1U);
    if (s_boot == 0U) s_boot = 1U;
    return ESP_OK;
}

static void flash_append(record_t *rec)
{
    uint32_t slot = s_write_slot;
    if (slot % RECORDS_PER_SECTOR == 0U &&
        esp_partition_erase_range(s_part, (slot / RECORDS_PER_SECTOR) * SECTOR_SIZE,
                                  SECTOR_SIZE) != ESP_OK) {
        s_write_slot = sector_start(slot / RECORDS_PER_SECTOR + 1U);
        return;
    }
    s_write_slot = (slot + 1U) % s_slots;
    rec->seq = s_next_seq;
    rec->crc = record_crc(rec);
    if (esp_partition_write(s_part, slot * RECORD_SIZE, rec, RECORD_SIZE) == ESP_OK) s_next_seq++;
}

/* Caller holds s_flash_lock. */
static void flush_locked(void)
{
    for (;;) {
        record_t rec;
        bool have = false;
        uint32_t dropped = 0U;
        portENTER_CRITICAL(&s_ring_lock);
        if (s_ring.count > 0U) {
            rec = s_ring.rec[s_ring.head];
            s_ring.head = (s_ring.head + 1U) % RING_LEN;
            s_ring.count--;
            have = true;
        } else {
            dropped = s_ring.dropped;
            s_ring.dropped = 0U;
        }
        portEXIT_CRITICAL(&s_ring_lock);

        if (!have) {
            if (dropped > 0U) {
                char text[48];
                int n = snprintf(text, sizeof(text), "errlog: %lu lines lost, buffer full",
                                 (unsigned long)dropped);
                fill_record(&rec, 'W', 0U, text, clamp_len(n, sizeof(text)), false);
                flash_append(&rec);
            }
            return;
        }
        if (record_valid(&rec)) flash_append(&rec);
    }
}

static void writer_task(void *arg)
{
    (void)arg;
    esp_err_t wdt_err = esp_task_wdt_add(NULL);
    if (wdt_err != ESP_OK) {
        ESP_LOGE("errlog", "errlog_writer WDT registration failed: %s", esp_err_to_name(wdt_err));
        esp_restart();
    }
    for (;;) {
        (void)esp_task_wdt_reset();
        xSemaphoreTake(s_flash_lock, portMAX_DELAY);
        flush_locked();
        xSemaphoreGive(s_flash_lock);
        (void)esp_task_wdt_reset();
        vTaskDelay(pdMS_TO_TICKS(WRITER_PERIOD_MS));
    }
}

size_t app_errlog_read(uint32_t start_seq, app_errlog_entry_t *out, size_t max,
                       uint32_t *next_seq, bool *more)
{
    if (next_seq != NULL) *next_seq = start_seq;
    if (more != NULL) *more = false;
    if (!s_ready || out == NULL || max == 0U) return 0U;
    uint8_t *buf = malloc(SECTOR_SIZE);
    if (buf == NULL) return 0U;

    size_t count = 0U;
    bool newer = false;
    xSemaphoreTake(s_flash_lock, portMAX_DELAY);
    flush_locked();
    /* The oldest records are in the sector the writer erases next. */
    uint32_t first = s_write_slot / RECORDS_PER_SECTOR;
    if (s_write_slot % RECORDS_PER_SECTOR != 0U) first++;
    for (uint32_t k = 0; k < s_sectors && !newer; k++) {
        uint32_t sector = (first + k) % s_sectors;
        if (esp_partition_read(s_part, sector * SECTOR_SIZE, buf, SECTOR_SIZE) != ESP_OK) continue;
        for (uint32_t i = 0; i < RECORDS_PER_SECTOR; i++) {
            const record_t *rec = (const record_t *)(buf + i * RECORD_SIZE);
            if (!record_valid(rec) || rec->seq < start_seq) continue;
            if (count == max) {
                newer = true;
                break;
            }
            app_errlog_entry_t *entry = &out[count++];
            entry->seq = rec->seq;
            entry->boot = rec->boot;
            entry->level = (char)rec->level;
            entry->uptime_ms = rec->uptime_ms;
            entry->epoch_s = rec->epoch_s;
            memcpy(entry->text, rec->text, rec->text_len);
            entry->text[rec->text_len] = '\0';
        }
    }
    uint32_t latest = s_next_seq;
    xSemaphoreGive(s_flash_lock);
    free(buf);

    if (next_seq != NULL) *next_seq = count > 0U ? out[count - 1U].seq + 1U : latest;
    if (more != NULL) *more = newer;
    return count;
}

/* ---- Boot record --------------------------------------------------------------------------- */

static const char *reset_name(esp_reset_reason_t reason)
{
    switch (reason) {
    case ESP_RST_POWERON: return "power_on";
    case ESP_RST_EXT: return "external";
    case ESP_RST_SW: return "software";
    case ESP_RST_PANIC: return "panic";
    case ESP_RST_INT_WDT: return "int_wdt";
    case ESP_RST_TASK_WDT: return "task_wdt";
    case ESP_RST_WDT: return "other_wdt";
    case ESP_RST_DEEPSLEEP: return "deep_sleep";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_USB: return "usb";
    case ESP_RST_JTAG: return "jtag";
    case ESP_RST_PWR_GLITCH: return "power_glitch";
    case ESP_RST_CPU_LOCKUP: return "cpu_lockup";
    default: return "unknown";
    }
}

static void log_crash_summary(void)
{
#if CONFIG_ESP_COREDUMP_ENABLE_TO_FLASH && CONFIG_ESP_COREDUMP_DATA_FORMAT_ELF
    char text[APP_ERRLOG_TEXT_LEN + 1U];
    if (esp_core_dump_image_check() != ESP_OK) {
        push_text('E', text, snprintf(text, sizeof(text), "crash: no valid core dump"));
        return;
    }
    esp_core_dump_summary_t *summary = malloc(sizeof(*summary));
    if (summary == NULL) return;
    if (esp_core_dump_get_summary(summary) == ESP_OK) {
        push_text('E', text, snprintf(text, sizeof(text),
                  "crash: task=%s pc=0x%08lx cause=%lu vaddr=0x%08lx%s", summary->exc_task,
                  (unsigned long)summary->exc_pc, (unsigned long)summary->ex_info.exc_cause,
                  (unsigned long)summary->ex_info.exc_vaddr,
                  summary->exc_bt_info.corrupted ? " bt_corrupted" : ""));
        uint32_t depth = summary->exc_bt_info.depth;
        if (depth > 16U) depth = 16U;
        for (uint32_t first = 0; first < depth; first += 8U) {
            size_t len = clamp_len(snprintf(text, sizeof(text), "crash: bt"), sizeof(text));
            for (uint32_t i = first; i < depth && i < first + 8U; i++) {
                len += clamp_len(snprintf(text + len, sizeof(text) - len, " 0x%08lx",
                                          (unsigned long)summary->exc_bt_info.bt[i]),
                                 sizeof(text) - len);
            }
            push_text('E', text, (int)len);
        }
    }
    free(summary);
#endif
}

static void log_boot(void)
{
    char text[APP_ERRLOG_TEXT_LEN + 1U];
    esp_reset_reason_t reason = esp_reset_reason();
    push_text('I', text, snprintf(text, sizeof(text), "boot: start #%u, reset=%s",
                                  (unsigned)s_boot, reset_name(reason)));
    if (reason == ESP_RST_PANIC || reason == ESP_RST_INT_WDT || reason == ESP_RST_TASK_WDT ||
        reason == ESP_RST_WDT) {
        log_crash_summary();
    }
}

esp_err_t app_errlog_init(void)
{
    if (s_ready) return ESP_OK;
    s_part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, PARTITION_SUBTYPE, PARTITION_LABEL);
    if (s_part == NULL) return ESP_ERR_NOT_FOUND;
    if (s_part->size < 2U * SECTOR_SIZE || s_part->size % SECTOR_SIZE != 0U) {
        return ESP_ERR_INVALID_SIZE;
    }
    s_sectors = s_part->size / SECTOR_SIZE;
    s_slots = s_sectors * RECORDS_PER_SECTOR;
    s_flash_lock = xSemaphoreCreateMutex();
    if (s_flash_lock == NULL) return ESP_ERR_NO_MEM;
    esp_err_t err = scan();
    if (err != ESP_OK) return err;

    if (!ring_valid()) {
        memset(&s_ring, 0, sizeof(s_ring));
        s_ring.magic = RING_MAGIC;
    }
    /* Lines the previous run could not write go to flash before this boot's records. */
    xSemaphoreTake(s_flash_lock, portMAX_DELAY);
    flush_locked();
    xSemaphoreGive(s_flash_lock);

    s_ready = true;
    log_boot();
    s_prev_vprintf = esp_log_set_vprintf(log_hook);
    if (xTaskCreate(writer_task, "errlog_writer", WRITER_STACK, NULL, WRITER_PRIORITY, NULL) !=
        pdPASS) {
        (void)esp_log_set_vprintf(s_prev_vprintf);
        s_ready = false;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
