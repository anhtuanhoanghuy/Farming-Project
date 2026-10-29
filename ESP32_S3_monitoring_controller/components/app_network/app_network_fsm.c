#include "app_network_fsm.h"

#include <string.h>

#include "app_network_eth.h"
#include "app_network_wifi.h"
#include "app_log.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/dns.h"
#include "lwip/ip_addr.h"
#include "ping/ping_sock.h"

#define TICK_MS                     100U
#define PROBE_TARGET_COUNT          2U
#define PROBE_WATCHDOG_US           (15LL * 1000000LL)
#define PROBE_STOP_GRACE_US         (3LL * 1000000LL)
#define FAILOVER_VERIFY_TIMEOUT_US  (8LL * 1000000LL)
#define ENFORCE_PERIOD_US           (1000LL * 1000LL)
#define VALIDATE_LOCK_WAIT_MS       10000U
#define VALIDATE_DONE_TIMEOUT_MS    8000U
#define PROBE_TASK_PRIORITY         3U
#define MS_TO_US(ms)                ((int64_t)(ms) * 1000LL)

typedef enum {
    FSM_CONNECTING = 0,
    FSM_ACTIVE,
    FSM_FAILOVER,
    FSM_LOST,
    FSM_FACTORY_RESET
} fsm_state_t;

typedef struct {
    portMUX_TYPE lock;
    esp_ping_handle_t sessions[PROBE_TARGET_COUNT];
    uint8_t created;
    uint8_t pending;
    uint32_t requests;
    uint32_t replies;
    uint32_t generation;
    net_interface_t iface;
    SemaphoreHandle_t done_sem; /* NULL: completion is reported by task notification */
} probe_job_t;

typedef struct {
    bool l3;
    bool wan_ok;
    int64_t verdict_us;
    int64_t next_probe_us;
} if_state_t;

static const char *TAG = "net_fsm";

static TaskHandle_t s_task;
static bool s_started;

/* net_mgmt_task-owned state; other tasks only use the atomics and the event group. */
static if_state_t s_if[2]; /* [0] Ethernet, [1] Wi-Fi */
static int s_fsm = FSM_CONNECTING;
static int s_active = NET_IF_NONE;
static int s_prov_runtime;
static uint32_t s_failover_count;
static int64_t s_state_since_us;
static net_interface_t s_verify_target = NET_IF_NONE;
static uint32_t s_eth_streak;
static EventBits_t s_published;
static bool s_prio_checked;
static bool s_eth_started;
static int64_t s_next_eth_init_us;
static int64_t s_next_eth_health_us;
static int64_t s_next_enforce_us;

static probe_job_t s_jobs[2];
static unsigned s_job_index;
static probe_job_t *s_cur;
static int64_t s_probe_started_us;
static int64_t s_probe_stop_started_us;
static uint32_t s_generation;
static int s_open_sessions;
static bool s_probe_stop_requested;
static bool s_probe_faulted;

static portMUX_TYPE s_validate_once = portMUX_INITIALIZER_UNLOCKED;
static StaticSemaphore_t s_validate_lock_buf;
static StaticSemaphore_t s_validate_done_buf;
static SemaphoreHandle_t s_validate_lock;
static SemaphoreHandle_t s_validate_done;
static probe_job_t s_validate_job;

static inline size_t if_idx(net_interface_t iface)
{
    return iface == NET_IF_ETH ? 0U : 1U;
}

static inline net_interface_t other_of(net_interface_t iface)
{
    return iface == NET_IF_ETH ? NET_IF_WIFI : NET_IF_ETH;
}

static inline const char *if_name(net_interface_t iface)
{
    return iface == NET_IF_ETH ? "ETH" : (iface == NET_IF_WIFI ? "WIFI" : "NONE");
}

static inline net_interface_t active_load(void)
{
    return (net_interface_t)__atomic_load_n(&s_active, __ATOMIC_RELAXED);
}

static inline fsm_state_t fsm_load(void)
{
    return (fsm_state_t)__atomic_load_n(&s_fsm, __ATOMIC_RELAXED);
}

static esp_netif_t *netif_of(net_interface_t iface)
{
    return iface == NET_IF_ETH ? app_eth_get_netif_handle() : app_wifi_get_netif_handle();
}

static bool l3_of(net_interface_t iface)
{
    return iface == NET_IF_ETH ? app_eth_w5500_is_connected() : app_wifi_sta_is_connected();
}

static void set_fsm(fsm_state_t state, int64_t now)
{
    static const char *const names[] = {"NET_CONNECTING", "ACTIVE", "FAILOVER", "NET_LOST",
                                        "FACTORY_RESET"};

    if (fsm_load() != state) {
        ESP_LOGI(TAG, "state %s -> %s", names[fsm_load()], names[state]);
    }
    __atomic_store_n(&s_fsm, (int)state, __ATOMIC_RELAXED);
    s_state_since_us = now;
}

/* ---- Isolated ping probes ------------------------------------------------------------------ */

static void probe_on_end(esp_ping_handle_t hdl, void *args)
{
    probe_job_t *job = args;
    uint32_t requests = 0;
    uint32_t replies = 0;

    (void)esp_ping_get_profile(hdl, ESP_PING_PROF_REQUEST, &requests, sizeof(requests));
    (void)esp_ping_get_profile(hdl, ESP_PING_PROF_REPLY, &replies, sizeof(replies));

    portENTER_CRITICAL(&job->lock);
    job->requests += requests;
    job->replies += replies;
    bool last = job->pending > 0U && --job->pending == 0U;
    portEXIT_CRITICAL(&job->lock);

    if (!last) {
        return;
    }
    if (job->done_sem != NULL) {
        xSemaphoreGive(job->done_sem);
    } else {
        xTaskNotify(s_task, job->generation, eSetValueWithOverwrite);
    }
}

static void probe_notify_done(probe_job_t *job)
{
    if (job->done_sem != NULL) {
        xSemaphoreGive(job->done_sem);
    } else {
        xTaskNotify(s_task, job->generation, eSetValueWithOverwrite);
    }
}

static void probe_mark_start_failed(probe_job_t *job)
{
    portENTER_CRITICAL(&job->lock);
    bool last = job->pending > 0U && --job->pending == 0U;
    portEXIT_CRITICAL(&job->lock);
    if (last) {
        probe_notify_done(job);
    }
}

static esp_err_t probe_start(probe_job_t *job, esp_netif_t *netif, net_interface_t iface,
                             uint32_t generation, SemaphoreHandle_t done_sem)
{
    static const char *const targets[PROBE_TARGET_COUNT] = {APP_NET_PROBE_TARGET_1,
                                                             APP_NET_PROBE_TARGET_2};
    int ifindex = esp_netif_get_netif_impl_index(netif);
    esp_err_t last = ESP_FAIL;

    if (ifindex <= 0) {
        return ESP_ERR_INVALID_STATE;
    }

    memset(job, 0, sizeof(*job));
    portMUX_INITIALIZE(&job->lock);
    job->iface = iface;
    job->generation = generation;
    job->done_sem = done_sem;
    s_probe_stop_requested = false;

    const esp_ping_callbacks_t callbacks = {
        .cb_args = job,
        .on_ping_end = probe_on_end,
    };

    for (size_t i = 0; i < PROBE_TARGET_COUNT; i++) {
        esp_ping_config_t config = ESP_PING_DEFAULT_CONFIG();

        config.count = APP_NET_PROBE_COUNT;
        config.interval_ms = APP_NET_PROBE_INTERVAL_MS;
        config.timeout_ms = APP_NET_PROBE_TIMEOUT_MS;
        config.task_prio = PROBE_TASK_PRIORITY;
        config.interface = (uint32_t)ifindex; /* pins the probe to this netif only */
        if (!ipaddr_aton(targets[i], &config.target_addr)) {
            ESP_LOGE(TAG, "bad probe target %s", targets[i]);
            continue;
        }
        last = esp_ping_new_session(&config, &callbacks, &job->sessions[job->created]);
        if (last == ESP_OK) {
            job->created++;
            __atomic_add_fetch(&s_open_sessions, 1, __ATOMIC_RELAXED);
        } else {
            ESP_LOGW(TAG, "ping session for %s failed: %s", targets[i], esp_err_to_name(last));
        }
    }
    if (job->created == 0U) {
        return last == ESP_OK ? ESP_FAIL : last;
    }

    job->pending = job->created; /* set before any session can finish */
    size_t started = 0U;
    esp_err_t start_error = ESP_FAIL;
    for (size_t i = 0; i < job->created; i++) {
        esp_err_t err = esp_ping_start(job->sessions[i]);
        if (err != ESP_OK) {
            start_error = err;
            ESP_LOGW(TAG, "ping start on %s target %u failed: %s", if_name(iface),
                     (unsigned)i, esp_err_to_name(err));
            esp_err_t delete_err = esp_ping_delete_session(job->sessions[i]);
            if (delete_err != ESP_OK) {
                ESP_LOGE(TAG, "could not delete unstarted ping session: %s",
                         esp_err_to_name(delete_err));
                s_probe_faulted = true;
                return delete_err;
            } else {
                job->sessions[i] = NULL;
                __atomic_sub_fetch(&s_open_sessions, 1, __ATOMIC_RELAXED);
            }
            probe_mark_start_failed(job);
        } else {
            started++;
        }
    }
    if (started == 0U) {
        job->pending = 0U;
        return start_error;
    }
    return ESP_OK;
}

static bool probe_release(probe_job_t *job)
{
    bool released = true;
    for (size_t i = 0; i < job->created; i++) {
        if (job->sessions[i] != NULL) {
            esp_err_t err = esp_ping_delete_session(job->sessions[i]);
            if (err != ESP_OK) {
                ESP_LOGE(TAG, "could not delete completed ping session: %s",
                         esp_err_to_name(err));
                released = false;
            } else {
                job->sessions[i] = NULL;
                __atomic_sub_fetch(&s_open_sessions, 1, __ATOMIC_RELAXED);
            }
        }
    }
    if (!released) {
        return false;
    }
    s_probe_stop_requested = false;
    s_probe_stop_started_us = 0;
    ESP_LOGD(TAG, "open ping sessions: %d", __atomic_load_n(&s_open_sessions, __ATOMIC_RELAXED));
    return true;
}

static bool probe_abort_release(probe_job_t *job)
{
    for (size_t i = 0; i < job->created; i++) {
        if (job->sessions[i] != NULL) {
            esp_err_t err = esp_ping_delete_session(job->sessions[i]);
            if (err != ESP_OK) {
                ESP_LOGE(TAG, "could not delete timed-out ping session: %s",
                         esp_err_to_name(err));
                return false;
            }
            job->sessions[i] = NULL;
            __atomic_sub_fetch(&s_open_sessions, 1, __ATOMIC_RELAXED);
        }
    }
    job->pending = 0U;
    return true;
}

/* ---- Interface selection ------------------------------------------------------------------- */

static portMUX_TYPE s_cb_lock = portMUX_INITIALIZER_UNLOCKED;
#define MAX_LISTENERS 4U
static struct {
    app_network_event_cb_t cb;
    void *ctx;
} s_listeners[MAX_LISTENERS];

esp_err_t app_network_register_event_cb(app_network_event_cb_t cb, void *ctx)
{
    esp_err_t err = ESP_ERR_NO_MEM;

    if (cb == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    portENTER_CRITICAL(&s_cb_lock);
    for (size_t i = 0; i < MAX_LISTENERS; i++) {
        if (s_listeners[i].cb == cb && s_listeners[i].ctx == ctx) {
            err = ESP_OK;
            break;
        }
        if (s_listeners[i].cb == NULL) {
            s_listeners[i].cb = cb;
            s_listeners[i].ctx = ctx;
            err = ESP_OK;
            break;
        }
    }
    portEXIT_CRITICAL(&s_cb_lock);
    return err;
}

static void notify_event(app_network_event_t event, net_interface_t from, net_interface_t to)
{
    for (size_t i = 0; i < MAX_LISTENERS; i++) {
        portENTER_CRITICAL(&s_cb_lock);
        app_network_event_cb_t cb = s_listeners[i].cb;
        void *ctx = s_listeners[i].ctx;
        portEXIT_CRITICAL(&s_cb_lock);

        if (cb != NULL) {
            cb(event, from, to, ctx);
        }
    }
}

static bool get_dns_address(esp_netif_t *netif, ip_addr_t *address)
{
    esp_netif_dns_info_t dns;

    if (esp_netif_get_dns_info(netif, ESP_NETIF_DNS_MAIN, &dns) != ESP_OK ||
        dns.ip.type != ESP_IPADDR_TYPE_V4 || dns.ip.u_addr.ip4.addr == 0U) {
        return false;
    }
    ip_addr_set_ip4_u32_val(*address, dns.ip.u_addr.ip4.addr);
    return true;
}

static bool global_dns_matches(const ip_addr_t *expected)
{
    const ip_addr_t *actual = dns_getserver(0);
    return actual != NULL && ip_addr_cmp(actual, expected);
}

static void enter_lost(int64_t now);

static bool restore_route(net_interface_t old, esp_netif_t *old_default,
                          const ip_addr_t *old_dns)
{
    esp_netif_t *rollback_netif = old == NET_IF_NONE ? old_default : netif_of(old);
    esp_err_t err = rollback_netif != NULL || old == NET_IF_NONE ?
                        esp_netif_set_default_netif(rollback_netif) : ESP_ERR_INVALID_STATE;
    bool route_ok = err == ESP_OK && esp_netif_get_default_netif() == rollback_netif;
    if (!route_ok) {
        ESP_LOGE(TAG, "could not restore previous default netif: %s", esp_err_to_name(err));
    }
    dns_setserver(0, old_dns);
    if (!global_dns_matches(old_dns)) {
        ESP_LOGE(TAG, "could not restore global DNS after failed interface switch");
        return false;
    }
    return route_ok;
}

static bool do_switch(net_interface_t target, int64_t now)
{
    esp_netif_t *netif = netif_of(target);
    esp_netif_t *old_default = esp_netif_get_default_netif();
    net_interface_t old = active_load();
    ip_addr_t dns_address;
    bool has_dns;
    const ip_addr_t *current_dns = dns_getserver(0);
    ip_addr_t old_dns = {0};
    if (current_dns != NULL) {
        old_dns = *current_dns;
    }

    if (netif == NULL) {
        ESP_LOGW(TAG, "cannot switch to %s: netif is unavailable", if_name(target));
        return false;
    }
    has_dns = get_dns_address(netif, &dns_address);
    if (!has_dns) {
        ESP_LOGW(TAG, "%s has no IPv4 DNS; keeping the current global DNS", if_name(target));
    }
    notify_event(APP_NET_EVENT_SWITCH_BEGIN, old, target);
    esp_err_t err = esp_netif_set_default_netif(netif);
    if (err != ESP_OK || esp_netif_get_default_netif() != netif) {
        ESP_LOGE(TAG, "set default netif %s failed or did not take effect: %s",
                 if_name(target), esp_err_to_name(err));
        bool restored = restore_route(old, old_default, &old_dns);
        if (restored && old != NET_IF_NONE && s_if[if_idx(old)].l3 &&
            s_if[if_idx(old)].wan_ok) {
            notify_event(APP_NET_EVENT_SWITCH_DONE, old, old);
        } else if (!restored) {
            enter_lost(esp_timer_get_time());
        }
        return false;
    }
    if (has_dns) {
        dns_setserver(0, &dns_address);
        if (!global_dns_matches(&dns_address)) {
            ESP_LOGE(TAG, "global DNS update for %s did not take effect", if_name(target));
            bool restored = restore_route(old, old_default, &old_dns);
            if (restored && old != NET_IF_NONE && s_if[if_idx(old)].l3 &&
                s_if[if_idx(old)].wan_ok) {
                notify_event(APP_NET_EVENT_SWITCH_DONE, old, old);
            } else if (!restored) {
                enter_lost(esp_timer_get_time());
            }
            return false;
        }
    }

    __atomic_store_n(&s_active, (int)target, __ATOMIC_RELAXED);
    if (old != NET_IF_NONE && old != target) {
        __atomic_add_fetch(&s_failover_count, 1U, __ATOMIC_RELAXED);
    }
    s_eth_streak = 0;
    s_verify_target = NET_IF_NONE;
    ESP_LOGI(TAG, "active interface %s -> %s", if_name(old), if_name(target));
    set_fsm(FSM_ACTIVE, now);
    notify_event(APP_NET_EVENT_SWITCH_DONE, old, target);
    return true;
}

static void enter_lost(int64_t now)
{
    net_interface_t old = active_load();

    __atomic_store_n(&s_active, (int)NET_IF_NONE, __ATOMIC_RELAXED);
    s_verify_target = NET_IF_NONE;
    s_eth_streak = 0;
    set_fsm(FSM_LOST, now);
    for (size_t i = 0; i < 2U; i++) {
        s_if[i].next_probe_us = now;
    }
    notify_event(APP_NET_EVENT_LOST, old, NET_IF_NONE);
}

static bool standby_fresh_ok(net_interface_t iface, int64_t now)
{
    const if_state_t *st = &s_if[if_idx(iface)];

    return st->l3 && st->wan_ok && st->verdict_us != 0 &&
           now - st->verdict_us < 2 * MS_TO_US(APP_NET_PROBE_PERIOD_STANDBY_MS);
}

/*
 * Only link/IP loss on the active interface or a failed WAN probe get here. MQTT or broker errors
 * are never an input, so a broker outage cannot trigger a switch (Rule D).
 */
static void begin_failover(const char *reason, int64_t now)
{
    net_interface_t lost = active_load();
    net_interface_t candidate = other_of(lost);

    ESP_LOGW(TAG, "active %s lost: %s", if_name(lost), reason);
    s_if[if_idx(lost)].wan_ok = false;
    s_if[if_idx(lost)].verdict_us = 0;
    set_fsm(FSM_FAILOVER, now);

    if (netif_of(candidate) == NULL || !s_if[if_idx(candidate)].l3) {
        enter_lost(now);
        return;
    }
    if (standby_fresh_ok(candidate, now)) {
        if (!do_switch(candidate, now)) {
            if (fsm_load() != FSM_LOST) {
                enter_lost(now);
            }
        }
        return;
    }
    s_verify_target = candidate;
    s_if[if_idx(candidate)].next_probe_us = now;
}

static int64_t next_period_us(net_interface_t iface, bool ok)
{
    uint32_t ms;

    if (fsm_load() != FSM_ACTIVE) {
        ms = APP_NET_PROBE_PERIOD_RECOVERY_MS;
    } else if (iface == active_load()) {
        ms = ok ? APP_NET_PROBE_PERIOD_ACTIVE_MS : APP_NET_PROBE_PERIOD_RECOVERY_MS;
    } else if (iface == NET_IF_ETH) {
        ms = APP_NET_FAILBACK_PERIOD_MS; /* ETH is the standby while Wi-Fi carries traffic */
    } else {
        ms = APP_NET_PROBE_PERIOD_STANDBY_MS;
    }
    return MS_TO_US(ms);
}

static void on_probe_done(int64_t now)
{
    probe_job_t *job = s_cur;
    net_interface_t iface = job->iface;
    bool ok = job->replies >= 1U;
    uint32_t requests = job->requests;
    uint32_t replies = job->replies;

    if (!probe_release(job)) {
        s_probe_faulted = true;
        s_cur = NULL;
        ESP_LOGE(TAG, "probe sessions could not be released; disabling further probes without reboot");
        return;
    }
    s_cur = NULL;

    if (!s_if[if_idx(iface)].l3) {
        return; /* the interface dropped while probing; refresh_l3() already handled it */
    }

    s_if[if_idx(iface)].wan_ok = ok;
    s_if[if_idx(iface)].verdict_us = now;
    s_if[if_idx(iface)].next_probe_us = now + next_period_us(iface, ok);
    ESP_LOGI(TAG, "WAN probe %s: %s (%u/%u replies)", if_name(iface), ok ? "OK" : "FAIL",
             (unsigned)replies, (unsigned)requests);

    switch (fsm_load()) {
    case FSM_CONNECTING:
    case FSM_LOST:
        if (ok) {
            /* Ethernet wins when both have WAN. */
            net_interface_t best = s_if[0].wan_ok && s_if[0].l3 ? NET_IF_ETH : iface;
            if (!do_switch(best, now)) {
                if (fsm_load() != FSM_LOST) {
                    enter_lost(now);
                }
            }
        }
        break;
    case FSM_ACTIVE:
        if (iface == active_load()) {
            if (!ok) {
                begin_failover("WAN probe failed", now);
            }
        } else if (iface == NET_IF_ETH) {
            /* Failback hysteresis: 5 consecutive OK probes (about 15 s) before returning to ETH. */
            if (!ok) {
                s_eth_streak = 0;
            } else if (++s_eth_streak >= APP_NET_FAILBACK_OK_COUNT) {
                ESP_LOGI(TAG, "ETH stable for %u probes, failing back", (unsigned)s_eth_streak);
                if (!do_switch(NET_IF_ETH, now)) {
                    s_eth_streak = 0U;
                    net_interface_t active = active_load();
                    if (fsm_load() != FSM_LOST &&
                        (active == NET_IF_NONE || !s_if[if_idx(active)].l3 ||
                         !s_if[if_idx(active)].wan_ok)) {
                        enter_lost(now);
                    }
                }
            }
        }
        break;
    case FSM_FAILOVER:
        if (iface == s_verify_target) {
            if (ok) {
                if (!do_switch(iface, now)) {
                    if (fsm_load() != FSM_LOST) {
                        enter_lost(now);
                    }
                }
            } else {
                enter_lost(now);
            }
        }
        break;
    case FSM_FACTORY_RESET:
        break;
    }
}

static void refresh_l3(int64_t now)
{
    static const net_interface_t ifaces[2] = {NET_IF_ETH, NET_IF_WIFI};

    for (size_t i = 0; i < 2U; i++) {
        net_interface_t iface = ifaces[i];
        bool up = netif_of(iface) != NULL && l3_of(iface);

        if (up == s_if[i].l3) {
            continue;
        }
        s_if[i].l3 = up;
        s_if[i].wan_ok = false;
        s_if[i].verdict_us = 0;
        if (iface == NET_IF_ETH) {
            s_eth_streak = 0;
        }
        ESP_LOGI(TAG, "%s L3 %s", if_name(iface), up ? "up" : "down");

        if (up) {
            s_if[i].next_probe_us = now;
        } else if (fsm_load() == FSM_ACTIVE && iface == active_load()) {
            begin_failover("link or IP lost", now); /* immediate, no ping wait */
        } else if (fsm_load() == FSM_FAILOVER && iface == s_verify_target) {
            enter_lost(now);
        }
    }
}

static size_t probe_order(net_interface_t order[2])
{
    switch (fsm_load()) {
    case FSM_FAILOVER:
        order[0] = s_verify_target;
        return 1U;
    case FSM_ACTIVE:
        order[0] = active_load();
        order[1] = other_of(order[0]);
        return 2U;
    default:
        order[0] = NET_IF_ETH;
        order[1] = NET_IF_WIFI;
        return 2U;
    }
}

static void schedule_probe(int64_t now)
{
    net_interface_t order[2];

    if (s_probe_faulted) {
        return;
    }

    if (s_cur != NULL) {
        if (!s_probe_stop_requested && now - s_probe_started_us > PROBE_WATCHDOG_US) {
            ESP_LOGE(TAG, "probe on %s exceeded watchdog; stopping its sessions", if_name(s_cur->iface));
            s_probe_stop_requested = true;
            s_probe_stop_started_us = now;
            for (size_t i = 0; i < s_cur->created; i++) {
                if (s_cur->sessions[i] != NULL) {
                    esp_err_t err = esp_ping_stop(s_cur->sessions[i]);
                    if (err != ESP_OK) {
                        ESP_LOGE(TAG, "could not stop ping session: %s", esp_err_to_name(err));
                    }
                }
            }
        } else if (s_probe_stop_requested &&
                   now - s_probe_stop_started_us > PROBE_STOP_GRACE_US) {
            probe_job_t *job = s_cur;
            net_interface_t iface = job->iface;
            if (!probe_abort_release(job)) {
                s_probe_faulted = true;
                s_cur = NULL;
                s_probe_stop_requested = false;
                s_probe_stop_started_us = 0;
                ESP_LOGE(TAG,
                         "timed-out probe on %s could not be released; disabling further probes "
                         "without rebooting",
                         if_name(iface));
                return;
            }
            s_cur = NULL;
            s_probe_stop_requested = false;
            s_probe_stop_started_us = 0;
            if_state_t *st = &s_if[if_idx(iface)];
            st->wan_ok = false;
            st->verdict_us = now;
            st->next_probe_us = now + MS_TO_US(APP_NET_PROBE_PERIOD_RECOVERY_MS);
            ESP_LOGW(TAG, "probe on %s timed out and was released; treating WAN as failed",
                     if_name(iface));
            if (fsm_load() == FSM_ACTIVE && iface == active_load()) {
                begin_failover("WAN probe timed out", now);
            }
        }
        return;
    }

    size_t count = probe_order(order);
    for (size_t i = 0; i < count; i++) {
        net_interface_t iface = order[i];
        if_state_t *st = &s_if[if_idx(iface)];

        if (!st->l3 || now < st->next_probe_us) {
            continue;
        }
        /* Alternate job slots so a late callback of a dropped probe cannot touch the new one. */
        probe_job_t *job = &s_jobs[s_job_index++ & 1U];
        esp_err_t err = probe_start(job, netif_of(iface), iface, ++s_generation, NULL);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "probe on %s not started: %s", if_name(iface), esp_err_to_name(err));
            st->next_probe_us = now + MS_TO_US(APP_NET_PROBE_PERIOD_RECOVERY_MS);
            continue;
        }
        s_cur = job;
        s_probe_started_us = now;
        return;
    }
}

/* ---- Housekeeping -------------------------------------------------------------------------- */

static void eth_maintenance(int64_t now)
{
    if (!s_eth_started) {
        if (now < s_next_eth_init_us) {
            return;
        }
        s_next_eth_init_us = now + MS_TO_US(APP_NET_ETH_INIT_RETRY_MS);
        esp_err_t err = app_eth_w5500_init();
        if (err == ESP_OK) {
            err = app_eth_w5500_start();
        }
        if (err == ESP_OK) {
            s_eth_started = true;
            (void)__atomic_fetch_and(&g_sys.sys_error_mask,
                                     ~(uint32_t)SYS_ERR_ETH_INIT, __ATOMIC_RELAXED);
            s_next_eth_health_us = now + MS_TO_US(APP_NET_ETH_HEALTH_PERIOD_MS);
        } else {
            (void)__atomic_fetch_or(&g_sys.sys_error_mask,
                                    (uint32_t)SYS_ERR_ETH_INIT, __ATOMIC_RELAXED);
            ESP_LOGW(TAG, "W5500 not available (%s); retrying in %u s", esp_err_to_name(err),
                     (unsigned)(APP_NET_ETH_INIT_RETRY_MS / 1000U));
        }
        return;
    }
    if (app_eth_w5500_is_faulted()) {
        (void)__atomic_fetch_or(&g_sys.sys_error_mask,
                                (uint32_t)SYS_ERR_ETH_INIT, __ATOMIC_RELAXED);
        return;
    }
    if (now < s_next_eth_health_us) {
        return;
    }
    s_next_eth_health_us = now + MS_TO_US(APP_NET_ETH_HEALTH_PERIOD_MS);
    esp_err_t err = app_eth_check_hardware_health();
    if (err == ESP_OK) {
        (void)__atomic_fetch_and(&g_sys.sys_error_mask,
                                 ~(uint32_t)SYS_ERR_ETH_INIT, __ATOMIC_RELAXED);
    } else {
        (void)__atomic_fetch_or(&g_sys.sys_error_mask,
                                (uint32_t)SYS_ERR_ETH_INIT, __ATOMIC_RELAXED);
    }
    if (err != ESP_OK && err != ESP_ERR_INVALID_RESPONSE) {
        ESP_LOGW(TAG, "W5500 health check: %s", esp_err_to_name(err));
    }
}

static void enforce_default_netif(int64_t now)
{
    if (now < s_next_enforce_us) {
        return;
    }
    s_next_enforce_us = now + ENFORCE_PERIOD_US;

    net_interface_t active = active_load();
    esp_netif_t *netif = active == NET_IF_NONE ? NULL : netif_of(active);

    if (netif != NULL && esp_netif_get_default_netif() != netif) {
        ESP_LOGW(TAG, "default netif drifted; restoring %s", if_name(active));
        esp_err_t err = esp_netif_set_default_netif(netif);
        if (err != ESP_OK || esp_netif_get_default_netif() != netif) {
            ESP_LOGE(TAG, "default netif enforcement failed for %s: %s", if_name(active),
                     esp_err_to_name(err));
        }
    }

    if (!s_prio_checked && app_eth_get_netif_handle() != NULL && app_wifi_get_netif_handle() != NULL) {
        s_prio_checked = true;
        int eth_prio = esp_netif_get_route_prio(app_eth_get_netif_handle());
        int wifi_prio = esp_netif_get_route_prio(app_wifi_get_netif_handle());
        ESP_LOGI(TAG, "route_prio ETH=%d Wi-Fi=%d", eth_prio, wifi_prio);
        if (eth_prio <= wifi_prio) {
            ESP_LOGW(TAG, "ETH route_prio is not above Wi-Fi; relying on explicit default netif");
        }
    }
}

static void publish_bits(int64_t now)
{
    net_interface_t active = active_load();
    EventBits_t on = 0;

    if (s_if[0].l3) {
        on |= BIT_NET_ETH_CONNECTED;
    }
    if (s_if[0].l3 && s_if[0].wan_ok) {
        on |= BIT_NET_ETH_WAN_OK;
    }
    if (s_if[1].l3 && s_if[1].wan_ok) {
        on |= BIT_NET_WIFI_WAN_OK;
    }
    if (active != NET_IF_NONE && s_if[if_idx(active)].l3 && s_if[if_idx(active)].wan_ok) {
        on |= BIT_NET_ACTIVE_READY;
        if (standby_fresh_ok(other_of(active), now)) {
            on |= BIT_NET_STANDBY_READY;
        }
    }
    if (fsm_load() == FSM_LOST) {
        on |= BIT_SYS_NET_LOST;
    }

    const EventBits_t managed = BIT_NET_ETH_CONNECTED | BIT_NET_ETH_WAN_OK | BIT_NET_WIFI_WAN_OK |
                                BIT_NET_ACTIVE_READY | BIT_NET_STANDBY_READY | BIT_SYS_NET_LOST;
    if (on != s_published) {
        xEventGroupSetBits(g_sys.sys_event_group, on & ~s_published);
        xEventGroupClearBits(g_sys.sys_event_group, (s_published & managed) & ~on);
        s_published = on;
    }
}

static void handle_commands(int64_t now)
{
    net_cmd_t cmd;

    while (g_sys.net_cmd_queue != NULL && xQueueReceive(g_sys.net_cmd_queue, &cmd, 0) == pdTRUE) {
        switch (cmd) {
        case NET_CMD_START_BLE_PROV_RUNTIME:
            if (fsm_load() == FSM_FACTORY_RESET) {
                break;
            }
            if (__atomic_exchange_n(&s_prov_runtime, 1, __ATOMIC_RELAXED) != 0) {
                ESP_LOGI(TAG, "runtime provisioning already active");
                break;
            }
            ESP_LOGI(TAG, "runtime BLE provisioning requested; network and MQTT stay up");
            notify_event(APP_NET_EVENT_PROV_RUNTIME_REQUEST, active_load(), active_load());
            break;
        case NET_CMD_FACTORY_RESET:
            if (fsm_load() != FSM_FACTORY_RESET) {
                set_fsm(FSM_FACTORY_RESET, now);
                notify_event(APP_NET_EVENT_SHUTDOWN, active_load(), NET_IF_NONE);
            }
            break;
        default:
            break;
        }
    }
}

static void tick(int64_t now)
{
    handle_commands(now);
    if (fsm_load() == FSM_FACTORY_RESET) {
        return; /* the controller is about to restart; stop probing and switching */
    }
    refresh_l3(now);

    if (fsm_load() == FSM_CONNECTING && now - s_state_since_us > MS_TO_US(APP_NET_CONNECT_TIMEOUT_MS)) {
        ESP_LOGW(TAG, "no interface with WAN after %u s", (unsigned)(APP_NET_CONNECT_TIMEOUT_MS / 1000U));
        enter_lost(now);
    } else if (fsm_load() == FSM_FAILOVER && now - s_state_since_us > FAILOVER_VERIFY_TIMEOUT_US) {
        ESP_LOGW(TAG, "standby verification timed out");
        enter_lost(now);
    }

    eth_maintenance(now);
    schedule_probe(now);
    enforce_default_netif(now);
    publish_bits(now);
}

static void net_mgmt_task(void *arg)
{
    (void)arg;
    s_task = xTaskGetCurrentTaskHandle();

    esp_err_t wdt_err = esp_task_wdt_add(NULL);
    if (wdt_err != ESP_OK) {
        ESP_LOGE(TAG, "net_mgmt_task WDT registration failed: %s",
                 esp_err_to_name(wdt_err));
        esp_restart();
    }

    for (;;) {
        uint32_t generation = 0;
        BaseType_t notified = xTaskNotifyWait(0, UINT32_MAX, &generation, pdMS_TO_TICKS(TICK_MS));
        int64_t now = esp_timer_get_time();

        (void)esp_task_wdt_reset();
        if (notified == pdTRUE && s_cur != NULL && s_cur->generation == generation) {
            on_probe_done(now);
        }
        tick(now);
    }
}

esp_err_t app_network_fsm_init(void)
{
    if (s_started) {
        return ESP_OK;
    }
    if (g_sys.sys_event_group == NULL) {
        ESP_LOGE(TAG, "g_sys.sys_event_group is not created");
        return ESP_ERR_INVALID_STATE;
    }

    int64_t now = esp_timer_get_time();
    memset(s_if, 0, sizeof(s_if));
    if (g_sys.net_cmd_queue != NULL) {
        xQueueReset(g_sys.net_cmd_queue); /* drop button presses made before the FSM existed */
    }
    set_fsm(FSM_CONNECTING, now);

    BaseType_t created = xTaskCreatePinnedToCore(net_mgmt_task, "net_mgmt_task",
                                                 APP_NET_TASK_STACK_BYTES, NULL,
                                                 APP_NET_TASK_PRIORITY, &s_task, APP_NET_TASK_CORE);
    if (created != pdPASS) {
        ESP_LOGE(TAG, "net_mgmt_task creation failed");
        return ESP_ERR_NO_MEM;
    }
    s_started = true;
    ESP_LOGI(TAG, "network FSM started");
    return ESP_OK;
}

/* ---- Public getters ------------------------------------------------------------------------ */

net_interface_t app_network_get_active_interface(void)
{
    return active_load();
}

bool app_network_is_wan_connected(void)
{
    if (g_sys.sys_event_group == NULL) {
        return false;
    }
    return (xEventGroupGetBits(g_sys.sys_event_group) & BIT_NET_ACTIVE_READY) != 0U;
}

sys_state_t app_network_get_state(void)
{
    if (fsm_load() == FSM_FACTORY_RESET) {
        return STATE_FACTORY_RESET;
    }
    if (__atomic_load_n(&s_prov_runtime, __ATOMIC_RELAXED) != 0) {
        return STATE_BLE_PROV_RUNTIME;
    }
    switch (fsm_load()) {
    case FSM_ACTIVE:
        if (g_sys.sys_event_group != NULL &&
            (xEventGroupGetBits(g_sys.sys_event_group) & BIT_MQTT_CONNECTED) != 0U) {
            return STATE_OPERATIONAL;
        }
        return STATE_MQTT_CONNECTING;
    case FSM_FAILOVER:
        return STATE_FAILOVER;
    case FSM_LOST:
        return STATE_NET_LOST;
    case FSM_CONNECTING:
    default:
        return STATE_NET_CONNECTING;
    }
}

net_fault_t app_network_get_fault(void)
{
    switch (fsm_load()) {
    case FSM_LOST:
        return NET_FAULT_ALL_DOWN;
    case FSM_FAILOVER:
        return NET_FAULT_WAN_DOWN;
    case FSM_ACTIVE:
        if (app_network_is_wan_connected() && g_sys.sys_event_group != NULL &&
            (xEventGroupGetBits(g_sys.sys_event_group) & BIT_MQTT_CONNECTED) == 0U) {
            return NET_FAULT_BROKER_DOWN;
        }
        return NET_FAULT_NONE;
    case FSM_CONNECTING:
    default:
        return NET_FAULT_NONE;
    }
}

uint32_t app_network_get_failover_count(void)
{
    return __atomic_load_n(&s_failover_count, __ATOMIC_RELAXED);
}

void app_network_prov_runtime_finished(void)
{
    __atomic_store_n(&s_prov_runtime, 0, __ATOMIC_RELAXED);
}

/* ---- BLE provisioning: isolated Wi-Fi WAN check -------------------------------------------- */

static void validate_resources_init(void)
{
    portENTER_CRITICAL(&s_validate_once);
    if (s_validate_lock == NULL) {
        s_validate_lock = xSemaphoreCreateMutexStatic(&s_validate_lock_buf);
        s_validate_done = xSemaphoreCreateBinaryStatic(&s_validate_done_buf);
    }
    portEXIT_CRITICAL(&s_validate_once);
}

esp_err_t app_network_validate_wifi_wan_report(app_wifi_wan_report_t *report)
{
    if (report == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    memset(report, 0, sizeof(*report));
    report->active_interface = active_load();

    esp_netif_t *netif = app_wifi_get_netif_handle();
    if (netif == NULL || !app_wifi_sta_is_connected()) {
        report->status = WIFI_WAN_ERR_NOT_CONNECTED;
        return ESP_ERR_INVALID_STATE;
    }

    validate_resources_init();
    if (xSemaphoreTake(s_validate_lock, pdMS_TO_TICKS(VALIDATE_LOCK_WAIT_MS)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    (void)xSemaphoreTake(s_validate_done, 0);

    esp_err_t err = probe_start(&s_validate_job, netif, NET_IF_WIFI, 0, s_validate_done);
    if (err == ESP_OK) {
        if (xSemaphoreTake(s_validate_done, pdMS_TO_TICKS(VALIDATE_DONE_TIMEOUT_MS)) == pdTRUE) {
            bool ok = s_validate_job.replies >= 1U;

            report->retry_attempts = s_validate_job.requests / s_validate_job.created;
            report->status = ok ? WIFI_WAN_OK : WIFI_WAN_WARN_NO_INTERNET;
            err = ok ? ESP_OK : APP_NETWORK_ERR_WIFI_NO_WAN;
            ESP_LOGI(TAG, "Wi-Fi WAN check: %s (%u/%u replies)", ok ? "OK" : "no internet",
                     (unsigned)s_validate_job.replies, (unsigned)s_validate_job.requests);
        } else {
            ESP_LOGE(TAG, "Wi-Fi WAN check timed out");
            err = ESP_ERR_TIMEOUT;
        }
        probe_release(&s_validate_job);
    }
    xSemaphoreGive(s_validate_lock);
    return err;
}

esp_err_t app_network_validate_wifi_wan(uint32_t *out_retries)
{
    app_wifi_wan_report_t report;
    esp_err_t err = app_network_validate_wifi_wan_report(&report);

    if (out_retries != NULL) {
        *out_retries = report.retry_attempts;
    }
    return err;
}
