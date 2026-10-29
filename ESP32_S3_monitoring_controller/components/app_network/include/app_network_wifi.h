#ifndef APP_NETWORK_WIFI_H
#define APP_NETWORK_WIFI_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_netif.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef APP_WIFI_BACKOFF_BASE_MS
#define APP_WIFI_BACKOFF_BASE_MS 1000U
#endif
#ifndef APP_WIFI_BACKOFF_MAX_MS
#define APP_WIFI_BACKOFF_MAX_MS 5000U
#endif
#ifndef APP_WIFI_BACKOFF_FLOOR_MS
#define APP_WIFI_BACKOFF_FLOOR_MS 200U
#endif

#define APP_WIFI_SSID_MAX_LEN 32U
#define APP_WIFI_PASS_MIN_LEN 8U
#define APP_WIFI_PASS_MAX_LEN 63U

/*
 * One-time setup: creates the default STA netif, initialises the Wi-Fi driver (credentials are not
 * persisted by the driver), registers event handlers and starts WIFI_MODE_STA without connecting.
 * Requires the default event loop. Idempotent once it has succeeded.
 */
esp_err_t app_wifi_sta_init(void);

/*
 * Stores the credentials and starts connecting. A NULL or empty pass selects an open network.
 * Returns immediately; failures after this call are retried with exponential backoff and full
 * jitter (base/max/floor above) until app_wifi_sta_disconnect() is called. Calling it while
 * connected re-associates with the new credentials.
 * Returns ESP_ERR_INVALID_STATE before init and ESP_ERR_INVALID_ARG for out-of-range lengths.
 */
esp_err_t app_wifi_sta_connect(const char *ssid, const char *pass);

/* Cancels pending retries and drops the association; no automatic reconnect afterwards. */
esp_err_t app_wifi_sta_disconnect(void);

/* True while the STA is associated and holds an IPv4 address. Safe to call from any task. */
bool app_wifi_sta_is_connected(void);

/* Returns the STA netif, or NULL before app_wifi_sta_init() succeeds. */
esp_netif_t *app_wifi_get_netif_handle(void);

/* Failed attempts since the last app_wifi_sta_connect(); reset by a successful connection. */
uint32_t app_wifi_sta_get_retry_count(void);

/* wifi_err_reason_t of the last disconnect since app_wifi_sta_connect(), 0 if none. */
int app_wifi_sta_get_last_disconnect_reason(void);

#ifdef __cplusplus
}
#endif

#endif
