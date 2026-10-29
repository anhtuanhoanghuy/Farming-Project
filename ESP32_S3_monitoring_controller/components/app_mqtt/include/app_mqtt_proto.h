#ifndef APP_MQTT_PROTO_H
#define APP_MQTT_PROTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MQTT_PROTO_CMD_ID_LEN 37U
#define MQTT_PROTO_REASON_LEN 49U
#define MQTT_PROTO_NAME_LEN 32U
#define MQTT_PROTO_DEDUPE_WINDOW 16U
#define MQTT_PROTO_COMMAND_MAX 640U
#define MQTT_PROTO_TELEMETRY_MAX 2560U
#define MQTT_PROTO_ACK_MAX 512U
#define MQTT_PROTO_EVENT_MAX 1024U
#define MQTT_PROTO_STATUS_MAX 7168U
#define MQTT_PROTO_TOPIC_MAX 80U

/* ACK `code` values. */
typedef enum {
    MQTT_PROTO_OK = 0,
    MQTT_PROTO_INVALID_JSON,
    MQTT_PROTO_INVALID_FIELDS,
    MQTT_PROTO_INVALID_VALUE,
    MQTT_PROTO_UNSUPPORTED_ACTION,
    MQTT_PROTO_UNSUPPORTED_VERSION,
    MQTT_PROTO_FORBIDDEN,
    MQTT_PROTO_CONFLICT,
    MQTT_PROTO_EXPIRED,
    MQTT_PROTO_BUSY,
    MQTT_PROTO_PAYLOAD_TOO_LARGE,
    MQTT_PROTO_SHUTTING_DOWN,
    MQTT_PROTO_STORAGE_ERROR,
    MQTT_PROTO_INTERNAL_ERROR
} mqtt_proto_code_t;

/* Every command of mqtt_protocol.md section 2. */
typedef enum {
    MQTT_CMD_SET_LOAD_STATE = 0,
    MQTT_CMD_SET_LOAD_DELAY,
    MQTT_CMD_SET_LOAD_NAME,
    MQTT_CMD_TOGGLE_LOAD_CAPABILITY,
    MQTT_CMD_SET_LOAD_CONDITION,
    MQTT_CMD_SET_LOAD_SCHEDULE,
    MQTT_CMD_DELETE_LOAD_CONDITION,
    MQTT_CMD_DELETE_LOAD_SCHEDULER,
    MQTT_CMD_ADD_LOAD_CONDITION,
    MQTT_CMD_ADD_LOAD_SCHEDULER,
    MQTT_CMD_TOGGLE_LOAD_CONDITION,
    MQTT_CMD_TOGGLE_LOAD_SCHEDULER,
    MQTT_CMD_STOP_LOAD_DELAY,
    MQTT_CMD_SENSOR_CONFIG,
    MQTT_CMD_DELETE_SENSOR,
    MQTT_CMD_TOGGLE_SENSOR_CAPABILITY,
    MQTT_CMD_SET_DEVICE_NAME,
    MQTT_CMD_GET_STATUS,
    MQTT_CMD_EMERGENCY_STOP,
    MQTT_CMD_SET_TELEMETRY_INTERVAL,
    MQTT_CMD_GET_TELEMETRY
} mqtt_cmd_type_t;

/* A validated command. Indexes are 0-based (DO1 = 0, CON1 = 0, SHE1 = 0, RS1 = port 0). */
typedef struct {
    char cmd_id[MQTT_PROTO_CMD_ID_LEN];
    mqtt_cmd_type_t type;
    uint8_t load;
    uint8_t index;              /* condition or scheduler */
    uint8_t port;               /* sensor port */
    bool action;                /* SET_LOAD_STATE, TOGGLE_*, SENSOR_CONFIG (true = add) */
    bool enabled;               /* condition_enabled / scheduler_enabled / sensor enabled */
    bool mode;                  /* SET_LOAD_DELAY: false = ON_THEN_OFF */
    uint16_t delay_min;
    uint16_t duration_min;
    uint16_t telemetry_interval_s;
    bool cond_action;           /* turn the load on when the condition holds */
    bool op_gt;
    uint8_t cond_port;
    uint8_t cond_value_index;
    float threshold;
    uint8_t days_mask;
    uint16_t on_minute_utc;
    uint16_t off_minute_utc;
    uint8_t slave_id;
    char name[MQTT_PROTO_NAME_LEN];
} mqtt_cmd_t;

typedef struct {
    char cmd_id[MQTT_PROTO_CMD_ID_LEN];
    bool has_cmd_id;
    const char *cmd_name;       /* NULL when the command could not be identified */
    bool success;
    mqtt_proto_code_t code;
    char reason[MQTT_PROTO_REASON_LEN];
    bool dup;
    bool has_ts;
    int64_t ts_ms;
} mqtt_proto_ack_t;

typedef struct {
    bool occupied;
    mqtt_proto_ack_t ack;
} mqtt_proto_dedupe_entry_t;

typedef struct {
    mqtt_proto_dedupe_entry_t entries[MQTT_PROTO_DEDUPE_WINDOW];
    uint8_t next;
} mqtt_proto_dedupe_t;

/* Everything the retained snapshot reports. */
typedef struct {
    const char *boot_id;
    const char *net_interface;
    char ssid[33];
    char ip_address[16];
    char device_name[MQTT_PROTO_NAME_LEN];
    bool has_ts;
    int64_t ts_ms;
    uint32_t uptime_ms;
    device_cfg_t cfg;
    load_runtime_t load[APP_LOAD_COUNT];
    sensor_sample_t sample[APP_SENSOR_INTERFACE_COUNT];
    bool interlock_tripped;
    bool emergency_active;
    uint32_t error_mask;
    uint32_t free_heap;
    uint32_t min_free_heap;
    uint32_t reconnects;
    uint32_t rx_rejected;
    uint32_t tx_fail;
    uint32_t telemetry_dropped;
    uint32_t telemetry_interval_s;
} mqtt_proto_snapshot_t;

typedef struct {
    uint32_t seq;
    uint32_t uptime_ms;
    bool has_ts;
    int64_t ts_ms;
    bool buffered;
    const char *boot_id;
    const char *net_interface;
    uint32_t error_mask;
    device_cfg_t cfg;           /* names, which ports are enabled */
    sensor_cycle_t cycle;
} mqtt_proto_telemetry_t;

typedef struct {
    char user_id[37];
    char device_id[13];
    char telemetry[MQTT_PROTO_TOPIC_MAX];
    char commands[MQTT_PROTO_TOPIC_MAX];
    char ack[MQTT_PROTO_TOPIC_MAX];
    char status[MQTT_PROTO_TOPIC_MAX];
} mqtt_proto_topics_t;

bool mqtt_proto_valid_user_id(const char *user_id);
bool mqtt_proto_valid_cmd_id(const char *cmd_id);
bool mqtt_proto_valid_name(const char *name);
bool mqtt_proto_build_topics(const char *user_id, const char *device_id, mqtt_proto_topics_t *out);
const char *mqtt_proto_code_name(mqtt_proto_code_t code);
const char *mqtt_proto_cmd_name(mqtt_cmd_type_t type);

/*
 * Parses and validates one command. On failure the code says why and reason names the field;
 * cmd_id is filled when it could be read so the rejection can still carry it.
 */
mqtt_proto_code_t mqtt_proto_parse_command(const char *json, size_t len, mqtt_cmd_t *out,
                                           char *reason, size_t reason_cap, const char **cmd_name);

int mqtt_proto_serialize_ack(const mqtt_proto_ack_t *ack, const char *boot_id, char *out, size_t cap);
int mqtt_proto_serialize_lwt(const char *boot_id, char *out, size_t cap);
int mqtt_proto_serialize_snapshot(const mqtt_proto_snapshot_t *snapshot, char *out, size_t cap);
int mqtt_proto_serialize_telemetry(const mqtt_proto_telemetry_t *sample, char *out, size_t cap);
int mqtt_proto_serialize_event(const mqtt_event_t *event, const char *boot_id, bool has_ts,
                               int64_t ts_ms, char *out, size_t cap);

void mqtt_proto_dedupe_init(mqtt_proto_dedupe_t *window);
const mqtt_proto_ack_t *mqtt_proto_dedupe_find(const mqtt_proto_dedupe_t *window,
                                                const char *cmd_id);
void mqtt_proto_dedupe_store(mqtt_proto_dedupe_t *window, const mqtt_proto_ack_t *ack);
uint32_t mqtt_proto_backoff_ms(uint32_t attempt, uint32_t random_value, uint32_t base_ms,
                               uint32_t max_ms, uint32_t floor_ms);

#ifdef __cplusplus
}
#endif

#endif
