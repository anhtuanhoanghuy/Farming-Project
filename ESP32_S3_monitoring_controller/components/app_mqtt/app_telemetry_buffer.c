#include "app_telemetry_buffer.h"

#include <string.h>
#include <sys/time.h>

#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define BUFFER_LOCK_TIMEOUT_MS 20U

static telemetry_slot_t s_slots[APP_TELEMETRY_SLOTS];
static size_t s_head; /* index of the oldest slot */
static size_t s_count;
static uint32_t s_next_seq = 1U;
static uint32_t s_dropped;

static portMUX_TYPE s_once_lock = portMUX_INITIALIZER_UNLOCKED;
static StaticSemaphore_t s_mutex_buf;
static SemaphoreHandle_t s_mutex;

esp_err_t app_telemetry_buffer_init(void)
{
    portENTER_CRITICAL(&s_once_lock);
    if (s_mutex == NULL) {
        s_mutex = xSemaphoreCreateMutexStatic(&s_mutex_buf);
    }
    portEXIT_CRITICAL(&s_once_lock);
    return s_mutex != NULL ? ESP_OK : ESP_ERR_NO_MEM;
}

static bool lock(void)
{
    return app_telemetry_buffer_init() == ESP_OK &&
           xSemaphoreTake(s_mutex, pdMS_TO_TICKS(BUFFER_LOCK_TIMEOUT_MS)) == pdTRUE;
}

static void unlock(void)
{
    xSemaphoreGive(s_mutex);
}

static bool unix_time_ms(int64_t *out)
{
    struct timeval tv;

    if (g_sys.sys_event_group == NULL ||
        (xEventGroupGetBits(g_sys.sys_event_group) & BIT_TIME_VALID) == 0U) {
        return false;
    }
    gettimeofday(&tv, NULL);
    *out = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
    return true;
}

esp_err_t app_telemetry_buffer_stamp(const sensor_cycle_t *data, telemetry_slot_t *out)
{
    if (data == NULL || out == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!lock()) {
        return ESP_ERR_TIMEOUT;
    }
    memset(out, 0, sizeof(*out));
    out->seq = s_next_seq++;
    unlock();

    if (data->ts_ms > 0 && g_sys.sys_event_group != NULL &&
        (xEventGroupGetBits(g_sys.sys_event_group) & BIT_TIME_VALID) != 0U) {
        out->ts_ms = data->ts_ms;
    } else {
        (void)unix_time_ms(&out->ts_ms);
    }
    out->uptime_ms = (uint32_t)(esp_timer_get_time() / 1000);
    sensor_cycle_t stamped = *data;
    stamped.uptime_ms = out->uptime_ms;
    stamped.ts_ms = out->ts_ms;
    memcpy(out->payload, &stamped, sizeof(stamped));
    return ESP_OK;
}

esp_err_t app_telemetry_buffer_push_slot(const telemetry_slot_t *slot)
{
    if (slot == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!lock()) {
        return ESP_ERR_TIMEOUT;
    }
    if (s_count == APP_TELEMETRY_SLOTS) {
        s_head = (s_head + 1U) % APP_TELEMETRY_SLOTS;
        s_count--;
        s_dropped++;
    }
    s_slots[(s_head + s_count) % APP_TELEMETRY_SLOTS] = *slot;
    s_count++;
    unlock();
    return ESP_OK;
}

esp_err_t app_telemetry_buffer_push(const sensor_cycle_t *data)
{
    telemetry_slot_t slot;
    esp_err_t err = app_telemetry_buffer_stamp(data, &slot);

    return err == ESP_OK ? app_telemetry_buffer_push_slot(&slot) : err;
}

esp_err_t app_telemetry_buffer_peek(telemetry_slot_t *out)
{
    if (out == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!lock()) {
        return ESP_ERR_TIMEOUT;
    }
    esp_err_t err = ESP_ERR_NOT_FOUND;
    if (s_count > 0U) {
        *out = s_slots[s_head];
        err = ESP_OK;
    }
    unlock();
    return err;
}

esp_err_t app_telemetry_buffer_pop(void)
{
    if (!lock()) {
        return ESP_ERR_TIMEOUT;
    }
    esp_err_t err = ESP_ERR_NOT_FOUND;
    if (s_count > 0U) {
        s_head = (s_head + 1U) % APP_TELEMETRY_SLOTS;
        s_count--;
        err = ESP_OK;
    }
    unlock();
    return err;
}

size_t app_telemetry_buffer_count(void)
{
    size_t count = 0;

    if (lock()) {
        count = s_count;
        unlock();
    }
    return count;
}

uint32_t app_telemetry_buffer_dropped(void)
{
    uint32_t dropped = 0;

    if (lock()) {
        dropped = s_dropped;
        unlock();
    }
    return dropped;
}
