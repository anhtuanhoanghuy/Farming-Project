#include "app_sysmon.h"

#include <stdbool.h>
#include <stddef.h>

#include "app_nvm.h"
#include "app_control.h"
#include "app_network.h"
#include "app_network_fsm.h"
#include "driver/gpio.h"
#include "app_log.h"
#include "esp_attr.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define SYSMON_TASK_STACK_BYTES 4096
#define SYSMON_TASK_PRIORITY    2
#define SYSMON_TASK_CORE        1
#define BUTTON_POLL_MS          20U
#define STATUS_UPDATE_MS        100U
#define LOW_HEAP_WARNING_BYTES  (20U * 1024U)
#define LOW_HEAP_WARNING_GAP_US (60LL * 1000000LL)
#define LED_TICK_MS             25U
#define STARTUP_LED_ON_MS       2000U
#define RESET_LED_PHASE_MS      1000U
#define MS_TO_US(ms)            ((int64_t)(ms) * 1000LL)

static const char *TAG = "sysmon";

static TaskHandle_t s_task;
static esp_timer_handle_t s_led_timer;
static int s_led_base = APP_LED_OFF;
static int s_estop_indicator;
static int s_provisioning_indicator;
static int s_all_leds_on;
static int s_factory_reset_pattern;
static int64_t s_startup_leds_until_us;
static int64_t s_factory_reset_pattern_start_us;
static int64_t s_last_low_heap_warning_us;
static bool s_wdt_configured;
RTC_DATA_ATTR static uint32_t s_skip_startup_led_animation;

/* ---- LED_ERROR blink engine ---------------------------------------------------------------- */

static uint32_t half_period_ticks(int mode)
{
    switch (mode) {
    case APP_LED_BLINK_1HZ:
        return 500U / LED_TICK_MS;
    case APP_LED_BLINK_05HZ:
        return 1000U / LED_TICK_MS;
    case APP_LED_BLINK_2HZ:
        return 250U / LED_TICK_MS;
    case APP_LED_BLINK_4HZ:
        return 125U / LED_TICK_MS;
    default:
        return 50U / LED_TICK_MS; /* 10 Hz */
    }
}

static int led_mode_level(int mode, uint32_t tick, uint32_t mode_start)
{
    if (mode == APP_LED_OFF) {
        return 0;
    }
    if (mode == APP_LED_ON) {
        return 1;
    }
    return (((tick - mode_start) / half_period_ticks(mode)) & 1U) == 0U;
}

static void set_active_network_leds(void)
{
    net_interface_t active = app_network_get_active_interface();
    if (active == NET_IF_WIFI) {
        (void)gpio_set_level(APP_PIN_LED_ETH, 0);
        (void)gpio_set_level(APP_PIN_LED_WIFI, 1);
    } else {
        (void)gpio_set_level(APP_PIN_LED_WIFI, 0);
        (void)gpio_set_level(APP_PIN_LED_ETH, active == NET_IF_ETH ? 1 : 0);
    }
}

static void led_timer_cb(void *arg)
{
    static uint32_t tick;
    static uint32_t error_mode_start;
    static uint32_t provisioning_mode_start;
    static int last_error_mode = -1;
    static int last_provisioning_indicator = -1;

    (void)arg;
    int base = __atomic_load_n(&s_led_base, __ATOMIC_RELAXED);
    tick++;
    int64_t now_us = esp_timer_get_time();
    int factory_reset_pattern =
        __atomic_load_n(&s_factory_reset_pattern, __ATOMIC_RELAXED);
    if (now_us < s_startup_leds_until_us ||
        __atomic_load_n(&s_all_leds_on, __ATOMIC_RELAXED) != 0) {
        (void)gpio_set_level(APP_PIN_LED_ERROR, 1);
        (void)gpio_set_level(APP_PIN_LED_WIFI, 1);
        (void)gpio_set_level(APP_PIN_LED_ETH, 1);
#if APP_PIN_LED_LOAD >= 0
        (void)gpio_set_level(APP_PIN_LED_LOAD, 1);
#endif
        return;
    }
    if (factory_reset_pattern != 0) {
        int64_t pattern_start_us =
            __atomic_load_n(&s_factory_reset_pattern_start_us, __ATOMIC_RELAXED);
        int64_t elapsed_ms = (now_us - pattern_start_us) / 1000LL;
        if (elapsed_ms < 3LL * RESET_LED_PHASE_MS) {
            int level = elapsed_ms < RESET_LED_PHASE_MS ||
                        (elapsed_ms >= 2LL * RESET_LED_PHASE_MS &&
                         elapsed_ms < 3LL * RESET_LED_PHASE_MS);
            (void)gpio_set_level(APP_PIN_LED_ERROR, level);
            (void)gpio_set_level(APP_PIN_LED_WIFI, level);
            (void)gpio_set_level(APP_PIN_LED_ETH, level);
            return;
        }
    }

    int error_mode = base;
    if (error_mode != last_error_mode) {
        last_error_mode = error_mode;
        error_mode_start = tick;
    }
    (void)gpio_set_level(APP_PIN_LED_ERROR,
                         led_mode_level(error_mode, tick, error_mode_start));

    int provisioning_indicator =
        __atomic_load_n(&s_provisioning_indicator, __ATOMIC_RELAXED);
    if (provisioning_indicator != last_provisioning_indicator) {
        last_provisioning_indicator = provisioning_indicator;
        provisioning_mode_start = tick;
    }
    if (provisioning_indicator != 0) {
        int level = led_mode_level(APP_LED_BLINK_2HZ, tick, provisioning_mode_start);
        (void)gpio_set_level(APP_PIN_LED_WIFI, level);
        (void)gpio_set_level(APP_PIN_LED_ETH, level);
    } else {
        set_active_network_leds();
    }
}

void app_sysmon_led_error_set(app_led_mode_t mode)
{
    __atomic_store_n(&s_led_base, (int)mode, __ATOMIC_RELAXED);
}

void app_sysmon_set_provisioning_indicator(bool active)
{
    __atomic_store_n(&s_provisioning_indicator, active ? 1 : 0, __ATOMIC_RELAXED);
}

void app_sysmon_led_all_on(bool active)
{
    __atomic_store_n(&s_all_leds_on, active ? 1 : 0, __ATOMIC_RELAXED);
}

void app_sysmon_set_estop_indicator(bool active)
{
    __atomic_store_n(&s_estop_indicator, active ? 1 : 0, __ATOMIC_RELAXED);
}

void app_sysmon_error_mask_update(uint32_t set_mask, uint32_t clear_mask)
{
    if (clear_mask != 0U) {
        (void)__atomic_fetch_and(&g_sys.sys_error_mask, ~clear_mask, __ATOMIC_RELAXED);
    }
    if (set_mask != 0U) {
        (void)__atomic_fetch_or(&g_sys.sys_error_mask, set_mask, __ATOMIC_RELAXED);
    }
}

static void update_status_led_modes(int64_t now_us)
{
    EventBits_t bits = g_sys.sys_event_group != NULL
                           ? xEventGroupGetBits(g_sys.sys_event_group)
                           : 0U;
    bool network_lost = (bits & BIT_SYS_NET_LOST) != 0U;
    if (network_lost) {
        (void)__atomic_fetch_or(&g_sys.sys_error_mask, (uint32_t)SYS_ERR_NET_LOST,
                                __ATOMIC_RELAXED);
    } else {
        (void)__atomic_fetch_and(&g_sys.sys_error_mask,
                                 ~(uint32_t)SYS_ERR_NET_LOST, __ATOMIC_RELAXED);
    }

    bool estop = (bits & BIT_SYS_ESTOP) != 0U;
    app_sysmon_set_estop_indicator(estop);
    uint32_t errors = __atomic_load_n(&g_sys.sys_error_mask, __ATOMIC_RELAXED);
    app_led_mode_t error_mode = APP_LED_OFF;
    const uint32_t critical_errors =
        (uint32_t)SYS_ERR_NVM_FAIL | (uint32_t)SYS_ERR_ETH_INIT |
        (uint32_t)SYS_ERR_INIT_FAILURE | (uint32_t)SYS_ERR_RESOURCE_ALLOC;
    if ((errors & critical_errors) != 0U || estop ||
        (bits & BIT_SYS_INTERLOCK_TRIPPED) != 0U) {
        error_mode = APP_LED_ON;
    } else if (errors != 0U) {
        error_mode = APP_LED_BLINK_2HZ;
    }
    app_sysmon_led_error_set(error_mode);

#if APP_PIN_LED_LOAD >= 0
    bool any_load_on = false;
    for (uint8_t load_id = 1U; load_id <= APP_LOAD_COUNT; load_id++) {
        load_runtime_t runtime = {0};
        esp_err_t err = app_control_get_load_runtime(load_id, &runtime);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "load %u status unavailable for LED: %s",
                     (unsigned)load_id, esp_err_to_name(err));
            continue;
        }
        any_load_on = any_load_on || runtime.output;
    }
    (void)gpio_set_level(APP_PIN_LED_LOAD, any_load_on ? 1 : 0);
#endif
}

esp_err_t app_sysmon_wdt_init(void)
{
    if (s_wdt_configured) {
        return ESP_OK;
    }
    const esp_task_wdt_config_t config = {
        .timeout_ms = 10000U,
        .idle_core_mask = (1U << portNUM_PROCESSORS) - 1U,
        .trigger_panic = true,
    };
    esp_err_t err = esp_task_wdt_reconfigure(&config);
    if (err == ESP_ERR_INVALID_STATE) {
        err = esp_task_wdt_init(&config);
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "TWDT initialization/reconfiguration failed: %s", esp_err_to_name(err));
        return err;
    }
    s_wdt_configured = true;
    ESP_LOGI(TAG, "TWDT configured: timeout=10 s, idle cores monitored, panic enabled");
    return ESP_OK;
}

/* ---- User button state machine ------------------------------------------------------------- */

static inline bool button_pressed(void)
{
    return gpio_get_level(APP_PIN_BUTTON_RESET) == 0;
}

static void post_net_cmd(net_cmd_t cmd)
{
    if (g_sys.net_cmd_queue == NULL || xQueueSend(g_sys.net_cmd_queue, &cmd, 0) != pdTRUE) {
        ESP_LOGW(TAG, "net command %d not queued", (int)cmd);
    }
}

typedef enum {
    BTN_IDLE,
    BTN_HOLD1,      /* first press, timing towards the provisioning threshold */
    BTN_CLICK_WAIT, /* one short click done, waiting for the second click */
    BTN_CLICK2,     /* second short click in progress */
    BTN_PROV_WAIT,  /* long hold released, waiting for a second press to confirm a full reset */
    BTN_HOLD2,      /* second press, timing towards the reset threshold */
    BTN_DONE        /* action taken; ignore the button until released */
} btn_state_t;

/* Runs the moment the second hold reaches the reset threshold, without waiting for release. */
static void run_factory_reset(void)
{
    ESP_LOGW(TAG, "second hold reached %u s: factory reset", (unsigned)(APP_SYSMON_BUTTON_RESET_HOLD_MS / 1000U));
    app_sysmon_set_provisioning_indicator(false);
    (void)app_control_force_all_off("factory_reset");
    post_net_cmd(NET_CMD_FACTORY_RESET);

    esp_err_t err = app_nvm_factory_reset();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "factory reset failed: %s; staying up", esp_err_to_name(err));
        return;
    }
    ESP_LOGW(TAG, "NVS erased; showing three-LED reset pattern before restart");
    int64_t pattern_start_us = esp_timer_get_time();
    __atomic_store_n(&s_factory_reset_pattern_start_us, pattern_start_us,
                     __ATOMIC_RELAXED);
    __atomic_store_n(&s_factory_reset_pattern, 1, __ATOMIC_RELAXED);
    int64_t restart_at_us = pattern_start_us + MS_TO_US(3U * RESET_LED_PHASE_MS);
    while (esp_timer_get_time() < restart_at_us) {
        (void)esp_task_wdt_reset();
        vTaskDelay(pdMS_TO_TICKS(BUTTON_POLL_MS));
    }
    __atomic_store_n(&s_factory_reset_pattern, 0, __ATOMIC_RELAXED);
    s_skip_startup_led_animation = 1U;
    esp_restart();
}

static void sysmon_task(void *arg)
{
    (void)arg;

    esp_err_t wdt_err = esp_task_wdt_add(NULL);
    if (wdt_err != ESP_OK) {
        ESP_LOGE(TAG, "sysmon_task WDT registration failed: %s", esp_err_to_name(wdt_err));
        esp_restart();
    }

    bool raw = button_pressed();
    bool stable = raw;
    int64_t raw_since = esp_timer_get_time();
    bool armed = !stable; /* a button held at power-up must be released first */
    btn_state_t state = BTN_IDLE;
    bool prov_marked = false;
    int64_t press_start = 0;
    int64_t deadline = 0;
    int64_t last_status_update_us = 0;

    if (stable) {
        ESP_LOGW(TAG, "button held at power-up; waiting for release");
    }

    for (;;) {
        int64_t now = esp_timer_get_time();
        if (last_status_update_us == 0 ||
            now - last_status_update_us >= MS_TO_US(STATUS_UPDATE_MS)) {
            update_status_led_modes(now);
            last_status_update_us = now;
        }
        uint32_t heap = esp_get_free_heap_size();
        if (heap < LOW_HEAP_WARNING_BYTES &&
            (s_last_low_heap_warning_us == 0 ||
             now - s_last_low_heap_warning_us >= LOW_HEAP_WARNING_GAP_US)) {
            s_last_low_heap_warning_us = now;
            ESP_LOGW(TAG, "Low heap: free=%lu B, minimum=%lu B",
                     (unsigned long)heap,
                     (unsigned long)esp_get_minimum_free_heap_size());
        } else if (heap >= LOW_HEAP_WARNING_BYTES) {
            s_last_low_heap_warning_us = 0;
        }
        bool sample = button_pressed();

        if (sample != raw) {
            raw = sample;
            raw_since = now;
        }

        if (raw != stable && now - raw_since >= MS_TO_US(APP_SYSMON_BUTTON_DEBOUNCE_MS)) {
            stable = raw;
            if (stable && armed) {
                ESP_LOGI(TAG, "button pressed");
                switch (state) {
                case BTN_CLICK_WAIT:
                    state = BTN_CLICK2;
                    break;
                case BTN_PROV_WAIT:
                    state = BTN_HOLD2;
                    break;
                default:
                    state = BTN_HOLD1;
                    prov_marked = false;
                    break;
                }
                press_start = raw_since;
            } else if (!stable) {
                int64_t held = raw_since - press_start;

                switch (state) {
                case BTN_HOLD1:
                    if (held >= MS_TO_US(APP_SYSMON_BUTTON_PROV_HOLD_MS)) {
                        deadline = raw_since + MS_TO_US(APP_SYSMON_BUTTON_REARM_WINDOW_MS);
                        state = BTN_PROV_WAIT;
                        ESP_LOGI(TAG, "released after %d ms: press and hold again within %u ms for full reset",
                                 (int)(held / 1000), (unsigned)APP_SYSMON_BUTTON_REARM_WINDOW_MS);
                    } else if (held < MS_TO_US(APP_SYSMON_BUTTON_CLICK_MAX_MS)) {
                        deadline = raw_since + MS_TO_US(APP_SYSMON_BUTTON_DOUBLE_CLICK_GAP_MS);
                        state = BTN_CLICK_WAIT;
                    } else {
                        ESP_LOGI(TAG, "released after %d ms: ignored", (int)(held / 1000));
                        state = BTN_IDLE;
                    }
                    break;
                case BTN_CLICK2:
                    if (held < MS_TO_US(APP_SYSMON_BUTTON_CLICK_MAX_MS)) {
                        bool enabled = app_log_toggle();
                        /* Direct call: this confirmation must print whatever the new state is. */
                        ESP_LOG_LEVEL(ESP_LOG_INFO, TAG, "double click: application log %s",
                                      enabled ? "ON" : "OFF");
                    }
                    state = BTN_IDLE;
                    break;
                case BTN_HOLD2:
                    ESP_LOGI(TAG, "second press released after %d ms: runtime BLE provisioning only",
                             (int)(held / 1000));
                    post_net_cmd(NET_CMD_START_BLE_PROV_RUNTIME);
                    state = BTN_IDLE;
                    break;
                default:
                    state = BTN_IDLE;
                    break;
                }
                armed = true;
            }
        }

        switch (state) {
        case BTN_HOLD1:
            if (stable && !prov_marked &&
                now - press_start >= MS_TO_US(APP_SYSMON_BUTTON_PROV_HOLD_MS)) {
                prov_marked = true;
                app_sysmon_set_provisioning_indicator(true);
                ESP_LOGI(TAG, "5 s reached: Wi-Fi and Ethernet LEDs blink at 2 Hz");
            }
            break;
        case BTN_CLICK_WAIT:
            /* A press already in debounce at the deadline still counts. */
            if (now > deadline && !(raw && raw_since <= deadline)) {
                state = BTN_IDLE;
            }
            break;
        case BTN_PROV_WAIT:
            if (now > deadline && !(raw && raw_since <= deadline)) {
                ESP_LOGI(TAG, "no second hold: runtime BLE provisioning");
                post_net_cmd(NET_CMD_START_BLE_PROV_RUNTIME);
                state = BTN_IDLE;
            }
            break;
        case BTN_HOLD2:
            if (stable && now - press_start >= MS_TO_US(APP_SYSMON_BUTTON_RESET_HOLD_MS)) {
                state = BTN_DONE;
                run_factory_reset();
            }
            break;
        default:
            break;
        }

        (void)esp_task_wdt_reset();
        vTaskDelay(pdMS_TO_TICKS(BUTTON_POLL_MS));
    }
}

esp_err_t app_sysmon_init(void)
{
    if (s_task != NULL) {
        return ESP_OK;
    }

    esp_err_t err = app_sysmon_wdt_init();
    if (err != ESP_OK) {
        return err;
    }
    const gpio_config_t button_config = {
        .pin_bit_mask = 1ULL << APP_PIN_BUTTON_RESET,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    err = gpio_config(&button_config);
    if (err != ESP_OK) {
        return err;
    }

    uint64_t led_mask = (1ULL << APP_PIN_LED_ERROR) |
                        (1ULL << APP_PIN_LED_WIFI) |
                        (1ULL << APP_PIN_LED_ETH);
#if APP_PIN_LED_LOAD >= 0
    led_mask |= 1ULL << APP_PIN_LED_LOAD;
#endif
    const gpio_config_t led_config = {
        .pin_bit_mask = led_mask,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    err = gpio_config(&led_config);
    if (err != ESP_OK) {
        return err;
    }
    const gpio_num_t status_led_pins[] = {
        APP_PIN_LED_ERROR,
        APP_PIN_LED_WIFI,
        APP_PIN_LED_ETH,
    };
    for (size_t i = 0; i < sizeof(status_led_pins) / sizeof(status_led_pins[0]); i++) {
        err = gpio_set_level(status_led_pins[i], 0);
        if (err != ESP_OK) {
            return err;
        }
    }
#if APP_PIN_LED_LOAD >= 0
    err = gpio_set_level(APP_PIN_LED_LOAD, 0);
    if (err != ESP_OK) {
        return err;
    }
#endif

    bool skip_startup_animation = s_skip_startup_led_animation != 0U;
    s_skip_startup_led_animation = 0U;
    s_startup_leds_until_us = skip_startup_animation
                                  ? esp_timer_get_time()
                                  : esp_timer_get_time() + MS_TO_US(STARTUP_LED_ON_MS);
    for (size_t i = 0; i < sizeof(status_led_pins) / sizeof(status_led_pins[0]); i++) {
        err = gpio_set_level(status_led_pins[i], skip_startup_animation ? 0 : 1);
        if (err != ESP_OK) {
            return err;
        }
    }

    const esp_timer_create_args_t timer_args = {
        .callback = led_timer_cb,
        .name = "led_blink",
    };
    err = esp_timer_create(&timer_args, &s_led_timer);
    if (err == ESP_OK) {
        err = esp_timer_start_periodic(s_led_timer, MS_TO_US(LED_TICK_MS));
    }
    if (err != ESP_OK) {
        return err;
    }

    if (xTaskCreatePinnedToCore(sysmon_task, "sysmon_task", SYSMON_TASK_STACK_BYTES, NULL,
                                SYSMON_TASK_PRIORITY, &s_task, SYSMON_TASK_CORE) != pdPASS) {
        s_task = NULL;
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "button monitor started on GPIO%d", (int)APP_PIN_BUTTON_RESET);
    return ESP_OK;
}
