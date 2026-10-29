#ifndef APP_TELEMETRY_BUFFER_H
#define APP_TELEMETRY_BUFFER_H

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "main_data_types.h"
#include "sdkconfig.h"

#ifdef __cplusplus
extern "C" {
#endif

#define APP_TELEMETRY_SLOTS         CONFIG_APP_MQTT_TELEMETRY_SLOTS
#define APP_TELEMETRY_SLOT_SIZE     256U
#define APP_TELEMETRY_PAYLOAD_SIZE  240U

/* Fixed 256-byte slot (spec 6.1); the payload carries a raw sensor_data_t. */
typedef struct {
    int64_t ts_ms;      /* 0 while the clock is not synchronised */
    uint32_t seq;       /* increments per telemetry sample, independent of sensor cycle seq */
    uint32_t uptime_ms;
    uint8_t payload[APP_TELEMETRY_PAYLOAD_SIZE];
} telemetry_slot_t;

_Static_assert(sizeof(telemetry_slot_t) == APP_TELEMETRY_SLOT_SIZE, "telemetry slot must be 256 bytes");
_Static_assert(sizeof(sensor_cycle_t) <= sizeof(((telemetry_slot_t *)0)->payload),
               "sensor_cycle_t exceeds the slot payload");

/* Creates the mutex; safe to call repeatedly. All other calls initialise lazily as well. */
esp_err_t app_telemetry_buffer_init(void);

/*
 * Builds a slot from a sample: assigns the next telemetry seq and uptime, and a Unix timestamp
 * only while BIT_TIME_VALID is set. Preserves the sensor cycle seq in the payload. Does not store it.
 */
esp_err_t app_telemetry_buffer_stamp(const sensor_cycle_t *data, telemetry_slot_t *out);

/* Stamps and stores a sample; when full, the oldest slot is dropped (FIFO drop-oldest). */
esp_err_t app_telemetry_buffer_push(const sensor_cycle_t *data);

/* Stores an already stamped slot, e.g. a live sample that could not be published. */
esp_err_t app_telemetry_buffer_push_slot(const telemetry_slot_t *slot);

/* Copies the oldest slot without removing it. ESP_ERR_NOT_FOUND when empty. */
esp_err_t app_telemetry_buffer_peek(telemetry_slot_t *out);

/* Removes the oldest slot once it has been handed to the MQTT client. */
esp_err_t app_telemetry_buffer_pop(void);

size_t app_telemetry_buffer_count(void);

/* Slots discarded because the buffer was full. */
uint32_t app_telemetry_buffer_dropped(void);

#ifdef __cplusplus
}
#endif

#endif
