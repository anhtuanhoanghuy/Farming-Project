#include "app_ble_prov.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app_nvm.h"
#include "defines.h"
#include "cJSON.h"
#include "app_log.h"
#include "esp_mac.h"
#include "esp_wifi.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "protocomm.h"
#include "protocomm_ble.h"
#include "protocomm_security1.h"

#define PROV_SESSION_ENDPOINT "prov-session"
#define PROV_CONFIG_ENDPOINT "prov-config"
#define PROV_STATUS_ENDPOINT "prov-status"
#define WIFI_SCAN_ENDPOINT "wifi-scan"
#define PROV_SESSION_UUID 0xFF51
#define PROV_CONFIG_UUID 0xFF52
#define PROV_STATUS_UUID 0xFF53
#define WIFI_SCAN_UUID 0xFF54
#define PROV_CONFIG_FIELD_COUNT 4
#define PROV_MAX_REQUEST_SIZE 512
#define SCAN_MAX_RECORDS 20
#define SCAN_RESPONSE_BUDGET 440
#define WORKER_STACK_BYTES 4096
#define WORKER_PRIORITY 4

typedef enum {
    PROV_IDLE = 0,
    PROV_APPLYING,
    PROV_DONE
} prov_state_t;

typedef struct {
    char ssid[33];
    int8_t rssi;
    uint8_t auth;
} scan_entry_t;

static const char *TAG = "app_ble_prov";

/* Default Espressif provisioning service UUID so standard provisioning clients can discover it. */
static const uint8_t s_service_uuid[BLE_UUID128_VAL_LENGTH] = {
    0xb4, 0xdf, 0x5a, 0x1c, 0x3f, 0x6b, 0xf4, 0xbf,
    0xea, 0x4a, 0x82, 0x03, 0x04, 0x90, 0x1a, 0x02,
};

static protocomm_ble_name_uuid_t s_endpoint_uuids[] = {
    {PROV_SESSION_ENDPOINT, PROV_SESSION_UUID},
    {PROV_CONFIG_ENDPOINT, PROV_CONFIG_UUID},
    {PROV_STATUS_ENDPOINT, PROV_STATUS_UUID},
    {WIFI_SCAN_ENDPOINT, WIFI_SCAN_UUID},
};

/* protocomm keeps this pointer for the lifetime of the session. */
static const protocomm_security1_params_t s_security_params = {
    .data = (const uint8_t *)APP_BLE_PROV_POP,
    .len = sizeof(APP_BLE_PROV_POP) - 1,
};

static protocomm_t *s_protocomm;
static EventGroupHandle_t s_event_group;
static app_ble_prov_apply_cb_t s_apply_cb;
static TaskHandle_t s_worker;
static volatile bool s_stop;
static int s_state;
static app_config_t s_pending;
static app_prov_apply_result_t s_result;
static bool s_saved;
static volatile bool s_scan_enabled = true;
static scan_entry_t s_scan[SCAN_MAX_RECORDS];
static size_t s_scan_count;

static esp_err_t send_json(uint8_t **outbuf, ssize_t *outlen, const char *body)
{
    size_t length = strlen(body);
    uint8_t *response = malloc(length);

    if (response == NULL) {
        return ESP_ERR_NO_MEM;
    }
    memcpy(response, body, length);
    *outbuf = response;
    *outlen = (ssize_t)length;
    return ESP_OK;
}

static esp_err_t get_device_id(char device_id[13])
{
    uint8_t mac[6];
    esp_err_t err = esp_read_mac(mac, ESP_MAC_WIFI_STA);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read Wi-Fi STA MAC: %s", esp_err_to_name(err));
        return err;
    }

    (void)snprintf(device_id, 13, "%02x%02x%02x%02x%02x%02x",
                   mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    return ESP_OK;
}

static esp_err_t send_status(uint8_t **outbuf, ssize_t *outlen, const char *status,
                             const char *reason)
{
    char device_id[13];
    esp_err_t err = get_device_id(device_id);
    if (err != ESP_OK) {
        return err;
    }

    char body[144];
    int length;

    if (reason != NULL) {
        length = snprintf(body, sizeof(body),
                          "{\"status\":\"%s\",\"reason\":\"%s\",\"device_id\":\"%s\"}",
                          status, reason, device_id);
    } else {
        length = snprintf(body, sizeof(body), "{\"status\":\"%s\",\"device_id\":\"%s\"}",
                           status, device_id);
    }
    if (length < 0 || (size_t)length >= sizeof(body)) {
        return ESP_FAIL;
    }
    return send_json(outbuf, outlen, body);
}

static bool copy_json_string(const cJSON *root, const char *key, char *destination,
                             size_t capacity)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, key);
    if (!cJSON_IsString(item) || item->valuestring == NULL) {
        return false;
    }

    size_t length = strlen(item->valuestring);
    if (length >= capacity) {
        return false;
    }
    memcpy(destination, item->valuestring, length + 1);
    return true;
}

static prov_state_t state_get(void)
{
    return (prov_state_t)__atomic_load_n(&s_state, __ATOMIC_ACQUIRE);
}

static void state_set(prov_state_t state)
{
    __atomic_store_n(&s_state, (int)state, __ATOMIC_RELEASE);
}

/* ---- Worker: applies the config off the BLE host task --------------------------------------- */

static void prov_worker(void *arg)
{
    (void)arg;

    for (;;) {
        (void)ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        if (s_stop) {
            break;
        }

        memset(&s_result, 0, sizeof(s_result));
        s_result.status = APP_PROV_STATUS_ERROR;
        s_result.max_sensor_count = APP_SENSOR_INTERFACE_COUNT;
        s_result.max_load_count = APP_LOAD_COUNT;
        s_saved = false;
        s_apply_cb(&s_pending, &s_result);

        if (s_result.save_config) {
            if (app_nvm_save_config(&s_pending) == ESP_OK) {
                s_saved = true;
                ESP_LOGI(TAG, "Provisioning config saved");
            } else {
                s_result.status = APP_PROV_STATUS_ERROR;
                s_result.code = "ERR_STORAGE";
                s_result.reason = "storage_error";
                s_result.message = NULL;
            }
        }
        memset(&s_pending, 0, sizeof(s_pending)); /* drops the Wi-Fi password from RAM */

        state_set(PROV_DONE);
        xEventGroupSetBits(s_event_group, BIT_PROV_DONE);
    }
    s_worker = NULL;
    vTaskDelete(NULL);
}

/* ---- prov-config ---------------------------------------------------------------------------- */

static esp_err_t prov_config_handler(uint32_t session_id, const uint8_t *inbuf, ssize_t inlen,
                                     uint8_t **outbuf, ssize_t *outlen, void *priv_data)
{
    (void)session_id;
    (void)priv_data;

    prov_state_t state = state_get();
    if (state != PROV_IDLE) {
        return send_status(outbuf, outlen, "ERROR",
                           state == PROV_APPLYING ? "busy" : "already_provisioned");
    }
    if (inbuf == NULL || inlen <= 0 || inlen > PROV_MAX_REQUEST_SIZE) {
        return send_status(outbuf, outlen, "ERROR", "invalid_request");
    }

    cJSON *root = cJSON_ParseWithLength((const char *)inbuf, (size_t)inlen);
    app_config_t *config = calloc(1, sizeof(*config));
    esp_err_t result = ESP_OK;
    const char *error_reason = NULL;

    if (root == NULL || config == NULL) {
        error_reason = root == NULL ? "invalid_json" : "no_memory";
        goto respond;
    }

    /* Exactly the four provisioning fields are accepted. */
    const cJSON *ethernet_only = cJSON_GetObjectItemCaseSensitive(root, "only_use_ethernet");
    if (!cJSON_IsObject(root) || cJSON_GetArraySize(root) != PROV_CONFIG_FIELD_COUNT ||
        !cJSON_IsBool(ethernet_only)) {
        error_reason = "invalid_fields";
        goto respond;
    }

    /* Keep sensor/load settings; defaults are filled when nothing valid is stored. */
    (void)app_nvm_load_config(config);

    if (!copy_json_string(root, "ssid", config->wifi_ssid, sizeof(config->wifi_ssid)) ||
        !copy_json_string(root, "password", config->wifi_password,
                          sizeof(config->wifi_password)) ||
        !copy_json_string(root, "user_id", config->user_id, sizeof(config->user_id))) {
        error_reason = "invalid_fields";
        goto respond;
    }
    config->only_use_ethernet = cJSON_IsTrue(ethernet_only);

    if (app_nvm_validate_provisioning(config) != ESP_OK) {
        error_reason = "invalid_value";
        goto respond;
    }

    s_pending = *config;
    state_set(PROV_APPLYING);
    xTaskNotifyGive(s_worker);
    ESP_LOGI(TAG, "Provisioning config accepted (%s)",
             config->only_use_ethernet ? "Ethernet only" : "Wi-Fi");

respond:
    if (error_reason != NULL) {
        ESP_LOGW(TAG, "Provisioning rejected: %s", error_reason);
        result = send_status(outbuf, outlen, "ERROR", error_reason);
    } else {
        result = send_status(outbuf, outlen, "IN_PROGRESS", NULL);
    }

    if (config != NULL) {
        memset(config, 0, sizeof(*config));
    }
    cJSON_Delete(root);
    free(config);
    return result;
}

/* ---- prov-status ---------------------------------------------------------------------------- */

static const char *status_text(app_prov_status_t status)
{
    switch (status) {
    case APP_PROV_STATUS_SUCCESS:
        return "SUCCESS";
    case APP_PROV_STATUS_WARNING:
        return "WARNING";
    default:
        return "ERROR";
    }
}

static esp_err_t prov_status_handler(uint32_t session_id, const uint8_t *inbuf, ssize_t inlen,
                                     uint8_t **outbuf, ssize_t *outlen, void *priv_data)
{
    (void)session_id;
    (void)inbuf;
    (void)inlen;
    (void)priv_data;

    prov_state_t state = state_get();
    char device_id[13];
    esp_err_t err = get_device_id(device_id);
    if (err != ESP_OK) {
        return err;
    }

    if (state == PROV_IDLE) {
        char body[48];
        (void)snprintf(body, sizeof(body), "{\"state\":\"idle\",\"device_id\":\"%s\"}",
                       device_id);
        return send_json(outbuf, outlen, body);
    }
    if (state == PROV_APPLYING) {
        char body[56];
        (void)snprintf(body, sizeof(body),
                       "{\"state\":\"in_progress\",\"device_id\":\"%s\"}", device_id);
        return send_json(outbuf, outlen, body);
    }

    char body[320];
    int length = snprintf(body, sizeof(body),
                          "{\"state\":\"done\",\"status\":\"%s\",\"saved\":%s,"
                          "\"attempts\":%u,\"device_id\":\"%s\","
                          "\"max_sensor_count\":%u,\"max_load_count\":%u",
                          status_text(s_result.status), s_saved ? "true" : "false",
                          (unsigned)s_result.attempts, device_id,
                          (unsigned)s_result.max_sensor_count,
                          (unsigned)s_result.max_load_count);
    if (s_result.code != NULL && length > 0 && (size_t)length < sizeof(body)) {
        length += snprintf(body + length, sizeof(body) - (size_t)length, ",\"code\":\"%s\"",
                           s_result.code);
    }
    if (s_result.reason != NULL && length > 0 && (size_t)length < sizeof(body)) {
        length += snprintf(body + length, sizeof(body) - (size_t)length, ",\"reason\":\"%s\"",
                           s_result.reason);
    }
    if (s_result.message != NULL && length > 0 && (size_t)length < sizeof(body)) {
        length += snprintf(body + length, sizeof(body) - (size_t)length, ",\"message\":\"%s\"",
                           s_result.message);
    }
    if (length > 0 && (size_t)length < sizeof(body)) {
        length += snprintf(body + length, sizeof(body) - (size_t)length, "}");
    }
    if (length <= 0 || (size_t)length >= sizeof(body)) {
        return ESP_FAIL;
    }

    esp_err_t result = send_json(outbuf, outlen, body);
    if (result == ESP_OK) {
        xEventGroupSetBits(s_event_group, BIT_PROV_RESULT_SENT);
    }
    return result;
}

/* ---- wifi-scan ------------------------------------------------------------------------------ */

static esp_err_t run_scan(void)
{
    /* With Bluetooth enabled the Wi-Fi driver requires the default active scan times (0). */
    wifi_scan_config_t scan_config = {
        .scan_type = WIFI_SCAN_TYPE_ACTIVE,
    };
    esp_err_t err = esp_wifi_scan_start(&scan_config, true);
    if (err != ESP_OK) {
        return err;
    }

    uint16_t count = SCAN_MAX_RECORDS;
    wifi_ap_record_t *records = calloc(count, sizeof(*records));
    if (records == NULL) {
        (void)esp_wifi_clear_ap_list();
        return ESP_ERR_NO_MEM;
    }
    err = esp_wifi_scan_get_ap_records(&count, records);
    if (err == ESP_OK) {
        s_scan_count = 0;
        for (uint16_t i = 0; i < count; i++) {
            const char *ssid = (const char *)records[i].ssid;
            size_t existing = 0;

            if (ssid[0] == '\0') {
                continue;
            }
            for (; existing < s_scan_count; existing++) {
                if (strcmp(s_scan[existing].ssid, ssid) == 0) {
                    break;
                }
            }
            if (existing == s_scan_count) {
                if (s_scan_count == SCAN_MAX_RECORDS) {
                    continue;
                }
                s_scan_count++;
            } else if (s_scan[existing].rssi >= records[i].rssi) {
                continue;
            }
            strlcpy(s_scan[existing].ssid, ssid, sizeof(s_scan[existing].ssid));
            s_scan[existing].rssi = records[i].rssi;
            s_scan[existing].auth = (uint8_t)records[i].authmode;
        }
        for (size_t i = 1; i < s_scan_count; i++) {
            scan_entry_t entry = s_scan[i];
            size_t j = i;
            for (; j > 0 && s_scan[j - 1].rssi < entry.rssi; j--) {
                s_scan[j] = s_scan[j - 1];
            }
            s_scan[j] = entry;
        }
    }
    free(records);
    return err;
}

static esp_err_t wifi_scan_handler(uint32_t session_id, const uint8_t *inbuf, ssize_t inlen,
                                   uint8_t **outbuf, ssize_t *outlen, void *priv_data)
{
    (void)session_id;
    (void)priv_data;

    if (state_get() != PROV_IDLE) {
        return send_status(outbuf, outlen, "ERROR", "busy");
    }
    if (!s_scan_enabled) {
        return send_status(outbuf, outlen, "ERROR", "wifi_unavailable");
    }

    double start = 0;
    if (inbuf != NULL && inlen > 0) {
        cJSON *request = cJSON_ParseWithLength((const char *)inbuf, (size_t)inlen);
        if (request == NULL) {
            return send_status(outbuf, outlen, "ERROR", "invalid_json");
        }
        const cJSON *item = cJSON_GetObjectItemCaseSensitive(request, "start");
        if (item != NULL) {
            start = cJSON_IsNumber(item) ? item->valuedouble : -1;
        }
        cJSON_Delete(request);
    }
    if (start < 0 || start != (double)(size_t)start) {
        return send_status(outbuf, outlen, "ERROR", "invalid_value");
    }

    size_t first = (size_t)start;
    if (first == 0) {
        esp_err_t err = run_scan();
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "Wi-Fi scan failed: %s", esp_err_to_name(err));
            return send_status(outbuf, outlen, "ERROR", "scan_failed");
        }
    } else if (s_scan_count == 0) {
        return send_status(outbuf, outlen, "ERROR", "no_scan");
    }
    if (first > s_scan_count) {
        return send_status(outbuf, outlen, "ERROR", "invalid_value");
    }

    cJSON *response = cJSON_CreateObject();
    cJSON *list = cJSON_CreateArray();
    if (response == NULL || list == NULL) {
        cJSON_Delete(response);
        cJSON_Delete(list);
        return send_status(outbuf, outlen, "ERROR", "no_memory");
    }
    cJSON_AddStringToObject(response, "status", "SUCCESS");
    cJSON_AddNumberToObject(response, "total", (double)s_scan_count);
    cJSON_AddNumberToObject(response, "start", (double)first);
    cJSON_AddItemToObject(response, "aps", list);

    for (size_t i = first; i < s_scan_count; i++) {
        cJSON *entry = cJSON_CreateObject();
        if (entry == NULL) {
            break;
        }
        cJSON_AddStringToObject(entry, "ssid", s_scan[i].ssid);
        cJSON_AddNumberToObject(entry, "rssi", s_scan[i].rssi);
        cJSON_AddNumberToObject(entry, "auth", s_scan[i].auth);
        cJSON_AddItemToArray(list, entry);

        char *text = cJSON_PrintUnformatted(response);
        size_t length = text != NULL ? strlen(text) : SCAN_RESPONSE_BUDGET + 1U;
        free(text);
        if (length > SCAN_RESPONSE_BUDGET && i > first) {
            cJSON_Delete(cJSON_DetachItemFromArray(list, cJSON_GetArraySize(list) - 1));
            break;
        }
    }

    char *text = cJSON_PrintUnformatted(response);
    cJSON_Delete(response);
    if (text == NULL) {
        return ESP_ERR_NO_MEM;
    }
    *outbuf = (uint8_t *)text;
    *outlen = (ssize_t)strlen(text);
    return ESP_OK;
}

/* ---- Start / stop --------------------------------------------------------------------------- */

esp_err_t app_ble_prov_start(EventGroupHandle_t sys_event_group, app_ble_prov_apply_cb_t apply_cb)
{
    if (sys_event_group == NULL || apply_cb == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (s_protocomm != NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    s_event_group = sys_event_group;
    s_apply_cb = apply_cb;
    s_stop = false;
    s_saved = false;
    s_scan_count = 0;
    state_set(PROV_IDLE);

    if (xTaskCreate(prov_worker, "prov_worker", WORKER_STACK_BYTES, NULL, WORKER_PRIORITY,
                    &s_worker) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }

    s_protocomm = protocomm_new();
    if (s_protocomm == NULL) {
        s_stop = true;
        xTaskNotifyGive(s_worker);
        return ESP_ERR_NO_MEM;
    }

    protocomm_ble_config_t ble_config = {
        .nu_lookup_count = sizeof(s_endpoint_uuids) / sizeof(s_endpoint_uuids[0]),
        .nu_lookup = s_endpoint_uuids,
        .ble_sm_sc = 1,
    };
    memcpy(ble_config.service_uuid, s_service_uuid, sizeof(ble_config.service_uuid));

    uint8_t mac[6];
    esp_err_t result = esp_read_mac(mac, ESP_MAC_BT);
    if (result == ESP_OK) {
        (void)snprintf(ble_config.device_name, sizeof(ble_config.device_name), "%s%02X%02X%02X",
                       APP_BLE_PROV_NAME_PREFIX, mac[3], mac[4], mac[5]);
        result = protocomm_set_security(s_protocomm, PROV_SESSION_ENDPOINT, &protocomm_security1,
                                        &s_security_params);
    }
    if (result == ESP_OK) {
        result = protocomm_add_endpoint(s_protocomm, PROV_CONFIG_ENDPOINT, prov_config_handler,
                                        NULL);
    }
    if (result == ESP_OK) {
        result = protocomm_add_endpoint(s_protocomm, PROV_STATUS_ENDPOINT, prov_status_handler,
                                        NULL);
    }
    if (result == ESP_OK) {
        result = protocomm_add_endpoint(s_protocomm, WIFI_SCAN_ENDPOINT, wifi_scan_handler, NULL);
    }
    if (result == ESP_OK) {
        result = protocomm_ble_start(s_protocomm, &ble_config);
    }

    if (result != ESP_OK) {
        ESP_LOGE(TAG, "BLE provisioning start failed: %s", esp_err_to_name(result));
        protocomm_delete(s_protocomm);
        s_protocomm = NULL;
        s_stop = true;
        xTaskNotifyGive(s_worker);
        return result;
    }

    ESP_LOGI(TAG, "Advertising as %s", ble_config.device_name);
    return ESP_OK;
}

esp_err_t app_ble_prov_stop(void)
{
    if (s_protocomm == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t result = protocomm_ble_stop(s_protocomm);
    protocomm_delete(s_protocomm);
    s_protocomm = NULL;
    s_stop = true;
    if (s_worker != NULL) {
        xTaskNotifyGive(s_worker);
    }
    return result;
}

esp_err_t app_ble_prov_stop_advertising(void)
{
    if (!ble_gap_adv_active()) {
        return ESP_OK;
    }
    int result = ble_gap_adv_stop();
    if (result != 0 && result != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "Could not stop BLE advertising: %d", result);
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "BLE advertising stopped");
    return ESP_OK;
}

bool app_ble_prov_is_busy(void)
{
    return state_get() == PROV_APPLYING;
}

void app_ble_prov_set_scan_enabled(bool enabled)
{
    s_scan_enabled = enabled;
}
