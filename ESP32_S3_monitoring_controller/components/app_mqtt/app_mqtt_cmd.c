#include "app_mqtt_cmd.h"

#include <stdio.h>
#include <string.h>

#include "app_control.h"
#include "app_device.h"
#include "app_log.h"
#include "app_modbus.h"
#include "app_mqtt.h"
#include "app_nvm.h"
#include "nvs.h"

static const char *TAG = "app_cmd";

static mqtt_proto_code_t set_reason(char *reason, size_t cap, mqtt_proto_code_t code, const char *text)
{
    if (reason != NULL && cap > 0U) (void)snprintf(reason, cap, "%s", text);
    return code;
}

static mqtt_proto_code_t from_ctl(ctl_result_t result, char *reason, size_t cap)
{
    if (result == CTL_OK) return MQTT_PROTO_OK;
    (void)set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, app_control_result_reason(result));
    switch (result) {
    case CTL_ERR_ARG:
    case CTL_ERR_DISABLED:
    case CTL_ERR_NOT_FOUND:
    case CTL_ERR_LIMIT:
        return MQTT_PROTO_INVALID_VALUE;
    case CTL_ERR_EXISTS:
        return MQTT_PROTO_CONFLICT;
    case CTL_ERR_STORAGE:
        return MQTT_PROTO_STORAGE_ERROR;
    case CTL_ERR_INTERLOCK:
        return MQTT_PROTO_FORBIDDEN;
    default:
        return MQTT_PROTO_INTERNAL_ERROR;
    }
}

static mqtt_proto_code_t commit(const device_cfg_t *next, char *reason, size_t cap)
{
    esp_err_t err = app_device_commit(next);
    if (err == ESP_OK) return MQTT_PROTO_OK;
    ESP_LOGW(TAG, "commit rejected: %s", esp_err_to_name(err));
    if (err == ESP_ERR_INVALID_STATE) return set_reason(reason, cap, MQTT_PROTO_CONFLICT, "slave_id already used");
    if (err == ESP_ERR_INVALID_ARG) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "value rejected by validation");
    return set_reason(reason, cap, MQTT_PROTO_STORAGE_ERROR, "could not write NVM");
}

static void reset_condition(load_condition_cfg_t *cond)
{
    memset(cond, 0, sizeof(*cond));
    cond->sensor_port = APP_PORT_NONE;
}

static mqtt_proto_code_t exec_condition(const mqtt_cmd_t *cmd, char *reason, size_t cap)
{
    device_cfg_t next;
    app_device_get(&next);
    load_cfg_t *load = &next.load[cmd->load];
    load_condition_cfg_t *cond = &load->condition[cmd->index];

    if (cmd->type == MQTT_CMD_ADD_LOAD_CONDITION) {
        if (cond->present) return set_reason(reason, cap, MQTT_PROTO_CONFLICT, "condition already exists");
        if (!load->enabled) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "load is disabled");
        reset_condition(cond);
        cond->present = true;
        return commit(&next, reason, cap);
    }
    if (!cond->present) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "condition not found");

    switch (cmd->type) {
    case MQTT_CMD_DELETE_LOAD_CONDITION:
        reset_condition(cond);
        break;
    case MQTT_CMD_TOGGLE_LOAD_CONDITION:
        if (cmd->enabled) {
            if (!load->enabled) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "load is disabled");
            if (cond->sensor_port == APP_PORT_NONE || !next.sensor[cond->sensor_port].configured) {
                return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "condition has no valid sensor");
            }
        }
        cond->enabled = cmd->enabled;
        break;
    default:    /* MQTT_CMD_SET_LOAD_CONDITION */
        if (!load->enabled) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "load is disabled");
        if (!next.sensor[cmd->cond_port].configured) {
            return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "sensor_id is not configured");
        }
        cond->enabled = cmd->enabled;
        cond->action = cmd->cond_action;
        cond->op_gt = cmd->op_gt;
        cond->sensor_port = cmd->cond_port;
        cond->value_index = cmd->cond_value_index;
        cond->threshold = cmd->threshold;
        break;
    }
    return commit(&next, reason, cap);
}

static mqtt_proto_code_t exec_scheduler(const mqtt_cmd_t *cmd, char *reason, size_t cap)
{
    device_cfg_t next;
    app_device_get(&next);
    load_cfg_t *load = &next.load[cmd->load];
    load_scheduler_cfg_t *sch = &load->scheduler[cmd->index];

    if (cmd->type == MQTT_CMD_ADD_LOAD_SCHEDULER) {
        if (sch->present) return set_reason(reason, cap, MQTT_PROTO_CONFLICT, "scheduler already exists");
        if (!load->enabled) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "load is disabled");
        memset(sch, 0, sizeof(*sch));
        sch->present = true;
        return commit(&next, reason, cap);
    }
    if (!sch->present) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "scheduler not found");

    switch (cmd->type) {
    case MQTT_CMD_DELETE_LOAD_SCHEDULER:
        memset(sch, 0, sizeof(*sch));
        break;
    case MQTT_CMD_TOGGLE_LOAD_SCHEDULER:
        if (cmd->enabled) {
            if (!load->enabled) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "load is disabled");
            if (sch->days_mask == 0U) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "days_mask is empty");
        }
        sch->enabled = cmd->enabled;
        break;
    default:    /* MQTT_CMD_SET_LOAD_SCHEDULE */
        if (!load->enabled) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "load is disabled");
        if (cmd->on_minute_utc == cmd->off_minute_utc) {
            return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "on and off time are equal");
        }
        if (cmd->enabled && cmd->days_mask == 0U) {
            return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "days_mask is empty");
        }
        sch->enabled = cmd->enabled;
        sch->days_mask = cmd->days_mask;
        sch->on_minute_utc = cmd->on_minute_utc;
        sch->off_minute_utc = cmd->off_minute_utc;
        break;
    }
    return commit(&next, reason, cap);
}

static mqtt_proto_code_t exec_sensor(const mqtt_cmd_t *cmd, char *reason, size_t cap)
{
    device_cfg_t next;
    app_device_get(&next);
    sensor_port_cfg_t *sensor = &next.sensor[cmd->port];
    bool is_rs485 = app_port_interface(cmd->port) == SENSOR_INTERFACE_RS485;
    uint8_t old_slave_id = 0U;

    switch (cmd->type) {
    case MQTT_CMD_SENSOR_CONFIG:
        if (cmd->action && sensor->configured) {
            return set_reason(reason, cap, MQTT_PROTO_CONFLICT, "port already has a sensor");
        }
        if (!cmd->action && !sensor->configured) {
            return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "sensor not found");
        }
        if (is_rs485) {
            old_slave_id = sensor->configured ? sensor->slave_id : 1U;
            for (size_t i = 0; i < APP_RS485_INTERFACE_COUNT; i++) {
                if (i == cmd->port || !next.sensor[i].configured) continue;
                if (next.sensor[i].slave_id == cmd->slave_id) {
                    return set_reason(reason, cap, MQTT_PROTO_CONFLICT,
                                      "slave_id already used by another sensor");
                }
                if (cmd->slave_id != old_slave_id &&
                    next.sensor[i].slave_id == old_slave_id) {
                    return set_reason(reason, cap, MQTT_PROTO_CONFLICT,
                                      "old slave_id is shared; isolate this sensor before changing it");
                }
            }
        }
        sensor->configured = true;
        sensor->enabled = cmd->enabled;
        sensor->slave_id = is_rs485 ? cmd->slave_id : 0U;
        strlcpy(sensor->name, cmd->name, sizeof(sensor->name));
        break;
    case MQTT_CMD_TOGGLE_SENSOR_CAPABILITY:
        if (!sensor->configured) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "sensor not found");
        sensor->enabled = cmd->enabled;
        break;
    default: {  /* MQTT_CMD_DELETE_SENSOR */
        if (!sensor->configured) return set_reason(reason, cap, MQTT_PROTO_INVALID_VALUE, "sensor not found");
        memset(sensor, 0, sizeof(*sensor));
        sensor->slave_id = is_rs485 ? (uint8_t)(cmd->port + 1U) : 0U;
        /* A condition cannot keep watching a sensor that no longer exists. */
        for (size_t i = 0; i < APP_LOAD_COUNT; i++) {
            for (size_t c = 0; c < APP_CONDITIONS_PER_LOAD; c++) {
                load_condition_cfg_t *cond = &next.load[i].condition[c];
                if (cond->present && cond->sensor_port == cmd->port && cond->enabled) {
                    ESP_LOGI(TAG, "DO%u CON%u disabled: its sensor was deleted", (unsigned)(i + 1U),
                             (unsigned)(c + 1U));
                    cond->enabled = false;
                }
            }
        }
        break;
    }
    }

    if (cmd->type == MQTT_CMD_SENSOR_CONFIG && is_rs485 &&
        old_slave_id != cmd->slave_id) {
        esp_err_t err = app_modbus_change_slave_id(old_slave_id, cmd->slave_id);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "RS485 port %u Slave ID change %u -> %u failed: %s",
                     (unsigned)cmd->port, (unsigned)old_slave_id,
                     (unsigned)cmd->slave_id, esp_err_to_name(err));
            return set_reason(reason, cap, MQTT_PROTO_INTERNAL_ERROR,
                              "Slave ID change was not confirmed; NVM unchanged; verify the sensor ID before retrying");
        }
    }

    mqtt_proto_code_t code = commit(&next, reason, cap);
    if (code != MQTT_PROTO_OK && cmd->type == MQTT_CMD_SENSOR_CONFIG &&
        is_rs485 && old_slave_id != cmd->slave_id) {
        esp_err_t rollback = app_modbus_change_slave_id(cmd->slave_id, old_slave_id);
        if (rollback != ESP_OK) {
            ESP_LOGE(TAG, "RS485 port %u NVM commit failed and Slave ID rollback %u -> %u failed: %s",
                     (unsigned)cmd->port, (unsigned)cmd->slave_id,
                     (unsigned)old_slave_id, esp_err_to_name(rollback));
            return set_reason(reason, cap, MQTT_PROTO_STORAGE_ERROR,
                              "NVM save failed and sensor rollback failed; sensor may now use the new ID");
        }
    }
    if (code == MQTT_PROTO_OK) {
        app_modbus_config_changed();
        if (cmd->type != MQTT_CMD_DELETE_SENSOR && next.sensor[cmd->port].enabled) {
            app_control_estop_ack_reenable();
        }
    }
    return code;
}

static mqtt_proto_code_t exec_device_name(const mqtt_cmd_t *cmd, char *reason, size_t cap)
{
    app_config_t config;
    esp_err_t err = app_nvm_load_config(&config);
    if (err != ESP_OK && err != ESP_ERR_NVS_NOT_FOUND) {
        return set_reason(reason, cap, MQTT_PROTO_STORAGE_ERROR, "could not read NVM");
    }
    strlcpy(config.device_name, cmd->name, sizeof(config.device_name));
    err = app_nvm_save_config(&config);
    if (err != ESP_OK) return set_reason(reason, cap, MQTT_PROTO_STORAGE_ERROR, "could not write NVM");
    app_mqtt_device_name_changed(config.device_name);
    return MQTT_PROTO_OK;
}

static mqtt_proto_code_t exec_telemetry_interval(const mqtt_cmd_t *cmd, char *reason, size_t cap)
{
    app_config_t config;
    esp_err_t err = app_nvm_load_config(&config);
    if (err != ESP_OK && err != ESP_ERR_NVS_NOT_FOUND) {
        return set_reason(reason, cap, MQTT_PROTO_STORAGE_ERROR, "could not read NVM");
    }
    config.telemetry_interval_s = cmd->telemetry_interval_s;
    err = app_nvm_save_config(&config);
    if (err != ESP_OK) {
        return set_reason(reason, cap, MQTT_PROTO_STORAGE_ERROR, "could not write NVM");
    }
    app_mqtt_telemetry_interval_changed(config.telemetry_interval_s);
    return MQTT_PROTO_OK;
}

mqtt_proto_code_t app_mqtt_cmd_execute(const mqtt_cmd_t *cmd, char *reason, size_t reason_cap)
{
    if (cmd == NULL) return MQTT_PROTO_INTERNAL_ERROR;
    if (reason != NULL && reason_cap > 0U) reason[0] = '\0';

    switch (cmd->type) {
    case MQTT_CMD_SET_LOAD_STATE:
        return from_ctl(app_control_set_state_verified(cmd->load, cmd->action, 2000U),
                        reason, reason_cap);
    case MQTT_CMD_SET_LOAD_DELAY:
        return from_ctl(app_control_set_delay(cmd->load, cmd->mode, cmd->delay_min, cmd->duration_min),
                        reason, reason_cap);
    case MQTT_CMD_STOP_LOAD_DELAY:
        return from_ctl(app_control_stop_delay(cmd->load), reason, reason_cap);
    case MQTT_CMD_TOGGLE_LOAD_CAPABILITY:
        return from_ctl(app_control_set_enabled(cmd->load, cmd->action), reason, reason_cap);
    case MQTT_CMD_SET_LOAD_NAME: {
        device_cfg_t next;
        app_device_get(&next);
        strlcpy(next.load[cmd->load].name, cmd->name, sizeof(next.load[cmd->load].name));
        return commit(&next, reason, reason_cap);
    }
    case MQTT_CMD_ADD_LOAD_CONDITION:
    case MQTT_CMD_SET_LOAD_CONDITION:
    case MQTT_CMD_DELETE_LOAD_CONDITION:
    case MQTT_CMD_TOGGLE_LOAD_CONDITION:
        return exec_condition(cmd, reason, reason_cap);
    case MQTT_CMD_ADD_LOAD_SCHEDULER:
    case MQTT_CMD_SET_LOAD_SCHEDULE:
    case MQTT_CMD_DELETE_LOAD_SCHEDULER:
    case MQTT_CMD_TOGGLE_LOAD_SCHEDULER:
        return exec_scheduler(cmd, reason, reason_cap);
    case MQTT_CMD_SENSOR_CONFIG:
    case MQTT_CMD_DELETE_SENSOR:
    case MQTT_CMD_TOGGLE_SENSOR_CAPABILITY:
        return exec_sensor(cmd, reason, reason_cap);
    case MQTT_CMD_SET_DEVICE_NAME:
        return exec_device_name(cmd, reason, reason_cap);
    case MQTT_CMD_SET_TELEMETRY_INTERVAL:
        return exec_telemetry_interval(cmd, reason, reason_cap);
    case MQTT_CMD_GET_STATUS:
    case MQTT_CMD_GET_TELEMETRY:
        return MQTT_PROTO_OK;
    case MQTT_CMD_EMERGENCY_STOP: {
        uint8_t loads_off = 0;
        ctl_result_t result = app_control_emergency_stop(&loads_off);
        app_modbus_config_changed();
        return from_ctl(result, reason, reason_cap);
    }
    }
    return MQTT_PROTO_UNSUPPORTED_ACTION;
}
