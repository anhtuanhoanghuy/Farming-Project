#ifndef APP_CONTROL_H
#define APP_CONTROL_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Load engine: owns the four relay outputs and decides every state change.
 *
 * Priority, highest first (see mqtt_protocol.md 6.4):
 *   emergency stop > load disabled > manual set_state / ONx_ / OFFx_ button > delay >
 *   sensor condition > schedule.
 * All index arguments are 0-based load indexes (DO1 = 0) except app_control_get_load_runtime().
 * Commands that change configuration persist it through app_device before they return.
 */

typedef enum {
    CTL_OK = 0,
    CTL_ERR_ARG,
    CTL_ERR_DISABLED,   /* the load is disabled */
    CTL_ERR_NOT_FOUND,  /* condition / scheduler / sensor does not exist */
    CTL_ERR_EXISTS,     /* condition / scheduler / sensor already exists */
    CTL_ERR_LIMIT,
    CTL_ERR_STORAGE,
    CTL_ERR_INTERLOCK,  /* safety interlock keeps loads off */
    CTL_ERR_FEEDBACK,   /* feedback input did not confirm the requested state */
    CTL_ERR_INTERNAL
} ctl_result_t;

/* Short human readable reason for the ACK. */
const char *app_control_result_reason(ctl_result_t result);

/* Configures every relay LOW, loads the config through app_device, then starts the engine task.
 * Needs app_device_init() first. */
esp_err_t app_control_init(void);

/* Latest samples for the sensor conditions (one per port, see sensor_cycle_t). Never blocks. */
esp_err_t app_control_sensor_update(const sensor_cycle_t *cycle);

/* SET_LOAD_STATE: switches now and disables the load's conditions and schedulers. */
ctl_result_t app_control_set_state(uint8_t load_index, bool on);
/* Executes a configured enabled ONx_/OFFx_ momentary-button input for this DI. */
ctl_result_t app_control_process_button_di(uint8_t di_index);
/* SET_LOAD_STATE with optional DI feedback verification; timeout is in milliseconds. */
ctl_result_t app_control_set_state_verified(uint8_t load_index, bool on, uint32_t timeout_ms);
/* Reads a configured DOx_* feedback DI. Returns ESP_ERR_NOT_FOUND if none is configured. */
esp_err_t app_control_get_feedback(uint8_t load_index, bool *state);
/* Emits LOAD_CHANGED when a mapped feedback DI changes in a sensor cycle. */
void app_control_process_feedback(const sensor_cycle_t *cycle);

/* SET_LOAD_DELAY: mode false = wait then ON for duration then OFF, true = the opposite;
 * duration 0 keeps the state reached after the delay. Replaces a running delay. */
ctl_result_t app_control_set_delay(uint8_t load_index, bool mode, uint16_t delay_min,
                                   uint16_t duration_min);

/* STOP_LOAD_DELAY: stops the timer and keeps the current output. */
ctl_result_t app_control_stop_delay(uint8_t load_index);

/* TOGGLE_LOAD_CAPABILITY: disabling switches the load off, stops its delay and deletes its
 * conditions and schedulers; enabling leaves the load off. */
ctl_result_t app_control_set_enabled(uint8_t load_index, bool enabled);

/* EMERGENCY_STOP: every load off with its delay, conditions and schedulers deleted (the loads
 * stay enabled), every sensor disabled. */
ctl_result_t app_control_emergency_stop(uint8_t *loads_off);
bool app_control_is_estop(void);
/* A load or a sensor was enabled again: the emergency flag no longer applies. */
void app_control_estop_ack_reenable(void);

/* Switches every load off without touching the configuration (factory reset, interlock). */
esp_err_t app_control_force_all_off(const char *source);

bool app_control_is_interlock_tripped(void);
void app_control_interlock_trip(uint32_t after_s);
void app_control_interlock_clear(void);

/* load_id is 1-based here (kept for app_sysmon). */
esp_err_t app_control_get_load_runtime(uint8_t load_id, load_runtime_t *runtime);

#ifdef __cplusplus
}
#endif

#endif
