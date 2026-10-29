#include "app_mqtt.h"

#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#include "app_network.h"
#include "app_network_fsm.h"
#include "app_control.h"
#include "app_device.h"
#include "app_mqtt_cmd.h"
#include "app_nvm.h"
#include "esp_crt_bundle.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "app_log.h"
#include "esp_mac.h"
#include "esp_netif_sntp.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "freertos/timers.h"
#include "mqtt_client.h"

#if defined(CONFIG_APP_MQTT_ALLOW_PLAINTEXT) && CONFIG_APP_MQTT_ALLOW_PLAINTEXT
#define APP_MQTT_PLAINTEXT_ALLOWED 1
#else
#define APP_MQTT_PLAINTEXT_ALLOWED 0
#endif

#define MQTT_TASK_STACK 6144U
#define MQTT_WORKER_STACK 9216U
#define MQTT_TASK_PRIORITY 5U
#define MQTT_TASK_CORE 0
#define MQTT_TRANSPORT_BUFFER_SIZE \
    (CONFIG_APP_MQTT_BUFFER_SIZE < MQTT_PROTO_STATUS_MAX ? \
     MQTT_PROTO_STATUS_MAX : CONFIG_APP_MQTT_BUFFER_SIZE)
#define MQTT_CTRL_QUEUE_DEPTH 8U
#define MQTT_SIGNAL_QUEUE_DEPTH 8U
#define MQTT_STOP_TIMEOUT_MS 4500U
#define MQTT_RESET_STOP_MS 250U
#define MQTT_SUBACK_TIMEOUT_MS 5000U
#define MQTT_OFFLINE_DEBOUNCE_MS 10000U
#define MQTT_SNAPSHOT_MIN_GAP_US 300000LL
#define MQTT_TELEMETRY_INTERVAL_MIN_S 5U
#define MQTT_TELEMETRY_INTERVAL_MAX_S 600U
#define MQTT_RX_TOPIC_MAX MQTT_PROTO_TOPIC_MAX
#define MQTT_RX_DATA_MAX MQTT_PROTO_COMMAND_MAX

static const char *TAG = "app_mqtt";

typedef enum {
    MQTT_STATE_STOPPED = 0,
    MQTT_STATE_WAIT_TIME,
    MQTT_STATE_CONNECTING,
    MQTT_STATE_SUBSCRIBING,
    MQTT_STATE_ONLINE,
    MQTT_STATE_BACKOFF
} mqtt_state_t;

typedef enum {
    CTRL_START = 0,
    CTRL_STOP,
    CTRL_SWITCH_BEGIN,
    CTRL_SWITCH_DONE,
    CTRL_NETWORK_LOST,
    CTRL_SHUTDOWN
} ctrl_kind_t;

typedef struct {
    ctrl_kind_t kind;
    TaskHandle_t reply_task;
    net_interface_t from;
    net_interface_t to;
} ctrl_request_t;

typedef enum {
    SIGNAL_CONNECTED = 0,
    SIGNAL_DISCONNECTED,
    SIGNAL_SUBSCRIBED,
    SIGNAL_ERROR,
    SIGNAL_RETRY
} signal_kind_t;

typedef struct {
    signal_kind_t kind;
    int msg_id;
    uint8_t suback;
    bool intentional;
    esp_mqtt_error_codes_t error;
} mqtt_signal_t;

typedef struct {
    uint8_t state;
    uint8_t qos;
    uint8_t retained;
    uint16_t topic_len;
    uint16_t total_len;
    uint16_t received;
    uint8_t oversize;
    char topic[MQTT_RX_TOPIC_MAX];
    char data[MQTT_RX_DATA_MAX + 1U];
} rx_slot_t;

typedef enum {
    MQTT_RX_FREE = 0,
    MQTT_RX_ASSEMBLING,
    MQTT_RX_QUEUED
} rx_slot_state_t;

static esp_mqtt_client_handle_t s_client;
static TaskHandle_t s_task;
static QueueHandle_t s_ctrl_queue;
static QueueHandle_t s_signal_queue;
static QueueHandle_t s_rx_queue;
static QueueHandle_t s_retry_queue;
static TimerHandle_t s_retry_timer;
static TimerHandle_t s_safety_timer;
static portMUX_TYPE s_rx_lock = portMUX_INITIALIZER_UNLOCKED;
static portMUX_TYPE s_name_lock = portMUX_INITIALIZER_UNLOCKED;
static rx_slot_t s_rx_slots[CONFIG_APP_MQTT_RX_SLOTS];
static mqtt_proto_dedupe_t s_dedupe;
static sensor_cycle_t s_latest_cycle;
static bool s_have_latest_cycle;
static int64_t s_telemetry_due_us;
static mqtt_proto_topics_t s_topics;
static app_mqtt_stats_t s_stats;
static mqtt_proto_snapshot_t s_snapshot;
static mqtt_proto_telemetry_t s_telemetry;
static telemetry_slot_t s_flush_slot;
static esp_mqtt_error_codes_t s_last_mqtt_error;
static int s_initialized;
static int s_enabled;
static int s_client_running;
static int s_shutdown;
static int s_tls_mode;
static int s_network_ready;
static int s_sntp_started;
static int s_interlock_due;
static int s_intentional_stop;
static int s_time_synced_seen;
static int s_snapshot_dirty;
static int s_rx_assembling = -1;
static int s_state = MQTT_STATE_STOPPED;
static uint32_t s_backoff_attempt;
static uint32_t s_safety_timeout_s;
static uint32_t s_telemetry_interval_s = APP_NVM_DEFAULT_TELEMETRY_INTERVAL_S;
static uint32_t s_seen_error_mask;
static uint32_t s_pending_sub_msg;
static uint8_t s_suback_mask;
static int64_t s_state_since_us;
static int64_t s_offline_since_us;
static int64_t s_online_since_us;
static int64_t s_flush_due_us;
static int64_t s_snapshot_due_us;
static int64_t s_snapshot_min_us;
static int64_t s_last_low_heap_us;
static bool s_pending_net_event;
static char s_pending_net_from[8];
static char s_pending_net_to[8];
static char s_device_id[13];
static char s_device_name[32];
static char s_boot_id[9];
static const char s_firmware_version[] = "1.0.0";
static char s_broker_host[128];
static uint16_t s_broker_port;
static char s_lwt_payload[160];
static char s_snapshot_payload[MQTT_PROTO_STATUS_MAX + 1U];
static char s_telemetry_payload[MQTT_PROTO_TELEMETRY_MAX + 1U];
static char s_ack_payload[MQTT_PROTO_ACK_MAX + 1U];
static char s_event_payload[MQTT_PROTO_EVENT_MAX + 1U];

static void mqtt_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data);
static void mqtt_worker(void *arg);
static void network_event_cb(app_network_event_t event, net_interface_t from, net_interface_t to,
                             void *ctx);
                             
static void publish_latest_sample(void);

static uint32_t increment(uint32_t *value)
{
    return __atomic_add_fetch(value, 1U, __ATOMIC_RELAXED);
}

static bool time_valid(void)
{
    return g_sys.sys_event_group != NULL &&
           (xEventGroupGetBits(g_sys.sys_event_group) & BIT_TIME_VALID) != 0U;
}

static int64_t current_epoch_ms(void)
{
    struct timeval tv;
    if (!time_valid() || gettimeofday(&tv, NULL) != 0) return 0;
    return (int64_t)tv.tv_sec * 1000LL + tv.tv_usec / 1000LL;
}

static const char *interface_name(net_interface_t iface)
{
    return iface == NET_IF_ETH ? "ETH" : iface == NET_IF_WIFI ? "WIFI" : "NONE";
}

static void set_broker_error(bool value)
{
    uint32_t bit = (uint32_t)SYS_ERR_MQTT_BROKER;
    if (value) __atomic_fetch_or(&g_sys.sys_error_mask, bit, __ATOMIC_RELAXED);
    else __atomic_fetch_and(&g_sys.sys_error_mask, ~bit, __ATOMIC_RELAXED);
}

static esp_err_t parse_broker_uri(const char *uri, char *host, size_t host_capacity, uint16_t *port)
{
    const char *authority;
    const char *end;
    const char *colon = NULL;
    size_t host_length;
    unsigned parsed_port = 0;
    bool tls;

    if (uri == NULL || host == NULL || host_capacity == 0U || port == NULL) return ESP_ERR_INVALID_ARG;
    tls = strncmp(uri, "mqtts://", 8U) == 0;
    if (strncmp(uri, "mqtt://", 7U) == 0) authority = uri + 7;
    else if (tls) authority = uri + 8;
    else return ESP_ERR_INVALID_ARG;
    end = authority + strcspn(authority, "/?#");
    if (authority == end) return ESP_ERR_INVALID_ARG;
    if (memchr(authority, '@', (size_t)(end - authority)) != NULL) return ESP_ERR_INVALID_ARG;
    if (*authority == '[') {
        const char *close = memchr(authority, ']', (size_t)(end - authority));
        if (close == NULL) return ESP_ERR_INVALID_ARG;
        host_length = (size_t)(close - authority - 1);
        authority++;
        if (close + 1 < end) {
            if (close[1] != ':') return ESP_ERR_INVALID_ARG;
            colon = close + 1;
        }
    } else {
        for (const char *p = authority; p < end; p++) if (*p == ':') colon = p;
        host_length = (size_t)((colon != NULL ? colon : end) - authority);
    }
    if (host_length == 0U || host_length >= host_capacity) return ESP_ERR_INVALID_ARG;
    memcpy(host, authority, host_length);
    host[host_length] = '\0';
    *port = tls ? 8883U : 1883U;
    if (colon != NULL) {
        const char *p = colon + 1;
        if (p == end) return ESP_ERR_INVALID_ARG;
        for (; p < end; p++) {
            if (*p < '0' || *p > '9') return ESP_ERR_INVALID_ARG;
            parsed_port = parsed_port * 10U + (unsigned)(*p - '0');
            if (parsed_port > UINT16_MAX) return ESP_ERR_INVALID_ARG;
        }
        if (parsed_port == 0U) return ESP_ERR_INVALID_ARG;
        *port = (uint16_t)parsed_port;
    }
    return ESP_OK;
}

static void sntp_synced_cb(struct timeval *tv)
{
    (void)tv;
    xEventGroupSetBits(g_sys.sys_event_group, BIT_TIME_VALID);
    if (s_task != NULL) xTaskNotifyGive(s_task);
}

static void start_sntp_if_needed(void)
{
    if (s_sntp_started || time_valid()) return;
    esp_sntp_config_t cfg = ESP_NETIF_SNTP_DEFAULT_CONFIG(CONFIG_APP_MQTT_NTP_SERVER);
    cfg.wait_for_sync = false;
    cfg.sync_cb = sntp_synced_cb;
    esp_err_t err = esp_netif_sntp_init(&cfg);
    if (err == ESP_OK) s_sntp_started = 1;
    else if (err != ESP_ERR_INVALID_STATE) ESP_LOGW(TAG, "SNTP init failed: %s", esp_err_to_name(err));
}

static void retry_timer_cb(TimerHandle_t timer)
{
    uint8_t token = 1U;
    (void)timer;
    if (s_retry_queue != NULL) (void)xQueueSend(s_retry_queue, &token, 0);
    if (s_task != NULL) xTaskNotifyGive(s_task);
}

static void safety_timer_cb(TimerHandle_t timer)
{
    (void)timer;
    __atomic_store_n(&s_interlock_due, 1, __ATOMIC_RELAXED);
    if (s_task != NULL) xTaskNotifyGive(s_task);
}

static uint32_t next_backoff_ms(void)
{
    uint32_t attempt = s_backoff_attempt;
    if (attempt > CONFIG_APP_MQTT_MAX_RECONNECT_ATTEMPT) attempt = CONFIG_APP_MQTT_MAX_RECONNECT_ATTEMPT;
    uint32_t delay = mqtt_proto_backoff_ms(attempt, esp_random(),
        CONFIG_APP_MQTT_BACKOFF_BASE_MS, CONFIG_APP_MQTT_BACKOFF_MAX_MS,
        CONFIG_APP_MQTT_BACKOFF_FLOOR_MS);
    if (s_backoff_attempt < 11U) s_backoff_attempt++;
    if (s_tls_mode && (s_last_mqtt_error.esp_tls_cert_verify_flags != 0 ||
                       s_last_mqtt_error.esp_tls_last_esp_err != ESP_OK))
        delay = CONFIG_APP_MQTT_BACKOFF_MAX_MS;
    __atomic_store_n(&s_stats.backoff_ms, delay, __ATOMIC_RELAXED);
    return delay;
}

static void schedule_backoff(void)
{
    uint32_t delay = next_backoff_ms();
    s_state = MQTT_STATE_BACKOFF;
    s_state_since_us = esp_timer_get_time();
    if (xTimerChangePeriod(s_retry_timer, pdMS_TO_TICKS(delay), 0) != pdPASS)
        ESP_LOGE(TAG, "retry timer command queue full");
    ESP_LOGW(TAG, "reconnect attempt scheduled in %u ms", (unsigned)delay);
}

static void ensure_client_start(void)
{
    if (!s_enabled || s_shutdown || !s_network_ready) return;
    start_sntp_if_needed();
    if (s_tls_mode && !time_valid()) {
        if (s_state != MQTT_STATE_WAIT_TIME) s_state_since_us = esp_timer_get_time();
        s_state = MQTT_STATE_WAIT_TIME;
        start_sntp_if_needed();
        return;
    }
    if (s_client_running) {
        if (s_state == MQTT_STATE_WAIT_TIME) {
            s_state = MQTT_STATE_CONNECTING;
            (void)esp_mqtt_client_reconnect(s_client);
        }
        return;
    }
    s_state = MQTT_STATE_CONNECTING;
    s_state_since_us = esp_timer_get_time();
    increment(&s_stats.connect_attempts);
    s_client_running = 1;
    ESP_LOGI(TAG, "Network ready; connecting to broker %s:%u as %s",
             s_broker_host, (unsigned)s_broker_port, s_device_id);
    esp_err_t err = esp_mqtt_client_start(s_client);
    if (err != ESP_OK) {
        s_client_running = 0;
        __atomic_store_n(&s_stats.last_error, MQTT_PROTO_INTERNAL_ERROR, __ATOMIC_RELAXED);
        schedule_backoff();
    }
}

static esp_err_t control_request(ctrl_kind_t kind, net_interface_t from, net_interface_t to,
                                 uint32_t timeout_ms)
{
    ctrl_request_t req = {.kind = kind, .reply_task = xTaskGetCurrentTaskHandle(), .from = from, .to = to};
    uint32_t result = ESP_ERR_TIMEOUT;
    if (s_ctrl_queue == NULL || s_task == NULL) return ESP_ERR_INVALID_STATE;
    (void)xTaskNotifyStateClear(NULL);
    if (xQueueSend(s_ctrl_queue, &req, 0) != pdTRUE) return ESP_ERR_TIMEOUT;
    xTaskNotifyGive(s_task);
    if (xTaskNotifyWait(0, UINT32_MAX, &result, pdMS_TO_TICKS(timeout_ms)) != pdTRUE) return ESP_ERR_TIMEOUT;
    return (esp_err_t)result;
}

static void control_request_async(ctrl_kind_t kind, net_interface_t from, net_interface_t to)
{
    ctrl_request_t req = {.kind = kind, .reply_task = NULL, .from = from, .to = to};
    if (s_ctrl_queue == NULL || xQueueSend(s_ctrl_queue, &req, 0) != pdTRUE) {
        ESP_LOGE(TAG, "MQTT control queue full for request %d", (int)kind);
    } else if (s_task != NULL) xTaskNotifyGive(s_task);
}

static void stop_client(bool graceful, const char *reason)
{
    (void)xTimerStop(s_retry_timer, 0);
    s_intentional_stop = 1;
    if (s_client_running) {
        if (graceful && (xEventGroupGetBits(g_sys.sys_event_group) & BIT_MQTT_CONNECTED)) {
            ESP_LOGI(TAG, "Publishing offline state before stop (%s)", reason != NULL ? reason : "stop");
            (void)esp_mqtt_client_enqueue(s_client, s_topics.status, s_lwt_payload,
                                          (int)strlen(s_lwt_payload), 1, 1, true);
            vTaskDelay(pdMS_TO_TICKS(80));
        }
        esp_err_t err = esp_mqtt_client_stop(s_client);
        if (err != ESP_OK) ESP_LOGW(TAG, "esp_mqtt_client_stop returned %s", esp_err_to_name(err));
    }
    s_client_running = 0;
    xEventGroupClearBits(g_sys.sys_event_group, BIT_MQTT_CONNECTED);
    s_state = MQTT_STATE_STOPPED;
    s_state_since_us = esp_timer_get_time();
    s_intentional_stop = 0;
}

/* esp_mqtt_client_disconnect() is only honoured in the CONNECTED state and may never yield a
 * DISCONNECTED event on a dead link, so session failures do a hard stop and schedule a retry. */
static void abort_session(const char *reason)
{
    ESP_LOGW(TAG, "%s; restarting MQTT session", reason);
    stop_client(false, NULL);
    increment(&s_stats.disconnects);
    __atomic_store_n(&s_stats.online_since_s, 0U, __ATOMIC_RELAXED);
    if (s_offline_since_us == 0) s_offline_since_us = esp_timer_get_time();
    if (s_enabled && s_network_ready && !s_shutdown) {
        schedule_backoff();
        if (xTimerIsTimerActive(s_safety_timer) == pdFALSE)
            (void)xTimerChangePeriod(s_safety_timer, pdMS_TO_TICKS(s_safety_timeout_s * 1000U), 0);
    }
}

static void force_outputs_safe(void)
{
    app_control_interlock_trip(s_safety_timeout_s);
}

/* ---- Publishing ---------------------------------------------------------------------------- */

static void publish_status(const char *payload, int length, bool retain)
{
    if (s_state != MQTT_STATE_ONLINE || length <= 0 || length > MQTT_PROTO_STATUS_MAX) return;
    int id = esp_mqtt_client_enqueue(s_client, s_topics.status, payload, length, 1, retain, true);
    if (id < 0) increment(&s_stats.tx_fail);
    else increment(&s_stats.tx_status);
}

static void make_snapshot(mqtt_proto_snapshot_t *out)
{
    memset(out, 0, sizeof(*out));
    out->boot_id = s_boot_id;
    portENTER_CRITICAL(&s_name_lock);
    strlcpy(out->device_name, s_device_name, sizeof(out->device_name));
    portEXIT_CRITICAL(&s_name_lock);
    out->net_interface = interface_name(app_network_get_active_interface());
    (void)app_network_get_active_details(out->ssid, sizeof(out->ssid), out->ip_address,
                                         sizeof(out->ip_address));
    out->has_ts = time_valid();
    out->ts_ms = current_epoch_ms();
    out->uptime_ms = (uint32_t)(esp_timer_get_time() / 1000LL);
    out->telemetry_interval_s = s_telemetry_interval_s;
    app_device_get(&out->cfg);

    for (uint8_t i = 0; i < APP_LOAD_COUNT; i++) {
        load_runtime_t runtime = {0};
        (void)app_control_get_load_runtime((uint8_t)(i + 1U), &runtime);
        bool feedback_state;
        if (app_control_get_feedback(i, &feedback_state) == ESP_OK) {
            runtime.output = feedback_state;
        }
        out->load[i] = runtime;
    }
    if (s_have_latest_cycle) {
        for (size_t p = 0; p < s_latest_cycle.count && p < APP_SENSOR_INTERFACE_COUNT; p++) {
            out->sample[p] = s_latest_cycle.s[p];
        }
    }
    out->interlock_tripped = (xEventGroupGetBits(g_sys.sys_event_group) & BIT_SYS_INTERLOCK_TRIPPED) != 0U;
    out->emergency_active = app_control_is_estop();
    out->error_mask = __atomic_load_n(&g_sys.sys_error_mask, __ATOMIC_RELAXED);
    out->free_heap = esp_get_free_heap_size();
    out->min_free_heap = esp_get_minimum_free_heap_size();
    out->reconnects = s_stats.disconnects;
    out->rx_rejected = s_stats.rx_rejected;
    out->tx_fail = s_stats.tx_fail;
    out->telemetry_dropped = app_telemetry_buffer_dropped();
}

static void publish_snapshot(const char *why)
{
    int64_t now = esp_timer_get_time();
    make_snapshot(&s_snapshot);
    int n = mqtt_proto_serialize_snapshot(&s_snapshot, s_snapshot_payload, sizeof(s_snapshot_payload));
    if (n <= 0 || n > MQTT_PROTO_STATUS_MAX) {
        increment(&s_stats.tx_fail);
        ESP_LOGW(TAG, "snapshot (%s) does not fit in %u bytes", why, MQTT_PROTO_STATUS_MAX);
        return;
    }
    __atomic_store_n(&s_snapshot_dirty, 0, __ATOMIC_RELAXED);
    s_snapshot_due_us = now + (int64_t)CONFIG_APP_MQTT_SNAPSHOT_PERIOD_S * 1000000LL;
    s_snapshot_min_us = now + MQTT_SNAPSHOT_MIN_GAP_US;
    publish_status(s_snapshot_payload, n, true);
    ESP_LOGI(TAG, "SNAPSHOT tx (%s) %d bytes, retained", why, n);
}

static void publish_event_value(const mqtt_event_t *src)
{
    switch (src->kind) {
    case MQTT_EVENT_LOAD_CHANGED:
        ESP_LOGI(TAG, "EVENT load_changed DO%u state=%d source=%s", (unsigned)src->load_id,
                 (int)src->state, src->source);
        break;
    case MQTT_EVENT_EMERGENCY_STOP:
        ESP_LOGW(TAG, "EVENT emergency_stop loads_off=%u", (unsigned)src->loads_off);
        break;
    default:
        break;
    }
    if (src->kind == MQTT_EVENT_LOAD_CHANGED || src->kind == MQTT_EVENT_EMERGENCY_STOP ||
        src->kind == MQTT_EVENT_INTERLOCK_TRIPPED || src->kind == MQTT_EVENT_INTERLOCK_CLEARED) {
        __atomic_store_n(&s_snapshot_dirty, 1, __ATOMIC_RELAXED);
    }
    if (s_state != MQTT_STATE_ONLINE) return;
    int n = mqtt_proto_serialize_event(src, s_boot_id, time_valid(), current_epoch_ms(),
                                       s_event_payload, sizeof(s_event_payload));
    if (n <= 0) increment(&s_stats.tx_fail);
    else publish_status(s_event_payload, n, false);
}

static void publish_online_state(void)
{
    /* The retained snapshot replaces the broker's retained LWT, which is what marks us online. */
    publish_snapshot("online");
    mqtt_event_t reboot = {.kind = MQTT_EVENT_REBOOT};
    esp_reset_reason_t reset = esp_reset_reason();
    const char *reason = reset == ESP_RST_POWERON ? "power" :
                         (reset == ESP_RST_TASK_WDT || reset == ESP_RST_INT_WDT || reset == ESP_RST_WDT) ? "wdt" :
                         reset == ESP_RST_BROWNOUT ? "brownout" : reset == ESP_RST_PANIC ? "panic" : "sw";
    strlcpy(reboot.reason, reason, sizeof(reboot.reason));
    publish_event_value(&reboot);
    if (s_pending_net_event) {
        mqtt_event_t switched = {.kind = MQTT_EVENT_NET_SWITCHED};
        strlcpy(switched.from, s_pending_net_from, sizeof(switched.from));
        strlcpy(switched.to, s_pending_net_to, sizeof(switched.to));
        publish_event_value(&switched);
        s_pending_net_event = false;
    }
}

static int build_telemetry_json(const telemetry_slot_t *slot, bool buffered, char *out, size_t cap)
{
    if (slot == NULL) return -1;
    memcpy(&s_telemetry.cycle, slot->payload, sizeof(s_telemetry.cycle));
    if (s_telemetry.cycle.count > APP_SENSOR_INTERFACE_COUNT) return -1;
    app_device_get(&s_telemetry.cfg);
    s_telemetry.seq = slot->seq;
    s_telemetry.uptime_ms = slot->uptime_ms;
    s_telemetry.has_ts = slot->ts_ms != 0;
    s_telemetry.ts_ms = slot->ts_ms;
    s_telemetry.buffered = buffered;
    s_telemetry.boot_id = s_boot_id;
    s_telemetry.net_interface = interface_name(app_network_get_active_interface());
    s_telemetry.error_mask = __atomic_load_n(&g_sys.sys_error_mask, __ATOMIC_RELAXED);
    return mqtt_proto_serialize_telemetry(&s_telemetry, out, cap);
}

static void publish_ack_value(mqtt_proto_ack_t *ack)
{
    if (time_valid() && !ack->has_ts) { ack->has_ts = true; ack->ts_ms = current_epoch_ms(); }
    int n = mqtt_proto_serialize_ack(ack, s_boot_id, s_ack_payload, sizeof(s_ack_payload));
    if (n <= 0 || n > MQTT_PROTO_ACK_MAX || s_state != MQTT_STATE_ONLINE) {
        ESP_LOGW(TAG, "ACK tx dropped cmd_id=%s (%s)", ack->has_cmd_id ? ack->cmd_id : "-",
                 s_state != MQTT_STATE_ONLINE ? "offline" : "serialize");
        increment(&s_stats.tx_fail);
        return;
    }
    int id = esp_mqtt_client_enqueue(s_client, s_topics.ack, s_ack_payload, n, 1, 0, true);
    if (id < 0) {
        increment(&s_stats.tx_fail);
        ESP_LOGW(TAG, "ACK tx enqueue failed cmd_id=%s", ack->has_cmd_id ? ack->cmd_id : "-");
    } else {
        increment(&s_stats.tx_ack);
        ESP_LOGI(TAG, "ACK tx cmd=%s cmd_id=%s result=%s code=%s%s%s%s", ack->cmd_name != NULL ? ack->cmd_name : "?",
                 ack->has_cmd_id ? ack->cmd_id : "-", ack->success ? "ok" : "error",
                 mqtt_proto_code_name(ack->code), ack->dup ? " dup" : "",
                 ack->reason[0] ? " reason=" : "", ack->reason);
    }
}

/* ---- Commands ------------------------------------------------------------------------------ */

static void reject_message(mqtt_proto_code_t code, const char *cmd_id, const char *cmd_name,
                           const char *reason)
{
    mqtt_proto_ack_t ack = {0};
    ack.success = false;
    ack.code = code;
    ack.cmd_name = cmd_name;
    ack.has_cmd_id = mqtt_proto_valid_cmd_id(cmd_id);
    if (ack.has_cmd_id) strlcpy(ack.cmd_id, cmd_id, sizeof(ack.cmd_id));
    if (reason != NULL) strlcpy(ack.reason, reason, sizeof(ack.reason));
    ESP_LOGW(TAG, "CMD err cmd=%s cmd_id=%s code=%s reason=%s", cmd_name != NULL ? cmd_name : "?",
             ack.has_cmd_id ? ack.cmd_id : "-", mqtt_proto_code_name(code), ack.reason);
    mqtt_proto_dedupe_store(&s_dedupe, &ack);
    publish_ack_value(&ack);
    increment(&s_stats.rx_rejected);
}

static void handle_command(const rx_slot_t *slot)
{
    static mqtt_cmd_t cmd;
    char reason[MQTT_PROTO_REASON_LEN] = {0};
    const char *name = NULL;
    mqtt_proto_code_t code = mqtt_proto_parse_command(slot->data, slot->total_len, &cmd,
                                                      reason, sizeof(reason), &name);
    ESP_LOGI(TAG, "CMD rx cmd=%s cmd_id=%s len=%u", name != NULL ? name : "?",
             cmd.cmd_id[0] != '\0' ? cmd.cmd_id : "-", (unsigned)slot->total_len);
    if (code != MQTT_PROTO_OK) { reject_message(code, cmd.cmd_id, name, reason); return; }
    if (slot->retained) {
        ESP_LOGW(TAG, "CMD ignored (retained) cmd_id=%s", cmd.cmd_id);
        increment(&s_stats.rx_retained_ignored);
        return;
    }

    const mqtt_proto_ack_t *cached = mqtt_proto_dedupe_find(&s_dedupe, cmd.cmd_id);
    if (cached != NULL) {
        mqtt_proto_ack_t dup = *cached;
        dup.dup = true;
        ESP_LOGW(TAG, "CMD duplicate cmd_id=%s: replaying the earlier ACK", cmd.cmd_id);
        publish_ack_value(&dup);
        increment(&s_stats.rx_dup);
        return;
    }
    if (s_shutdown) { reject_message(MQTT_PROTO_SHUTTING_DOWN, cmd.cmd_id, name, "shutting down"); return; }

    if (cmd.type == MQTT_CMD_GET_TELEMETRY && !s_have_latest_cycle) {
        code = MQTT_PROTO_BUSY;
        (void)snprintf(reason, sizeof(reason), "telemetry not available yet");
    } else {
        code = app_mqtt_cmd_execute(&cmd, reason, sizeof(reason));
    }
    mqtt_proto_ack_t ack = {0};
    ack.success = code == MQTT_PROTO_OK;
    ack.code = code;
    ack.cmd_name = name;
    ack.has_cmd_id = true;
    strlcpy(ack.cmd_id, cmd.cmd_id, sizeof(ack.cmd_id));
    if (!ack.success) strlcpy(ack.reason, reason, sizeof(ack.reason));
    if (ack.success) ESP_LOGI(TAG, "CMD ok cmd=%s cmd_id=%s", name, cmd.cmd_id);
    else ESP_LOGW(TAG, "CMD err cmd=%s cmd_id=%s code=%s reason=%s", name, cmd.cmd_id,
                  mqtt_proto_code_name(code), ack.reason);
    mqtt_proto_dedupe_store(&s_dedupe, &ack);
    publish_ack_value(&ack);
    if (ack.success && cmd.type == MQTT_CMD_GET_TELEMETRY) {
        publish_latest_sample();
    } else if (ack.success) {
        /* The app mirrors the device from the retained snapshot, so send the new state right away. */
        publish_snapshot(name);
    }
}

static void process_rx_slot(uint8_t index)
{
    if (index >= CONFIG_APP_MQTT_RX_SLOTS) return;
    rx_slot_t *slot = &s_rx_slots[index];
    if (slot->state != MQTT_RX_QUEUED) return;
    if (slot->oversize) reject_message(MQTT_PROTO_PAYLOAD_TOO_LARGE, NULL, NULL, "payload too large");
    else {
        slot->data[slot->total_len] = '\0';
        increment(&s_stats.rx_total);
        if (strcmp(slot->topic, s_topics.commands) == 0) handle_command(slot);
    }
    portENTER_CRITICAL(&s_rx_lock);
    memset(slot, 0, sizeof(*slot));
    slot->state = MQTT_RX_FREE;
    if (s_rx_assembling == (int)index) s_rx_assembling = -1;
    portEXIT_CRITICAL(&s_rx_lock);
}

static void process_rx_event(const esp_mqtt_event_t *event)
{
    if (event == NULL || event->data_len < 0 || event->total_data_len < 0 ||
        event->data_len > event->total_data_len) return;
    if (event->retain) { increment(&s_stats.rx_retained_ignored); return; }
    if (event->current_data_offset == 0) {
        if (event->topic == NULL || event->topic_len <= 0 || event->topic_len >= MQTT_RX_TOPIC_MAX) {
            increment(&s_stats.rx_dropped); return;
        }
        int selected = -1;
        portENTER_CRITICAL(&s_rx_lock);
        for (size_t i = 0; i < CONFIG_APP_MQTT_RX_SLOTS; i++) {
            if (s_rx_slots[i].state == MQTT_RX_FREE) {
                selected = (int)i;
                memset(&s_rx_slots[i], 0, sizeof(s_rx_slots[i]));
                s_rx_slots[i].state = MQTT_RX_ASSEMBLING;
                s_rx_assembling = selected;
                break;
            }
        }
        portEXIT_CRITICAL(&s_rx_lock);
        if (selected < 0) { increment(&s_stats.rx_dropped); return; }
        rx_slot_t *slot = &s_rx_slots[selected];
        memcpy(slot->topic, event->topic, (size_t)event->topic_len);
        slot->topic[event->topic_len] = '\0';
        slot->topic_len = (uint16_t)event->topic_len;
        slot->total_len = (uint16_t)(event->total_data_len > UINT16_MAX ? UINT16_MAX : event->total_data_len);
        slot->qos = (uint8_t)event->qos;
        slot->retained = event->retain;
        if ((size_t)event->total_data_len > MQTT_RX_DATA_MAX) {
            slot->oversize = 1U;
            slot->total_len = 0U;
            increment(&s_stats.rx_oversize);
        }
    }
    int selected;
    portENTER_CRITICAL(&s_rx_lock); selected = s_rx_assembling; portEXIT_CRITICAL(&s_rx_lock);
    if (selected < 0 || selected >= (int)CONFIG_APP_MQTT_RX_SLOTS) { increment(&s_stats.rx_dropped); return; }
    rx_slot_t *slot = &s_rx_slots[selected];
    if (slot->state != MQTT_RX_ASSEMBLING || event->current_data_offset != slot->received ||
        (!slot->oversize && (uint32_t)slot->received + (uint32_t)event->data_len > MQTT_RX_DATA_MAX)) {
        portENTER_CRITICAL(&s_rx_lock); memset(slot, 0, sizeof(*slot)); slot->state = MQTT_RX_FREE; s_rx_assembling = -1; portEXIT_CRITICAL(&s_rx_lock);
        increment(&s_stats.rx_dropped);
        return;
    }
    if (!slot->oversize && event->data_len > 0 && event->data != NULL)
        memcpy(slot->data + slot->received, event->data, (size_t)event->data_len);
    slot->received = (uint16_t)(slot->received + event->data_len);
    if (slot->oversize || slot->received >= slot->total_len) {
        uint8_t token = (uint8_t)selected;
        portENTER_CRITICAL(&s_rx_lock); slot->state = MQTT_RX_QUEUED; s_rx_assembling = -1; portEXIT_CRITICAL(&s_rx_lock);
        if (xQueueSend(s_rx_queue, &token, 0) != pdTRUE) {
            portENTER_CRITICAL(&s_rx_lock); memset(slot, 0, sizeof(*slot)); slot->state = MQTT_RX_FREE; portEXIT_CRITICAL(&s_rx_lock);
            increment(&s_stats.rx_dropped);
        }
    }
}

static void mqtt_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base;
    const esp_mqtt_event_t *event = data;
    if (event == NULL) return;
    if (id == MQTT_EVENT_DATA) { process_rx_event(event); if (s_task) xTaskNotifyGive(s_task); return; }
    mqtt_signal_t sig = {0};
    if (id == MQTT_EVENT_CONNECTED) sig.kind = SIGNAL_CONNECTED;
    else if (id == MQTT_EVENT_DISCONNECTED) {
        sig.kind = SIGNAL_DISCONNECTED;
        sig.intentional = s_intentional_stop != 0;
    }
    else if (id == MQTT_EVENT_SUBSCRIBED) {
        sig.kind = SIGNAL_SUBSCRIBED; sig.msg_id = event->msg_id;
        sig.suback = event->data_len > 0 && event->data ? (uint8_t)event->data[0] : 0xffU;
    } else if (id == MQTT_EVENT_ERROR) {
        sig.kind = SIGNAL_ERROR;
        if (event->error_handle != NULL) sig.error = *event->error_handle;
    } else return;
    if (xQueueSend(s_signal_queue, &sig, 0) != pdTRUE) ESP_LOGW(TAG, "MQTT event signal queue full");
    if (s_task != NULL) xTaskNotifyGive(s_task);
}

static void process_signal(const mqtt_signal_t *sig)
{
    switch (sig->kind) {
    case SIGNAL_CONNECTED:
        s_state = MQTT_STATE_SUBSCRIBING;
        s_state_since_us = esp_timer_get_time();
        s_suback_mask = 0;
        ESP_LOGI(TAG, "Connected to broker %s:%u; subscribing to %s",
                 s_broker_host, (unsigned)s_broker_port, s_topics.commands);
        s_pending_sub_msg = (uint32_t)esp_mqtt_client_subscribe_single(s_client, s_topics.commands, 1);
        if (s_pending_sub_msg == UINT32_MAX) {
            increment(&s_stats.tx_fail); abort_session("subscribe enqueue failed");
        }
        break;
    case SIGNAL_SUBSCRIBED:
        if (s_state != MQTT_STATE_SUBSCRIBING) break;
        if (sig->suback == 0x80U) { abort_session("SUBACK rejected"); break; }
        if ((uint32_t)sig->msg_id == s_pending_sub_msg) s_suback_mask |= 1U;
        if (s_suback_mask == 1U) {
            ESP_LOGI(TAG, "SUBACK received: MQTT ONLINE (commands)");
            s_state = MQTT_STATE_ONLINE;
            s_online_since_us = esp_timer_get_time();
            __atomic_store_n(&s_stats.online_since_s, (uint32_t)(s_online_since_us / 1000000LL), __ATOMIC_RELAXED);
            s_offline_since_us = 0;
            s_backoff_attempt = 0;
            increment(&s_stats.connect_ok);
            xEventGroupSetBits(g_sys.sys_event_group, BIT_MQTT_CONNECTED);
            set_broker_error(false);
            app_control_interlock_clear();
            (void)xTimerStop(s_safety_timer, 0);
            publish_online_state();
            s_flush_due_us = esp_timer_get_time();
        }
        break;
    case SIGNAL_DISCONNECTED:
        ESP_LOGW(TAG, "Disconnected from broker (intentional=%d)", (int)sig->intentional);
        xEventGroupClearBits(g_sys.sys_event_group, BIT_MQTT_CONNECTED);
        increment(&s_stats.disconnects);
        __atomic_store_n(&s_stats.online_since_s, 0U, __ATOMIC_RELAXED);
        if (!sig->intentional && s_enabled && s_network_ready) {
            if (s_state == MQTT_STATE_ONLINE && esp_timer_get_time() - s_online_since_us >= 30000000LL)
                s_backoff_attempt = 0;
            s_offline_since_us = esp_timer_get_time();
            __atomic_store_n(&s_stats.online_since_s, 0U, __ATOMIC_RELAXED);
            s_state = MQTT_STATE_BACKOFF;
            schedule_backoff();
            if (xTimerIsTimerActive(s_safety_timer) == pdFALSE)
                (void)xTimerChangePeriod(s_safety_timer, pdMS_TO_TICKS(s_safety_timeout_s * 1000U), 0);
        }
        break;
    case SIGNAL_ERROR:
        ESP_LOGW(TAG, "MQTT error type=%d connect_return_code=%d tls_err=0x%x",
                 (int)sig->error.error_type, (int)sig->error.connect_return_code,
                 (unsigned)sig->error.esp_tls_last_esp_err);
        s_last_mqtt_error = sig->error;
        __atomic_store_n(&s_stats.last_error, (uint32_t)sig->error.error_type, __ATOMIC_RELAXED);
        if (sig->error.error_type == MQTT_ERROR_TYPE_CONNECTION_REFUSED ||
            sig->error.esp_tls_cert_verify_flags != 0 || sig->error.esp_tls_last_esp_err != ESP_OK) {
            set_broker_error(true);
            increment(&s_stats.tx_fail);
            if (s_tls_mode && sig->error.esp_tls_cert_verify_flags != 0)
                __atomic_store_n(&s_stats.backoff_ms, CONFIG_APP_MQTT_BACKOFF_MAX_MS, __ATOMIC_RELAXED);
        }
        break;
    case SIGNAL_RETRY:
        if (s_enabled && s_network_ready && !s_shutdown) {
            if (s_tls_mode && !time_valid()) {
                if (esp_timer_get_time() - s_state_since_us >= (int64_t)CONFIG_APP_MQTT_TLS_TIME_WAIT_S * 1000000LL) {
                    __atomic_store_n(&s_stats.last_error, 1U, __ATOMIC_RELAXED);
                    set_broker_error(true);
                    start_sntp_if_needed();
                    schedule_backoff();
                } else {
                    s_state = MQTT_STATE_WAIT_TIME;
                    start_sntp_if_needed();
                }
            } else if (s_client_running) {
                s_state = MQTT_STATE_CONNECTING;
                (void)esp_mqtt_client_reconnect(s_client);
            } else ensure_client_start();
        }
        break;
    }
}

static void handle_control(const ctrl_request_t *req)
{
    esp_err_t result = ESP_OK;
    switch (req->kind) {
    case CTRL_START:
        s_enabled = 1; s_shutdown = 0;
        s_network_ready = (xEventGroupGetBits(g_sys.sys_event_group) & BIT_NET_ACTIVE_READY) != 0U;
        ensure_client_start();
        break;
    case CTRL_STOP:
        s_enabled = 0; stop_client(false, NULL); break;
    case CTRL_SWITCH_BEGIN:
            s_network_ready = 0; s_backoff_attempt = 0; s_offline_since_us = esp_timer_get_time();
            set_broker_error(false); stop_client(false, NULL);
            if (!app_mqtt_safety_interlock_tripped())
                (void)xTimerChangePeriod(s_safety_timer, pdMS_TO_TICKS(s_safety_timeout_s * 1000U), 0);
            break;
    case CTRL_SWITCH_DONE: {
        s_network_ready = 1; s_backoff_attempt = 0; start_sntp_if_needed(); ensure_client_start();
        strlcpy(s_pending_net_from, interface_name(req->from), sizeof(s_pending_net_from));
        strlcpy(s_pending_net_to, interface_name(req->to), sizeof(s_pending_net_to));
        s_pending_net_event = true;
        break;
    }
    case CTRL_NETWORK_LOST:
        s_network_ready = 0; stop_client(false, NULL); s_offline_since_us = esp_timer_get_time();
        set_broker_error(false);
        if (!app_mqtt_safety_interlock_tripped())
            (void)xTimerChangePeriod(s_safety_timer, pdMS_TO_TICKS(s_safety_timeout_s * 1000U), 0);
        break;
    case CTRL_SHUTDOWN:
        s_enabled = 0; s_shutdown = 1; stop_client(true, "factory_reset"); (void)xTimerStop(s_safety_timer, 0); break;
    }
    if (req->reply_task != NULL) xTaskNotify(req->reply_task, (uint32_t)result, eSetValueWithOverwrite);
}

static void network_event_cb(app_network_event_t event, net_interface_t from, net_interface_t to,
                             void *ctx)
{
    (void)ctx;
    switch (event) {
    case APP_NET_EVENT_SWITCH_BEGIN:
        (void)control_request(CTRL_SWITCH_BEGIN, from, to, MQTT_STOP_TIMEOUT_MS);
        break;
    case APP_NET_EVENT_SWITCH_DONE:
        control_request_async(CTRL_SWITCH_DONE, from, to);
        break;
    case APP_NET_EVENT_LOST:
        control_request_async(CTRL_NETWORK_LOST, from, to);
        break;
    case APP_NET_EVENT_SHUTDOWN:
        (void)app_mqtt_shutdown_for_reset(MQTT_RESET_STOP_MS);
        break;
    case APP_NET_EVENT_PROV_RUNTIME_REQUEST:
        break;
    }
}

/* ---- Periodic work and sensor samples ------------------------------------------------------ */

static void check_periodic(void)
{
    int64_t now = esp_timer_get_time();
    if (s_state == MQTT_STATE_SUBSCRIBING && now - s_state_since_us > MQTT_SUBACK_TIMEOUT_MS * 1000LL) {
        abort_session("SUBACK timeout");
    }
    if (s_state == MQTT_STATE_WAIT_TIME && time_valid()) ensure_client_start();
    if (s_state == MQTT_STATE_WAIT_TIME && now - s_state_since_us > (int64_t)CONFIG_APP_MQTT_TLS_TIME_WAIT_S * 1000000LL) {
        set_broker_error(true); __atomic_store_n(&s_stats.last_error, 1U, __ATOMIC_RELAXED); s_state_since_us = now;
        ESP_LOGW(TAG, "time_not_synced; TLS remains gated and SNTP retry continues");
        start_sntp_if_needed();
    }
    if (s_network_ready && s_offline_since_us != 0 && now - s_offline_since_us >= MQTT_OFFLINE_DEBOUNCE_MS * 1000LL)
        set_broker_error(true);
    if (s_state == MQTT_STATE_ONLINE) {
        bool dirty = __atomic_load_n(&s_snapshot_dirty, __ATOMIC_RELAXED) != 0;
        if (now >= s_snapshot_due_us) publish_snapshot("periodic");
        else if (dirty && now >= s_snapshot_min_us) publish_snapshot("state changed");
    }
    if (s_state == MQTT_STATE_ONLINE && now >= s_flush_due_us && app_telemetry_buffer_peek(&s_flush_slot) == ESP_OK) {
        int n = build_telemetry_json(&s_flush_slot, true, s_telemetry_payload, sizeof(s_telemetry_payload));
        if (n > 0 && n <= MQTT_PROTO_TELEMETRY_MAX &&
            esp_mqtt_client_enqueue(s_client, s_topics.telemetry, s_telemetry_payload, n, 0, 0, true) >= 0) {
            (void)app_telemetry_buffer_pop(); increment(&s_stats.tx_telemetry);
        } else increment(&s_stats.tx_fail);
        s_flush_due_us = now + (int64_t)CONFIG_APP_MQTT_FLUSH_GAP_MS * 1000LL;
    }
    uint32_t heap = esp_get_free_heap_size();
    if (heap < 20U * 1024U && (s_last_low_heap_us == 0 || now - s_last_low_heap_us >= 60000000LL)) {
        s_last_low_heap_us = now;
        mqtt_event_t e = {.kind = MQTT_EVENT_LOW_HEAP, .free_heap = heap,
                          .min_free_heap = esp_get_minimum_free_heap_size()};
        publish_event_value(&e);
    } else if (heap > 24U * 1024U) s_last_low_heap_us = 0;
    if (time_valid() && !s_time_synced_seen) {
        s_time_synced_seen = 1;
        ESP_LOGI(TAG, "Clock synchronised by SNTP: schedules and delay start times are valid now");
        mqtt_event_t e = {.kind = MQTT_EVENT_TIME_SYNCED};
        publish_event_value(&e);
        __atomic_store_n(&s_snapshot_dirty, 1, __ATOMIC_RELAXED);
    }
    uint32_t current_errors = __atomic_load_n(&g_sys.sys_error_mask, __ATOMIC_RELAXED);
    if (current_errors != s_seen_error_mask) {
        mqtt_event_t event = {.kind = MQTT_EVENT_ERRORS_CHANGED, .code_mask = current_errors,
            .added = current_errors & ~s_seen_error_mask,
            .cleared = s_seen_error_mask & ~current_errors};
        s_seen_error_mask = current_errors;
        publish_event_value(&event);
    }
}

/* True when a digital input differs from the previous cycle (validity or on/off level). */
static bool di_changed(const sensor_cycle_t *previous, const sensor_cycle_t *cycle)
{
    for (uint8_t d = 0; d < APP_DI_COUNT; d++) {
        const uint8_t port = (uint8_t)(APP_PORT_DI_FIRST + d);
        if (port >= previous->count || port >= cycle->count) continue;
        const sensor_sample_t *before = &previous->s[port];
        const sensor_sample_t *now = &cycle->s[port];
        if (before->valid != now->valid) return true;
        if (now->valid && (before->v1 >= 0.5f) != (now->v1 >= 0.5f)) return true;
    }
    return false;
}

/* Returns true when a DI changed, so the caller sends telemetry without waiting for the interval. */
static bool publish_sample(const sensor_cycle_t *cycle)
{
    if (cycle->count > APP_SENSOR_INTERFACE_COUNT) { increment(&s_stats.rx_rejected); return false; }
    const bool changed = s_have_latest_cycle && di_changed(&s_latest_cycle, cycle);
    s_latest_cycle = *cycle;
    s_have_latest_cycle = true;
    esp_err_t control_result = app_control_sensor_update(cycle);
    if (control_result != ESP_OK) {
        ESP_LOGW(TAG, "Sensor sample was not queued for load control: %s",
                 esp_err_to_name(control_result));
    }
    app_control_process_feedback(cycle);
    return changed;
}

static void publish_latest_sample(void)
{
    telemetry_slot_t slot;
    if (app_telemetry_buffer_stamp(&s_latest_cycle, &slot) != ESP_OK) { increment(&s_stats.telemetry_dropped); return; }
    if (s_state != MQTT_STATE_ONLINE) {
        if (app_telemetry_buffer_push_slot(&slot) == ESP_OK) increment(&s_stats.telemetry_buffered);
        else increment(&s_stats.telemetry_dropped);
        return;
    }
    int n = build_telemetry_json(&slot, false, s_telemetry_payload, sizeof(s_telemetry_payload));
    if (n <= 0 || n > MQTT_PROTO_TELEMETRY_MAX ||
        esp_mqtt_client_enqueue(s_client, s_topics.telemetry, s_telemetry_payload, n, 0, 0, true) < 0) {
        (void)app_telemetry_buffer_push_slot(&slot);
        increment(&s_stats.telemetry_buffered); increment(&s_stats.tx_fail);
    } else increment(&s_stats.tx_telemetry);
}

static void mqtt_worker(void *arg)
{
    (void)arg;
    s_task = xTaskGetCurrentTaskHandle();
    s_telemetry_due_us = esp_timer_get_time() + (int64_t)s_telemetry_interval_s * 1000000LL;
    esp_err_t wdt_err = esp_task_wdt_add(NULL);
    if (wdt_err != ESP_OK) {
        ESP_LOGE(TAG, "mqtt_client_task WDT registration failed: %s",
                 esp_err_to_name(wdt_err));
        esp_restart();
    }
    for (;;) {
        ctrl_request_t ctrl;
        if (xQueueReceive(s_ctrl_queue, &ctrl, 0) == pdTRUE) handle_control(&ctrl);
        mqtt_signal_t signal;
        while (xQueueReceive(s_signal_queue, &signal, 0) == pdTRUE) process_signal(&signal);
        uint8_t token;
        while (xQueueReceive(s_retry_queue, &token, 0) == pdTRUE) {
            mqtt_signal_t retry = {.kind = SIGNAL_RETRY};
            process_signal(&retry);
            (void)token;
        }
        while (xQueueReceive(s_rx_queue, &token, 0) == pdTRUE) process_rx_slot(token);
        static sensor_cycle_t cycle;
        bool di_event = false;
        if (g_sys.sensor_data_queue != NULL && xQueueReceive(g_sys.sensor_data_queue, &cycle, 0) == pdTRUE) {
            di_event = publish_sample(&cycle);
        }
        int64_t now = esp_timer_get_time();
        if (s_have_latest_cycle && (di_event || now >= s_telemetry_due_us)) {
            publish_latest_sample();
            s_telemetry_due_us = now + (int64_t)s_telemetry_interval_s * 1000000LL;
        }
        mqtt_event_t event;
        while (g_sys.mqtt_event_queue != NULL &&
               xQueueReceive(g_sys.mqtt_event_queue, &event, 0) == pdTRUE)
            publish_event_value(&event);
        if (s_interlock_due) {
            __atomic_store_n(&s_interlock_due, 0, __ATOMIC_RELAXED);
            force_outputs_safe();
        }
        check_periodic();
        (void)esp_task_wdt_reset();
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(50));
    }
}

/* ---- Public API ---------------------------------------------------------------------------- */

esp_err_t app_mqtt_init(const app_config_t *config)
{
    if (s_initialized) return ESP_OK;
    if (config == NULL || g_sys.sys_event_group == NULL || g_sys.sensor_data_queue == NULL ||
        g_sys.mqtt_event_queue == NULL)
        return ESP_ERR_INVALID_ARG;
    if (!mqtt_proto_valid_user_id(config->user_id) || CONFIG_APP_MQTT_BROKER_URI[0] == '\0')
        return ESP_ERR_INVALID_ARG;
    s_tls_mode = strncmp(CONFIG_APP_MQTT_BROKER_URI, "mqtts://", 8U) == 0;
    if (!s_tls_mode && !APP_MQTT_PLAINTEXT_ALLOWED) {
        ESP_LOGE(TAG, "plain MQTT disabled by build policy"); return ESP_ERR_NOT_SUPPORTED;
    }
    esp_err_t err = parse_broker_uri(CONFIG_APP_MQTT_BROKER_URI, s_broker_host, sizeof(s_broker_host), &s_broker_port);
    if (err != ESP_OK) return err;
    strlcpy(s_device_name, config->device_name, sizeof(s_device_name));
    s_safety_timeout_s = config->safety_timeout_s ? config->safety_timeout_s : APP_NVM_DEFAULT_SAFETY_TIMEOUT_S;
    if (s_safety_timeout_s > 86400U) s_safety_timeout_s = APP_NVM_DEFAULT_SAFETY_TIMEOUT_S;
    s_telemetry_interval_s = config->telemetry_interval_s;
    if (s_telemetry_interval_s < MQTT_TELEMETRY_INTERVAL_MIN_S ||
        s_telemetry_interval_s > MQTT_TELEMETRY_INTERVAL_MAX_S) {
        s_telemetry_interval_s = APP_NVM_DEFAULT_TELEMETRY_INTERVAL_S;
    }
    uint8_t mac[6];
    err = esp_read_mac(mac, ESP_MAC_WIFI_STA);
    if (err != ESP_OK) return err;
    snprintf(s_device_id, sizeof(s_device_id), "%02x%02x%02x%02x%02x%02x", mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    if (!mqtt_proto_build_topics(config->user_id, s_device_id, &s_topics)) return ESP_ERR_INVALID_ARG;
    uint32_t boot = esp_random();
    snprintf(s_boot_id, sizeof(s_boot_id), "%08lx", (unsigned long)boot);
    mqtt_proto_dedupe_init(&s_dedupe);

    s_ctrl_queue = xQueueCreate(MQTT_CTRL_QUEUE_DEPTH, sizeof(ctrl_request_t));
    s_signal_queue = xQueueCreate(MQTT_SIGNAL_QUEUE_DEPTH, sizeof(mqtt_signal_t));
    s_rx_queue = xQueueCreate(CONFIG_APP_MQTT_RX_SLOTS, sizeof(uint8_t));
    s_retry_queue = xQueueCreate(2, sizeof(uint8_t));
    if (!s_ctrl_queue || !s_signal_queue || !s_rx_queue || !s_retry_queue)
        return ESP_ERR_NO_MEM;
    s_retry_timer = xTimerCreate("mqtt_retry", pdMS_TO_TICKS(CONFIG_APP_MQTT_BACKOFF_FLOOR_MS), pdFALSE, NULL, retry_timer_cb);
    s_safety_timer = xTimerCreate("mqtt_safety", pdMS_TO_TICKS(s_safety_timeout_s * 1000U), pdFALSE, NULL, safety_timer_cb);
    if (!s_retry_timer || !s_safety_timer) return ESP_ERR_NO_MEM;
    memset(s_rx_slots, 0, sizeof(s_rx_slots));

    int lwt_len = mqtt_proto_serialize_lwt(s_boot_id, s_lwt_payload, sizeof(s_lwt_payload));
    if (lwt_len <= 0) return ESP_FAIL;
    esp_mqtt_client_config_t mc = {
        .broker.address.uri = CONFIG_APP_MQTT_BROKER_URI,
        .credentials.client_id = s_device_id,
        .credentials.username = CONFIG_APP_MQTT_USERNAME[0] ? CONFIG_APP_MQTT_USERNAME : NULL,
        .credentials.authentication.password = CONFIG_APP_MQTT_PASSWORD[0] ? CONFIG_APP_MQTT_PASSWORD : NULL,
        .session.keepalive = CONFIG_APP_MQTT_KEEPALIVE_S,
        .session.disable_clean_session = false,
        .session.last_will.topic = s_topics.status,
        .session.last_will.msg = s_lwt_payload,
        .session.last_will.msg_len = lwt_len,
        .session.last_will.qos = 1,
        .session.last_will.retain = 1,
        .network.disable_auto_reconnect = true,
        .network.timeout_ms = CONFIG_APP_MQTT_CONNECT_TIMEOUT_MS,
        .task.priority = MQTT_TASK_PRIORITY,
        .task.stack_size = MQTT_TASK_STACK,
        .buffer.size = MQTT_TRANSPORT_BUFFER_SIZE,
        .buffer.out_size = MQTT_TRANSPORT_BUFFER_SIZE,
        .outbox.limit = CONFIG_APP_MQTT_OUTBOX_LIMIT,
    };
    if (s_tls_mode) mc.broker.verification.crt_bundle_attach = esp_crt_bundle_attach;
    s_client = esp_mqtt_client_init(&mc);
    if (s_client == NULL) return ESP_FAIL;
    err = esp_mqtt_client_register_event(s_client, ESP_EVENT_ANY_ID, mqtt_event_handler, NULL);
    if (err != ESP_OK) return err;
    if (xTaskCreatePinnedToCore(mqtt_worker, "mqtt_client_task", MQTT_WORKER_STACK, NULL,
        MQTT_TASK_PRIORITY, &s_task, MQTT_TASK_CORE) != pdPASS) return ESP_ERR_NO_MEM;
    err = app_network_register_event_cb(network_event_cb, NULL);
    if (err != ESP_OK) return err;
    s_initialized = 1;
    if (!s_tls_mode) ESP_LOGW(TAG, "DEVELOPMENT ONLY: plaintext public broker; do not send private/control data");
    ESP_LOGI(TAG, "broker=%s:%u client_id=%s firmware=%s boot_id=%s", s_broker_host,
             (unsigned)s_broker_port, s_device_id, s_firmware_version, s_boot_id);
    ESP_LOGI(TAG, "topics: sub=%s | pub=%s %s %s", s_topics.commands, s_topics.ack, s_topics.status,
             s_topics.telemetry);
    return ESP_OK;
}

esp_err_t app_mqtt_start(void)
{
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    return control_request(CTRL_START, NET_IF_NONE, NET_IF_NONE, 500U);
}

esp_err_t app_mqtt_stop(uint32_t timeout_ms)
{
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    return control_request(CTRL_STOP, NET_IF_NONE, NET_IF_NONE, timeout_ms);
}

esp_err_t app_mqtt_shutdown_for_reset(uint32_t timeout_ms)
{
    if (!s_initialized) return ESP_OK;
    return control_request(CTRL_SHUTDOWN, NET_IF_NONE, NET_IF_NONE, timeout_ms);
}

esp_err_t app_mqtt_publish_telemetry(const sensor_cycle_t *data)
{
    if (!s_initialized || data == NULL || data->count > APP_SENSOR_INTERFACE_COUNT) return ESP_ERR_INVALID_ARG;
    if (xQueueSend(g_sys.sensor_data_queue, data, 0) == pdTRUE) return ESP_OK;
    sensor_cycle_t discarded;
    (void)xQueueReceive(g_sys.sensor_data_queue, &discarded, 0);
    increment(&s_stats.telemetry_dropped);
    return xQueueSend(g_sys.sensor_data_queue, data, 0) == pdTRUE ? ESP_OK : ESP_ERR_TIMEOUT;
}

esp_err_t app_mqtt_event_submit(const mqtt_event_t *event)
{
    if (!s_initialized || event == NULL) return ESP_ERR_INVALID_ARG;
    if (xQueueSend(g_sys.mqtt_event_queue, event, 0) != pdTRUE) return ESP_ERR_TIMEOUT;
    if (s_task != NULL) xTaskNotifyGive(s_task);
    return ESP_OK;
}

void app_mqtt_device_name_changed(const char *name)
{
    if (name == NULL) return;
    portENTER_CRITICAL(&s_name_lock);
    strlcpy(s_device_name, name, sizeof(s_device_name));
    portEXIT_CRITICAL(&s_name_lock);
}

void app_mqtt_telemetry_interval_changed(uint32_t interval_s)
{
    if (interval_s < MQTT_TELEMETRY_INTERVAL_MIN_S ||
        interval_s > MQTT_TELEMETRY_INTERVAL_MAX_S) {
        ESP_LOGE(TAG, "refusing invalid telemetry interval: %u s", (unsigned)interval_s);
        return;
    }
    s_telemetry_interval_s = interval_s;
    s_telemetry_due_us = esp_timer_get_time() + (int64_t)interval_s * 1000000LL;
    __atomic_store_n(&s_snapshot_dirty, 1, __ATOMIC_RELAXED);
    ESP_LOGI(TAG, "telemetry interval changed to %u s", (unsigned)interval_s);
}

bool app_mqtt_is_connected(void)
{
    return s_initialized && g_sys.sys_event_group != NULL &&
           (xEventGroupGetBits(g_sys.sys_event_group) & BIT_MQTT_CONNECTED) != 0U;
}

bool app_mqtt_safety_interlock_tripped(void)
{
    return g_sys.sys_event_group != NULL &&
        (xEventGroupGetBits(g_sys.sys_event_group) & BIT_SYS_INTERLOCK_TRIPPED) != 0U;
}

void app_mqtt_get_stats(app_mqtt_stats_t *out)
{
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));
    out->connect_attempts = __atomic_load_n(&s_stats.connect_attempts, __ATOMIC_RELAXED);
    out->connect_ok = __atomic_load_n(&s_stats.connect_ok, __ATOMIC_RELAXED);
    out->disconnects = __atomic_load_n(&s_stats.disconnects, __ATOMIC_RELAXED);
    out->rx_total = __atomic_load_n(&s_stats.rx_total, __ATOMIC_RELAXED);
    out->rx_rejected = __atomic_load_n(&s_stats.rx_rejected, __ATOMIC_RELAXED);
    out->rx_dropped = __atomic_load_n(&s_stats.rx_dropped, __ATOMIC_RELAXED);
    out->rx_retained_ignored = __atomic_load_n(&s_stats.rx_retained_ignored, __ATOMIC_RELAXED);
    out->rx_oversize = __atomic_load_n(&s_stats.rx_oversize, __ATOMIC_RELAXED);
    out->rx_dup = __atomic_load_n(&s_stats.rx_dup, __ATOMIC_RELAXED);
    out->tx_telemetry = __atomic_load_n(&s_stats.tx_telemetry, __ATOMIC_RELAXED);
    out->tx_ack = __atomic_load_n(&s_stats.tx_ack, __ATOMIC_RELAXED);
    out->tx_status = __atomic_load_n(&s_stats.tx_status, __ATOMIC_RELAXED);
    out->tx_fail = __atomic_load_n(&s_stats.tx_fail, __ATOMIC_RELAXED);
    out->ack_dropped = __atomic_load_n(&s_stats.ack_dropped, __ATOMIC_RELAXED);
    out->last_error = __atomic_load_n(&s_stats.last_error, __ATOMIC_RELAXED);
    out->backoff_ms = __atomic_load_n(&s_stats.backoff_ms, __ATOMIC_RELAXED);
    out->online_since_s = __atomic_load_n(&s_stats.online_since_s, __ATOMIC_RELAXED);
    out->telemetry_buffered = (uint32_t)app_telemetry_buffer_count();
    out->telemetry_dropped = app_telemetry_buffer_dropped();
}

const char *app_mqtt_get_broker_host(void) { return s_broker_host; }
uint16_t app_mqtt_get_broker_port(void) { return s_broker_port; }
