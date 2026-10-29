#include "app_network.h"

#include <string.h>

#include "app_network_eth.h"
#include "app_network_fsm.h"
#include "app_network_wifi.h"
#include "esp_event.h"
#include "app_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/task.h"

#define PROV_POLL_MS 200U
#define PROV_WIFI_DISCONNECT_TIMEOUT_MS 5000U

static const char *TAG = "app_network";

static EventGroupHandle_t s_event_group;
static bool s_started;
static bool s_wifi_stopped;

static void network_event_handler(void *argument, esp_event_base_t event_base, int32_t event_id,
                                  void *event_data)
{
    (void)argument;
    (void)event_data;

    if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        xEventGroupSetBits(s_event_group, BIT_NET_WIFI_CONNECTED);
    } else {
        xEventGroupClearBits(s_event_group, BIT_NET_WIFI_CONNECTED);
    }
}

static const char *wifi_reason_text(int reason)
{
    switch (reason) {
    case WIFI_REASON_AUTH_FAIL:
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_MIC_FAILURE:
    case WIFI_REASON_802_1X_AUTH_FAILED:
        return "wrong_password";
    case WIFI_REASON_NO_AP_FOUND:
        return "ap_not_found";
    default:
        return "unknown";
    }
}

esp_err_t app_network_start(EventGroupHandle_t sys_event_group, const app_config_t *config)
{
    if (sys_event_group == NULL || config == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (__atomic_load_n(&s_started, __ATOMIC_RELAXED)) {
        return ESP_ERR_INVALID_STATE;
    }

    if (!config->only_use_ethernet && config->wifi_ssid[0] == '\0') {
        return ESP_ERR_INVALID_ARG;
    }

    s_event_group = sys_event_group;

    esp_err_t result = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                 network_event_handler, NULL);
    if (result == ESP_OK) {
        result = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_LOST_IP, network_event_handler,
                                            NULL);
    }
    if (result == ESP_OK) {
        result = esp_event_handler_register(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED,
                                            network_event_handler, NULL);
    }
    if (result != ESP_OK) {
        ESP_LOGE(TAG, "event handler register failed: %s", esp_err_to_name(result));
        return result;
    }

    if (config->only_use_ethernet) {
        /* Keep Wi-Fi event tracking ready for runtime provisioning without starting the radio. */
        (void)esp_wifi_stop();
        __atomic_store_n(&s_wifi_stopped, true, __ATOMIC_RELAXED);
        __atomic_store_n(&s_started, true, __ATOMIC_RELAXED);
        ESP_LOGI(TAG, "Ethernet-only mode, Wi-Fi disabled");
        return ESP_OK;
    }

    result = app_wifi_sta_init();
    if (result != ESP_OK) {
        return result;
    }

    if (app_wifi_sta_is_connected()) {
        /* The provisioning check already connected; avoid a reassociation. */
        xEventGroupSetBits(s_event_group, BIT_NET_WIFI_CONNECTED);
    } else {
        result = app_wifi_sta_connect(config->wifi_ssid, config->wifi_password);
        if (result != ESP_OK) {
            return result;
        }
    }

    __atomic_store_n(&s_started, true, __ATOMIC_RELAXED);
    return ESP_OK;
}

static bool wait_wifi(app_prov_net_report_t *report)
{
    int64_t deadline = esp_timer_get_time() + (int64_t)APP_PROV_WIFI_TIMEOUT_MS * 1000;

    while (esp_timer_get_time() < deadline) {
        if (app_wifi_sta_is_connected()) {
            report->wifi_attempts = app_wifi_sta_get_retry_count() + 1U;
            return true;
        }
        if (app_wifi_sta_get_retry_count() >= APP_PROV_WIFI_MAX_ATTEMPTS) {
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(PROV_POLL_MS));
    }
    report->wifi_attempts = app_wifi_sta_get_retry_count();
    report->wifi_reason = wifi_reason_text(app_wifi_sta_get_last_disconnect_reason());
    return false;
}

static bool wait_wifi_disconnected(void)
{
    const int64_t deadline =
        esp_timer_get_time() + (int64_t)PROV_WIFI_DISCONNECT_TIMEOUT_MS * 1000;

    while (esp_timer_get_time() < deadline) {
        if (!app_wifi_sta_is_connected()) {
            return true;
        }
        vTaskDelay(pdMS_TO_TICKS(PROV_POLL_MS));
    }
    return !app_wifi_sta_is_connected();
}

esp_err_t app_network_provision_connect(const app_config_t *config, app_prov_net_report_t *report)
{
    if (config == NULL || report == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    memset(report, 0, sizeof(*report));

    /* Started first so its DHCP runs while Wi-Fi is being tried. */
    int64_t eth_deadline = esp_timer_get_time() + (int64_t)APP_PROV_ETH_WAIT_MS * 1000;
    bool eth_started = app_eth_w5500_init() == ESP_OK && app_eth_w5500_start() == ESP_OK;
    if (!eth_started) {
        ESP_LOGW(TAG, "Ethernet not available during provisioning");
    }

    if (!config->only_use_ethernet) {
        esp_err_t err = app_wifi_sta_init();
        if (err == ESP_OK) {
            err = app_wifi_sta_connect(config->wifi_ssid, config->wifi_password);
        }
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Wi-Fi could not be started: %s", esp_err_to_name(err));
            report->wifi_reason = "unknown";
        } else if (wait_wifi(report)) {
            report->eth_up = eth_started && app_eth_w5500_is_connected();
            report->outcome = APP_PROV_NET_OK;
            return ESP_OK;
        }
        ESP_LOGW(TAG, "Wi-Fi failed after %u attempt(s): %s", (unsigned)report->wifi_attempts,
                 report->wifi_reason != NULL ? report->wifi_reason : "unknown");
    }

    while (eth_started && !app_eth_w5500_is_connected() && esp_timer_get_time() < eth_deadline) {
        vTaskDelay(pdMS_TO_TICKS(PROV_POLL_MS));
    }
    report->eth_up = eth_started && app_eth_w5500_is_connected();

    if (config->only_use_ethernet) {
        report->outcome = report->eth_up ? APP_PROV_NET_OK : APP_PROV_NET_ETH_FAILED;
    } else if (report->eth_up) {
        report->outcome = APP_PROV_NET_WIFI_FAILED_ETH_OK; /* Wi-Fi keeps retrying in the background */
    } else {
        report->outcome = APP_PROV_NET_NONE;
        (void)app_wifi_sta_disconnect();
    }
    return ESP_OK;
}

esp_err_t app_network_wifi_radio_on(void)
{
    esp_err_t err = app_wifi_sta_init();

    if (err == ESP_OK && __atomic_load_n(&s_wifi_stopped, __ATOMIC_RELAXED)) {
        err = esp_wifi_start();
        __atomic_store_n(&s_wifi_stopped, err != ESP_OK, __ATOMIC_RELAXED);
    }
    return err;
}

void app_network_wifi_radio_restore(const app_config_t *config)
{
    if (config != NULL && config->only_use_ethernet &&
        !__atomic_load_n(&s_wifi_stopped, __ATOMIC_RELAXED)) {
        (void)app_wifi_sta_disconnect();
        __atomic_store_n(&s_wifi_stopped, esp_wifi_stop() == ESP_OK, __ATOMIC_RELAXED);
    }
}

esp_err_t app_network_get_active_details(char *ssid, size_t ssid_size, char *ip_address,
                                         size_t ip_address_size)
{
    if (ssid == NULL || ssid_size == 0U || ip_address == NULL || ip_address_size == 0U) {
        return ESP_ERR_INVALID_ARG;
    }

    ssid[0] = '\0';
    ip_address[0] = '\0';
    net_interface_t active = app_network_get_active_interface();
    esp_netif_t *netif = NULL;

    if (active == NET_IF_WIFI) {
        netif = app_wifi_get_netif_handle();
        wifi_ap_record_t ap = {0};
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
            ap.ssid[sizeof(ap.ssid) - 1U] = '\0';
            strlcpy(ssid, (const char *)ap.ssid, ssid_size);
        }
    } else if (active == NET_IF_ETH) {
        netif = app_eth_get_netif_handle();
    }

    if (netif != NULL) {
        esp_netif_ip_info_t info = {0};
        if (esp_netif_get_ip_info(netif, &info) == ESP_OK && info.ip.addr != 0U) {
            (void)esp_ip4addr_ntoa(&info.ip, ip_address, (int)ip_address_size);
        }
    }
    return ESP_OK;
}

esp_err_t app_network_runtime_apply(const app_config_t *new_config, const app_config_t *current,
                                    app_prov_net_report_t *report)
{
    if (new_config == NULL || current == NULL || report == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    memset(report, 0, sizeof(*report));

    if (new_config->only_use_ethernet) {
        report->eth_up = app_eth_w5500_is_connected();
        if (!report->eth_up) {
            report->outcome = APP_PROV_NET_ETH_FAILED;
            return ESP_OK;
        }
        (void)app_wifi_sta_disconnect();
        __atomic_store_n(&s_wifi_stopped, esp_wifi_stop() == ESP_OK, __ATOMIC_RELAXED);
        report->outcome = APP_PROV_NET_OK;
        return ESP_OK;
    }

    esp_err_t err = app_network_wifi_radio_on();
    if (err == ESP_OK && app_wifi_sta_is_connected()) {
        ESP_LOGW(TAG, "Disconnecting current Wi-Fi for runtime credential update");
        err = app_wifi_sta_disconnect();
        if (err == ESP_OK && !wait_wifi_disconnected()) {
            ESP_LOGE(TAG, "Wi-Fi did not disconnect for runtime credential update");
            report->wifi_reason = "disconnect_timeout";
            report->outcome = APP_PROV_NET_WIFI_BUSY;
            return ESP_OK;
        }
    }
    if (err == ESP_OK) {
        err = app_wifi_sta_connect(new_config->wifi_ssid, new_config->wifi_password);
    }
    if (err == ESP_OK && wait_wifi(report)) {
        report->eth_up = app_eth_w5500_is_connected();
        report->outcome = APP_PROV_NET_OK;
        return ESP_OK;
    }
    if (err != ESP_OK) {
        report->wifi_reason = "unknown";
    }

    ESP_LOGW(TAG, "Runtime Wi-Fi change failed; restoring the stored credentials");
    if (current->only_use_ethernet || current->wifi_ssid[0] == '\0') {
        (void)app_wifi_sta_disconnect();
    } else {
        (void)app_wifi_sta_connect(current->wifi_ssid, current->wifi_password);
    }
    report->outcome = APP_PROV_NET_NONE;
    return ESP_OK;
}

bool app_network_wifi_is_enabled(void)
{
    return __atomic_load_n(&s_started, __ATOMIC_RELAXED) &&
           !__atomic_load_n(&s_wifi_stopped, __ATOMIC_RELAXED);
}
