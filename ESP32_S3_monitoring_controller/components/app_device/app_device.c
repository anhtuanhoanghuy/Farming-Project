#include "app_device.h"

#include <string.h>

#include "app_log.h"
#include "app_nvm.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"

static const char *TAG = "app_device";

static const char *const k_port_names[APP_SENSOR_INTERFACE_COUNT] = {
    "RS1", "RS2", "RS3", "RS4", "AN1", "DI1", "DI2", "DI3", "DI4",
};
static const char *const k_load_names[APP_LOAD_COUNT] = {"DO1", "DO2", "DO3", "DO4"};

static SemaphoreHandle_t s_lock;
static device_cfg_t s_cfg;
static uint32_t s_generation;

esp_err_t app_device_init(void)
{
    if (s_lock == NULL) {
        s_lock = xSemaphoreCreateMutex();
        if (s_lock == NULL) {
            return ESP_ERR_NO_MEM;
        }
    }

    device_cfg_t loaded;
    esp_err_t result = app_nvm_load_device_cfg(&loaded);
    if (result == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "No stored sensor/load config; using defaults");
    } else if (result != ESP_OK) {
        ESP_LOGW(TAG, "Stored sensor/load config unusable (%s); using defaults",
                 esp_err_to_name(result));
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_cfg = loaded;
    s_generation++;
    xSemaphoreGive(s_lock);

    unsigned sensors = 0;
    for (size_t i = 0; i < APP_SENSOR_INTERFACE_COUNT; i++) {
        if (loaded.sensor[i].configured) sensors++;
    }
    ESP_LOGI(TAG, "Config ready: %u sensor(s) configured, %u load(s)", sensors,
             (unsigned)APP_LOAD_COUNT);
    return ESP_OK;
}

void app_device_get(device_cfg_t *out)
{
    if (out == NULL) {
        return;
    }
    if (s_lock == NULL) {
        app_nvm_set_default_device_cfg(out);
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *out = s_cfg;
    xSemaphoreGive(s_lock);
}

esp_err_t app_device_commit(const device_cfg_t *cfg)
{
    if (cfg == NULL || s_lock == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    esp_err_t result = app_nvm_save_device_cfg(cfg);
    if (result != ESP_OK) {
        return result;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_cfg = *cfg;
    s_generation++;
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

uint32_t app_device_generation(void)
{
    return __atomic_load_n(&s_generation, __ATOMIC_RELAXED);
}

const char *app_device_port_name(uint8_t port)
{
    return port < APP_SENSOR_INTERFACE_COUNT ? k_port_names[port] : NULL;
}

uint8_t app_device_port_from_name(const char *name)
{
    if (name == NULL) {
        return APP_PORT_NONE;
    }
    for (uint8_t i = 0; i < APP_SENSOR_INTERFACE_COUNT; i++) {
        if (strcmp(name, k_port_names[i]) == 0) {
            return i;
        }
    }
    return APP_PORT_NONE;
}

const char *app_device_load_name(uint8_t load_index)
{
    return load_index < APP_LOAD_COUNT ? k_load_names[load_index] : NULL;
}

uint8_t app_device_load_from_name(const char *name)
{
    if (name == NULL) {
        return APP_PORT_NONE;
    }
    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        if (strcmp(name, k_load_names[i]) == 0) {
            return i;
        }
    }
    return APP_PORT_NONE;
}
