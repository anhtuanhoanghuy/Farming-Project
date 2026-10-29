#ifndef APP_NETWORK_H
#define APP_NETWORK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define APP_PROV_WIFI_MAX_ATTEMPTS 3U
#define APP_PROV_WIFI_TIMEOUT_MS   45000U
#define APP_PROV_ETH_WAIT_MS       15000U

typedef enum {
    APP_PROV_NET_OK = 0,            /* requested network is up */
    APP_PROV_NET_WIFI_FAILED_ETH_OK, /* Wi-Fi failed, Ethernet has an IP */
    APP_PROV_NET_ETH_FAILED,        /* Ethernet-only requested, no IP */
    APP_PROV_NET_NONE,              /* Wi-Fi failed and Ethernet has no IP */
    APP_PROV_NET_WIFI_BUSY          /* runtime only: active Wi-Fi did not disconnect in time */
} app_prov_net_outcome_t;

typedef struct {
    app_prov_net_outcome_t outcome;
    uint32_t wifi_attempts;      /* failed or used Wi-Fi attempts, 0 in Ethernet-only mode */
    const char *wifi_reason;     /* "wrong_password", "ap_not_found", "unknown" or NULL */
    bool eth_up;
} app_prov_net_report_t;

/*
 * Starts the networks selected by the stored config: Wi-Fi STA (retrying with backoff until it
 * connects) unless only_use_ethernet is set, in which case Wi-Fi is stopped. Ethernet is brought up
 * and supervised by the network FSM (app_network_fsm_init()).
 */
esp_err_t app_network_start(EventGroupHandle_t sys_event_group, const app_config_t *config);

/*
 * Provisioning check, blocking up to about a minute: starts Ethernet in parallel, then either waits
 * for Ethernet to get an IP (only_use_ethernet) or tries Wi-Fi up to APP_PROV_WIFI_MAX_ATTEMPTS
 * times and, if that fails, reports whether Ethernet has an IP. Does not touch the NVM. When
 * Wi-Fi failed and Ethernet is up, Wi-Fi keeps retrying in the background.
 */
esp_err_t app_network_provision_connect(const app_config_t *config, app_prov_net_report_t *report);

/*
 * Runtime provisioning check: changes Wi-Fi without touching Ethernet or the default netif. If
 * Wi-Fi is carrying traffic, it is disconnected briefly while the new credentials are tested, so
 * MQTT may reconnect. A failed attempt restores the Wi-Fi credentials of `current`; outcome OK
 * means the new settings are live and may be saved. Ethernet-only requires Ethernet to have an IP
 * and then stops Wi-Fi.
 */
esp_err_t app_network_runtime_apply(const app_config_t *new_config, const app_config_t *current,
                                    app_prov_net_report_t *report);

/* Reads the active interface's SSID (Wi-Fi only) and IPv4 address; unavailable values are empty. */
esp_err_t app_network_get_active_details(char *ssid, size_t ssid_size, char *ip_address,
                                         size_t ip_address_size);

/* Initialises and starts the Wi-Fi radio without connecting, so the app can scan for SSIDs. */
esp_err_t app_network_wifi_radio_on(void);

/* Turns the radio off again when `config` is Ethernet-only; call when a provisioning session ends. */
void app_network_wifi_radio_restore(const app_config_t *config);
/* Returns whether this boot's network configuration has Wi-Fi enabled. */
bool app_network_wifi_is_enabled(void);

#ifdef __cplusplus
}
#endif

#endif
