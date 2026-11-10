#ifndef APP_MQTT_H
#define APP_MQTT_H

#include <stdbool.h>

#include "app_telemetry_buffer.h"
#include "app_mqtt_proto.h"
#include "esp_err.h"
#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Prepares the esp-mqtt client and application worker. Copies a previously validated config; it
 * does not read or write NVM. Needs the network FSM and CONFIG_APP_MQTT_BROKER_URI. Does not connect.
 *
 * Topics (v1/{userId}/devices/{deviceId}/...): the device subscribes to `commands` only and
 * publishes `ack`, `status` (retained snapshot, LWT, events) and `telemetry`.
 */
esp_err_t app_mqtt_init(const app_config_t *config);

/*
 * Allows the client to run. It connects as soon as the network FSM reports an active interface
 * with WAN (immediately if that already happened) and again after every interface switch.
 */
esp_err_t app_mqtt_start(void);

/* Disconnects, cancels reconnect/flush timers and keeps the client down until app_mqtt_start(). */
esp_err_t app_mqtt_stop(uint32_t timeout_ms);

/* Best-effort retained offline presence, bounded by timeout_ms, then stop without reconnect. */
esp_err_t app_mqtt_shutdown_for_reset(uint32_t timeout_ms);

/*
 * Single entry point for sensor samples. Connected: stamps and queues the sample for immediate
 * transmission (QoS 0) and the buffered backlog follows at 100 ms per message. Not connected, or
 * outbox full: the sample goes to the telemetry ring buffer instead. Never blocks on the network.
 */
esp_err_t app_mqtt_publish_telemetry(const sensor_cycle_t *data);

bool app_mqtt_is_connected(void);

/* Thread-safe zero-wait submission of a status event (published while online). */
esp_err_t app_mqtt_event_submit(const mqtt_event_t *event);

/* The device name stored by SET_DEVICE_NAME; the next snapshot reports it. */
void app_mqtt_device_name_changed(const char *name);

/* Applies a persisted telemetry interval and restarts the periodic publish timer from now. */
void app_mqtt_telemetry_interval_changed(uint32_t interval_s);

/*
 * True once the safety timer expired after SYS_ERR_NET_LOST-equivalent loss of all networks and all
 * relay outputs were driven low. Loads are never switched back on by this module; the flag
 * (BIT_SYS_INTERLOCK_TRIPPED) is cleared when MQTT is back online.
 */
bool app_mqtt_safety_interlock_tripped(void);

typedef struct {
	uint32_t connect_attempts, connect_ok, disconnects;
	uint32_t rx_total, rx_rejected, rx_dropped, rx_retained_ignored, rx_oversize, rx_dup;
	uint32_t tx_telemetry, tx_ack, tx_status, tx_fail;
	uint32_t telemetry_buffered, telemetry_dropped, ack_dropped;
	uint32_t last_error;
	uint32_t backoff_ms;
	uint32_t online_since_s;
} app_mqtt_stats_t;

void app_mqtt_get_stats(app_mqtt_stats_t *out);
const char *app_mqtt_get_broker_host(void);
uint16_t app_mqtt_get_broker_port(void);

#ifdef __cplusplus
}
#endif

#endif
