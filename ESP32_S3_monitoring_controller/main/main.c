#include "esp_attr.h"
#include "esp_event.h"
#include "app_log.h"
#include "esp_system.h"
#include "nvs.h"

#include "app_ble_prov.h"
#include "app_control.h"
#include "app_device.h"
#include "app_modbus.h"
#include "app_mqtt.h"
#include "app_network.h"
#include "app_network_fsm.h"
#include "app_network_wifi.h"
#include "app_nvm.h"
#include "app_sysmon.h"
#include "main_data_types.h"
#include <string.h>

#define PROV_RESULT_READ_TIMEOUT_MS 30000U
#define PROV_RESPONSE_FLUSH_MS 2000U
#define BLE_START_RETRY_DELAY_MS 5000U
#define RUNTIME_PROV_TIMEOUT_MS APP_BLE_PROV_WINDOW_MS
#define RUNTIME_PROV_TASK_STACK 3072U
#define RUNTIME_PROV_TASK_PRIORITY 4U

static const char *TAG = "main";

sys_context_t g_sys;
static sys_state_t s_state = STATE_INIT;
static app_config_t s_config;
static SemaphoreHandle_t s_config_mutex;
RTC_DATA_ATTR static uint32_t s_pending_startup_error_mask;

static uint32_t init_error_code(esp_err_t err)
{
    return err == ESP_ERR_NO_MEM ? (uint32_t)SYS_ERR_RESOURCE_ALLOC
                                 : (uint32_t)SYS_ERR_INIT_FAILURE;
}

static void record_startup_fault(uint32_t error_mask)
{
    (void)__atomic_fetch_or(&s_pending_startup_error_mask, error_mask, __ATOMIC_RELAXED);
    (void)__atomic_fetch_or(&g_sys.sys_error_mask, error_mask, __ATOMIC_RELAXED);
}

static void create_shared_resources(void)
{
    g_sys.sys_event_group = xEventGroupCreate();
    g_sys.sensor_data_queue = xQueueCreate(4, sizeof(sensor_cycle_t));
    g_sys.mqtt_event_queue = xQueueCreate(16, sizeof(mqtt_event_t));
    g_sys.net_cmd_queue = xQueueCreate(4, sizeof(net_cmd_t));
    g_sys.modbus_uart_mutex = xSemaphoreCreateMutex();
    s_config_mutex = xSemaphoreCreateMutex();

    if (!g_sys.sys_event_group || !g_sys.sensor_data_queue || !g_sys.mqtt_event_queue ||
        !g_sys.net_cmd_queue || !g_sys.modbus_uart_mutex || !s_config_mutex) {
        record_startup_fault((uint32_t)SYS_ERR_RESOURCE_ALLOC);
        ESP_LOGE(TAG, "Failed to allocate shared RTOS resources");
        esp_restart();
    }
    uint32_t pending_errors =
        __atomic_exchange_n(&s_pending_startup_error_mask, 0U, __ATOMIC_RELAXED);
    (void)__atomic_fetch_or(&g_sys.sys_error_mask, pending_errors, __ATOMIC_RELAXED);
}

static bool load_provisioned_config(void)
{
    esp_err_t result = app_nvm_load_config(&s_config);
    if (result == ESP_OK) {
        result = app_nvm_validate_provisioning(&s_config);
    }
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "No valid provisioning config in NVM: %s", esp_err_to_name(result));
        return false;
    }
    return true;
}

/* First-boot provisioning, runs on the BLE worker task: tries the network and builds the result. */
static void prov_apply(const app_config_t *config, app_prov_apply_result_t *result)
{
    app_prov_net_report_t report;

    if (app_network_provision_connect(config, &report) != ESP_OK) {
        result->status = APP_PROV_STATUS_ERROR;
        result->code = "ERR_INTERNAL";
        return;
    }
    result->attempts = report.wifi_attempts;

    switch (report.outcome) {
    case APP_PROV_NET_OK:
        result->status = APP_PROV_STATUS_SUCCESS;
        result->message = "Connected";
        result->save_config = true;
        break;
    case APP_PROV_NET_WIFI_FAILED_ETH_OK:
        result->status = APP_PROV_STATUS_WARNING;
        result->code = "ERR_WIFI_CONNECT_FAILED";
        result->reason = report.wifi_reason;
        result->message = "Wi-Fi failed, running on Ethernet";
        result->save_config = true;
        break;
    case APP_PROV_NET_ETH_FAILED:
        result->status = APP_PROV_STATUS_ERROR;
        result->code = "ERR_ETH_NO_LINK";
        result->reason = "no_ip";
        result->message = "Ethernet has no link or IP";
        break;
    case APP_PROV_NET_NONE:
    default:
        result->status = APP_PROV_STATUS_ERROR;
        result->code = "ERR_WIFI_CONNECT_FAILED";
        result->reason = report.wifi_reason;
        result->message = "Wi-Fi failed and Ethernet is not available";
        break;
    }
}

/* Runtime provisioning: the running network is never disturbed and failures keep the old config. */
static void prov_apply_runtime(const app_config_t *config, app_prov_apply_result_t *result)
{
    app_prov_net_report_t report;
    app_config_t current;

    xSemaphoreTake(s_config_mutex, portMAX_DELAY);
    current = s_config;
    xSemaphoreGive(s_config_mutex);

    if (app_network_runtime_apply(config, &current, &report) != ESP_OK) {
        result->status = APP_PROV_STATUS_ERROR;
        result->code = "ERR_INTERNAL";
        return;
    }
    result->attempts = report.wifi_attempts;

    switch (report.outcome) {
    case APP_PROV_NET_OK:
        result->status = APP_PROV_STATUS_SUCCESS;
        result->message = "Connected";
        result->save_config = true;
        break;
    case APP_PROV_NET_WIFI_BUSY:
        result->status = APP_PROV_STATUS_ERROR;
        result->code = "ERR_WIFI_ACTIVE_BUSY";
        result->reason = "wifi_is_active_interface";
        result->message = "Could not disconnect the active Wi-Fi connection";
        break;
    case APP_PROV_NET_ETH_FAILED:
        result->status = APP_PROV_STATUS_ERROR;
        result->code = "ERR_ETH_NO_LINK";
        result->reason = "no_ip";
        result->message = "Ethernet has no link or IP";
        break;
    default:
        result->status = APP_PROV_STATUS_ERROR;
        result->code = "ERR_WIFI_CONNECT_FAILED";
        result->reason = report.wifi_reason;
        result->message = "Wi-Fi failed, previous settings kept";
        break;
    }
}

static void runtime_prov_task(void *arg)
{
    (void)arg;
    bool mqtt_owner_changed = false;

    app_sysmon_set_provisioning_indicator(true);
    ESP_LOGI(TAG, "Runtime BLE provisioning started (%u s window)",
             (unsigned)(RUNTIME_PROV_TIMEOUT_MS / 1000U));
    /* Scanning must always be possible: the radio is switched on even in Ethernet-only mode. */
    esp_err_t radio = app_network_wifi_radio_on();
    if (radio != ESP_OK) {
        ESP_LOGW(TAG, "Wi-Fi radio unavailable, scan will fail: %s", esp_err_to_name(radio));
    }
    app_ble_prov_set_scan_enabled(radio == ESP_OK);
    xEventGroupClearBits(g_sys.sys_event_group, BIT_PROV_DONE | BIT_PROV_RESULT_SENT);

    esp_err_t result = app_ble_prov_start(g_sys.sys_event_group, prov_apply_runtime);
    if (result != ESP_OK) {
        ESP_LOGE(TAG, "Runtime BLE provisioning could not start: %s", esp_err_to_name(result));
    } else {
        EventBits_t bits = xEventGroupWaitBits(g_sys.sys_event_group, BIT_PROV_DONE, pdTRUE,
                                               pdFALSE, pdMS_TO_TICKS(RUNTIME_PROV_TIMEOUT_MS));
        ESP_ERROR_CHECK(app_ble_prov_stop_advertising());
        if ((bits & BIT_PROV_DONE) == 0U && app_ble_prov_is_busy()) {
            bits = xEventGroupWaitBits(g_sys.sys_event_group, BIT_PROV_DONE, pdTRUE,
                                       pdFALSE, portMAX_DELAY);
        }
        if ((bits & BIT_PROV_DONE) != 0U) {
            (void)xEventGroupWaitBits(g_sys.sys_event_group, BIT_PROV_RESULT_SENT, pdTRUE, pdFALSE,
                                      pdMS_TO_TICKS(PROV_RESULT_READ_TIMEOUT_MS));
            vTaskDelay(pdMS_TO_TICKS(PROV_RESPONSE_FLUSH_MS));
            app_config_t saved_config;
            esp_err_t load_result = app_nvm_load_config(&saved_config);
            if (load_result == ESP_OK) {
                xSemaphoreTake(s_config_mutex, portMAX_DELAY);
                mqtt_owner_changed = strncmp(saved_config.user_id, s_config.user_id,
                                              sizeof(saved_config.user_id)) != 0;
                s_config = saved_config;
                xSemaphoreGive(s_config_mutex);
                ESP_LOGI(TAG, "Runtime provisioning config reloaded (%s)",
                         saved_config.only_use_ethernet ? "Ethernet only" : "Ethernet + Wi-Fi");
            } else {
                ESP_LOGE(TAG, "Could not reload runtime provisioning config: %s",
                         esp_err_to_name(load_result));
                app_sysmon_error_mask_update((uint32_t)SYS_ERR_NVM_FAIL, 0U);
            }
        } else {
            ESP_LOGW(TAG, "Runtime BLE provisioning timed out");
        }
        ESP_ERROR_CHECK(app_ble_prov_stop());
    }

    if (mqtt_owner_changed) {
        ESP_LOGI(TAG, "MQTT owner changed; restarting to apply account topics");
        esp_restart();
    }

    app_ble_prov_set_scan_enabled(true);
    app_sysmon_set_provisioning_indicator(false);
    xSemaphoreTake(s_config_mutex, portMAX_DELAY);
    app_network_wifi_radio_restore(&s_config);
    xSemaphoreGive(s_config_mutex);
    app_network_prov_runtime_finished();
    ESP_LOGI(TAG, "Runtime BLE provisioning ended");
    vTaskDelete(NULL);
}

/* Runs on net_mgmt_task, so it only spawns the session task. */
static void main_network_event_cb(app_network_event_t event, net_interface_t from,
                                  net_interface_t to, void *ctx)
{
    (void)from;
    (void)to;
    (void)ctx;

    if (event != APP_NET_EVENT_PROV_RUNTIME_REQUEST) {
        return;
    }
    if (xTaskCreatePinnedToCore(runtime_prov_task, "prov_runtime", RUNTIME_PROV_TASK_STACK, NULL,
                                RUNTIME_PROV_TASK_PRIORITY, NULL, 0) != pdPASS) {
        ESP_LOGE(TAG, "Runtime provisioning task could not be created");
        app_sysmon_set_provisioning_indicator(false);
        app_network_prov_runtime_finished();
    }
}

static void run_ble_provisioning(void)
{
    s_state = STATE_BLE_PROV;
    app_sysmon_set_provisioning_indicator(true);

    /* The Wi-Fi driver must be up for the wifi-scan endpoint. */
    esp_err_t result = app_wifi_sta_init();
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Wi-Fi unavailable, scan endpoint will fail: %s", esp_err_to_name(result));
    }

    for (;;) {
        xEventGroupClearBits(g_sys.sys_event_group, BIT_PROV_DONE | BIT_PROV_RESULT_SENT);
        xQueueReset(g_sys.net_cmd_queue);
        result = app_ble_prov_start(g_sys.sys_event_group, prov_apply);
        if (result != ESP_OK) {
            ESP_LOGE(TAG, "BLE provisioning could not start: %s", esp_err_to_name(result));
            vTaskDelay(pdMS_TO_TICKS(BLE_START_RETRY_DELAY_MS));
            esp_restart();
        }

        ESP_LOGI(TAG, "Waiting for BLE provisioning (300 s window)");
        EventBits_t done = xEventGroupWaitBits(g_sys.sys_event_group, BIT_PROV_DONE, pdTRUE,
                                               pdFALSE, pdMS_TO_TICKS(APP_BLE_PROV_WINDOW_MS));
        ESP_ERROR_CHECK(app_ble_prov_stop_advertising());
        /* A request accepted just before expiry must finish before the worker is freed. */
        if ((done & BIT_PROV_DONE) == 0U && app_ble_prov_is_busy()) {
            done = xEventGroupWaitBits(g_sys.sys_event_group, BIT_PROV_DONE, pdTRUE,
                                       pdFALSE, portMAX_DELAY);
        }
        if ((done & BIT_PROV_DONE) != 0U) {
            EventBits_t sent = xEventGroupWaitBits(g_sys.sys_event_group, BIT_PROV_RESULT_SENT,
                                                   pdTRUE, pdFALSE,
                                                   pdMS_TO_TICKS(PROV_RESULT_READ_TIMEOUT_MS));
            if ((sent & BIT_PROV_RESULT_SENT) == 0U) {
                ESP_LOGW(TAG, "App did not read the provisioning result in time");
            }
            vTaskDelay(pdMS_TO_TICKS(PROV_RESPONSE_FLUSH_MS));
        }
        ESP_ERROR_CHECK(app_ble_prov_stop());
        if (load_provisioned_config()) {
            app_sysmon_set_provisioning_indicator(false);
            return;
        }

        xQueueReset(g_sys.net_cmd_queue);
        ESP_LOGI(TAG, "Provisioning closed; hold the user button to reopen");
        net_cmd_t command;
        do {
            (void)xQueueReceive(g_sys.net_cmd_queue, &command, portMAX_DELAY);
        } while (command != NET_CMD_START_BLE_PROV_RUNTIME);
    }
}

void app_main(void)
{
    create_shared_resources();
    esp_err_t event_loop_result = esp_event_loop_create_default();
    if (event_loop_result != ESP_OK && event_loop_result != ESP_ERR_INVALID_STATE) {
        record_startup_fault(init_error_code(event_loop_result));
        ESP_LOGE(TAG, "Default event loop init failed: %s",
                 esp_err_to_name(event_loop_result));
        esp_restart();
    }

    esp_err_t sysmon_result = app_sysmon_wdt_init();
    if (sysmon_result != ESP_OK) {
        record_startup_fault(init_error_code(sysmon_result));
        ESP_LOGE(TAG, "Task watchdog could not be configured: %s",
                 esp_err_to_name(sysmon_result));
        esp_restart();
    }

    esp_err_t nvm_result = app_nvm_init();
    if (nvm_result != ESP_OK) {
        ESP_LOGE(TAG, "NVM unavailable (%s); provisioning cannot be stored",
                 esp_err_to_name(nvm_result));
        app_sysmon_error_mask_update((uint32_t)SYS_ERR_NVM_FAIL, 0U);
    }
    if (nvm_result == ESP_OK) {
        app_diagnostic_record_t diagnostics;
        esp_err_t diagnostics_result = app_nvm_load_diagnostics(&diagnostics);
        if (diagnostics_result != ESP_OK && diagnostics_result != ESP_ERR_NVS_NOT_FOUND) {
            ESP_LOGW(TAG, "Diagnostic history load failed: %s",
                     esp_err_to_name(diagnostics_result));
            memset(&diagnostics, 0, sizeof(diagnostics));
        }
        diagnostics.boot_count++;
        diagnostics.reset_reason = (uint32_t)esp_reset_reason();
        diagnostics.uptime_ms = 0U;
        diagnostics_result = app_nvm_save_diagnostics(&diagnostics);
        if (diagnostics_result != ESP_OK) {
            ESP_LOGW(TAG, "Diagnostic history boot record failed: %s",
                     esp_err_to_name(diagnostics_result));
        }
    }

    esp_err_t config_load_result = app_nvm_load_config(&s_config);
    if (config_load_result != ESP_OK && config_load_result != ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "Config load failed (%s); starting with safe defaults",
                 esp_err_to_name(config_load_result));
        app_sysmon_error_mask_update((uint32_t)SYS_ERR_NVM_FAIL, 0U);
        app_nvm_set_default_config(&s_config);
    }

    /* Sensors and loads: every relay is driven low before the engine starts. */
    esp_err_t device_result = app_device_init();
    if (device_result != ESP_OK) {
        record_startup_fault(init_error_code(device_result));
        ESP_LOGE(TAG, "Device config could not start: %s", esp_err_to_name(device_result));
        esp_restart();
    }
    esp_err_t control_result = app_control_init();
    if (control_result != ESP_OK) {
        record_startup_fault(init_error_code(control_result));
        ESP_LOGE(TAG, "Load control could not establish safe relay outputs: %s",
                 esp_err_to_name(control_result));
        esp_restart();
    }

    /* The button must work in every state, including first-boot provisioning. */
    sysmon_result = app_sysmon_init();
    if (sysmon_result != ESP_OK) {
        record_startup_fault(init_error_code(sysmon_result));
        ESP_LOGE(TAG, "Button monitor failed to start: %s", esp_err_to_name(sysmon_result));
        esp_restart();
    }

    if (nvm_result != ESP_OK || !load_provisioned_config()) {
        run_ble_provisioning();
    }

    esp_err_t modbus_result = app_modbus_init();
    if (modbus_result != ESP_OK) {
        ESP_LOGE(TAG, "Modbus or digital-input initialization reported an error: %s",
                 esp_err_to_name(modbus_result));
        app_sysmon_error_mask_update(init_error_code(modbus_result), 0U);
    }
    modbus_result = app_modbus_start_task();
    if (modbus_result != ESP_OK) {
        ESP_LOGE(TAG, "Sensor polling could not start: %s", esp_err_to_name(modbus_result));
        app_sysmon_error_mask_update(init_error_code(modbus_result), 0U);
    }

    s_state = STATE_NET_CONNECTING;
    esp_err_t net_result = app_network_start(g_sys.sys_event_group, &s_config);
    if (net_result != ESP_OK) {
        ESP_LOGE(TAG, "Network start failed: %s", esp_err_to_name(net_result));
        app_sysmon_error_mask_update(init_error_code(net_result), 0U);
    }
    (void)app_network_register_event_cb(main_network_event_cb, NULL);
    net_result = app_network_fsm_init();
    if (net_result != ESP_OK) {
        ESP_LOGE(TAG, "Network FSM start failed: %s", esp_err_to_name(net_result));
        app_sysmon_error_mask_update(init_error_code(net_result), 0U);
    }

    esp_err_t mqtt_result = app_mqtt_init(&s_config);
    if (mqtt_result == ESP_OK) {
        mqtt_result = app_mqtt_start();
        if (mqtt_result != ESP_OK) {
            ESP_LOGE(TAG, "MQTT start failed: %s", esp_err_to_name(mqtt_result));
            app_sysmon_error_mask_update((uint32_t)SYS_ERR_MQTT_BROKER, 0U);
        }
    } else {
        ESP_LOGW(TAG, "MQTT init failed: %s", esp_err_to_name(mqtt_result));
        uint32_t error = mqtt_result == ESP_ERR_INVALID_ARG
                             ? (uint32_t)SYS_ERR_MQTT_BROKER
                             : init_error_code(mqtt_result);
        app_sysmon_error_mask_update(error, 0U);
    }
    ESP_LOGI(TAG, "State: %d", (int)s_state);
}
