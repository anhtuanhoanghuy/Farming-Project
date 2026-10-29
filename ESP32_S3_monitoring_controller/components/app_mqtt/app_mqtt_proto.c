#include "app_mqtt_proto.h"

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "app_device.h"
#include "cJSON.h"

#define JSON_VERSION 1
#define CMD_ID_MAX 36U
#define NAME_MAX_BYTES 31U

static const char *const k_cmd_names[] = {
    "SET_LOAD_STATE", "SET_LOAD_DELAY", "SET_LOAD_NAME", "TOGGLE_LOAD_CAPABILITY",
    "SET_LOAD_CONDITION", "SET_LOAD_SCHEDULE", "DELETE_LOAD_CONDITION", "DELETE_LOAD_SCHEDULER",
    "ADD_LOAD_CONDITION", "ADD_LOAD_SCHEDULER", "TOGGLE_LOAD_CONDITION", "TOGGLE_LOAD_SCHEDULER",
    "STOP_LOAD_DELAY", "SENSOR_CONFIG", "DELETE_SENSOR", "TOGGLE_SENSOR_CAPABILITY",
    "SET_DEVICE_NAME", "GET_STATUS", "EMERGENCY_STOP", "SET_TELEMETRY_INTERVAL",
    "GET_TELEMETRY",
};
_Static_assert(sizeof(k_cmd_names) / sizeof(k_cmd_names[0]) ==
                   (size_t)MQTT_CMD_GET_TELEMETRY + 1U,
               "command name table out of sync");

/* ---- Validators and topics ----------------------------------------------------------------- */

bool mqtt_proto_valid_name(const char *s)
{
    size_t len;
    if (s == NULL || (len = strlen(s)) == 0U || len > NAME_MAX_BYTES ||
        isspace((unsigned char)s[0]) || isspace((unsigned char)s[len - 1U])) {
        return false;
    }

    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20U || c == 0x7fU) return false;
        if (c < 0x80U) continue;
        unsigned need;
        if (c >= 0xc2U && c <= 0xdfU) need = 1U;
        else if (c >= 0xe0U && c <= 0xefU) need = 2U;
        else if (c >= 0xf0U && c <= 0xf4U) need = 3U;
        else return false;
        if (i + need >= len) return false;
        unsigned char second = (unsigned char)s[i + 1U];
        if ((second & 0xc0U) != 0x80U ||
            (c == 0xe0U && second < 0xa0U) || (c == 0xedU && second >= 0xa0U) ||
            (c == 0xf0U && second < 0x90U) || (c == 0xf4U && second > 0x8fU)) return false;
        for (unsigned j = 2; j <= need; j++)
            if (((unsigned char)s[i + j] & 0xc0U) != 0x80U) return false;
        i += need;
    }
    return true;
}

bool mqtt_proto_valid_user_id(const char *user_id)
{
    if (user_id == NULL) return false;
    size_t len = strlen(user_id);
    if (len == 0U || len > 36U) return false;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)user_id[i];
        if (c < 0x21U || c > 0x7eU || c == '/' || c == '+' || c == '#') return false;
    }
    return true;
}

bool mqtt_proto_valid_cmd_id(const char *cmd_id)
{
    if (cmd_id == NULL) return false;
    size_t len = strlen(cmd_id);
    if (len == 0U || len > CMD_ID_MAX) return false;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)cmd_id[i];
        if (!(isalnum(c) || c == '_' || c == '-')) return false;
    }
    return true;
}

static bool append_topic(char *out, size_t cap, const char *user, const char *device,
                         const char *leaf)
{
    int n = snprintf(out, cap, "v1/%s/devices/%s/%s", user, device, leaf);
    return n > 0 && (size_t)n < cap;
}

bool mqtt_proto_build_topics(const char *user_id, const char *device_id, mqtt_proto_topics_t *out)
{
    if (out == NULL || !mqtt_proto_valid_user_id(user_id) || device_id == NULL ||
        strlen(device_id) != 12U) return false;
    for (size_t i = 0; i < 12U; i++) {
        if (!((device_id[i] >= '0' && device_id[i] <= '9') ||
              (device_id[i] >= 'a' && device_id[i] <= 'f'))) return false;
    }
    memset(out, 0, sizeof(*out));
    if (snprintf(out->user_id, sizeof(out->user_id), "%s", user_id) >= (int)sizeof(out->user_id) ||
        snprintf(out->device_id, sizeof(out->device_id), "%s", device_id) >= (int)sizeof(out->device_id)) return false;
    return append_topic(out->telemetry, sizeof(out->telemetry), user_id, device_id, "telemetry") &&
           append_topic(out->commands, sizeof(out->commands), user_id, device_id, "commands") &&
           append_topic(out->ack, sizeof(out->ack), user_id, device_id, "ack") &&
           append_topic(out->status, sizeof(out->status), user_id, device_id, "status");
}

const char *mqtt_proto_code_name(mqtt_proto_code_t code)
{
    static const char *const names[] = {
        "OK", "INVALID_JSON", "INVALID_FIELDS", "INVALID_VALUE", "UNSUPPORTED_ACTION",
        "UNSUPPORTED_VERSION", "FORBIDDEN", "CONFLICT", "EXPIRED", "BUSY",
        "PAYLOAD_TOO_LARGE", "SHUTTING_DOWN", "STORAGE_ERROR", "INTERNAL_ERROR",
    };
    return (unsigned)code < sizeof(names) / sizeof(names[0]) ? names[code] : "INTERNAL_ERROR";
}

const char *mqtt_proto_cmd_name(mqtt_cmd_type_t type)
{
    return (unsigned)type < sizeof(k_cmd_names) / sizeof(k_cmd_names[0]) ? k_cmd_names[type] : "UNKNOWN";
}

/* ---- Command parsing ----------------------------------------------------------------------- */

typedef struct {
    const cJSON *root;
    mqtt_proto_code_t code;
    char *reason;
    size_t cap;
} parse_ctx_t;

static bool fail(parse_ctx_t *c, mqtt_proto_code_t code, const char *field, const char *why)
{
    c->code = code;
    if (c->reason != NULL && c->cap > 0U) (void)snprintf(c->reason, c->cap, "%s: %s", field, why);
    return false;
}

static const cJSON *item(const parse_ctx_t *c, const char *key)
{
    return cJSON_GetObjectItemCaseSensitive(c->root, key);
}

static bool req_bool(parse_ctx_t *c, const char *key, bool *out)
{
    const cJSON *it = item(c, key);
    if (!cJSON_IsBool(it)) return fail(c, MQTT_PROTO_INVALID_FIELDS, key, "missing or not a bool");
    *out = cJSON_IsTrue(it);
    return true;
}

static bool req_int(parse_ctx_t *c, const char *key, int64_t min, int64_t max, int64_t *out)
{
    const cJSON *it = item(c, key);
    if (!cJSON_IsNumber(it)) return fail(c, MQTT_PROTO_INVALID_FIELDS, key, "missing or not a number");
    if (!isfinite(it->valuedouble) || floor(it->valuedouble) != it->valuedouble ||
        it->valuedouble < (double)min || it->valuedouble > (double)max) {
        return fail(c, MQTT_PROTO_INVALID_VALUE, key, "out of range");
    }
    *out = (int64_t)it->valuedouble;
    return true;
}

static bool req_float(parse_ctx_t *c, const char *key, double min, double max, float *out)
{
    const cJSON *it = item(c, key);
    if (!cJSON_IsNumber(it)) return fail(c, MQTT_PROTO_INVALID_FIELDS, key, "missing or not a number");
    if (!isfinite(it->valuedouble) || it->valuedouble < min || it->valuedouble > max) {
        return fail(c, MQTT_PROTO_INVALID_VALUE, key, "out of range");
    }
    *out = (float)it->valuedouble;
    return true;
}

static const char *req_string(parse_ctx_t *c, const char *key)
{
    const cJSON *it = item(c, key);
    if (!cJSON_IsString(it) || it->valuestring == NULL) {
        (void)fail(c, MQTT_PROTO_INVALID_FIELDS, key, "missing or not a string");
        return NULL;
    }
    return it->valuestring;
}

static bool req_load(parse_ctx_t *c, uint8_t *out)
{
    const char *s = req_string(c, "load_id");
    if (s == NULL) return false;
    uint8_t index = app_device_load_from_name(s);
    if (index == APP_PORT_NONE) return fail(c, MQTT_PROTO_INVALID_VALUE, "load_id", "expected DO1..DO4");
    *out = index;
    return true;
}

static bool req_port(parse_ctx_t *c, const char *key, uint8_t *out)
{
    const char *s = req_string(c, key);
    if (s == NULL) return false;
    uint8_t port = app_device_port_from_name(s);
    if (port == APP_PORT_NONE) return fail(c, MQTT_PROTO_INVALID_VALUE, key, "expected RS1..RS4, AN1, DI1..DI4");
    *out = port;
    return true;
}

/* "CON2" -> 1, "SHE3" -> 2. */
static bool req_numbered(parse_ctx_t *c, const char *key, const char *prefix, uint8_t max, uint8_t *out)
{
    const char *s = req_string(c, key);
    if (s == NULL) return false;
    size_t prefix_len = strlen(prefix);
    if (strncmp(s, prefix, prefix_len) != 0 || s[prefix_len] < '1' ||
        s[prefix_len] > (char)('0' + max) || s[prefix_len + 1U] != '\0') {
        return fail(c, MQTT_PROTO_INVALID_VALUE, key, "unknown id");
    }
    *out = (uint8_t)(s[prefix_len] - '1');
    return true;
}

static bool req_name(parse_ctx_t *c, char *out)
{
    const char *s = req_string(c, "name");
    if (s == NULL) return false;
    if (!mqtt_proto_valid_name(s)) return fail(c, MQTT_PROTO_INVALID_VALUE, "name", "1..31 byte UTF-8");
    strlcpy(out, s, MQTT_PROTO_NAME_LEN);
    return true;
}

static bool req_hhmm(parse_ctx_t *c, const char *key, uint16_t *out)
{
    const char *s = req_string(c, key);
    if (s == NULL) return false;
    if (strlen(s) != 5U || s[2] != ':' || !isdigit((unsigned char)s[0]) || !isdigit((unsigned char)s[1]) ||
        !isdigit((unsigned char)s[3]) || !isdigit((unsigned char)s[4])) {
        return fail(c, MQTT_PROTO_INVALID_VALUE, key, "expected HH:MM");
    }
    unsigned hour = (unsigned)(s[0] - '0') * 10U + (unsigned)(s[1] - '0');
    unsigned minute = (unsigned)(s[3] - '0') * 10U + (unsigned)(s[4] - '0');
    if (hour > 23U || minute > 59U) return fail(c, MQTT_PROTO_INVALID_VALUE, key, "expected HH:MM");
    *out = (uint16_t)(hour * 60U + minute);
    return true;
}

static bool parse_sensor_config(parse_ctx_t *c, mqtt_cmd_t *out)
{
    const char *interface_type = req_string(c, "interface_type");
    if (interface_type == NULL || !req_bool(c, "action", &out->action) ||
        !req_bool(c, "enabled", &out->enabled) || !req_port(c, "sensor_id", &out->port) ||
        !req_name(c, out->name)) {
        return false;
    }

    sensor_interface_type_t expected = app_port_interface(out->port);
    const char *expected_name = expected == SENSOR_INTERFACE_RS485 ? "rs485" :
                                expected == SENSOR_INTERFACE_ANALOG_4_20MA ? "analog_4_20ma" : "di";
    if (strcmp(interface_type, expected_name) != 0) {
        return fail(c, MQTT_PROTO_INVALID_VALUE, "interface_type", "does not match sensor_id");
    }

    out->slave_id = 0U;
    if (expected == SENSOR_INTERFACE_RS485) {
        int64_t slave;
        if (!req_int(c, "slave_id", 1, 247, &slave)) return false;
        out->slave_id = (uint8_t)slave;
    }
    return true;
}

static bool req_sensor_value(parse_ctx_t *c, uint8_t port, uint8_t *out)
{
    const char *name = req_string(c, "value_name");
    if (name == NULL) return false;

    sensor_type_t type = app_port_sensor_type(port);
    for (uint8_t i = 0; i < app_sensor_value_count(type); i++) {
        const char *candidate = app_sensor_value_name(type, i);
        if (candidate != NULL && strcmp(name, candidate) == 0) {
            *out = i;
            return true;
        }
    }
    return fail(c, MQTT_PROTO_INVALID_VALUE, "value_name",
                "does not match values reported by the selected sensor");
}

mqtt_proto_code_t mqtt_proto_parse_command(const char *json, size_t len, mqtt_cmd_t *out,
                                           char *reason, size_t reason_cap, const char **cmd_name)
{
    if (out == NULL || json == NULL) return MQTT_PROTO_INTERNAL_ERROR;
    memset(out, 0, sizeof(*out));
    if (reason != NULL && reason_cap > 0U) reason[0] = '\0';
    if (cmd_name != NULL) *cmd_name = NULL;

    cJSON *root = cJSON_ParseWithLength(json, len);
    if (root == NULL) {
        if (reason != NULL) (void)snprintf(reason, reason_cap, "payload is not valid JSON");
        return MQTT_PROTO_INVALID_JSON;
    }
    parse_ctx_t ctx = {.root = root, .code = MQTT_PROTO_OK, .reason = reason, .cap = reason_cap};
    mqtt_proto_code_t result = MQTT_PROTO_OK;

    if (!cJSON_IsObject(root)) {
        result = MQTT_PROTO_INVALID_JSON;
        if (reason != NULL) (void)snprintf(reason, reason_cap, "payload is not a JSON object");
        goto done;
    }

    const cJSON *id = item(&ctx, "cmd_id");
    if (cJSON_IsString(id) && mqtt_proto_valid_cmd_id(id->valuestring)) {
        strlcpy(out->cmd_id, id->valuestring, sizeof(out->cmd_id));
    } else {
        (void)fail(&ctx, MQTT_PROTO_INVALID_FIELDS, "cmd_id", "missing or invalid");
        result = ctx.code;
        goto done;
    }

    const cJSON *version = item(&ctx, "v");
    if (!cJSON_IsNumber(version)) {
        (void)fail(&ctx, MQTT_PROTO_INVALID_FIELDS, "v", "missing");
        result = ctx.code;
        goto done;
    }
    if (version->valuedouble != (double)JSON_VERSION) {
        (void)fail(&ctx, MQTT_PROTO_UNSUPPORTED_VERSION, "v", "only version 1");
        result = ctx.code;
        goto done;
    }

    /* Every command name comes from `type`; `action` is only ever a bool argument. */
    const cJSON *name = item(&ctx, "type");
    if (!cJSON_IsString(name) || name->valuestring == NULL) {
        (void)fail(&ctx, MQTT_PROTO_INVALID_FIELDS, "type", "missing");
        result = ctx.code;
        goto done;
    }
    bool known = false;
    for (size_t i = 0; i < sizeof(k_cmd_names) / sizeof(k_cmd_names[0]); i++) {
        if (strcmp(name->valuestring, k_cmd_names[i]) == 0) {
            out->type = (mqtt_cmd_type_t)i;
            known = true;
            break;
        }
    }
    if (!known) {
        (void)fail(&ctx, MQTT_PROTO_UNSUPPORTED_ACTION, "type", "unknown command");
        result = ctx.code;
        goto done;
    }
    if (cmd_name != NULL) *cmd_name = mqtt_proto_cmd_name(out->type);

    bool ok = true;
    int64_t n = 0;
    switch (out->type) {
    case MQTT_CMD_SET_LOAD_STATE:
    case MQTT_CMD_TOGGLE_LOAD_CAPABILITY:
        ok = req_load(&ctx, &out->load) && req_bool(&ctx, "action", &out->action);
        break;
    case MQTT_CMD_SET_LOAD_DELAY:
        ok = req_load(&ctx, &out->load) && req_bool(&ctx, "mode", &out->mode) &&
             req_int(&ctx, "delay_min", 0, 1440, &n);
        if (ok) {
            out->delay_min = (uint16_t)n;
            ok = req_int(&ctx, "duration", 0, 1440, &n);
            out->duration_min = (uint16_t)n;
        }
        break;
    case MQTT_CMD_SET_LOAD_NAME:
        ok = req_load(&ctx, &out->load) && req_name(&ctx, out->name);
        break;
    case MQTT_CMD_STOP_LOAD_DELAY:
        ok = req_load(&ctx, &out->load);
        break;
    case MQTT_CMD_SET_LOAD_CONDITION:
        ok = req_numbered(&ctx, "condition_id", "CON", APP_CONDITIONS_PER_LOAD, &out->index) &&
             req_bool(&ctx, "condition_enabled", &out->enabled) && req_load(&ctx, &out->load) &&
             req_bool(&ctx, "action", &out->cond_action) && req_port(&ctx, "sensor_id", &out->cond_port) &&
             req_sensor_value(&ctx, out->cond_port, &out->cond_value_index) &&
             req_bool(&ctx, "operator", &out->op_gt) &&
             req_float(&ctx, "threshold", -1.0e6, 1.0e6, &out->threshold);
        break;
    case MQTT_CMD_ADD_LOAD_CONDITION:
    case MQTT_CMD_DELETE_LOAD_CONDITION:
        ok = req_load(&ctx, &out->load) &&
             req_numbered(&ctx, "condition_id", "CON", APP_CONDITIONS_PER_LOAD, &out->index);
        break;
    case MQTT_CMD_TOGGLE_LOAD_CONDITION:
        ok = req_load(&ctx, &out->load) &&
             req_numbered(&ctx, "condition_id", "CON", APP_CONDITIONS_PER_LOAD, &out->index) &&
             req_bool(&ctx, "action", &out->enabled);
        break;
    case MQTT_CMD_SET_LOAD_SCHEDULE:
        ok = req_numbered(&ctx, "scheduler_id", "SHE", APP_SCHEDULERS_PER_LOAD, &out->index) &&
             req_load(&ctx, &out->load) && req_bool(&ctx, "scheduler_enabled", &out->enabled) &&
             req_int(&ctx, "days_mask", 0, 127, &n);
        if (ok) {
            out->days_mask = (uint8_t)n;
            ok = req_hhmm(&ctx, "on_time_utc", &out->on_minute_utc) &&
                 req_hhmm(&ctx, "off_time_utc", &out->off_minute_utc);
        }
        break;
    case MQTT_CMD_ADD_LOAD_SCHEDULER:
    case MQTT_CMD_DELETE_LOAD_SCHEDULER:
        ok = req_load(&ctx, &out->load) &&
             req_numbered(&ctx, "scheduler_id", "SHE", APP_SCHEDULERS_PER_LOAD, &out->index);
        break;
    case MQTT_CMD_TOGGLE_LOAD_SCHEDULER:
        ok = req_load(&ctx, &out->load) &&
             req_numbered(&ctx, "scheduler_id", "SHE", APP_SCHEDULERS_PER_LOAD, &out->index) &&
             req_bool(&ctx, "action", &out->enabled);
        break;
    case MQTT_CMD_SENSOR_CONFIG:
        ok = parse_sensor_config(&ctx, out);
        break;
    case MQTT_CMD_DELETE_SENSOR:
        ok = req_port(&ctx, "sensor_id", &out->port);
        break;
    case MQTT_CMD_TOGGLE_SENSOR_CAPABILITY:
        ok = req_port(&ctx, "sensor_id", &out->port) && req_bool(&ctx, "action", &out->enabled);
        break;
    case MQTT_CMD_SET_DEVICE_NAME:
        ok = req_name(&ctx, out->name);
        break;
    case MQTT_CMD_GET_STATUS:
    case MQTT_CMD_EMERGENCY_STOP:
    case MQTT_CMD_GET_TELEMETRY:
        break;
    case MQTT_CMD_SET_TELEMETRY_INTERVAL:
        ok = req_int(&ctx, "interval_s", 5, 600, &n);
        if (ok) out->telemetry_interval_s = (uint16_t)n;
        break;
    }
    if (!ok) result = ctx.code == MQTT_PROTO_OK ? MQTT_PROTO_INVALID_FIELDS : ctx.code;

done:
    cJSON_Delete(root);
    return result;
}

/* ---- Serialization ------------------------------------------------------------------------- */

static cJSON *new_base(void)
{
    cJSON *o = cJSON_CreateObject();
    if (o != NULL) cJSON_AddNumberToObject(o, "v", JSON_VERSION);
    return o;
}

static int print_bounded(cJSON *o, char *out, size_t cap)
{
    if (o == NULL || out == NULL || cap == 0U) { cJSON_Delete(o); return -1; }
    char *text = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (text == NULL) return -1;
    size_t n = strlen(text);
    if (n >= cap) { cJSON_free(text); return -1; }
    memcpy(out, text, n + 1U);
    cJSON_free(text);
    return (int)n;
}

static double rounded(double value, double scale)
{
    return round(value * scale) / scale;
}

static void format_hhmm(char out[6], uint16_t minute_of_day)
{
    unsigned hour = minute_of_day / 60U;
    unsigned minute = minute_of_day % 60U;
    out[0] = (char)('0' + (hour / 10U));
    out[1] = (char)('0' + (hour % 10U));
    out[2] = ':';
    out[3] = (char)('0' + (minute / 10U));
    out[4] = (char)('0' + (minute % 10U));
    out[5] = '\0';
}

static const char *interface_name(uint8_t port)
{
    switch (app_port_interface(port)) {
    case SENSOR_INTERFACE_RS485: return "rs485";
    case SENSOR_INTERFACE_ANALOG_4_20MA: return "analog_4_20ma";
    default: return "di";
    }
}

int mqtt_proto_serialize_ack(const mqtt_proto_ack_t *ack, const char *boot_id, char *out, size_t cap)
{
    if (ack == NULL) return -1;
    cJSON *o = new_base();
    if (o == NULL) return -1;
    if (ack->has_cmd_id) cJSON_AddStringToObject(o, "cmd_id", ack->cmd_id);
    else cJSON_AddNullToObject(o, "cmd_id");
    cJSON_AddStringToObject(o, "type", "ACK");
    if (ack->cmd_name != NULL) cJSON_AddStringToObject(o, "cmd", ack->cmd_name);
    cJSON_AddStringToObject(o, "result", ack->success ? "ok" : "error");
    cJSON_AddStringToObject(o, "code", mqtt_proto_code_name(ack->code));
    if (!ack->success && ack->reason[0] != '\0') cJSON_AddStringToObject(o, "reason", ack->reason);
    cJSON_AddStringToObject(o, "boot_id", boot_id != NULL ? boot_id : "00000000");
    cJSON_AddBoolToObject(o, "dup", ack->dup);
    if (ack->has_ts) cJSON_AddNumberToObject(o, "ts", (double)ack->ts_ms);
    return print_bounded(o, out, cap);
}

int mqtt_proto_serialize_lwt(const char *boot_id, char *out, size_t cap)
{
    cJSON *o = new_base();
    if (o == NULL) return -1;
    cJSON_AddStringToObject(o, "type", "LWT");
    cJSON_AddStringToObject(o, "state", "offline");
    cJSON_AddStringToObject(o, "boot_id", boot_id != NULL ? boot_id : "00000000");
    return print_bounded(o, out, cap);
}

static void add_port_list(cJSON *parent, const char *key, bool runtime_available, bool with_runtime,
                          uint8_t first, uint8_t count)
{
    cJSON *cap = cJSON_CreateObject();
    cJSON_AddBoolToObject(cap, "supported", true);
    if (with_runtime) cJSON_AddBoolToObject(cap, "runtime_available", runtime_available);
    cJSON_AddNumberToObject(cap, "count", count);
    cJSON *ports = cJSON_AddArrayToObject(cap, "port_lists");
    for (uint8_t i = 0; i < count; i++) {
        const char *name = key[0] == 'l' ? app_device_load_name(i) : app_device_port_name((uint8_t)(first + i));
        if (name != NULL) cJSON_AddItemToArray(ports, cJSON_CreateString(name));
    }
    cJSON_AddItemToObject(parent, key, cap);
}

static void add_error_names(cJSON *array, uint32_t mask)
{
    static const char *const names[] = {
        "SYS_ERR_MODBUS_TIMEOUT", "SYS_ERR_NET_LOST", "SYS_ERR_MQTT_BROKER",
        "SYS_ERR_NVM_FAIL", "SYS_ERR_SENSOR_OUT_RANGE", "SYS_ERR_ETH_INIT",
        "SYS_ERR_INIT_FAILURE", "SYS_ERR_RESOURCE_ALLOC",
        "SYS_ERR_LOAD_OUTPUT_DO1", "SYS_ERR_LOAD_OUTPUT_DO2",
        "SYS_ERR_LOAD_OUTPUT_DO3", "SYS_ERR_LOAD_OUTPUT_DO4"
    };
    for (unsigned bit = 0; bit < sizeof(names) / sizeof(names[0]); bit++) {
        if (mask & (1U << bit)) cJSON_AddItemToArray(array, cJSON_CreateString(names[bit]));
    }
}

static const char *delay_phase_name(load_delay_phase_t phase)
{
    switch (phase) {
    case LOAD_DELAY_WAIT_FIRST: return "WAIT_FIRST";
    case LOAD_DELAY_WAIT_SECOND: return "WAIT_SECOND";
    default: return "IDLE";
    }
}

static cJSON *snapshot_load(const mqtt_proto_snapshot_t *s, uint8_t i)
{
    const load_cfg_t *cfg = &s->cfg.load[i];
    const load_runtime_t *rt = &s->load[i];
    cJSON *load = cJSON_CreateObject();
    cJSON_AddStringToObject(load, "load_id", app_device_load_name(i));
    cJSON_AddStringToObject(load, "name", cfg->name);
    cJSON_AddBoolToObject(load, "enabled", cfg->enabled);
    cJSON_AddBoolToObject(load, "state", rt->output);

    cJSON *delay = cJSON_AddObjectToObject(load, "load_delay");
    cJSON_AddBoolToObject(delay, "active", rt->delay_active);
    if (rt->delay_active && rt->delay_start_epoch_s > 0) {
        time_t start = (time_t)rt->delay_start_epoch_s;
        struct tm utc;
        char text[6];
        gmtime_r(&start, &utc);
        format_hhmm(text, (uint16_t)(utc.tm_hour * 60 + utc.tm_min));
        cJSON_AddStringToObject(delay, "start_time", text);
    }
    cJSON_AddBoolToObject(delay, "mode", rt->delay_mode);
    cJSON_AddNumberToObject(delay, "delay_min", rt->delay_min);
    cJSON_AddNumberToObject(delay, "duration", rt->delay_duration_min);
    cJSON_AddStringToObject(delay, "phase", delay_phase_name(rt->delay_phase));
    cJSON_AddNumberToObject(delay, "remaining_s", rt->delay_remaining_s);

    cJSON *conditions = cJSON_AddArrayToObject(load, "load_condition");
    for (uint8_t c = 0; c < APP_CONDITIONS_PER_LOAD; c++) {
        const load_condition_cfg_t *cond = &cfg->condition[c];
        if (!cond->present) continue;
        char id[5];
        (void)snprintf(id, sizeof(id), "CON%u", (unsigned)(c + 1U));
        cJSON *o = cJSON_CreateObject();
        cJSON_AddStringToObject(o, "condition_id", id);
        cJSON_AddBoolToObject(o, "condition_enabled", cond->enabled);
        cJSON_AddBoolToObject(o, "action", cond->action);
        const char *port = app_device_port_name(cond->sensor_port);
        cJSON_AddStringToObject(o, "sensor_id", port != NULL ? port : "");
        const char *value_name = cond->sensor_port < APP_SENSOR_INTERFACE_COUNT
                                     ? app_sensor_value_name(
                                           app_port_sensor_type(cond->sensor_port),
                                           cond->value_index)
                                     : NULL;
        cJSON_AddStringToObject(o, "value_name",
                                value_name != NULL ? value_name : "");
        cJSON_AddBoolToObject(o, "operator", cond->op_gt);
        cJSON_AddNumberToObject(o, "threshold", rounded(cond->threshold, 1000.0));
        cJSON_AddItemToArray(conditions, o);
    }

    cJSON *schedulers = cJSON_AddArrayToObject(load, "load_scheduler");
    for (uint8_t k = 0; k < APP_SCHEDULERS_PER_LOAD; k++) {
        const load_scheduler_cfg_t *sch = &cfg->scheduler[k];
        if (!sch->present) continue;
        char id[5];
        char on[6];
        char off[6];
        (void)snprintf(id, sizeof(id), "SHE%u", (unsigned)(k + 1U));
        format_hhmm(on, sch->on_minute_utc);
        format_hhmm(off, sch->off_minute_utc);
        cJSON *o = cJSON_CreateObject();
        cJSON_AddStringToObject(o, "scheduler_id", id);
        cJSON_AddBoolToObject(o, "scheduler_enabled", sch->enabled);
        cJSON_AddNumberToObject(o, "days_mask", sch->days_mask);
        cJSON_AddStringToObject(o, "on_time_utc", on);
        cJSON_AddStringToObject(o, "off_time_utc", off);
        cJSON_AddItemToArray(schedulers, o);
    }
    return load;
}

int mqtt_proto_serialize_snapshot(const mqtt_proto_snapshot_t *s, char *out, size_t cap)
{
    if (s == NULL) return -1;
    cJSON *o = new_base();
    if (o == NULL) return -1;
    cJSON_AddStringToObject(o, "type", "SNAPSHOT");
    cJSON_AddStringToObject(o, "boot_id", s->boot_id != NULL ? s->boot_id : "00000000");
    cJSON_AddStringToObject(o, "device_name", s->device_name);
    cJSON_AddStringToObject(o, "net_interface", s->net_interface != NULL ? s->net_interface : "NONE");
    cJSON_AddStringToObject(o, "ssid", s->ssid);
    cJSON_AddStringToObject(o, "ip_address", s->ip_address);
    cJSON_AddNumberToObject(o, "uptime_ms", s->uptime_ms);
    cJSON_AddNumberToObject(o, "telemetry_interval_s", s->telemetry_interval_s);
    if (s->has_ts) cJSON_AddNumberToObject(o, "ts", (double)s->ts_ms);

    cJSON *caps = cJSON_AddObjectToObject(o, "capabilities");
    add_port_list(caps, "rs485", false, false, APP_PORT_RS485_FIRST, APP_RS485_INTERFACE_COUNT);
    add_port_list(caps, "analog_4_20ma", false, true, APP_PORT_ANALOG_FIRST, APP_ANALOG_4_20MA_INTERFACE_COUNT);
    add_port_list(caps, "digital_inputs", true, true, APP_PORT_DI_FIRST, APP_DI_COUNT);
    add_port_list(caps, "loads", false, false, 0U, APP_LOAD_COUNT);

    unsigned rs485_used = 0, analog_used = 0, di_used = 0, loads_used = 0;
    for (uint8_t p = 0; p < APP_SENSOR_INTERFACE_COUNT; p++) {
        if (!s->cfg.sensor[p].configured) continue;
        switch (app_port_interface(p)) {
        case SENSOR_INTERFACE_RS485: rs485_used++; break;
        case SENSOR_INTERFACE_ANALOG_4_20MA: analog_used++; break;
        default: di_used++; break;
        }
    }
    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        if (s->cfg.load[i].enabled) loads_used++;
    }
    cJSON *used = cJSON_AddObjectToObject(o, "runtime_interfaces");
    cJSON_AddNumberToObject(used, "rs485_used", rs485_used);
    cJSON_AddNumberToObject(used, "analog_4_20ma_used", analog_used);
    cJSON_AddNumberToObject(used, "digital_input_used", di_used);
    cJSON_AddNumberToObject(used, "loads_used", loads_used);

    cJSON *inputs = cJSON_AddArrayToObject(o, "input");
    for (uint8_t p = 0; p < APP_SENSOR_INTERFACE_COUNT; p++) {
        const sensor_port_cfg_t *cfg = &s->cfg.sensor[p];
        if (!cfg->configured) continue;
        cJSON *in = cJSON_CreateObject();
        cJSON_AddStringToObject(in, "interface_type", interface_name(p));
        cJSON_AddStringToObject(in, "port_id", app_device_port_name(p));
        cJSON_AddStringToObject(in, "name", cfg->name);
        cJSON_AddBoolToObject(in, "enabled", cfg->enabled);
        if (app_port_interface(p) == SENSOR_INTERFACE_RS485) cJSON_AddNumberToObject(in, "slave_id", cfg->slave_id);
        cJSON_AddBoolToObject(in, "valid", cfg->enabled && s->sample[p].valid != 0U);
        cJSON *names = cJSON_AddArrayToObject(in, "value_names");
        sensor_type_t type = app_port_sensor_type(p);
        for (uint8_t v = 0; v < app_sensor_value_count(type); v++) {
            cJSON_AddItemToArray(names, cJSON_CreateString(app_sensor_value_name(type, v)));
        }
        cJSON_AddItemToArray(inputs, in);
    }

    cJSON *loads = cJSON_AddArrayToObject(o, "loads");
    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) cJSON_AddItemToArray(loads, snapshot_load(s, i));

    cJSON *interlock = cJSON_AddObjectToObject(o, "interlock");
    cJSON_AddBoolToObject(interlock, "tripped", s->interlock_tripped);
    cJSON *emergency = cJSON_AddObjectToObject(o, "emergency");
    cJSON_AddBoolToObject(emergency, "active", s->emergency_active);
    cJSON *errors = cJSON_AddObjectToObject(o, "errors");
    cJSON_AddNumberToObject(errors, "code_mask", s->error_mask);
    add_error_names(cJSON_AddArrayToObject(errors, "messages"), s->error_mask);
    cJSON *heap = cJSON_AddObjectToObject(o, "heap");
    cJSON_AddNumberToObject(heap, "free", s->free_heap);
    cJSON_AddNumberToObject(heap, "min_free", s->min_free_heap);
    cJSON *mqtt = cJSON_AddObjectToObject(o, "mqtt");
    cJSON_AddNumberToObject(mqtt, "reconnects", s->reconnects);
    cJSON_AddNumberToObject(mqtt, "rx_rejected", s->rx_rejected);
    cJSON_AddNumberToObject(mqtt, "tx_fail", s->tx_fail);
    cJSON_AddNumberToObject(mqtt, "telemetry_dropped", s->telemetry_dropped);
    return print_bounded(o, out, cap);
}

static void add_value(cJSON *values, const char *name, const char *unit, double value)
{
    cJSON *v = cJSON_CreateObject();
    cJSON_AddStringToObject(v, "name", name);
    cJSON_AddStringToObject(v, "unit", unit);
    cJSON_AddNumberToObject(v, "value", value);
    cJSON_AddItemToArray(values, v);
}

static void add_sensor_values(cJSON *values, const sensor_sample_t *sample)
{
    switch ((sensor_type_t)sample->sensor_type) {
    case SENSOR_SHT40:
        add_value(values, "Nhiệt độ không khí", "°C", rounded(sample->v1, 10.0));
        add_value(values, "Độ ẩm không khí", "%RH", rounded(sample->v2, 10.0));
        break;
    case SENSOR_DO:
        add_value(values, "Nồng độ oxy hòa tan", "mg/L", rounded(sample->v1, 100.0));
        add_value(values, "Nhiệt độ nước", "°C", rounded(sample->v2, 10.0));
        add_value(values, "Độ bão hòa", "%", rounded(sample->v3, 10.0));
        break;
    case SENSOR_PH:
        add_value(values, "Độ pH", "pH", rounded(sample->v1, 100.0));
        add_value(values, "Nhiệt độ nước", "°C", rounded(sample->v2, 10.0));
        break;
    case SENSOR_ANALOG_4_20MA:
        add_value(values, "Dòng điện", "mA", rounded(sample->v1, 100.0));
        break;
    case SENSOR_DIGITAL_INPUT: {
        cJSON *v = cJSON_CreateObject();
        cJSON_AddStringToObject(v, "name", "Trạng thái");
        cJSON_AddStringToObject(v, "unit", "");
        cJSON_AddBoolToObject(v, "value", sample->v1 >= 0.5f);
        cJSON_AddItemToArray(values, v);
        break;
    }
    }
}

int mqtt_proto_serialize_telemetry(const mqtt_proto_telemetry_t *t, char *out, size_t cap)
{
    if (t == NULL || t->cycle.count > APP_SENSOR_INTERFACE_COUNT) return -1;
    cJSON *o = new_base();
    if (o == NULL) return -1;
    cJSON_AddNumberToObject(o, "seq", t->seq);
    cJSON_AddStringToObject(o, "boot_id", t->boot_id != NULL ? t->boot_id : "00000000");
    cJSON_AddNumberToObject(o, "uptime_ms", t->uptime_ms);
    cJSON_AddBoolToObject(o, "buffered", t->buffered);
    cJSON_AddStringToObject(o, "net_interface", t->net_interface != NULL ? t->net_interface : "NONE");
    if (t->has_ts) cJSON_AddNumberToObject(o, "ts", (double)t->ts_ms);

    cJSON *inputs = cJSON_AddArrayToObject(o, "input");
    for (uint8_t p = 0; p < t->cycle.count; p++) {
        const sensor_port_cfg_t *cfg = &t->cfg.sensor[p];
        const sensor_sample_t *sample = &t->cycle.s[p];
        if (!cfg->configured || !cfg->enabled) continue;    /* disabled sensors are not reported */
        cJSON *in = cJSON_CreateObject();
        cJSON_AddStringToObject(in, "interface_type", interface_name(p));
        cJSON_AddStringToObject(in, "port_id", app_device_port_name(p));
        cJSON_AddStringToObject(in, "name", cfg->name);
        bool valid = sample->valid != 0U;
        cJSON_AddBoolToObject(in, "valid", valid);
        cJSON *values = cJSON_AddArrayToObject(in, "values");
        if (valid) add_sensor_values(values, sample);
        cJSON_AddItemToArray(inputs, in);
    }

    cJSON *errors = cJSON_AddObjectToObject(o, "errors");
    cJSON_AddNumberToObject(errors, "code_mask", t->error_mask);
    add_error_names(cJSON_AddArrayToObject(errors, "messages"), t->error_mask);
    return print_bounded(o, out, cap);
}

int mqtt_proto_serialize_event(const mqtt_event_t *e, const char *boot_id, bool has_ts,
                               int64_t ts_ms, char *out, size_t cap)
{
    static const char *const names[] = {
        "LOAD_CHANGED", "INTERLOCK_TRIPPED", "INTERLOCK_CLEARED", "ERRORS_CHANGED",
        "NET_SWITCHED", "LOW_HEAP", "TIME_SYNCED", "REBOOT", "EMERGENCY_STOP",
    };
    if (e == NULL || (unsigned)e->kind >= sizeof(names) / sizeof(names[0])) return -1;
    cJSON *o = new_base();
    if (o == NULL) return -1;
    cJSON_AddStringToObject(o, "type", "EVENT");
    cJSON_AddStringToObject(o, "event", names[e->kind]);
    cJSON_AddStringToObject(o, "boot_id", boot_id != NULL ? boot_id : "00000000");
    if (has_ts) cJSON_AddNumberToObject(o, "ts", (double)ts_ms);
    switch (e->kind) {
    case MQTT_EVENT_LOAD_CHANGED: {
        const char *id = app_device_load_name((uint8_t)(e->load_id - 1U));
        cJSON_AddStringToObject(o, "load_id", id != NULL ? id : "");
        cJSON_AddBoolToObject(o, "state", e->state);
        cJSON_AddStringToObject(o, "source", e->source);
        break;
    }
    case MQTT_EVENT_INTERLOCK_TRIPPED:
        cJSON_AddNumberToObject(o, "after_s", e->after_s);
        break;
    case MQTT_EVENT_ERRORS_CHANGED:
        cJSON_AddNumberToObject(o, "code_mask", e->code_mask);
        add_error_names(cJSON_AddArrayToObject(o, "added"), e->added);
        add_error_names(cJSON_AddArrayToObject(o, "cleared"), e->cleared);
        break;
    case MQTT_EVENT_NET_SWITCHED:
        cJSON_AddStringToObject(o, "from", e->from);
        cJSON_AddStringToObject(o, "to", e->to);
        break;
    case MQTT_EVENT_LOW_HEAP:
        cJSON_AddNumberToObject(o, "free", e->free_heap);
        cJSON_AddNumberToObject(o, "min_free", e->min_free_heap);
        break;
    case MQTT_EVENT_REBOOT:
        cJSON_AddStringToObject(o, "reason", e->reason);
        break;
    case MQTT_EVENT_EMERGENCY_STOP:
        cJSON_AddStringToObject(o, "source", e->source);
        cJSON_AddNumberToObject(o, "loads_off", e->loads_off);
        break;
    default:
        break;
    }
    return print_bounded(o, out, cap);
}

/* ---- Duplicate window and backoff ---------------------------------------------------------- */

void mqtt_proto_dedupe_init(mqtt_proto_dedupe_t *w)
{
    if (w != NULL) memset(w, 0, sizeof(*w));
}

const mqtt_proto_ack_t *mqtt_proto_dedupe_find(const mqtt_proto_dedupe_t *w, const char *id)
{
    if (w == NULL || !mqtt_proto_valid_cmd_id(id)) return NULL;
    for (size_t i = 0; i < MQTT_PROTO_DEDUPE_WINDOW; i++) {
        if (w->entries[i].occupied && strcmp(w->entries[i].ack.cmd_id, id) == 0) return &w->entries[i].ack;
    }
    return NULL;
}

void mqtt_proto_dedupe_store(mqtt_proto_dedupe_t *w, const mqtt_proto_ack_t *ack)
{
    if (w == NULL || ack == NULL || !ack->has_cmd_id || !mqtt_proto_valid_cmd_id(ack->cmd_id)) return;
    w->entries[w->next].occupied = true;
    w->entries[w->next].ack = *ack;
    w->next = (uint8_t)((w->next + 1U) % MQTT_PROTO_DEDUPE_WINDOW);
}

uint32_t mqtt_proto_backoff_ms(uint32_t attempt, uint32_t random_value, uint32_t base,
                               uint32_t max, uint32_t floor_ms)
{
    if (attempt > 10U) attempt = 10U;
    if (base == 0U || max == 0U) return 0U;
    uint64_t cap = (uint64_t)base << attempt;
    if (cap > max) cap = max;
    uint32_t delay = (uint32_t)(random_value % (uint32_t)(cap + 1U));
    return delay < floor_ms ? floor_ms : delay;
}
