#ifndef APP_NETWORK_FSM_H
#define APP_NETWORK_FSM_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Defaults from technical_requirements_network_failover_FINAL.md (3.2, 3.4, 4.1). */
#ifndef APP_NET_PROBE_TARGET_1
#define APP_NET_PROBE_TARGET_1 "1.1.1.1"
#endif
#ifndef APP_NET_PROBE_TARGET_2
#define APP_NET_PROBE_TARGET_2 "8.8.8.8"
#endif
#define APP_NET_PROBE_COUNT            3U
#define APP_NET_PROBE_TIMEOUT_MS       1000U
#define APP_NET_PROBE_INTERVAL_MS      1000U
#define APP_NET_PROBE_PERIOD_ACTIVE_MS 1000U
#define APP_NET_PROBE_PERIOD_STANDBY_MS 1000U
#define APP_NET_PROBE_PERIOD_RECOVERY_MS 1000U
#define APP_NET_FAILBACK_PERIOD_MS     1000U
#define APP_NET_FAILBACK_OK_COUNT      5U
#define APP_NET_CONNECT_TIMEOUT_MS     30000U
#define APP_NET_ETH_HEALTH_PERIOD_MS   1000U
#define APP_NET_ETH_INIT_RETRY_MS      5000U

#define APP_NET_TASK_STACK_BYTES 8192U
#define APP_NET_TASK_PRIORITY    6U
#define APP_NET_TASK_CORE        0

/* Returned by the Wi-Fi validation when the AP is up but no probe target answered. */
#define APP_NETWORK_ERR_WIFI_NO_WAN ESP_ERR_INVALID_RESPONSE

typedef enum {
    NET_FAULT_NONE = 0,
    NET_FAULT_BROKER_DOWN, /* active WAN OK but MQTT not connected; never causes a failover */
    NET_FAULT_WAN_DOWN,    /* active WAN lost, switching or verifying the standby */
    NET_FAULT_ALL_DOWN     /* no interface has WAN */
} net_fault_t;

typedef enum {
    WIFI_WAN_OK = 0,
    WIFI_WAN_WARN_NO_INTERNET, /* BLE error_code WARN_WIFI_NO_INTERNET */
    WIFI_WAN_ERR_NOT_CONNECTED /* BLE error_code ERR_WIFI_CONNECT_FAILED */
} app_wifi_wan_status_t;

typedef struct {
    app_wifi_wan_status_t status;
    uint32_t retry_attempts;          /* ping attempts per target (max APP_NET_PROBE_COUNT) */
    net_interface_t active_interface; /* interface that carries traffic during the check */
} app_wifi_wan_report_t;

/* Interface switch notifications, delivered on net_mgmt_task (never on an event-loop task). */
typedef enum {
    APP_NET_EVENT_SWITCH_BEGIN = 0, /* before the default netif changes: stop sockets */
    APP_NET_EVENT_SWITCH_DONE,      /* default netif and DNS updated: sockets may restart */
    APP_NET_EVENT_LOST,             /* no interface has WAN */
    APP_NET_EVENT_PROV_RUNTIME_REQUEST, /* user button: start BLE provisioning, keep running */
    APP_NET_EVENT_SHUTDOWN          /* factory reset in progress: stop everything */
} app_network_event_t;

typedef void (*app_network_event_cb_t)(app_network_event_t event, net_interface_t from,
                                       net_interface_t to, void *ctx);

/* Registers a listener for the events above (up to 4). Identical cb/ctx pairs are accepted once. */
esp_err_t app_network_register_event_cb(app_network_event_cb_t cb, void *ctx);

/*
 * Called by the owner of runtime provisioning once its BLE session has ended. Until then
 * app_network_get_state() reports STATE_BLE_PROV_RUNTIME and further requests are ignored.
 */
void app_network_prov_runtime_finished(void);

/*
 * Starts net_mgmt_task (core 0, priority 6, 8 KB). The task brings up the W5500 (retrying if it
 * is absent), tracks the Wi-Fi and Ethernet netifs, probes WAN on each, owns the default netif and
 * publishes BIT_NET_ACTIVE_READY / BIT_NET_STANDBY_READY / BIT_SYS_NET_LOST / BIT_NET_ETH_*.
 * Requires g_sys.sys_event_group. Wi-Fi is started separately (app_network_start()).
 * Idempotent after success.
 */
esp_err_t app_network_fsm_init(void);

/* Interface currently selected as default netif, NET_IF_NONE while none has WAN. */
net_interface_t app_network_get_active_interface(void);

/* True when the active interface has an IP and its last WAN probe succeeded. */
bool app_network_is_wan_connected(void);

/*
 * Isolated WAN check on the Wi-Fi netif for BLE provisioning (spec 5.3): 3 attempts, 1 s timeout
 * each, pinned to the Wi-Fi interface so the default netif and MQTT are untouched. Blocks the
 * caller for up to ~4 s. Needs only the Wi-Fi engine, not the FSM task.
 * Returns ESP_OK (WAN OK), APP_NETWORK_ERR_WIFI_NO_WAN, ESP_ERR_INVALID_STATE (Wi-Fi has no IP),
 * or ESP_ERR_NO_MEM / ESP_ERR_TIMEOUT on resource failure. out_retries may be NULL.
 */
esp_err_t app_network_validate_wifi_wan(uint32_t *out_retries);

/* Same check with the full result needed to build the BLE response. */
esp_err_t app_network_validate_wifi_wan_report(app_wifi_wan_report_t *report);

/* Network view of the system state: NET_CONNECTING, MQTT_CONNECTING/OPERATIONAL, FAILOVER, NET_LOST. */
sys_state_t app_network_get_state(void);

net_fault_t app_network_get_fault(void);

/* Interface switches (failover and failback) since boot, for the failover_cnt diagnostic. */
uint32_t app_network_get_failover_count(void);

#ifdef __cplusplus
}
#endif

#endif
