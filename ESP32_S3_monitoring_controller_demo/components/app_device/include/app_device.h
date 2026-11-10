#ifndef APP_DEVICE_H
#define APP_DEVICE_H

#include <stdint.h>

#include "esp_err.h"
#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Single owner of the persistent sensor + load configuration (device_cfg_t). Readers take a value
 * copy; writers work on a copy and commit it, which validates, writes NVM and only then replaces
 * the RAM copy, so RAM never runs ahead of flash.
 */

/* Loads the stored config (defaults when nothing valid is stored). Requires app_nvm_init(). */
esp_err_t app_device_init(void);

void app_device_get(device_cfg_t *out);

/* Validates, persists and publishes cfg. The RAM copy is unchanged when this fails. */
esp_err_t app_device_commit(const device_cfg_t *cfg);

/* Increments on every successful commit; consumers re-read the config when it changes. */
uint32_t app_device_generation(void);

/* Stable protocol names even for stored disabled ports; from_name accepts supported ports only. */
const char *app_device_port_name(uint8_t port);
uint8_t app_device_port_from_name(const char *name);

/* Stable "DO1".."DO4"; from_name accepts supported loads only (APP_PORT_NONE otherwise). */
const char *app_device_load_name(uint8_t load_index);
uint8_t app_device_load_from_name(const char *name);

#ifdef __cplusplus
}
#endif

#endif
