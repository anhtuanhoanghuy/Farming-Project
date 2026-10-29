#include "app_network_wifi.h"

#include <string.h>

#include "esp_event.h"
#include "app_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

#define WIFI_BIT_LINK   (1U << 0) /* L2 associated */
#define WIFI_BIT_GOT_IP (1U << 1) /* L3 address acquired */
#define WIFI_BIT_WANT   (1U << 2) /* caller asked to stay connected */

static const char *TAG = "app_wifi";

static esp_netif_t *s_netif;
static EventGroupHandle_t s_state;
static esp_timer_handle_t s_retry_timer;
static uint32_t s_retry_count;
static int s_last_reason;
static bool s_initialized;

static uint32_t backoff_delay_ms(uint32_t attempt)
{
    if (attempt > 10U) {
        attempt = 10U;
    }
    uint32_t cap = APP_WIFI_BACKOFF_BASE_MS << attempt;
    if (cap > APP_WIFI_BACKOFF_MAX_MS) {
        cap = APP_WIFI_BACKOFF_MAX_MS;
    }
    uint32_t delay = esp_random() % (cap + 1U);
    return delay < APP_WIFI_BACKOFF_FLOOR_MS ? APP_WIFI_BACKOFF_FLOOR_MS : delay;
}

static void schedule_retry(void)
{
    uint32_t attempt = __atomic_fetch_add(&s_retry_count, 1U, __ATOMIC_RELAXED);
    uint32_t delay_ms = backoff_delay_ms(attempt);

    (void)esp_timer_stop(s_retry_timer);
    esp_err_t err = esp_timer_start_once(s_retry_timer, (uint64_t)delay_ms * 1000U);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "retry timer start failed: %s", esp_err_to_name(err));
        return;
    }
    ESP_LOGW(TAG, "reconnect attempt %u in %u ms", (unsigned)(attempt + 1U), (unsigned)delay_ms);
}

static void try_connect(void)
{
    esp_err_t err = esp_wifi_connect();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_connect failed: %s", esp_err_to_name(err));
        schedule_retry();
    }
}

static void retry_timer_callback(void *arg)
{
    (void)arg;
    if ((xEventGroupGetBits(s_state) & (WIFI_BIT_WANT | WIFI_BIT_LINK)) == WIFI_BIT_WANT) {
        try_connect();
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;

    if (base == WIFI_EVENT) {
        switch (id) {
        case WIFI_EVENT_STA_START:
            ESP_LOGI(TAG, "STA started");
            if (xEventGroupGetBits(s_state) & WIFI_BIT_WANT) {
                try_connect();
            }
            break;
        case WIFI_EVENT_STA_CONNECTED:
            (void)esp_timer_stop(s_retry_timer);
            xEventGroupSetBits(s_state, WIFI_BIT_LINK);
            ESP_LOGI(TAG, "associated with AP, waiting for IP");
            break;
        case WIFI_EVENT_STA_DISCONNECTED: {
            const wifi_event_sta_disconnected_t *event = data;
            EventBits_t bits = xEventGroupClearBits(s_state, WIFI_BIT_LINK | WIFI_BIT_GOT_IP);

            __atomic_store_n(&s_last_reason, (int)event->reason, __ATOMIC_RELAXED);

            if (bits & WIFI_BIT_WANT) {
                ESP_LOGW(TAG, "disconnected (reason %d)", event->reason);
                schedule_retry();
            } else {
                ESP_LOGI(TAG, "disconnected (reason %d), no reconnect requested", event->reason);
            }
            break;
        }
        default:
            break;
        }
    } else if (base == IP_EVENT) {
        if (id == IP_EVENT_STA_GOT_IP) {
            const ip_event_got_ip_t *event = data;

            (void)esp_timer_stop(s_retry_timer);
            __atomic_store_n(&s_retry_count, 0U, __ATOMIC_RELAXED);
            xEventGroupSetBits(s_state, WIFI_BIT_GOT_IP);
            ESP_LOGI(TAG, "got IP " IPSTR, IP2STR(&event->ip_info.ip));
        } else if (id == IP_EVENT_STA_LOST_IP) {
            xEventGroupClearBits(s_state, WIFI_BIT_GOT_IP);
            ESP_LOGW(TAG, "lost IP");
        }
    }
}

esp_err_t app_wifi_sta_init(void)
{
    if (s_initialized) {
        return ESP_OK;
    }

    esp_err_t err = esp_netif_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "netif init failed: %s", esp_err_to_name(err));
        return err;
    }
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "event loop create failed: %s", esp_err_to_name(err));
        return err;
    }

    s_state = xEventGroupCreate();
    if (s_state == NULL) {
        ESP_LOGE(TAG, "event group allocation failed");
        return ESP_ERR_NO_MEM;
    }

    const esp_timer_create_args_t timer_args = {
        .callback = retry_timer_callback,
        .name = "wifi_retry",
    };
    err = esp_timer_create(&timer_args, &s_retry_timer);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "retry timer create failed: %s", esp_err_to_name(err));
        goto fail_group;
    }

    s_netif = esp_netif_create_default_wifi_sta();
    if (s_netif == NULL) {
        ESP_LOGE(TAG, "STA netif creation failed");
        err = ESP_FAIL;
        goto fail_timer;
    }

    wifi_init_config_t init_config = WIFI_INIT_CONFIG_DEFAULT();
    err = esp_wifi_init(&init_config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_init failed: %s", esp_err_to_name(err));
        goto fail_netif;
    }

    err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "set storage failed: %s", esp_err_to_name(err));
        goto fail_wifi;
    }

    err = esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event_handler, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Wi-Fi handler register failed: %s", esp_err_to_name(err));
        goto fail_wifi;
    }
    err = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event_handler, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "GOT_IP handler register failed: %s", esp_err_to_name(err));
        goto fail_wifi_handler;
    }
    err = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_LOST_IP, wifi_event_handler, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "LOST_IP handler register failed: %s", esp_err_to_name(err));
        goto fail_ip_handler;
    }

    err = esp_wifi_set_mode(WIFI_MODE_STA);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "set mode failed: %s", esp_err_to_name(err));
        goto fail_lost_ip_handler;
    }
    err = esp_wifi_start();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_start failed: %s", esp_err_to_name(err));
        goto fail_lost_ip_handler;
    }

    s_initialized = true;
    ESP_LOGI(TAG, "Wi-Fi STA initialised");
    return ESP_OK;

fail_lost_ip_handler:
    (void)esp_event_handler_unregister(IP_EVENT, IP_EVENT_STA_LOST_IP, wifi_event_handler);
fail_ip_handler:
    (void)esp_event_handler_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event_handler);
fail_wifi_handler:
    (void)esp_event_handler_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event_handler);
fail_wifi:
    (void)esp_wifi_deinit();
fail_netif:
    esp_netif_destroy_default_wifi(s_netif);
    s_netif = NULL;
fail_timer:
    (void)esp_timer_delete(s_retry_timer);
    s_retry_timer = NULL;
fail_group:
    vEventGroupDelete(s_state);
    s_state = NULL;
    return err;
}

esp_err_t app_wifi_sta_connect(const char *ssid, const char *pass)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "connect called before init");
        return ESP_ERR_INVALID_STATE;
    }

    size_t ssid_len = ssid != NULL ? strnlen(ssid, APP_WIFI_SSID_MAX_LEN + 1U) : 0U;
    size_t pass_len = pass != NULL ? strnlen(pass, APP_WIFI_PASS_MAX_LEN + 1U) : 0U;
    if (ssid_len == 0U || ssid_len > APP_WIFI_SSID_MAX_LEN) {
        ESP_LOGE(TAG, "invalid SSID length");
        return ESP_ERR_INVALID_ARG;
    }
    if (pass_len != 0U && (pass_len < APP_WIFI_PASS_MIN_LEN || pass_len > APP_WIFI_PASS_MAX_LEN)) {
        ESP_LOGE(TAG, "invalid password length");
        return ESP_ERR_INVALID_ARG;
    }

    wifi_config_t config = {0};
    memcpy(config.sta.ssid, ssid, ssid_len);
    if (pass_len != 0U) {
        memcpy(config.sta.password, pass, pass_len);
    }
    config.sta.threshold.authmode = pass_len == 0U ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA2_PSK;
    config.sta.pmf_cfg.capable = true;
    config.sta.pmf_cfg.required = false;

    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "set config failed: %s", esp_err_to_name(err));
        return err;
    }

    (void)esp_timer_stop(s_retry_timer);
    __atomic_store_n(&s_retry_count, 0U, __ATOMIC_RELAXED);
    __atomic_store_n(&s_last_reason, 0, __ATOMIC_RELAXED);
    EventBits_t bits = xEventGroupSetBits(s_state, WIFI_BIT_WANT);

    ESP_LOGI(TAG, "connecting to SSID \"%s\"", ssid);
    if (bits & WIFI_BIT_LINK) {
        /* The DISCONNECTED handler reconnects with the new credentials. */
        err = esp_wifi_disconnect();
        if (err != ESP_OK && err != ESP_ERR_WIFI_NOT_CONNECT) {
            ESP_LOGE(TAG, "disconnect before reconnect failed: %s", esp_err_to_name(err));
            return err;
        }
    } else {
        try_connect();
    }
    return ESP_OK;
}

esp_err_t app_wifi_sta_disconnect(void)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    xEventGroupClearBits(s_state, WIFI_BIT_WANT);
    (void)esp_timer_stop(s_retry_timer);

    esp_err_t err = esp_wifi_disconnect();
    if (err != ESP_OK && err != ESP_ERR_WIFI_NOT_CONNECT) {
        ESP_LOGE(TAG, "disconnect failed: %s", esp_err_to_name(err));
        return err;
    }
    ESP_LOGI(TAG, "disconnect requested");
    return ESP_OK;
}

bool app_wifi_sta_is_connected(void)
{
    if (!s_initialized) {
        return false;
    }
    return (xEventGroupGetBits(s_state) & WIFI_BIT_GOT_IP) != 0U;
}

esp_netif_t *app_wifi_get_netif_handle(void)
{
    return s_netif;
}

uint32_t app_wifi_sta_get_retry_count(void)
{
    return __atomic_load_n(&s_retry_count, __ATOMIC_RELAXED);
}

int app_wifi_sta_get_last_disconnect_reason(void)
{
    return __atomic_load_n(&s_last_reason, __ATOMIC_RELAXED);
}
