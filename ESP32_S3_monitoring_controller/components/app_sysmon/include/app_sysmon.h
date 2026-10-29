#ifndef APP_SYSMON_H
#define APP_SYSMON_H

#include "esp_err.h"
#include "main_data_types.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Button thresholds from requirement_user_reset_button.md. */
#ifndef APP_SYSMON_BUTTON_DEBOUNCE_MS
#define APP_SYSMON_BUTTON_DEBOUNCE_MS 50U
#endif
#ifndef APP_SYSMON_BUTTON_PROV_HOLD_MS
#define APP_SYSMON_BUTTON_PROV_HOLD_MS 5000U
#endif
/* Second hold, started within APP_SYSMON_BUTTON_REARM_WINDOW_MS of the first, runs the factory reset. */
#ifndef APP_SYSMON_BUTTON_RESET_HOLD_MS
#define APP_SYSMON_BUTTON_RESET_HOLD_MS 5000U
#endif
#ifndef APP_SYSMON_BUTTON_REARM_WINDOW_MS
#define APP_SYSMON_BUTTON_REARM_WINDOW_MS 2000U
#endif
/* A click is a press shorter than CLICK_MAX_MS; two clicks within DOUBLE_CLICK_GAP_MS toggle logging. */
#ifndef APP_SYSMON_BUTTON_CLICK_MAX_MS
#define APP_SYSMON_BUTTON_CLICK_MAX_MS 800U
#endif
#ifndef APP_SYSMON_BUTTON_DOUBLE_CLICK_GAP_MS
#define APP_SYSMON_BUTTON_DOUBLE_CLICK_GAP_MS 500U
#endif

typedef enum {
    APP_LED_OFF = 0,
    APP_LED_ON,
    APP_LED_BLINK_1HZ,
    APP_LED_BLINK_05HZ,
    APP_LED_BLINK_2HZ,
    APP_LED_BLINK_4HZ,
    APP_LED_BLINK_10HZ
} app_led_mode_t;

/*
 * Starts sysmon_task (core 1, priority 2, registered with the task watchdog) and the status LED
 * timer. The task watches the user button on APP_PIN_BUTTON_RESET (active low, 50 ms debounce),
 * refreshes network/error LED states and reports low heap:
 *   hold 5 s or more, release   Wi-Fi and Ethernet LEDs blink at 2 Hz from 5 s;
 *                               if no second press starts within 2 s of the
 *                               release (or the second press is shorter than 5 s), posts
 *                               NET_CMD_START_BLE_PROV_RUNTIME (provisioning only)
 *   ...then press again, hold 5 s   loads forced off, NET_CMD_FACTORY_RESET posted, NVS erased,
 *                               all three status LEDs show the reset pattern until restart
 *                               (full reset)
 *   two short clicks            toggle application logging (PRINT_LOG, see app_log.h)
 *   any other press length      ignored
 * A button already held at power-up is ignored until it has been released once. Needs app_nvm.
 * Outside startup, provisioning and reset effects, only the active interface's network LED is on.
 */
esp_err_t app_sysmon_init(void);
esp_err_t app_sysmon_wdt_init(void);

/* Steady LED_ERROR pattern (error indication). */
void app_sysmon_led_error_set(app_led_mode_t mode);

void app_sysmon_set_provisioning_indicator(bool active);
/* Overrides normal indication to turn on all status LEDs. */
void app_sysmon_led_all_on(bool active);
void app_sysmon_set_estop_indicator(bool active);
void app_sysmon_error_mask_update(uint32_t set_mask, uint32_t clear_mask);

#ifdef __cplusplus
}
#endif

#endif
