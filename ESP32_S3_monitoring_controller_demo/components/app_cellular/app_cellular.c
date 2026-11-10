#include "app_cellular.h"

#include <stdlib.h>
#include <string.h>

#include "driver/gpio.h"
#include "driver/uart.h"
#include "app_pins.h"
#include "esp_event.h"
#include "esp_netif_ppp.h"
#include "esp_modem_api.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#ifndef CONFIG_APP_CELLULAR_APN
#define CONFIG_APP_CELLULAR_APN ""
#endif

#define CELLULAR_RESET_PULSE_MS 200U
#define CELLULAR_RESET_SETTLE_MS 10000U
#define CELLULAR_BOOT_WAIT_US (10000000LL)
#define CELLULAR_RETRY_US (5000000LL)
#define CELLULAR_RECOVERY_INITIAL_US (30000000LL)
#define CELLULAR_RECOVERY_MAX_US (300000000LL)
#define CELLULAR_MONITOR_PERIOD_MS 1000U

static const char *TAG = "app_cellular";
static esp_modem_dce_t *s_dce;
static esp_netif_t *s_netif;
static bool s_initialized;
static bool s_connected;
static app_cellular_state_t s_state = APP_CELLULAR_STATE_UNINITIALIZED;
static uint32_t s_recovery_count;
static esp_err_t s_last_error = ESP_OK;
static TaskHandle_t s_monitor_task;
static int64_t s_connecting_since_us;
static int64_t s_recovery_delay_us = CELLULAR_RECOVERY_INITIAL_US;
static int64_t s_modem_ready_at_us;
static int64_t s_next_attempt_us;
static bool s_start_pending;

static void cellular_monitor_task(void *arg);

static void set_error(esp_err_t err)
{
    __atomic_store_n(&s_last_error, err, __ATOMIC_RELAXED);
    if (err != ESP_OK) {
        __atomic_store_n(&s_state, APP_CELLULAR_STATE_ERROR, __ATOMIC_RELAXED);
        ESP_LOGE(TAG, "cellular operation failed: %s", esp_err_to_name(err));
    }
}

#ifndef CONFIG_ESP_MODEM_C_API_STR_MAX
#define CONFIG_ESP_MODEM_C_API_STR_MAX 128
#endif

/* Logs SIM, signal, registration and operator state; the modem must be in command mode. */
static void log_modem_diagnostics(void)
{
    static const char *const k_cmds[] = {
        "AT+CPIN?", "AT+CSQ", "AT+CREG?", "AT+CEREG?", "AT+COPS?", "AT+CGATT?",
    };
    char out[CONFIG_ESP_MODEM_C_API_STR_MAX + 1];
    for (size_t i = 0; i < sizeof(k_cmds) / sizeof(k_cmds[0]); i++) {
        out[0] = '\0';
        esp_err_t err = esp_modem_at(s_dce, k_cmds[i], out, 3000);
        for (char *p = out; *p != '\0'; p++) {
            if (*p == '\r' || *p == '\n') {
                *p = ' ';
            }
        }
        ESP_LOGI(TAG, "diag %s -> %s %s", k_cmds[i], esp_err_to_name(err), out);
    }
}

static bool modem_registered(void)
{
    static const char *const k_cmds[] = {"AT+CEREG?", "AT+CREG?"};
    char out[CONFIG_ESP_MODEM_C_API_STR_MAX + 1];
    for (size_t i = 0; i < sizeof(k_cmds) / sizeof(k_cmds[0]); i++) {
        out[0] = '\0';
        if (esp_modem_at(s_dce, k_cmds[i], out, 3000) != ESP_OK) {
            continue;
        }
        const char *comma = strchr(out, ',');
        if (comma != NULL) {
            int stat = atoi(comma + 1);
            if (stat == 1 || stat == 5) {
                return true;
            }
        }
    }
    return false;
}

static void cellular_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)data;
    if (base != IP_EVENT) {
        return;
    }
    if (id == IP_EVENT_PPP_GOT_IP) {
        __atomic_store_n(&s_connected, true, __ATOMIC_RELAXED);
        __atomic_store_n(&s_state, APP_CELLULAR_STATE_CONNECTED, __ATOMIC_RELAXED);
        __atomic_store_n(&s_last_error, ESP_OK, __ATOMIC_RELAXED);
        __atomic_store_n(&s_connecting_since_us, 0, __ATOMIC_RELAXED);
        __atomic_store_n(&s_recovery_delay_us, CELLULAR_RECOVERY_INITIAL_US, __ATOMIC_RELAXED);
        ESP_LOGI(TAG, "PPP connected");
    } else if (id == IP_EVENT_PPP_LOST_IP) {
        __atomic_store_n(&s_connected, false, __ATOMIC_RELAXED);
        if (__atomic_load_n(&s_state, __ATOMIC_RELAXED) != APP_CELLULAR_STATE_STOPPED) {
            __atomic_store_n(&s_state, APP_CELLULAR_STATE_CONNECTING, __ATOMIC_RELAXED);
            __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(), __ATOMIC_RELAXED);
        }
        ESP_LOGW(TAG, "PPP link lost");
    }
}

static esp_err_t ensure_initialized(void)
{
    if (s_initialized) {
        return s_monitor_task != NULL ? ESP_OK : ESP_ERR_NO_MEM;
    }

    esp_err_t err = esp_netif_init();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        set_error(err);
        return err;
    }

    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        set_error(err);
        return err;
    }

    gpio_config_t reset_cfg = {
        .pin_bit_mask = 1ULL << APP_PIN_CELLULAR_RESET,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    err = gpio_config(&reset_cfg);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    /* Pulse RST at boot so the modem always starts from a clean state. */
    err = gpio_set_level(APP_PIN_CELLULAR_RESET, 0);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    vTaskDelay(pdMS_TO_TICKS(CELLULAR_RESET_PULSE_MS));
    err = gpio_set_level(APP_PIN_CELLULAR_RESET, 1);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    /* The modem needs time after power-up before it answers AT commands. */
    s_modem_ready_at_us = esp_timer_get_time() + CELLULAR_BOOT_WAIT_US;

    gpio_config_t dtr_cfg = {
        .pin_bit_mask = 1ULL << APP_PIN_CELLULAR_DTR,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    err = gpio_config(&dtr_cfg);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    err = gpio_set_level(APP_PIN_CELLULAR_DTR, 0);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }

    esp_netif_config_t netif_config = ESP_NETIF_DEFAULT_PPP();
    s_netif = esp_netif_new(&netif_config);
    if (s_netif == NULL) {
        set_error(ESP_ERR_NO_MEM);
        return ESP_ERR_NO_MEM;
    }

    esp_modem_dte_config_t dte_config = ESP_MODEM_DTE_DEFAULT_CONFIG();
    dte_config.uart_config.port_num = UART_NUM_0;
    dte_config.uart_config.tx_io_num = APP_PIN_CELLULAR_TX;
    dte_config.uart_config.rx_io_num = APP_PIN_CELLULAR_RX;
    dte_config.uart_config.baud_rate = 115200;

    /* Show the AT commands/responses exchanged by esp-modem. */
    esp_log_level_set("uart_terminal", ESP_LOG_DEBUG);
    esp_log_level_set("command_lib", ESP_LOG_DEBUG);
    esp_log_level_set("modem_api", ESP_LOG_DEBUG);
    esp_log_level_set("modem_api_target", ESP_LOG_DEBUG);
    esp_log_level_set("esp-modem", ESP_LOG_DEBUG);

    esp_modem_dce_config_t dce_config = ESP_MODEM_DCE_DEFAULT_CONFIG(CONFIG_APP_CELLULAR_APN);
    s_dce = esp_modem_new(&dte_config, &dce_config, s_netif);
    if (s_dce == NULL) {
        esp_netif_destroy(s_netif);
        s_netif = NULL;
        set_error(ESP_FAIL);
        return ESP_FAIL;
    }

    err = esp_event_handler_register(IP_EVENT, ESP_EVENT_ANY_ID, cellular_event_handler, NULL);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    s_initialized = true;
    __atomic_store_n(&s_state, APP_CELLULAR_STATE_STOPPED, __ATOMIC_RELAXED);
    if (xTaskCreate(cellular_monitor_task, "cellular_monitor", 4096U, NULL, 4U,
                    &s_monitor_task) != pdPASS) {
        set_error(ESP_ERR_NO_MEM);
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

esp_err_t app_cellular_start(void)
{
    esp_err_t err = ensure_initialized();
    if (err != ESP_OK) {
        return err;
    }
    if (__atomic_load_n(&s_connected, __ATOMIC_RELAXED) ||
        __atomic_load_n(&s_state, __ATOMIC_RELAXED) == APP_CELLULAR_STATE_CONNECTING) {
        return ESP_OK;
    }
    __atomic_store_n(&s_state, APP_CELLULAR_STATE_CONNECTING, __ATOMIC_RELAXED);
    if (esp_timer_get_time() < s_modem_ready_at_us) {
        /* The monitor task enters data mode once the modem has finished booting. */
        __atomic_store_n(&s_connecting_since_us, s_modem_ready_at_us, __ATOMIC_RELAXED);
        __atomic_store_n(&s_next_attempt_us, s_modem_ready_at_us, __ATOMIC_RELAXED);
        __atomic_store_n(&s_start_pending, true, __ATOMIC_RELAXED);
        __atomic_store_n(&s_connected, false, __ATOMIC_RELAXED);
        __atomic_store_n(&s_last_error, ESP_OK, __ATOMIC_RELAXED);
        ESP_LOGI(TAG, "waiting for modem boot before starting PPP");
        return ESP_OK;
    }
    __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(), __ATOMIC_RELAXED);
    log_modem_diagnostics();
    esp_err_t mode_err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_DATA);
    if (mode_err != ESP_OK) {
        set_error(mode_err);
        __atomic_store_n(&s_state, APP_CELLULAR_STATE_CONNECTING, __ATOMIC_RELAXED);
        __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(), __ATOMIC_RELAXED);
        __atomic_store_n(&s_next_attempt_us, esp_timer_get_time() + CELLULAR_RETRY_US,
                         __ATOMIC_RELAXED);
        __atomic_store_n(&s_start_pending, true, __ATOMIC_RELAXED);
        return mode_err;
    }
    __atomic_store_n(&s_connected, false, __ATOMIC_RELAXED);
    __atomic_store_n(&s_last_error, ESP_OK, __ATOMIC_RELAXED);
    return ESP_OK;
}

esp_err_t app_cellular_stop(void)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }
    __atomic_store_n(&s_start_pending, false, __ATOMIC_RELAXED);
    esp_err_t err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    __atomic_store_n(&s_connected, false, __ATOMIC_RELAXED);
    __atomic_store_n(&s_state, APP_CELLULAR_STATE_STOPPED, __ATOMIC_RELAXED);
    __atomic_store_n(&s_connecting_since_us, 0, __ATOMIC_RELAXED);
    return ESP_OK;
}

bool app_cellular_is_connected(void)
{
    return __atomic_load_n(&s_connected, __ATOMIC_RELAXED);
}

esp_netif_t *app_cellular_get_netif_handle(void)
{
    return s_netif;
}

esp_err_t app_cellular_reset(void)
{
    esp_err_t err = ensure_initialized();
    if (err != ESP_OK) {
        return err;
    }
    esp_err_t mode_err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    __atomic_store_n(&s_start_pending, false, __ATOMIC_RELAXED);
    if (mode_err != ESP_OK) {
        ESP_LOGW(TAG, "modem did not enter command mode before hardware reset: %s",
                 esp_err_to_name(mode_err));
    }
    __atomic_store_n(&s_connected, false, __ATOMIC_RELAXED);
    err = gpio_set_level(APP_PIN_CELLULAR_RESET, 0);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    vTaskDelay(pdMS_TO_TICKS(CELLULAR_RESET_PULSE_MS));
    err = gpio_set_level(APP_PIN_CELLULAR_RESET, 1);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    vTaskDelay(pdMS_TO_TICKS(CELLULAR_RESET_SETTLE_MS));
    __atomic_add_fetch(&s_recovery_count, 1U, __ATOMIC_RELAXED);
    err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_DATA);
    if (err != ESP_OK) {
        set_error(err);
        return err;
    }
    __atomic_store_n(&s_state, APP_CELLULAR_STATE_CONNECTING, __ATOMIC_RELAXED);
    __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(), __ATOMIC_RELAXED);
    return ESP_OK;
}

static void cellular_monitor_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(CELLULAR_MONITOR_PERIOD_MS));
        if (__atomic_load_n(&s_start_pending, __ATOMIC_RELAXED)) {
            int64_t now = esp_timer_get_time();
            if (now >= __atomic_load_n(&s_next_attempt_us, __ATOMIC_RELAXED)) {
                __atomic_store_n(&s_start_pending, false, __ATOMIC_RELAXED);
                log_modem_diagnostics();
                esp_err_t start_err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_DATA);
                if (start_err == ESP_OK) {
                    ESP_LOGI(TAG, "modem entered data mode; waiting for PPP address");
                    __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(),
                                     __ATOMIC_RELAXED);
                } else {
                    ESP_LOGW(TAG, "modem start failed: %s; retrying", esp_err_to_name(start_err));
                    int64_t since = __atomic_load_n(&s_connecting_since_us, __ATOMIC_RELAXED);
                    int64_t recovery_delay =
                        __atomic_load_n(&s_recovery_delay_us, __ATOMIC_RELAXED);
                    if (since != 0 && now - since >= recovery_delay) {
                        ESP_LOGW(TAG, "modem start kept failing; resetting A7680C");
                        esp_err_t reset_err = app_cellular_reset();
                        if (recovery_delay < CELLULAR_RECOVERY_MAX_US) {
                            recovery_delay *= 2;
                            if (recovery_delay > CELLULAR_RECOVERY_MAX_US) {
                                recovery_delay = CELLULAR_RECOVERY_MAX_US;
                            }
                            __atomic_store_n(&s_recovery_delay_us, recovery_delay,
                                             __ATOMIC_RELAXED);
                        }
                        if (reset_err != ESP_OK) {
                            ESP_LOGW(TAG, "modem reset recovery failed: %s",
                                     esp_err_to_name(reset_err));
                            __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(),
                                             __ATOMIC_RELAXED);
                            __atomic_store_n(&s_next_attempt_us,
                                             esp_timer_get_time() + CELLULAR_RETRY_US,
                                             __ATOMIC_RELAXED);
                            __atomic_store_n(&s_start_pending, true, __ATOMIC_RELAXED);
                        }
                    } else {
                        __atomic_store_n(&s_next_attempt_us, now + CELLULAR_RETRY_US,
                                         __ATOMIC_RELAXED);
                        __atomic_store_n(&s_start_pending, true, __ATOMIC_RELAXED);
                    }
                }
            }
            continue;
        }
        if (__atomic_load_n(&s_state, __ATOMIC_RELAXED) != APP_CELLULAR_STATE_CONNECTING) {
            continue;
        }
        int64_t since = __atomic_load_n(&s_connecting_since_us, __ATOMIC_RELAXED);
        int64_t recovery_delay = __atomic_load_n(&s_recovery_delay_us, __ATOMIC_RELAXED);
        if (since == 0 || esp_timer_get_time() - since < recovery_delay) {
            continue;
        }
        __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(), __ATOMIC_RELAXED);
        ESP_LOGW(TAG, "4G has no PPP address for %lld s; checking modem AT responsiveness",
                 (long long)(recovery_delay / 1000000LL));

        esp_err_t err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
        if (err == ESP_OK) {
            int rssi = 0;
            int ber = 0;
            err = esp_modem_get_signal_quality(s_dce, &rssi, &ber);
            ESP_LOGI(TAG, "AT+CSQ -> %s rssi=%d ber=%d", esp_err_to_name(err), rssi, ber);
            if (err == ESP_OK && !modem_registered()) {
                /* The modem answers AT but is not on the network (e.g. a SIM swapped while
                 * powered is only read after a modem reset). */
                log_modem_diagnostics();
                ESP_LOGW(TAG, "modem not registered on the network; resetting A7680C");
                err = ESP_FAIL;
            }
        } else {
            ESP_LOGW(TAG, "could not enter command mode: %s", esp_err_to_name(err));
        }
        if (err == ESP_OK) {
            ESP_LOGW(TAG, "modem responds to AT; restarting PPP without hardware reset");
            err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_DATA);
            if (err == ESP_OK) {
                __atomic_store_n(&s_state, APP_CELLULAR_STATE_CONNECTING, __ATOMIC_RELAXED);
                __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(), __ATOMIC_RELAXED);
                continue;
            }
        }
        ESP_LOGW(TAG, "modem AT check failed: %s; resetting A7680C", esp_err_to_name(err));
        err = app_cellular_reset();
        recovery_delay = __atomic_load_n(&s_recovery_delay_us, __ATOMIC_RELAXED);
        if (recovery_delay < CELLULAR_RECOVERY_MAX_US) {
            recovery_delay *= 2;
            if (recovery_delay > CELLULAR_RECOVERY_MAX_US) {
                recovery_delay = CELLULAR_RECOVERY_MAX_US;
            }
            __atomic_store_n(&s_recovery_delay_us, recovery_delay, __ATOMIC_RELAXED);
        }
        if (err != ESP_OK) {
            set_error(err);
            __atomic_store_n(&s_state, APP_CELLULAR_STATE_CONNECTING, __ATOMIC_RELAXED);
            __atomic_store_n(&s_connecting_since_us, esp_timer_get_time(), __ATOMIC_RELAXED);
        }
    }
}

app_cellular_state_t app_cellular_get_state(void)
{
    return __atomic_load_n(&s_state, __ATOMIC_RELAXED);
}

uint32_t app_cellular_get_recovery_count(void)
{
    return __atomic_load_n(&s_recovery_count, __ATOMIC_RELAXED);
}

esp_err_t app_cellular_get_last_error(void)
{
    return __atomic_load_n(&s_last_error, __ATOMIC_RELAXED);
}
