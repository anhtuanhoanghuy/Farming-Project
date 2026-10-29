#include "app_nvm.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app_log.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "nvs_flash.h"

#define APP_NVM_NAMESPACE "app_cfg"
#define APP_NVM_CONFIG_KEY "config"
#define APP_NVM_DEVCFG_KEY "devcfg"
#define APP_NVM_RECORD_MAGIC 0x41504346U
#define APP_NVM_MAX_RECORD_SIZE 2048U

static const char *TAG = "app_nvm";

typedef struct {
    uint32_t magic;
    uint16_t schema_version;
    uint16_t payload_size;
    uint32_t crc32;
} app_nvm_record_header_t;

typedef struct {
    bool present;
    bool enabled;
    bool action;
    bool op_gt;
    uint8_t sensor_port;
    float threshold;
} legacy_load_condition_cfg_t;

typedef struct {
    bool present;
    bool enabled;
    uint8_t days_mask;
    uint16_t on_minute_utc;
    uint16_t off_minute_utc;
} legacy_load_scheduler_cfg_t;

typedef struct {
    char name[32];
    bool enabled;
    legacy_load_condition_cfg_t condition[APP_CONDITIONS_PER_LOAD];
    legacy_load_scheduler_cfg_t scheduler[APP_SCHEDULERS_PER_LOAD];
} legacy_load_cfg_t;

typedef struct {
    bool configured;
    bool enabled;
    uint8_t slave_id;
    float discarded_legacy_offset;
    char name[32];
} legacy_sensor_port_cfg_t;

typedef struct {
    legacy_sensor_port_cfg_t sensor[APP_SENSOR_INTERFACE_COUNT];
    legacy_load_cfg_t load[APP_LOAD_COUNT];
} legacy_device_cfg_t;

typedef struct {
    bool configured;
    bool enabled;
    uint8_t slave_id;
    float discarded_legacy_offset;
    char name[32];
} legacy_sensor_port_cfg_v2_t;

typedef struct {
    legacy_sensor_port_cfg_v2_t sensor[APP_SENSOR_INTERFACE_COUNT];
    load_cfg_t load[APP_LOAD_COUNT];
} legacy_device_cfg_v2_t;

_Static_assert(sizeof(legacy_load_condition_cfg_t) == 12U,
               "legacy condition layout changed");
_Static_assert(sizeof(legacy_load_scheduler_cfg_t) == 8U,
               "legacy scheduler layout changed");

/* Leading fields shared by every older "config" layout; the sensor and load tables that
 * followed them moved to the "devcfg" blob. */
typedef struct {
    char wifi_ssid[33];
    char wifi_password[64];
    char user_id[32];
    bool only_use_ethernet;
} app_config_legacy_a_t;     /* schema 1..3 */

typedef struct {
    char wifi_ssid[33];
    char wifi_password[64];
    char user_id[37];
    bool only_use_ethernet;
} app_config_legacy_b_t;     /* schema 4 */

typedef struct {
    char wifi_ssid[33];
    char wifi_password[64];
    char user_id[37];
    bool only_use_ethernet;
    char device_name[32];
} app_config_legacy_c_t;     /* schema 5 */

typedef struct {
    char wifi_ssid[33];
    char wifi_password[64];
    char user_id[37];
    bool only_use_ethernet;
    char device_name[32];
    uint32_t safety_timeout_s;
} app_config_legacy_d_t;     /* schema 6 */

_Static_assert(sizeof(app_nvm_record_header_t) == 12, "Unexpected NVM record header layout");
_Static_assert(sizeof(app_config_t) <= UINT16_MAX, "NVM config payload exceeds record format");
_Static_assert(sizeof(app_nvm_record_header_t) + sizeof(app_config_t) <= APP_NVM_MAX_RECORD_SIZE,
               "NVM config exceeds supported record size");
_Static_assert(sizeof(app_nvm_record_header_t) + sizeof(device_cfg_t) <= APP_NVM_MAX_RECORD_SIZE,
               "NVM device config exceeds supported record size");

static SemaphoreHandle_t s_nvm_mutex;
static bool s_initialized;

static uint32_t calculate_crc32(const uint8_t *data, size_t size)
{
    uint32_t crc = 0xFFFFFFFFU;

    for (size_t index = 0; index < size; index++) {
        crc ^= data[index];
        for (unsigned bit = 0; bit < 8; bit++) {
            uint32_t mask = (uint32_t)-(int32_t)(crc & 1U);
            crc = (crc >> 1) ^ (0xEDB88320U & mask);
        }
    }

    return ~crc;
}

static bool is_terminated(const char *value, size_t capacity)
{
    return memchr(value, '\0', capacity) != NULL;
}

static bool lock_nvm(void)
{
    return s_initialized && s_nvm_mutex != NULL &&
           xSemaphoreTake(s_nvm_mutex, portMAX_DELAY) == pdTRUE;
}

/* ---- Generic versioned record ------------------------------------------------------------- */

/* Reads one record. On success *record is a malloc'd buffer the caller frees; *payload points
 * into it. */
static esp_err_t read_record(const char *key, uint8_t **record, const uint8_t **payload,
                             uint16_t *schema, size_t *payload_size)
{
    if (!lock_nvm()) {
        return ESP_ERR_INVALID_STATE;
    }

    nvs_handle_t handle;
    esp_err_t result = nvs_open(APP_NVM_NAMESPACE, NVS_READONLY, &handle);
    if (result != ESP_OK) {
        xSemaphoreGive(s_nvm_mutex);
        return result;
    }

    size_t record_size = 0;
    result = nvs_get_blob(handle, key, NULL, &record_size);
    if (result != ESP_OK) {
        nvs_close(handle);
        xSemaphoreGive(s_nvm_mutex);
        return result;
    }
    if (record_size < sizeof(app_nvm_record_header_t) || record_size > APP_NVM_MAX_RECORD_SIZE) {
        nvs_close(handle);
        xSemaphoreGive(s_nvm_mutex);
        return ESP_ERR_INVALID_SIZE;
    }

    uint8_t *buffer = malloc(record_size);
    if (buffer == NULL) {
        nvs_close(handle);
        xSemaphoreGive(s_nvm_mutex);
        return ESP_ERR_NO_MEM;
    }

    result = nvs_get_blob(handle, key, buffer, &record_size);
    nvs_close(handle);
    xSemaphoreGive(s_nvm_mutex);
    if (result != ESP_OK) {
        free(buffer);
        return result;
    }

    app_nvm_record_header_t header;
    memcpy(&header, buffer, sizeof(header));
    const uint8_t *data = buffer + sizeof(header);
    if (header.magic != APP_NVM_RECORD_MAGIC ||
        header.payload_size != record_size - sizeof(header) ||
        calculate_crc32(data, header.payload_size) != header.crc32) {
        free(buffer);
        return ESP_ERR_INVALID_CRC;
    }

    *record = buffer;
    *payload = data;
    *schema = header.schema_version;
    *payload_size = header.payload_size;
    return ESP_OK;
}

static esp_err_t write_record(const char *key, uint16_t schema, const void *payload,
                              size_t payload_size)
{
    if (!lock_nvm()) {
        return ESP_ERR_INVALID_STATE;
    }

    const size_t record_size = sizeof(app_nvm_record_header_t) + payload_size;
    uint8_t *record = calloc(1, record_size);
    if (record == NULL) {
        xSemaphoreGive(s_nvm_mutex);
        return ESP_ERR_NO_MEM;
    }

    app_nvm_record_header_t header = {
        .magic = APP_NVM_RECORD_MAGIC,
        .schema_version = schema,
        .payload_size = (uint16_t)payload_size,
        .crc32 = calculate_crc32((const uint8_t *)payload, payload_size),
    };
    memcpy(record, &header, sizeof(header));
    memcpy(record + sizeof(header), payload, payload_size);

    nvs_handle_t handle;
    esp_err_t result = nvs_open(APP_NVM_NAMESPACE, NVS_READWRITE, &handle);
    if (result == ESP_OK) {
        result = nvs_set_blob(handle, key, record, record_size);
        if (result == ESP_OK) {
            result = nvs_commit(handle);
        }
        if (result == ESP_OK) {
            /* Read back and compare so the data is known to be in flash. */
            uint8_t *readback = calloc(1, record_size);
            size_t readback_size = record_size;
            if (readback == NULL) {
                result = ESP_ERR_NO_MEM;
            } else {
                result = nvs_get_blob(handle, key, readback, &readback_size);
                if (result == ESP_OK &&
                    (readback_size != record_size || memcmp(readback, record, record_size) != 0)) {
                    result = ESP_ERR_INVALID_CRC;
                }
                free(readback);
            }
        }
        nvs_close(handle);
    }

    free(record);
    xSemaphoreGive(s_nvm_mutex);

    /* NVM_FAIL only reflects real storage errors; one verified write clears it. */
    if (result == ESP_OK) {
        (void)__atomic_fetch_and(&g_sys.sys_error_mask, ~(uint32_t)SYS_ERR_NVM_FAIL,
                                 __ATOMIC_RELAXED);
    } else {
        ESP_LOGE(TAG, "Write of '%s' failed: %s", key, esp_err_to_name(result));
        (void)__atomic_fetch_or(&g_sys.sys_error_mask, (uint32_t)SYS_ERR_NVM_FAIL,
                                __ATOMIC_RELAXED);
    }
    return result;
}

/* ---- Provisioning / network config -------------------------------------------------------- */

/* The name a device has until the user renames it: the advertised BLE provisioning name
 * ("PROV_ESP32_" + the last 3 bytes of the Bluetooth MAC), so the app, the database and the
 * status snapshot all start with the same one. */
#define APP_NVM_DEFAULT_NAME_PREFIX "PROV_ESP32_"
#define APP_NVM_LEGACY_DEFAULT_NAME "Smart Farming Device"

static void set_default_device_name(app_config_t *config)
{
    uint8_t mac[6] = {0};
    if (esp_read_mac(mac, ESP_MAC_BT) != ESP_OK) {
        memset(mac, 0, sizeof(mac));
    }
    (void)snprintf(config->device_name, sizeof(config->device_name), "%s%02X%02X%02X",
                   APP_NVM_DEFAULT_NAME_PREFIX, mac[3], mac[4], mac[5]);
}

void app_nvm_set_default_config(app_config_t *config)
{
    if (config == NULL) {
        return;
    }

    memset(config, 0, sizeof(*config));
    config->safety_timeout_s = APP_NVM_DEFAULT_SAFETY_TIMEOUT_S;
    config->telemetry_interval_s = APP_NVM_DEFAULT_TELEMETRY_INTERVAL_S;
    set_default_device_name(config);
}

esp_err_t app_nvm_validate_config(const app_config_t *config)
{
    if (config == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!is_terminated(config->wifi_ssid, sizeof(config->wifi_ssid)) ||
        !is_terminated(config->wifi_password, sizeof(config->wifi_password)) ||
        !is_terminated(config->user_id, sizeof(config->user_id)) ||
        !is_terminated(config->device_name, sizeof(config->device_name))) {
        return ESP_ERR_INVALID_ARG;
    }
    if (config->telemetry_interval_s < 5U || config->telemetry_interval_s > 600U) {
        return ESP_ERR_INVALID_ARG;
    }

    return ESP_OK;
}

esp_err_t app_nvm_validate_provisioning(const app_config_t *config)
{
    esp_err_t result = app_nvm_validate_config(config);
    if (result != ESP_OK) {
        return result;
    }

    /* user_id becomes an MQTT topic level, so topic wildcards and separators are rejected. */
    size_t user_id_length = strlen(config->user_id);
    if (user_id_length == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    for (size_t index = 0; index < user_id_length; index++) {
        char character = config->user_id[index];
        if (character < 0x21 || character > 0x7E || character == '/' ||
            character == '+' || character == '#') {
            return ESP_ERR_INVALID_ARG;
        }
    }

    if (!config->only_use_ethernet) {
        size_t password_length = strlen(config->wifi_password);
        if (config->wifi_ssid[0] == '\0' ||
            (password_length != 0 && password_length < 8)) {
            return ESP_ERR_INVALID_ARG;
        }
    }

    return ESP_OK;
}

esp_err_t app_nvm_init(void)
{
    if (s_initialized) {
        return ESP_OK;
    }

    if (s_nvm_mutex == NULL) {
        s_nvm_mutex = xSemaphoreCreateMutex();
        if (s_nvm_mutex == NULL) {
            return ESP_ERR_NO_MEM;
        }
    }

    esp_err_t result = nvs_flash_init();
    if (result == ESP_ERR_NVS_NO_FREE_PAGES || result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS requires recovery; erasing the default NVS partition");
        result = nvs_flash_erase();
        if (result == ESP_OK) {
            result = nvs_flash_init();
        }
    }

    if (result == ESP_OK) {
        s_initialized = true;
    } else {
        ESP_LOGE(TAG, "NVS initialization failed: %s", esp_err_to_name(result));
    }

    return result;
}

esp_err_t app_nvm_save_config(const app_config_t *config)
{
    esp_err_t result = app_nvm_validate_config(config);
    if (result != ESP_OK) {
        return result;
    }
    return write_record(APP_NVM_CONFIG_KEY, APP_NVM_SCHEMA_VERSION, config, sizeof(*config));
}

esp_err_t app_nvm_load_config(app_config_t *config)
{
    if (config == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    app_nvm_set_default_config(config);

    uint8_t *record = NULL;
    const uint8_t *payload = NULL;
    uint16_t schema = 0;
    size_t size = 0;
    esp_err_t result = read_record(APP_NVM_CONFIG_KEY, &record, &payload, &schema, &size);
    if (result != ESP_OK) {
        return result;
    }

    bool migrated = false;
    if (schema == APP_NVM_SCHEMA_VERSION) {
        if (size != sizeof(app_config_t)) {
            free(record);
            return ESP_ERR_INVALID_SIZE;
        }
        memcpy(config, payload, sizeof(*config));
    } else if (schema >= 1U && schema <= 3U && size >= sizeof(app_config_legacy_a_t)) {
        app_config_legacy_a_t legacy;
        memcpy(&legacy, payload, sizeof(legacy));
        memcpy(config->wifi_ssid, legacy.wifi_ssid, sizeof(legacy.wifi_ssid));
        memcpy(config->wifi_password, legacy.wifi_password, sizeof(legacy.wifi_password));
        memcpy(config->user_id, legacy.user_id, sizeof(legacy.user_id));
        config->only_use_ethernet = legacy.only_use_ethernet;
        migrated = true;
    } else if ((schema == 4U && size >= sizeof(app_config_legacy_b_t)) ||
               (schema == 5U && size >= sizeof(app_config_legacy_c_t))) {
        app_config_legacy_c_t legacy = {0};
        memcpy(&legacy, payload, schema == 4U ? sizeof(app_config_legacy_b_t)
                                              : sizeof(app_config_legacy_c_t));
        memcpy(config->wifi_ssid, legacy.wifi_ssid, sizeof(legacy.wifi_ssid));
        memcpy(config->wifi_password, legacy.wifi_password, sizeof(legacy.wifi_password));
        memcpy(config->user_id, legacy.user_id, sizeof(legacy.user_id));
        config->only_use_ethernet = legacy.only_use_ethernet;
        if (schema == 5U && legacy.device_name[0] != '\0') {
            memcpy(config->device_name, legacy.device_name, sizeof(legacy.device_name));
        }
        migrated = true;
    } else if (schema == 6U && size >= sizeof(app_config_legacy_d_t)) {
        app_config_legacy_d_t legacy;
        memcpy(&legacy, payload, sizeof(legacy));
        memcpy(config->wifi_ssid, legacy.wifi_ssid, sizeof(legacy.wifi_ssid));
        memcpy(config->wifi_password, legacy.wifi_password, sizeof(legacy.wifi_password));
        memcpy(config->user_id, legacy.user_id, sizeof(legacy.user_id));
        config->only_use_ethernet = legacy.only_use_ethernet;
        memcpy(config->device_name, legacy.device_name, sizeof(legacy.device_name));
        config->safety_timeout_s = legacy.safety_timeout_s;
        migrated = true;
    } else {
        free(record);
        return ESP_ERR_NOT_SUPPORTED;
    }
    free(record);

    /* A device still carrying the old fixed default name gets the MAC-based one. */
    if (strcmp(config->device_name, APP_NVM_LEGACY_DEFAULT_NAME) == 0) {
        set_default_device_name(config);
    }

    result = app_nvm_validate_config(config);
    if (result != ESP_OK) {
        app_nvm_set_default_config(config);
        return result;
    }
    if (migrated) {
        ESP_LOGI(TAG, "Config schema %u migrated to %u (sensors and loads live in devcfg now)",
                 (unsigned)schema, (unsigned)APP_NVM_SCHEMA_VERSION);
        esp_err_t save = app_nvm_save_config(config);
        if (save != ESP_OK) {
            ESP_LOGW(TAG, "Config schema migration save failed: %s", esp_err_to_name(save));
        }
    }
    return ESP_OK;
}

/* ---- Sensor + load config ------------------------------------------------------------------ */

void app_nvm_set_default_device_cfg(device_cfg_t *cfg)
{
    if (cfg == NULL) {
        return;
    }

    memset(cfg, 0, sizeof(*cfg));
    for (size_t index = 0; index < APP_SENSOR_INTERFACE_COUNT; index++) {
        cfg->sensor[index].slave_id = app_port_interface((uint8_t)index) == SENSOR_INTERFACE_RS485
                                          ? (uint8_t)(index + 1U) : 0U;
    }
    for (size_t index = 0; index < APP_LOAD_COUNT; index++) {
        (void)snprintf(cfg->load[index].name, sizeof(cfg->load[index].name), "Load %u",
                       (unsigned)(index + 1U));
        cfg->load[index].enabled = true;
        for (size_t c = 0; c < APP_CONDITIONS_PER_LOAD; c++) {
            cfg->load[index].condition[c].sensor_port = APP_PORT_NONE;
        }
    }
}

esp_err_t app_nvm_validate_device_cfg(const device_cfg_t *cfg)
{
    if (cfg == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    for (size_t index = 0; index < APP_SENSOR_INTERFACE_COUNT; index++) {
        const sensor_port_cfg_t *sensor = &cfg->sensor[index];
        if (!is_terminated(sensor->name, sizeof(sensor->name))) {
            return ESP_ERR_INVALID_ARG;
        }
        if (!sensor->configured) {
            continue;
        }
        if (app_port_interface((uint8_t)index) == SENSOR_INTERFACE_RS485) {
            if (sensor->slave_id == 0U || sensor->slave_id > 247U) {
                return ESP_ERR_INVALID_ARG;
            }
            for (size_t other = 0; other < index; other++) {
                if (cfg->sensor[other].configured && cfg->sensor[other].enabled &&
                    sensor->enabled && app_port_interface((uint8_t)other) == SENSOR_INTERFACE_RS485 &&
                    cfg->sensor[other].slave_id == sensor->slave_id) {
                    return ESP_ERR_INVALID_STATE;
                }
            }
        }
    }

    for (size_t index = 0; index < APP_LOAD_COUNT; index++) {
        const load_cfg_t *load = &cfg->load[index];
        if (!is_terminated(load->name, sizeof(load->name))) {
            return ESP_ERR_INVALID_ARG;
        }
        for (size_t c = 0; c < APP_CONDITIONS_PER_LOAD; c++) {
            const load_condition_cfg_t *condition = &load->condition[c];
            if (!condition->present) {
                continue;
            }
            if ((condition->sensor_port >= APP_SENSOR_INTERFACE_COUNT &&
                 condition->sensor_port != APP_PORT_NONE) ||
                !isfinite(condition->threshold) ||
                (condition->enabled && condition->sensor_port == APP_PORT_NONE)) {
                return ESP_ERR_INVALID_ARG;
            }
            if (condition->sensor_port < APP_SENSOR_INTERFACE_COUNT &&
                condition->value_index >= app_sensor_value_count(
                    app_port_sensor_type(condition->sensor_port))) {
                return ESP_ERR_INVALID_ARG;
            }
        }
        for (size_t s = 0; s < APP_SCHEDULERS_PER_LOAD; s++) {
            const load_scheduler_cfg_t *scheduler = &load->scheduler[s];
            if (!scheduler->present) {
                continue;
            }
            if ((scheduler->days_mask & 0x80U) != 0U || scheduler->on_minute_utc >= 1440U ||
                scheduler->off_minute_utc >= 1440U ||
                (scheduler->enabled && scheduler->days_mask == 0U)) {
                return ESP_ERR_INVALID_ARG;
            }
        }
    }

    return ESP_OK;
}

esp_err_t app_nvm_save_device_cfg(const device_cfg_t *cfg)
{
    esp_err_t result = app_nvm_validate_device_cfg(cfg);
    if (result != ESP_OK) {
        return result;
    }
    return write_record(APP_NVM_DEVCFG_KEY, APP_NVM_DEVCFG_SCHEMA_VERSION, cfg, sizeof(*cfg));
}

esp_err_t app_nvm_load_device_cfg(device_cfg_t *cfg)
{
    if (cfg == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    app_nvm_set_default_device_cfg(cfg);

    uint8_t *record = NULL;
    const uint8_t *payload = NULL;
    uint16_t schema = 0;
    size_t size = 0;
    esp_err_t result = read_record(APP_NVM_DEVCFG_KEY, &record, &payload, &schema, &size);
    if (result != ESP_OK) {
        return result;
    }
    if (schema == 1U && size == sizeof(legacy_device_cfg_t)) {
        legacy_device_cfg_t legacy;
        memcpy(&legacy, payload, sizeof(legacy));
        for (size_t i = 0; i < APP_SENSOR_INTERFACE_COUNT; i++) {
            cfg->sensor[i].configured = legacy.sensor[i].configured;
            cfg->sensor[i].enabled = legacy.sensor[i].enabled;
            cfg->sensor[i].slave_id = legacy.sensor[i].slave_id;
            memcpy(cfg->sensor[i].name, legacy.sensor[i].name,
                   sizeof(cfg->sensor[i].name));
        }
        for (size_t i = 0; i < APP_LOAD_COUNT; i++) {
            memcpy(cfg->load[i].name, legacy.load[i].name, sizeof(cfg->load[i].name));
            cfg->load[i].enabled = legacy.load[i].enabled;
            for (size_t c = 0; c < APP_CONDITIONS_PER_LOAD; c++) {
                const legacy_load_condition_cfg_t *old = &legacy.load[i].condition[c];
                load_condition_cfg_t *condition = &cfg->load[i].condition[c];
                condition->present = old->present;
                condition->enabled = old->enabled;
                condition->action = old->action;
                condition->op_gt = old->op_gt;
                condition->sensor_port = old->sensor_port;
                condition->value_index = 0U;
                condition->threshold = old->threshold;
            }
            for (size_t s = 0; s < APP_SCHEDULERS_PER_LOAD; s++) {
                const legacy_load_scheduler_cfg_t *old = &legacy.load[i].scheduler[s];
                load_scheduler_cfg_t *scheduler = &cfg->load[i].scheduler[s];
                scheduler->present = old->present;
                scheduler->enabled = old->enabled;
                scheduler->days_mask = old->days_mask;
                scheduler->on_minute_utc = old->on_minute_utc;
                scheduler->off_minute_utc = old->off_minute_utc;
            }
        }
        free(record);
        result = app_nvm_validate_device_cfg(cfg);
        if (result == ESP_OK) {
            result = app_nvm_save_device_cfg(cfg);
        }
        if (result == ESP_OK) {
            ESP_LOGI(TAG, "Device config schema 1 migrated to %u",
                     (unsigned)APP_NVM_DEVCFG_SCHEMA_VERSION);
        } else {
            app_nvm_set_default_device_cfg(cfg);
        }
        return result;
    }
    if (schema == 2U && size == sizeof(legacy_device_cfg_v2_t)) {
        legacy_device_cfg_v2_t legacy;
        memcpy(&legacy, payload, sizeof(legacy));
        for (size_t i = 0; i < APP_SENSOR_INTERFACE_COUNT; i++) {
            cfg->sensor[i].configured = legacy.sensor[i].configured;
            cfg->sensor[i].enabled = legacy.sensor[i].enabled;
            cfg->sensor[i].slave_id = legacy.sensor[i].slave_id;
            memcpy(cfg->sensor[i].name, legacy.sensor[i].name,
                   sizeof(cfg->sensor[i].name));
        }
        memcpy(cfg->load, legacy.load, sizeof(cfg->load));
        free(record);
        result = app_nvm_validate_device_cfg(cfg);
        if (result == ESP_OK) result = app_nvm_save_device_cfg(cfg);
        if (result == ESP_OK) {
            ESP_LOGI(TAG, "Device config schema 2 migrated to %u (legacy sensor fields discarded)",
                     (unsigned)APP_NVM_DEVCFG_SCHEMA_VERSION);
        } else {
            app_nvm_set_default_device_cfg(cfg);
        }
        return result;
    }
    if (schema != APP_NVM_DEVCFG_SCHEMA_VERSION || size != sizeof(device_cfg_t)) {
        free(record);
        return schema != APP_NVM_DEVCFG_SCHEMA_VERSION ? ESP_ERR_NOT_SUPPORTED
                                                       : ESP_ERR_INVALID_SIZE;
    }
    memcpy(cfg, payload, sizeof(*cfg));
    free(record);

    result = app_nvm_validate_device_cfg(cfg);
    if (result != ESP_OK) {
        app_nvm_set_default_device_cfg(cfg);
    }
    return result;
}

esp_err_t app_nvm_factory_reset(void)
{
    if (!lock_nvm()) {
        return ESP_ERR_INVALID_STATE;
    }

    s_initialized = false;
    esp_err_t result = nvs_flash_erase();
    if (result == ESP_OK) {
        result = nvs_flash_init();
    }
    s_initialized = result == ESP_OK;
    xSemaphoreGive(s_nvm_mutex);

    if (result == ESP_OK) {
        app_config_t config;
        app_nvm_set_default_config(&config);
        result = app_nvm_save_config(&config);
    }

    if (result != ESP_OK) {
        ESP_LOGE(TAG, "Factory reset failed: %s", esp_err_to_name(result));
    }
    return result;
}
