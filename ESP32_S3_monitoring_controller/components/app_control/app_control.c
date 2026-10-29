#include "app_control.h"

#include <math.h>
#include <string.h>
#include <time.h>

#include "app_device.h"
#include "app_log.h"
#include "driver/gpio.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define CONTROL_TASK_STACK 4608U
#define CONTROL_TASK_PRIORITY 7U
#define CONTROL_TASK_CORE 1
#define CONTROL_TICK_MS 100U
#define MINUTE_US 60000000LL

_Static_assert(APP_LOAD_COUNT == 4, "app_control relay table requires four loads");

static const char *TAG = "app_control";
static const gpio_num_t s_relay_pins[APP_LOAD_COUNT] = {
    APP_PIN_RELAY_1, APP_PIN_RELAY_2, APP_PIN_RELAY_3, APP_PIN_RELAY_4,
};
static const gpio_num_t s_di_pins[APP_DI_COUNT] = {
    APP_PIN_DI_1, APP_PIN_DI_2, APP_PIN_DI_3, APP_PIN_DI_4,
};

typedef struct {
    bool output;
    bool delay_active;
    bool delay_mode;
    load_delay_phase_t delay_phase;
    uint16_t delay_min;
    uint16_t delay_duration_min;
    int64_t delay_deadline_us;
    int64_t delay_start_epoch_s;
    uint8_t sched_on_mask;      /* schedulers that switched this load on */
} load_state_t;

static SemaphoreHandle_t s_lock;
static TaskHandle_t s_task;
static device_cfg_t s_cfg;
static uint32_t s_cfg_generation;
static load_state_t s_load[APP_LOAD_COUNT];
static sensor_cycle_t s_sample;
static bool s_sample_new;
static int64_t s_last_minute_key = -1;
static bool s_estop;
static bool s_interlock;
static bool s_initialized;
static bool s_feedback_known[APP_LOAD_COUNT];
static bool s_feedback_state[APP_LOAD_COUNT];

const char *app_control_result_reason(ctl_result_t result)
{
    switch (result) {
    case CTL_OK: return "";
    case CTL_ERR_ARG: return "invalid argument";
    case CTL_ERR_DISABLED: return "load is disabled";
    case CTL_ERR_NOT_FOUND: return "not found";
    case CTL_ERR_EXISTS: return "already exists";
    case CTL_ERR_LIMIT: return "limit reached";
    case CTL_ERR_STORAGE: return "storage error";
    case CTL_ERR_INTERLOCK: return "safety interlock active";
    case CTL_ERR_FEEDBACK: return "load feedback did not confirm the requested state";
    default: return "internal error";
    }
}

/* ---- Helpers ------------------------------------------------------------------------------- */

static bool time_valid(void)
{
    return g_sys.sys_event_group != NULL &&
           (xEventGroupGetBits(g_sys.sys_event_group) & BIT_TIME_VALID) != 0U;
}

static void send_event(const mqtt_event_t *event)
{
    if (event == NULL || g_sys.mqtt_event_queue == NULL) return;
    if (xQueueSend(g_sys.mqtt_event_queue, event, 0) == pdTRUE) return;
    mqtt_event_t discarded;
    (void)xQueueReceive(g_sys.mqtt_event_queue, &discarded, 0);
    (void)xQueueSend(g_sys.mqtt_event_queue, event, 0);
}

static void emit_load_event(uint8_t index, bool state, const char *source)
{
    mqtt_event_t event = {.kind = MQTT_EVENT_LOAD_CHANGED,
                          .load_id = (uint8_t)(index + 1U), .state = state};
    strlcpy(event.source, source, sizeof(event.source));
    send_event(&event);
}

static uint32_t remaining_seconds(int64_t deadline_us, int64_t now_us)
{
    if (deadline_us <= now_us) return 0U;
    return (uint32_t)((deadline_us - now_us + 999999LL) / 1000000LL);
}

/* Returns 1 when the relay changed, 0 when it already had that state or the change was refused,
 * -1 when the GPIO write failed (the relay state is then unknown to the engine). */
static int set_output_locked(uint8_t index, bool on, const char *source, bool publish_event)
{
    load_state_t *load = &s_load[index];
    if (load->output == on) return 0;
    if (on && s_interlock) {
        ESP_LOGW(TAG, "DO%u ON refused (%s): safety interlock active", (unsigned)(index + 1U), source);
        return 0;
    }
    uint32_t output_error_bit = (uint32_t)SYS_ERR_LOAD_OUTPUT_DO1 << index;
    esp_err_t err = gpio_set_level(s_relay_pins[index], on ? 1 : 0);
    if (err != ESP_OK) {
        (void)__atomic_fetch_or(&g_sys.sys_error_mask,
                                output_error_bit, __ATOMIC_RELAXED);
        ESP_LOGE(TAG, "GPIO write failed for DO%u: %s", (unsigned)(index + 1U), esp_err_to_name(err));
        return -1;
    }
    (void)__atomic_fetch_and(&g_sys.sys_error_mask,
                             ~output_error_bit, __ATOMIC_RELAXED);
    load->output = on;
    ESP_LOGI(TAG, "DO%u -> %s (source=%s)", (unsigned)(index + 1U), on ? "ON" : "OFF", source);
    if (publish_event) emit_load_event(index, on, source);
    return 1;
}

static void delay_clear_locked(uint8_t index, const char *why)
{
    load_state_t *load = &s_load[index];
    if (!load->delay_active) return;
    load->delay_active = false;
    load->delay_phase = LOAD_DELAY_IDLE;
    load->delay_deadline_us = 0;
    ESP_LOGI(TAG, "DO%u delay stopped (%s)", (unsigned)(index + 1U), why);
}

static void clear_automation(load_cfg_t *load)
{
    for (size_t c = 0; c < APP_CONDITIONS_PER_LOAD; c++) {
        memset(&load->condition[c], 0, sizeof(load->condition[c]));
        load->condition[c].sensor_port = APP_PORT_NONE;
    }
    memset(load->scheduler, 0, sizeof(load->scheduler));
}

/* Commits next and keeps the local copy in step, so refresh_cfg_locked() does not redo it. */
static ctl_result_t commit_locked(const device_cfg_t *next)
{
    esp_err_t err = app_device_commit(next);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Config commit failed: %s", esp_err_to_name(err));
        return CTL_ERR_STORAGE;
    }
    s_cfg = *next;
    s_cfg_generation = app_device_generation();
    return CTL_OK;
}

/* Adopts a config changed elsewhere (conditions, schedules, sensors edited by the commands). */
static void refresh_cfg_locked(void)
{
    uint32_t generation = app_device_generation();
    if (generation == s_cfg_generation) return;
    app_device_get(&s_cfg);
    s_cfg_generation = generation;
    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        if (!s_cfg.load[i].enabled) {
            delay_clear_locked(i, "load disabled");
            (void)set_output_locked(i, false, "disable", true);
        }
    }
}

/* ---- Delay timer --------------------------------------------------------------------------- */

static void delay_step_locked(uint8_t index, int64_t now_us)
{
    load_state_t *load = &s_load[index];
    if (load->delay_phase == LOAD_DELAY_WAIT_FIRST) {
        bool first_state = !load->delay_mode;
        if (set_output_locked(index, first_state, "delay", true) != 1) emit_load_event(index, load->output, "delay");
        if (load->delay_duration_min == 0U) {
            ESP_LOGI(TAG, "DO%u delay finished (state kept %s)", (unsigned)(index + 1U),
                     load->output ? "ON" : "OFF");
            load->delay_active = false;
            load->delay_phase = LOAD_DELAY_IDLE;
            load->delay_deadline_us = 0;
        } else {
            load->delay_phase = LOAD_DELAY_WAIT_SECOND;
            load->delay_deadline_us = now_us + (int64_t)load->delay_duration_min * MINUTE_US;
            ESP_LOGI(TAG, "DO%u delay phase 2: %u min until %s", (unsigned)(index + 1U),
                     (unsigned)load->delay_duration_min, load->delay_mode ? "ON" : "OFF");
        }
    } else if (load->delay_phase == LOAD_DELAY_WAIT_SECOND) {
        bool second_state = load->delay_mode;
        if (set_output_locked(index, second_state, "delay", true) != 1) emit_load_event(index, load->output, "delay");
        ESP_LOGI(TAG, "DO%u delay finished", (unsigned)(index + 1U));
        load->delay_active = false;
        load->delay_phase = LOAD_DELAY_IDLE;
        load->delay_deadline_us = 0;
    }
}

/* ---- Automatic logic ----------------------------------------------------------------------- */

/* What the enabled conditions of a load ask for right now: 1 = on, 0 = off (off wins), -1 = none
 * of them holds, or no valid reading. */
static int condition_decision_locked(uint8_t index)
{
    const load_cfg_t *cfg = &s_cfg.load[index];
    bool want_on = false;
    bool want_off = false;
    for (size_t c = 0; c < APP_CONDITIONS_PER_LOAD; c++) {
        const load_condition_cfg_t *cond = &cfg->condition[c];
        if (!cond->present || !cond->enabled || cond->sensor_port >= APP_SENSOR_INTERFACE_COUNT) continue;
        const sensor_port_cfg_t *port = &s_cfg.sensor[cond->sensor_port];
        const sensor_sample_t *sample = &s_sample.s[cond->sensor_port];
        float value;
        switch (cond->value_index) {
        case 0U: value = sample->v1; break;
        case 1U: value = sample->v2; break;
        case 2U: value = sample->v3; break;
        default: continue;
        }
        if (!port->configured || !port->enabled || sample->valid == 0U || !isfinite(value)) continue;
        bool match = cond->op_gt ? value > cond->threshold : value < cond->threshold;
        if (!match) continue;
        if (cond->action) want_on = true;
        else want_off = true;
    }
    return want_off ? 0 : want_on ? 1 : -1;
}

static void evaluate_conditions_locked(void)
{
    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        if (!s_cfg.load[i].enabled || s_load[i].delay_active) continue;
        int decision = condition_decision_locked(i);
        if (decision >= 0) (void)set_output_locked(i, decision == 1, "condition", true);
    }
}

static void evaluate_schedules_locked(void)
{
    if (!time_valid()) return;
    time_t now = time(NULL);
    int64_t minute_key = (int64_t)now / 60;
    if (minute_key == s_last_minute_key) return;
    s_last_minute_key = minute_key;

    struct tm utc;
    gmtime_r(&now, &utc);
    uint16_t minute = (uint16_t)(utc.tm_hour * 60 + utc.tm_min);
    uint8_t day_bit = (uint8_t)(1U << ((utc.tm_wday + 6) % 7));    /* bit 0 = Monday */

    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        const load_cfg_t *cfg = &s_cfg.load[i];
        if (!cfg->enabled || s_load[i].delay_active) continue;
        /* A condition that currently holds outranks the schedule. */
        bool condition_holds = condition_decision_locked(i) >= 0;
        for (uint8_t s = 0; s < APP_SCHEDULERS_PER_LOAD; s++) {
            const load_scheduler_cfg_t *sch = &cfg->scheduler[s];
            if (!sch->present || !sch->enabled) continue;
            bool day_match = (sch->days_mask & day_bit) != 0U;
            /* An off-time also applies the next day when this schedule switched the load on
             * before midnight. */
            if (minute == sch->on_minute_utc && day_match) {
                if (condition_holds) {
                    ESP_LOGI(TAG, "DO%u SHE%u on-time ignored: a sensor condition holds", (unsigned)(i + 1U),
                             (unsigned)(s + 1U));
                } else if (set_output_locked(i, true, "schedule", true) == 1) {
                    ESP_LOGI(TAG, "DO%u SHE%u on-time %02u:%02u UTC", (unsigned)(i + 1U),
                             (unsigned)(s + 1U), (unsigned)(minute / 60U), (unsigned)(minute % 60U));
                    s_load[i].sched_on_mask |= (uint8_t)(1U << s);
                }
            } else if (minute == sch->off_minute_utc &&
                       (day_match || (s_load[i].sched_on_mask & (1U << s)) != 0U)) {
                s_load[i].sched_on_mask &= (uint8_t)~(1U << s);
                if (condition_holds) {
                    ESP_LOGI(TAG, "DO%u SHE%u off-time ignored: a sensor condition holds", (unsigned)(i + 1U),
                             (unsigned)(s + 1U));
                } else if (set_output_locked(i, false, "schedule", true) == 1) {
                    ESP_LOGI(TAG, "DO%u SHE%u off-time %02u:%02u UTC", (unsigned)(i + 1U),
                             (unsigned)(s + 1U), (unsigned)(minute / 60U), (unsigned)(minute % 60U));
                }
            }
        }
    }
}

static void app_control_task(void *arg)
{
    (void)arg;
    esp_err_t wdt_err = esp_task_wdt_add(NULL);
    if (wdt_err != ESP_OK) {
        ESP_LOGE(TAG, "load_control_task WDT registration failed: %s", esp_err_to_name(wdt_err));
        esp_restart();
    }

    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(CONTROL_TICK_MS));
        (void)esp_task_wdt_reset();

        xSemaphoreTake(s_lock, portMAX_DELAY);
        refresh_cfg_locked();
        int64_t now = esp_timer_get_time();
        for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
            while (s_load[i].delay_active && now >= s_load[i].delay_deadline_us) {
                delay_step_locked(i, now);
            }
        }
        if (s_sample_new) {
            s_sample_new = false;
            evaluate_conditions_locked();
        }
        evaluate_schedules_locked();
        xSemaphoreGive(s_lock);
    }
}

/* ---- Init ---------------------------------------------------------------------------------- */

static esp_err_t configure_relays_safe(void)
{
    uint64_t pin_mask = 0;
    for (size_t i = 0; i < APP_LOAD_COUNT; i++) pin_mask |= 1ULL << s_relay_pins[i];
    gpio_config_t config = {.pin_bit_mask = pin_mask, .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE, .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .intr_type = GPIO_INTR_DISABLE};
    esp_err_t err = gpio_config(&config);
    if (err != ESP_OK) return err;
    for (size_t i = 0; i < APP_LOAD_COUNT; i++) {
        err = gpio_set_level(s_relay_pins[i], 0);
        if (err != ESP_OK) return err;
    }
    return ESP_OK;
}

esp_err_t app_control_init(void)
{
    if (s_initialized) return ESP_OK;
    if (g_sys.sys_event_group == NULL) return ESP_ERR_INVALID_ARG;
    esp_err_t err = configure_relays_safe();
    if (err != ESP_OK) return err;
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;

    app_device_get(&s_cfg);
    s_cfg_generation = app_device_generation();
    s_interlock = (xEventGroupGetBits(g_sys.sys_event_group) & BIT_SYS_INTERLOCK_TRIPPED) != 0U;

    if (xTaskCreatePinnedToCore(app_control_task, "load_control_task", CONTROL_TASK_STACK,
                                NULL, CONTROL_TASK_PRIORITY, &s_task, CONTROL_TASK_CORE) != pdPASS) {
        vSemaphoreDelete(s_lock);
        s_lock = NULL;
        return ESP_ERR_NO_MEM;
    }
    s_initialized = true;
    ESP_LOGI(TAG, "Load engine ready: 4 relays off, tick %u ms", (unsigned)CONTROL_TICK_MS);
    return ESP_OK;
}

esp_err_t app_control_sensor_update(const sensor_cycle_t *cycle)
{
    if (cycle == NULL || cycle->count > APP_SENSOR_INTERFACE_COUNT || !s_initialized) {
        return ESP_ERR_INVALID_ARG;
    }
    if (xSemaphoreTake(s_lock, pdMS_TO_TICKS(100)) != pdTRUE) return ESP_ERR_TIMEOUT;
    s_sample = *cycle;
    s_sample_new = true;
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

/* ---- Commands ------------------------------------------------------------------------------ */

static ctl_result_t set_state_internal(uint8_t index, bool on, bool publish_event)
{
    if (index >= APP_LOAD_COUNT) return CTL_ERR_ARG;
    if (!s_initialized) return CTL_ERR_INTERNAL;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    refresh_cfg_locked();
    ctl_result_t result = CTL_OK;
    if (!s_cfg.load[index].enabled && on) {
        result = CTL_ERR_DISABLED;
    } else if (on && s_interlock) {
        result = CTL_ERR_INTERLOCK;
    } else {
        /* A manual command outranks automatic rules. */
        device_cfg_t next = s_cfg;
        bool changed = false;
        for (size_t c = 0; c < APP_CONDITIONS_PER_LOAD; c++) {
            if (next.load[index].condition[c].present && next.load[index].condition[c].enabled) {
                next.load[index].condition[c].enabled = false;
                changed = true;
            }
        }
        for (size_t s = 0; s < APP_SCHEDULERS_PER_LOAD; s++) {
            if (next.load[index].scheduler[s].present && next.load[index].scheduler[s].enabled) {
                next.load[index].scheduler[s].enabled = false;
                changed = true;
            }
        }
        if (changed) {
            ESP_LOGI(TAG, "DO%u manual command: conditions and schedulers disabled", (unsigned)(index + 1U));
            result = commit_locked(&next);
        }
        if (result == CTL_OK) {
            delay_clear_locked(index, "manual command");
            s_load[index].sched_on_mask = 0U;
            int changed = set_output_locked(index, on, "manual", publish_event);
            if (changed < 0) result = CTL_ERR_INTERNAL;
            else if (changed == 0 && publish_event)
                emit_load_event(index, s_load[index].output, "manual");
        }
    }
    xSemaphoreGive(s_lock);
    return result;
}

ctl_result_t app_control_set_state(uint8_t index, bool on)
{
    return set_state_internal(index, on, true);
}

ctl_result_t app_control_process_button_di(uint8_t di_index)
{
    if (di_index >= APP_DI_COUNT) return CTL_ERR_ARG;
    if (!s_initialized) return CTL_ERR_INTERNAL;

    const uint8_t port = (uint8_t)(APP_PORT_DI_FIRST + di_index);
    uint8_t load_index = APP_PORT_NONE;
    bool turn_on = false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    refresh_cfg_locked();
    const sensor_port_cfg_t *sensor = &s_cfg.sensor[port];
    if (sensor->configured && sensor->enabled) {
        for (uint8_t load = 0; load < APP_LOAD_COUNT; load++) {
            const char digit = (char)('1' + load);
            if (sensor->name[0] == 'O' && sensor->name[1] == 'N' &&
                sensor->name[2] == digit && sensor->name[3] == '_') {
                load_index = load;
                turn_on = true;
                break;
            }
            if (sensor->name[0] == 'O' && sensor->name[1] == 'F' &&
                sensor->name[2] == 'F' && sensor->name[3] == digit &&
                sensor->name[4] == '_') {
                load_index = load;
                turn_on = false;
                break;
            }
        }
    }
    xSemaphoreGive(s_lock);

    if (load_index == APP_PORT_NONE) return CTL_ERR_NOT_FOUND;
    return set_state_internal(load_index, turn_on, true);
}

static uint8_t feedback_di_for_load(const device_cfg_t *cfg, uint8_t load_index)
{
    const char digit = (char)('1' + load_index);
    for (uint8_t d = 0; d < APP_DI_COUNT; d++) {
        const uint8_t port = (uint8_t)(APP_PORT_DI_FIRST + d);
        const sensor_port_cfg_t *sensor = &cfg->sensor[port];
        if (sensor->configured && sensor->enabled &&
            sensor->name[0] == 'D' && sensor->name[1] == 'O' &&
            sensor->name[2] == digit && sensor->name[3] == '_') {
            return d;
        }
    }
    return APP_PORT_NONE;
}

esp_err_t app_control_get_feedback(uint8_t load_index, bool *state)
{
    if (load_index >= APP_LOAD_COUNT || state == NULL) return ESP_ERR_INVALID_ARG;
    device_cfg_t cfg;
    app_device_get(&cfg);
    const uint8_t di = feedback_di_for_load(&cfg, load_index);
    if (di == APP_PORT_NONE) return ESP_ERR_NOT_FOUND;
    *state = gpio_get_level(s_di_pins[di]) == 0;
    return ESP_OK;
}

ctl_result_t app_control_set_state_verified(uint8_t load_index, bool on,
                                            uint32_t timeout_ms)
{
    if (load_index >= APP_LOAD_COUNT) return CTL_ERR_ARG;
    bool feedback = false;
    const esp_err_t feedback_err = app_control_get_feedback(load_index, &feedback);
    if (feedback_err == ESP_ERR_NOT_FOUND) return app_control_set_state(load_index, on);
    if (feedback_err != ESP_OK) return CTL_ERR_INTERNAL;

    const ctl_result_t result = set_state_internal(load_index, on, false);
    if (result != CTL_OK) return result;

    if (timeout_ms == 0U) timeout_ms = 1U;
    const int64_t deadline = esp_timer_get_time() + (int64_t)timeout_ms * 1000LL;
    do {
        if (app_control_get_feedback(load_index, &feedback) == ESP_OK && feedback == on) {
            emit_load_event(load_index, feedback, "feedback");
            return CTL_OK;
        }
        vTaskDelay(pdMS_TO_TICKS(20U));
    } while (esp_timer_get_time() < deadline);

    if (app_control_get_feedback(load_index, &feedback) == ESP_OK) {
        emit_load_event(load_index, feedback, "feedback");
    }
    return CTL_ERR_FEEDBACK;
}

/* A disabled load that is switched on by hand (cabinet button) is enabled again: the config is
 * committed (RAM + NVM) and the engine follows the real state. The snapshot that the LOAD_CHANGED
 * event triggers then carries enabled=true to the app. Returns true when the load was enabled. */
static bool reenable_after_manual_on(uint8_t load)
{
    bool enabled_now = false;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    refresh_cfg_locked();
    if (!s_cfg.load[load].enabled) {
        device_cfg_t next = s_cfg;
        next.load[load].enabled = true;
        if (commit_locked(&next) == CTL_OK) {
            enabled_now = true;
            ESP_LOGI(TAG, "DO%u enabled again: switched on by hand while disabled", (unsigned)(load + 1U));
            (void)set_output_locked(load, true, "feedback", false);
        } else {
            ESP_LOGE(TAG, "DO%u could not be enabled again: config not stored", (unsigned)(load + 1U));
        }
    }
    xSemaphoreGive(s_lock);
    if (enabled_now) app_control_estop_ack_reenable();
    return enabled_now;
}

void app_control_process_feedback(const sensor_cycle_t *cycle)
{
    if (cycle == NULL || cycle->count > APP_SENSOR_INTERFACE_COUNT || !s_initialized) return;
    device_cfg_t cfg;
    app_device_get(&cfg);
    for (uint8_t load = 0; load < APP_LOAD_COUNT; load++) {
        const uint8_t di = feedback_di_for_load(&cfg, load);
        if (di == APP_PORT_NONE) {
            s_feedback_known[load] = false;
            continue;
        }
        const uint8_t port = (uint8_t)(APP_PORT_DI_FIRST + di);
        const sensor_sample_t *sample = &cycle->s[port];
        if (!sample->valid) continue;
        const bool state = sample->v1 >= 0.5f;
        if (!s_feedback_known[load] || s_feedback_state[load] != state) {
            s_feedback_known[load] = true;
            s_feedback_state[load] = state;
            if (state && !cfg.load[load].enabled) (void)reenable_after_manual_on(load);
            emit_load_event(load, state, "feedback");
        }
    }
}

ctl_result_t app_control_set_delay(uint8_t index, bool mode, uint16_t delay_min, uint16_t duration_min)
{
    if (index >= APP_LOAD_COUNT || delay_min > 1440U || duration_min > 1440U) return CTL_ERR_ARG;
    if (!s_initialized) return CTL_ERR_INTERNAL;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    refresh_cfg_locked();
    ctl_result_t result = CTL_OK;
    if (!s_cfg.load[index].enabled) {
        result = CTL_ERR_DISABLED;
    } else if (!mode && s_interlock) {
        result = CTL_ERR_INTERLOCK;     /* the first step would switch the load on */
    } else {
        load_state_t *load = &s_load[index];
        int64_t now = esp_timer_get_time();
        load->delay_active = true;
        load->delay_mode = mode;
        load->delay_phase = LOAD_DELAY_WAIT_FIRST;
        load->delay_min = delay_min;
        load->delay_duration_min = duration_min;
        load->delay_deadline_us = now + (int64_t)delay_min * MINUTE_US;
        load->delay_start_epoch_s = time_valid() ? (int64_t)time(NULL) : 0;
        ESP_LOGI(TAG, "DO%u delay started: %s after %u min, then %u min (0 = keep)",
                 (unsigned)(index + 1U), mode ? "OFF_THEN_ON" : "ON_THEN_OFF",
                 (unsigned)delay_min, (unsigned)duration_min);
        if (delay_min == 0U) delay_step_locked(index, now);
        else emit_load_event(index, load->output, "delay");
    }
    xSemaphoreGive(s_lock);
    return result;
}

ctl_result_t app_control_stop_delay(uint8_t index)
{
    if (index >= APP_LOAD_COUNT) return CTL_ERR_ARG;
    if (!s_initialized) return CTL_ERR_INTERNAL;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool was_active = s_load[index].delay_active;
    delay_clear_locked(index, "STOP_LOAD_DELAY");
    if (was_active) emit_load_event(index, s_load[index].output, "delay");
    xSemaphoreGive(s_lock);
    return CTL_OK;
}

ctl_result_t app_control_set_enabled(uint8_t index, bool enabled)
{
    if (index >= APP_LOAD_COUNT) return CTL_ERR_ARG;
    if (!s_initialized) return CTL_ERR_INTERNAL;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    refresh_cfg_locked();
    device_cfg_t next = s_cfg;
    next.load[index].enabled = enabled;
    if (!enabled) clear_automation(&next.load[index]);

    ctl_result_t result = CTL_OK;
    if (memcmp(&next, &s_cfg, sizeof(next)) != 0) result = commit_locked(&next);
    if (result == CTL_OK) {
        if (!enabled) {
            delay_clear_locked(index, "load disabled");
            s_load[index].sched_on_mask = 0U;
            if (set_output_locked(index, false, "disable", true) < 0) result = CTL_ERR_INTERNAL;
        }
        ESP_LOGI(TAG, "DO%u %s", (unsigned)(index + 1U),
                 enabled ? "enabled (stays off)" : "disabled: off, delay stopped, conditions/schedulers deleted");
    }
    xSemaphoreGive(s_lock);
    if (result == CTL_OK && enabled) app_control_estop_ack_reenable();
    return result;
}

ctl_result_t app_control_emergency_stop(uint8_t *loads_off)
{
    if (!s_initialized) return CTL_ERR_INTERNAL;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    refresh_cfg_locked();
    uint8_t count = 0;
    bool gpio_failed = false;
    /* Safety first: the relays drop whether or not the new config can be stored. */
    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        if (s_load[i].output) count++;
        delay_clear_locked(i, "emergency stop");
        s_load[i].sched_on_mask = 0U;
        if (set_output_locked(i, false, "emergency", true) < 0) gpio_failed = true;
    }

    device_cfg_t next = s_cfg;
    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        /* The loads stay enabled; only their delay, conditions and schedulers are deleted. */
        clear_automation(&next.load[i]);
    }
    for (size_t p = 0; p < APP_SENSOR_INTERFACE_COUNT; p++) {
        next.sensor[p].enabled = false;
    }
    ctl_result_t result = commit_locked(&next);
    if (result == CTL_OK && gpio_failed) result = CTL_ERR_INTERNAL;
    s_estop = true;
    xEventGroupSetBits(g_sys.sys_event_group, BIT_SYS_ESTOP);
    ESP_LOGW(TAG, "EMERGENCY STOP: %u load(s) switched off; delay/conditions/schedulers deleted, all sensors disabled (%s)",
             (unsigned)count, result == CTL_OK ? "stored" : "NOT stored");
    xSemaphoreGive(s_lock);

    mqtt_event_t event = {.kind = MQTT_EVENT_EMERGENCY_STOP, .state = true, .loads_off = count};
    strlcpy(event.source, "mqtt", sizeof(event.source));
    send_event(&event);
    if (loads_off != NULL) *loads_off = count;
    return result;
}

bool app_control_is_estop(void)
{
    if (!s_initialized) return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool active = s_estop;
    xSemaphoreGive(s_lock);
    return active;
}

void app_control_estop_ack_reenable(void)
{
    if (!s_initialized) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_estop) {
        s_estop = false;
        xEventGroupClearBits(g_sys.sys_event_group, BIT_SYS_ESTOP);
        ESP_LOGI(TAG, "Emergency flag cleared: a load or sensor was enabled again");
    }
    xSemaphoreGive(s_lock);
}

esp_err_t app_control_force_all_off(const char *source)
{
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        delay_clear_locked(i, source != NULL ? source : "all off");
        (void)set_output_locked(i, false, source != NULL ? source : "mqtt", true);
    }
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

bool app_control_is_interlock_tripped(void)
{
    return g_sys.sys_event_group != NULL &&
        (xEventGroupGetBits(g_sys.sys_event_group) & BIT_SYS_INTERLOCK_TRIPPED) != 0U;
}

void app_control_interlock_trip(uint32_t after_s)
{
    if (!s_initialized) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!s_interlock) {
        s_interlock = true;
        xEventGroupSetBits(g_sys.sys_event_group, BIT_SYS_INTERLOCK_TRIPPED);
        ESP_LOGW(TAG, "Safety interlock tripped after %u s without MQTT: all loads off",
                 (unsigned)after_s);
        for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
            delay_clear_locked(i, "interlock");
            (void)set_output_locked(i, false, "interlock", true);
        }
        mqtt_event_t event = {.kind = MQTT_EVENT_INTERLOCK_TRIPPED, .after_s = after_s};
        send_event(&event);
    }
    xSemaphoreGive(s_lock);
}

void app_control_interlock_clear(void)
{
    if (!s_initialized) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool changed = s_interlock;
    s_interlock = false;
    xEventGroupClearBits(g_sys.sys_event_group, BIT_SYS_INTERLOCK_TRIPPED);
    xSemaphoreGive(s_lock);
    if (changed) {
        ESP_LOGI(TAG, "Safety interlock cleared (MQTT is back)");
        mqtt_event_t event = {.kind = MQTT_EVENT_INTERLOCK_CLEARED};
        send_event(&event);
    }
}

esp_err_t app_control_get_load_runtime(uint8_t load_id, load_runtime_t *runtime)
{
    if (runtime == NULL || load_id == 0U || load_id > APP_LOAD_COUNT || !s_initialized)
        return ESP_ERR_INVALID_ARG;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const load_state_t *load = &s_load[load_id - 1U];
    memset(runtime, 0, sizeof(*runtime));
    runtime->output = load->output;
    runtime->delay_active = load->delay_active;
    runtime->delay_mode = load->delay_mode;
    runtime->delay_phase = load->delay_phase;
    runtime->delay_min = load->delay_min;
    runtime->delay_duration_min = load->delay_duration_min;
    runtime->delay_start_epoch_s = load->delay_start_epoch_s;
    if (load->delay_active) {
        runtime->delay_remaining_s = remaining_seconds(load->delay_deadline_us, esp_timer_get_time());
    }
    xSemaphoreGive(s_lock);
    return ESP_OK;
}
