#ifndef APP_MQTT_CMD_H
#define APP_MQTT_CMD_H

#include <stddef.h>

#include "app_mqtt_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Applies one validated command (mqtt_protocol.md section 2) to the load engine and the stored
 * configuration. Runs on the MQTT worker task and returns once the change is applied and
 * persisted, so the caller can acknowledge it. On failure `reason` explains why.
 * GET_STATUS changes nothing; the caller publishes the snapshot.
 */
mqtt_proto_code_t app_mqtt_cmd_execute(const mqtt_cmd_t *cmd, char *reason, size_t reason_cap);

#ifdef __cplusplus
}
#endif

#endif
