#ifndef APP_NVM_H
#define APP_NVM_H

#include "esp_err.h"
#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Schema of the provisioning / network blob ("config"). Older versions are migrated on load. */
#define APP_NVM_SCHEMA_VERSION 7U
/* Schema of the sensor + load blob ("devcfg"). */
#define APP_NVM_DEVCFG_SCHEMA_VERSION 3U
/* Provisional until the system safety policy is finalized. */
#define APP_NVM_DEFAULT_SAFETY_TIMEOUT_S 300U
#define APP_NVM_DEFAULT_TELEMETRY_INTERVAL_S 5U

typedef struct {
    uint32_t boot_count;
    uint32_t reset_reason;
    uint32_t error_mask;
    uint32_t mqtt_state;
    uint32_t network_state;
    uint32_t interlock;
    uint32_t emergency;
    uint32_t free_heap;
    uint32_t min_free_heap;
    uint32_t uptime_ms;
} app_diagnostic_record_t;

esp_err_t app_nvm_init(void);
void app_nvm_set_default_config(app_config_t *config);
esp_err_t app_nvm_validate_config(const app_config_t *config);
/* Checks that the config is usable for connecting: user_id plus Wi-Fi credentials unless Ethernet-only. */
esp_err_t app_nvm_validate_provisioning(const app_config_t *config);
/* Fills defaults first; returns ESP_ERR_NVS_NOT_FOUND for an empty namespace. */
esp_err_t app_nvm_load_config(app_config_t *config);
/* Saves one versioned blob; callers must pass a fully initialized config. */
esp_err_t app_nvm_save_config(const app_config_t *config);

/* No sensors configured, four enabled loads named "Load n" without conditions or schedules. */
void app_nvm_set_default_device_cfg(device_cfg_t *cfg);
esp_err_t app_nvm_validate_device_cfg(const device_cfg_t *cfg);
/* Fills defaults first; returns ESP_ERR_NVS_NOT_FOUND when nothing was stored yet. */
esp_err_t app_nvm_load_device_cfg(device_cfg_t *cfg);
esp_err_t app_nvm_save_device_cfg(const device_cfg_t *cfg);
esp_err_t app_nvm_load_diagnostics(app_diagnostic_record_t *record);
esp_err_t app_nvm_save_diagnostics(const app_diagnostic_record_t *record);

/* Erases the whole NVS partition, re-initialises it, and stores the default app config. */
esp_err_t app_nvm_factory_reset(void);

#ifdef __cplusplus
}
#endif

#endif
