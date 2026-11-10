#ifndef APP_CELLULAR_H
#define APP_CELLULAR_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_netif.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    APP_CELLULAR_STATE_UNINITIALIZED = 0,
    APP_CELLULAR_STATE_STOPPED,
    APP_CELLULAR_STATE_CONNECTING,
    APP_CELLULAR_STATE_CONNECTED,
    APP_CELLULAR_STATE_ERROR,
} app_cellular_state_t;

/* Creates the PPP modem stack on first call and starts PPP asynchronously. */
esp_err_t app_cellular_start(void);

/* Stops PPP; the modem/netif objects remain allocated for a later start. */
esp_err_t app_cellular_stop(void);

/* True after PPP obtains an IPv4 address. */
bool app_cellular_is_connected(void);

/* Returns the PPP netif after initialization, otherwise NULL. */
esp_netif_t *app_cellular_get_netif_handle(void);

/* Pulse active-low RESET_N and restart PPP. Synchronous, bounded to the reset pulse
 * plus esp_modem's bounded mode transition; returns an error on failure. */
esp_err_t app_cellular_reset(void);

app_cellular_state_t app_cellular_get_state(void);
uint32_t app_cellular_get_recovery_count(void);
esp_err_t app_cellular_get_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
