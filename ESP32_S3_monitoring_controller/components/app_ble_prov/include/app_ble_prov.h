#ifndef APP_BLE_PROV_H
#define APP_BLE_PROV_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define APP_BLE_PROV_NAME_PREFIX "PROV_ESP32_"
#define APP_BLE_PROV_WINDOW_MS 300000U

/* Provisional shared proof-of-possession; replace once the BLE security model is decided. */
#ifndef APP_BLE_PROV_POP
#define APP_BLE_PROV_POP "abcd1234"
#endif

typedef enum {
    APP_PROV_STATUS_SUCCESS = 0,
    APP_PROV_STATUS_WARNING,
    APP_PROV_STATUS_ERROR
} app_prov_status_t;

/* What the app is told once the controller has tried the requested network. */
typedef struct {
    app_prov_status_t status;
    const char *code;     /* machine readable, e.g. ERR_WIFI_CONNECT_FAILED; NULL for SUCCESS */
    const char *reason;   /* e.g. wrong_password; may be NULL */
    const char *message;  /* short plain text without quotes; may be NULL */
    uint32_t attempts;    /* Wi-Fi attempts used */
    uint32_t max_sensor_count; /* total sensor interfaces supported by this firmware */
    uint32_t max_load_count;   /* total load interfaces supported by this firmware */
    bool save_config;     /* persist the received config to the NVM */
} app_prov_apply_result_t;

/*
 * Called on the provisioning worker task (not the BLE host task) with the validated config; may
 * block for up to about a minute while it tries the networks. Strings in the result must stay valid.
 */
typedef void (*app_ble_prov_apply_cb_t)(const app_config_t *config, app_prov_apply_result_t *result);

/*
 * Starts BLE advertising with the secured endpoints:
 *   prov-config  accepts one config {ssid, password, user_id, only_use_ethernet}; answers
 *                IN_PROGRESS at once, or ERROR for an invalid request (the session stays open);
 *                both responses include the Wi-Fi STA MAC as lowercase device_id
 *   prov-status  returns device_id with idle/in_progress/done and final provisioning result
 *   wifi-scan    {"start":0} runs a Wi-Fi scan; {"start":N} pages through the cached list
 * After the first accepted config the worker calls apply_cb, saves the config when asked to, stores
 * the result and sets BIT_PROV_DONE. BIT_PROV_RESULT_SENT is set once the app has read the result.
 * Wi-Fi must already be initialised for wifi-scan to work.
 */
esp_err_t app_ble_prov_start(EventGroupHandle_t sys_event_group, app_ble_prov_apply_cb_t apply_cb);
esp_err_t app_ble_prov_stop(void);
/* Stops discovery without interrupting a connected client reading the result. */
esp_err_t app_ble_prov_stop_advertising(void);

/* True while a config is being applied; do not stop the session until it returns false. */
bool app_ble_prov_is_busy(void);

/* wifi-scan answers "wifi_unavailable" when disabled (the Wi-Fi radio could not be started). */
void app_ble_prov_set_scan_enabled(bool enabled);

#ifdef __cplusplus
}
#endif

#endif
