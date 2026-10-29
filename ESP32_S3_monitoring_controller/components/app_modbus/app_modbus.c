#include "app_modbus.h"
#include "app_modbus_proto.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

#include "app_device.h"
#include "app_control.h"
#include "app_sysmon.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "app_log.h"
#include "esp_attr.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define MODBUS_UART_PORT              UART_NUM_1
#define MODBUS_BAUD_RATE              4800
#define MODBUS_RESPONSE_TIMEOUT_MS    200U
#define MODBUS_RETRY_COUNT            3U
#define MODBUS_RETRY_DELAY_MS         50U
#define MODBUS_OFFLINE_FAIL_THRESHOLD 5U
#define MODBUS_OFFLINE_PROBE_US       (10LL * 1000000LL)
#define MODBUS_INTER_FRAME_DELAY_MS   50U
#define MODBUS_POLL_INTERVAL_MS       5000U /* start-to-start sensor cycle period */
#define MODBUS_TASK_STACK_BYTES       4096U
#define MODBUS_TASK_PRIORITY          5U
#define MODBUS_TASK_CORE              1
#define MODBUS_RX_BUFFER_SIZE         256U
#define MODBUS_TX_BUFFER_SIZE         256U /* must exceed the 128-byte UART hardware FIFO */
#define MODBUS_MAX_REGISTER_COUNT     6U
#define DI_BUTTON_QUEUE_LENGTH        16U
#define DI_BUTTON_DEBOUNCE_MS         40U
#define DI_BUTTON_TASK_STACK_BYTES    4096U
#define DI_BUTTON_TASK_PRIORITY       6U

static const char *TAG = "app_modbus";

static const gpio_num_t s_di_pins[APP_DI_COUNT] = {
    APP_PIN_DI_1, APP_PIN_DI_2, APP_PIN_DI_3, APP_PIN_DI_4,
};

static TaskHandle_t s_task;
static TaskHandle_t s_di_button_task;
static QueueHandle_t s_di_button_queue;
static bool s_initialized;
static bool s_uart_installed;
static bool s_di_button_isr_ready;
static uint32_t s_cycle_sequence;
static volatile uint32_t s_suspend_requested;

typedef struct {
    uint8_t di_index;
    TickType_t tick;
} di_button_event_t;

static void IRAM_ATTR di_button_isr(void *arg)
{
    const di_button_event_t event = {
        .di_index = (uint8_t)(uintptr_t)arg,
        .tick = xTaskGetTickCountFromISR(),
    };
    BaseType_t higher_priority_task_woken = pdFALSE;
    (void)xQueueSendFromISR(s_di_button_queue, &event, &higher_priority_task_woken);
    if (higher_priority_task_woken == pdTRUE) portYIELD_FROM_ISR();
}

static void di_button_task(void *arg)
{
    (void)arg;
    TickType_t last_press[APP_DI_COUNT] = {0};
    bool have_last_press[APP_DI_COUNT] = {false};
    const TickType_t debounce_ticks = pdMS_TO_TICKS(DI_BUTTON_DEBOUNCE_MS);

    for (;;) {
        di_button_event_t event;
        if (xQueueReceive(s_di_button_queue, &event, portMAX_DELAY) != pdTRUE ||
            event.di_index >= APP_DI_COUNT) {
            continue;
        }
        if (have_last_press[event.di_index] &&
            (TickType_t)(event.tick - last_press[event.di_index]) < debounce_ticks) {
            continue;
        }

        vTaskDelay(debounce_ticks);
        if (gpio_get_level(s_di_pins[event.di_index]) != 0) continue;

        have_last_press[event.di_index] = true;
        last_press[event.di_index] = event.tick;
        const ctl_result_t result = app_control_process_button_di(event.di_index);
        if (result != CTL_OK && result != CTL_ERR_NOT_FOUND) {
            ESP_LOGW(TAG, "DI%u button command failed: %s", (unsigned)(event.di_index + 1U),
                     app_control_result_reason(result));
        }
    }
}

/* Trạng thái circuit breaker của từng slot; chỉ task thu thập truy cập. */
typedef struct {
    uint8_t consecutive_fail_count;
    bool offline;
    int64_t next_probe_us;
} slot_health_t;

uint16_t app_modbus_crc16(const uint8_t *data, size_t length)
{
    if (data == NULL) {
        return 0U;
    }

    uint16_t crc = 0xFFFFU;
    for (size_t i = 0; i < length; i++) {
        crc ^= data[i];
        for (uint8_t bit = 0; bit < 8U; bit++) {
            crc = (crc & 1U) != 0U ? (uint16_t)((crc >> 1U) ^ 0xA001U)
                                   : (uint16_t)(crc >> 1U);
        }
    }
    return crc;
}

static bool uart_read_exact(uint8_t *buffer, size_t length, int64_t deadline_us)
{
    size_t received = 0U;
    while (received < length) {
        int64_t remaining_us = deadline_us - esp_timer_get_time();
        if (remaining_us <= 0) {
            return false;
        }

        uint32_t remaining_ms = (uint32_t)((remaining_us + 999LL) / 1000LL);
        TickType_t wait_ticks = pdMS_TO_TICKS(remaining_ms);
        if (wait_ticks == 0U) {
            wait_ticks = 1U;
        }
        int count = uart_read_bytes(MODBUS_UART_PORT, buffer + received,
                                    length - received, wait_ticks);
        if (count < 0) {
            return false;
        }
        received += (size_t)count;
    }
    return true;
}

static bool read_slave_id_at_address(uint8_t slave_id, uint16_t *read_id)
{
    uint8_t request[8] = {
        slave_id,
        APP_MODBUS_FUNCTION_READ_HOLDING,
        (uint8_t)(APP_MODBUS_SENSOR_SLAVE_ID_REGISTER >> 8U),
        (uint8_t)APP_MODBUS_SENSOR_SLAVE_ID_REGISTER,
        0U,
        1U,
    };
    uint16_t crc = app_modbus_crc16(request, 6U);
    request[6] = (uint8_t)crc;
    request[7] = (uint8_t)(crc >> 8U);

    (void)uart_flush_input(MODBUS_UART_PORT);
    if (uart_write_bytes(MODBUS_UART_PORT, (const char *)request, sizeof(request)) !=
            (int)sizeof(request) ||
        uart_wait_tx_done(MODBUS_UART_PORT, pdMS_TO_TICKS(MODBUS_RESPONSE_TIMEOUT_MS)) != ESP_OK) {
        return false;
    }

    uint8_t response[7];
    const int64_t deadline_us = esp_timer_get_time() +
                                ((int64_t)MODBUS_RESPONSE_TIMEOUT_MS * 1000LL);
    if (!uart_read_exact(response, sizeof(response), deadline_us)) {
        return false;
    }
    uint16_t response_crc = (uint16_t)response[5] |
                            (uint16_t)((uint16_t)response[6] << 8U);
    if (response[0] != slave_id || response[1] != APP_MODBUS_FUNCTION_READ_HOLDING ||
        response[2] != 2U || app_modbus_crc16(response, 5U) != response_crc) {
        return false;
    }
    *read_id = (uint16_t)(((uint16_t)response[3] << 8U) | response[4]);
    return true;
}

static sensor_sample_error_t exchange_registers(const modbus_sensor_cfg_t *config,
                                                const app_modbus_register_map_t *map,
                                                uint16_t *registers)
{
    uint8_t request[8] = {
        config->slave_id,
        map->function,
        (uint8_t)(map->start_register >> 8U),
        (uint8_t)map->start_register,
        (uint8_t)(map->register_count >> 8U),
        (uint8_t)map->register_count,
    };
    uint16_t request_crc = app_modbus_crc16(request, 6U);
    request[6] = (uint8_t)request_crc;
    request[7] = (uint8_t)(request_crc >> 8U);

    (void)uart_flush_input(MODBUS_UART_PORT);
    int written = uart_write_bytes(MODBUS_UART_PORT, (const char *)request, sizeof(request));
    if (written != (int)sizeof(request)) {
        return SENSOR_SAMPLE_ERROR_PROTOCOL;
    }
    if (uart_wait_tx_done(MODBUS_UART_PORT, pdMS_TO_TICKS(MODBUS_RESPONSE_TIMEOUT_MS)) != ESP_OK) {
        return SENSOR_SAMPLE_ERROR_TIMEOUT;
    }

    uint8_t response[3U + (MODBUS_MAX_REGISTER_COUNT * 2U) + 2U];
    const int64_t deadline_us = esp_timer_get_time() +
                                ((int64_t)MODBUS_RESPONSE_TIMEOUT_MS * 1000LL);
    if (!uart_read_exact(response, 3U, deadline_us)) {
        return SENSOR_SAMPLE_ERROR_TIMEOUT;
    }

    if (response[1] == (uint8_t)(map->function | 0x80U)) {
        if (!uart_read_exact(response + 3U, 2U, deadline_us)) {
            return SENSOR_SAMPLE_ERROR_TIMEOUT;
        }
        uint16_t exception_crc = (uint16_t)response[3] |
                                 (uint16_t)((uint16_t)response[4] << 8U);
        if (app_modbus_crc16(response, 3U) != exception_crc) {
            return SENSOR_SAMPLE_ERROR_CRC;
        }
        if (response[0] != config->slave_id) {
            return SENSOR_SAMPLE_ERROR_PROTOCOL;
        }
        ESP_LOGW(TAG, "Slave %u returned Modbus exception 0x%02x",
                 (unsigned)config->slave_id, (unsigned)response[2]);
        return SENSOR_SAMPLE_ERROR_MODBUS_EXCEPTION;
    }

    uint8_t byte_count = response[2];
    if (byte_count > MODBUS_MAX_REGISTER_COUNT * 2U) {
        (void)uart_flush_input(MODBUS_UART_PORT);
        return SENSOR_SAMPLE_ERROR_PROTOCOL;
    }
    size_t response_length = 3U + byte_count + 2U;
    if (!uart_read_exact(response + 3U, response_length - 3U, deadline_us)) {
        return SENSOR_SAMPLE_ERROR_TIMEOUT;
    }

    uint16_t received_crc = (uint16_t)response[response_length - 2U] |
                            (uint16_t)((uint16_t)response[response_length - 1U] << 8U);
    if (app_modbus_crc16(response, response_length - 2U) != received_crc) {
        return SENSOR_SAMPLE_ERROR_CRC;
    }
    if (response[0] != config->slave_id) {
        return SENSOR_SAMPLE_ERROR_PROTOCOL;
    }
    if (response[1] != map->function ||
        byte_count != (uint8_t)(map->register_count * 2U)) {
        return SENSOR_SAMPLE_ERROR_PROTOCOL;
    }

    for (uint16_t i = 0; i < map->register_count; i++) {
        size_t offset = 3U + ((size_t)i * 2U);
        registers[i] = (uint16_t)((uint16_t)response[offset] << 8U) |
                       (uint16_t)response[offset + 1U];
    }
    return SENSOR_SAMPLE_ERROR_NONE;
}

esp_err_t app_modbus_change_slave_id(uint8_t old_slave_id, uint8_t new_slave_id)
{
    if (old_slave_id == 0U || old_slave_id > 247U ||
        new_slave_id == 0U || new_slave_id > 247U) {
        return ESP_ERR_INVALID_ARG;
    }
    if (old_slave_id == new_slave_id) {
        return ESP_OK;
    }
    if (!s_uart_installed || g_sys.modbus_uart_mutex == NULL ||
        xSemaphoreTake(g_sys.modbus_uart_mutex, portMAX_DELAY) != pdTRUE) {
        return ESP_ERR_INVALID_STATE;
    }

    uint8_t request[8] = {
        old_slave_id,
        APP_MODBUS_FUNCTION_WRITE_SINGLE,
        (uint8_t)(APP_MODBUS_SENSOR_SLAVE_ID_REGISTER >> 8U),
        (uint8_t)APP_MODBUS_SENSOR_SLAVE_ID_REGISTER,
        0U,
        new_slave_id,
    };
    uint16_t crc = app_modbus_crc16(request, 6U);
    request[6] = (uint8_t)crc;
    request[7] = (uint8_t)(crc >> 8U);

    (void)uart_flush_input(MODBUS_UART_PORT);
    int written = uart_write_bytes(MODBUS_UART_PORT, (const char *)request, sizeof(request));
    bool response_valid = false;
    if (written == (int)sizeof(request) &&
        uart_wait_tx_done(MODBUS_UART_PORT, pdMS_TO_TICKS(MODBUS_RESPONSE_TIMEOUT_MS)) == ESP_OK) {
        uint8_t response[sizeof(request)];
        const int64_t deadline_us = esp_timer_get_time() +
                                    ((int64_t)MODBUS_RESPONSE_TIMEOUT_MS * 1000LL);
        if (uart_read_exact(response, sizeof(response), deadline_us)) {
            uint16_t response_crc = (uint16_t)response[6] |
                                    (uint16_t)((uint16_t)response[7] << 8U);
            if (app_modbus_crc16(response, 6U) == response_crc &&
                memcmp(response, request, 6U) == 0) {
                response_valid = true;
            }
        }
    }
    uint16_t actual_slave_id = 0U;
    bool verified = response_valid;
    if (!verified) {
        verified = read_slave_id_at_address(new_slave_id, &actual_slave_id) &&
                   actual_slave_id == new_slave_id;
    }
    xSemaphoreGive(g_sys.modbus_uart_mutex);
    return verified ? ESP_OK : ESP_FAIL;
}

static void initialize_sample(uint8_t interface_index,
                              const modbus_sensor_cfg_t *config,
                              sensor_sample_t *sample)
{
    memset(sample, 0, sizeof(*sample));
    sample->interface_type = SENSOR_INTERFACE_RS485;
    sample->interface_index = interface_index;
    sample->sensor_type = (uint8_t)config->sensor_type;
    sample->error = SENSOR_SAMPLE_ERROR_NOT_READY;
}

static esp_err_t read_sensor_config(uint8_t interface_index,
                                    const modbus_sensor_cfg_t *config,
                                    sensor_sample_t *sample)
{
    initialize_sample(interface_index, config, sample);
    if (!config->enabled) {
        sample->error = SENSOR_SAMPLE_ERROR_DISABLED;
        return ESP_OK;
    }

    app_modbus_register_map_t map;
    if (!app_modbus_get_register_map(config->sensor_type, &map) ||
        config->slave_id == 0U || config->slave_id > 247U) {
        sample->error = SENSOR_SAMPLE_ERROR_PROTOCOL;
        return ESP_OK;
    }

    if (!s_uart_installed) {
        sample->error = SENSOR_SAMPLE_ERROR_PROTOCOL;
        return ESP_OK;
    }

    if (g_sys.modbus_uart_mutex == NULL ||
        xSemaphoreTake(g_sys.modbus_uart_mutex, portMAX_DELAY) != pdTRUE) {
        return ESP_ERR_INVALID_STATE;
    }

    sensor_sample_error_t read_error = SENSOR_SAMPLE_ERROR_PROTOCOL;
    for (uint8_t attempt = 0U; attempt < MODBUS_RETRY_COUNT; attempt++) {
        uint16_t registers[MODBUS_MAX_REGISTER_COUNT] = {0};
        read_error = exchange_registers(config, &map, registers);
        if (read_error == SENSOR_SAMPLE_ERROR_NONE) {
            read_error = app_modbus_decode_registers(config->sensor_type,
                                                     registers,
                                                     map.register_count,
                                                     &sample->v1,
                                                     &sample->v2,
                                                     &sample->v3);
            break;
        }
        if (read_error != SENSOR_SAMPLE_ERROR_TIMEOUT &&
            read_error != SENSOR_SAMPLE_ERROR_CRC &&
            read_error != SENSOR_SAMPLE_ERROR_PROTOCOL) {
            break;
        }
        if (attempt + 1U < MODBUS_RETRY_COUNT) {
            vTaskDelay(pdMS_TO_TICKS(MODBUS_RETRY_DELAY_MS));
        }
    }
    xSemaphoreGive(g_sys.modbus_uart_mutex);

    sample->error = (uint8_t)read_error;
    sample->valid = read_error == SENSOR_SAMPLE_ERROR_NONE ? 1U : 0U;
    if (!sample->valid) {
        ESP_LOGW(TAG, "RS485 slot %u slave %u read failed (error=%u)",
                 (unsigned)interface_index, (unsigned)config->slave_id,
                 (unsigned)sample->error);
    }
    return ESP_OK;
}

static void update_system_errors(const sensor_cycle_t *cycle)
{
    bool offline = false;
    bool out_of_range = false;
    for (size_t i = 0; i < cycle->count; i++) {
        const sensor_sample_t *sample = &cycle->s[i];
        if (sample->error == SENSOR_SAMPLE_ERROR_OFFLINE) {
            offline = true;
        }
        if (sample->error == SENSOR_SAMPLE_ERROR_OUT_OF_RANGE) {
            out_of_range = true;
        }
    }

    uint32_t set_mask = 0U;
    uint32_t clear_mask = 0U;
    if (offline) {
        set_mask |= (uint32_t)SYS_ERR_MODBUS_TIMEOUT;
    } else {
        clear_mask |= (uint32_t)SYS_ERR_MODBUS_TIMEOUT;
    }
    if (out_of_range) {
        set_mask |= (uint32_t)SYS_ERR_SENSOR_OUT_RANGE;
    } else {
        clear_mask |= (uint32_t)SYS_ERR_SENSOR_OUT_RANGE;
    }
    app_sysmon_error_mask_update(set_mask, clear_mask);
}

/* Circuit breaker hai cấp: retry trong cycle, rồi OFFLINE sau 5 cycle lỗi liên tiếp. */
static void poll_slot(uint8_t index,
                      const modbus_sensor_cfg_t *config,
                      slot_health_t *health,
                      sensor_sample_t *sample)
{
    if (!config->enabled) {
        memset(health, 0, sizeof(*health));
        (void)read_sensor_config(index, config, sample);
        return;
    }

    int64_t now = esp_timer_get_time();
    if (health->offline && now < health->next_probe_us) {
        initialize_sample(index, config, sample);
        sample->error = SENSOR_SAMPLE_ERROR_OFFLINE;
        return;
    }

    esp_err_t result = read_sensor_config(index, config, sample);
    if (result != ESP_OK) {
        initialize_sample(index, config, sample);
        sample->error = SENSOR_SAMPLE_ERROR_PROTOCOL;
        ESP_LOGE(TAG, "Sensor slot %u read API failed: %s",
                 (unsigned)index, esp_err_to_name(result));
    }

    if (sample->valid != 0U || sample->error == SENSOR_SAMPLE_ERROR_OUT_OF_RANGE) {
        /* Cảm biến vẫn trả lời nên liên lạc hoạt động; OUT_OF_RANGE chỉ là lỗi dữ liệu. */
        if (health->offline) {
            ESP_LOGI(TAG, "RS485 slot %u back ONLINE", (unsigned)index);
        }
        memset(health, 0, sizeof(*health));
        return;
    }

    if (health->offline) {
        health->next_probe_us = now + MODBUS_OFFLINE_PROBE_US;
        sample->error = SENSOR_SAMPLE_ERROR_OFFLINE;
        return;
    }
    if (health->consecutive_fail_count < UINT8_MAX) {
        health->consecutive_fail_count++;
    }
    if (health->consecutive_fail_count >= MODBUS_OFFLINE_FAIL_THRESHOLD) {
        health->offline = true;
        health->next_probe_us = now + MODBUS_OFFLINE_PROBE_US;
        sample->error = SENSOR_SAMPLE_ERROR_OFFLINE;
        ESP_LOGW(TAG, "RS485 slot %u OFFLINE after %u failed cycles; probing every 10 s",
                 (unsigned)index, (unsigned)health->consecutive_fail_count);
    }
}

static bool polling_suspended(void)
{
    return __atomic_load_n(&s_suspend_requested, __ATOMIC_RELAXED) != 0U;
}

static void send_cycle(sensor_cycle_t *cycle)
{
    if (g_sys.sensor_data_queue == NULL) {
        ESP_LOGE(TAG, "sensor_data_queue is unavailable; dropping cycle");
        return;
    }
    if (xQueueSend(g_sys.sensor_data_queue, cycle, 0U) == pdTRUE) {
        return;
    }

    sensor_cycle_t discarded;
    (void)xQueueReceive(g_sys.sensor_data_queue, &discarded, 0U);
    if (xQueueSend(g_sys.sensor_data_queue, cycle, 0U) != pdTRUE) {
        ESP_LOGW(TAG, "sensor_data_queue remained full; cycle %lu dropped",
                 (unsigned long)cycle->seq);
    }
}

static void fill_disabled_sample(uint8_t port, sensor_sample_t *sample, sensor_sample_error_t error)
{
    memset(sample, 0, sizeof(*sample));
    sample->interface_type = (uint8_t)app_port_interface(port);
    sample->interface_index = app_port_index(port);
    sample->sensor_type = (uint8_t)app_port_sensor_type(port);
    sample->error = (uint8_t)error;
}

/* Digital input: true (1.0) while the contact pulls the pin to GND. */
static void read_digital_input(uint8_t port, const sensor_port_cfg_t *cfg, sensor_sample_t *sample)
{
    fill_disabled_sample(port, sample, SENSOR_SAMPLE_ERROR_DISABLED);
    if (!cfg->configured || !cfg->enabled) {
        return;
    }
    int level = gpio_get_level(s_di_pins[app_port_index(port)]);
    sample->valid = 1U;
    sample->error = SENSOR_SAMPLE_ERROR_NONE;
    sample->v1 = level == 0 ? 1.0f : 0.0f;
}

static void sensor_acquisition_task(void *arg)
{
    (void)arg;
    esp_err_t wdt_err = esp_task_wdt_add(NULL);
    if (wdt_err != ESP_OK) {
        ESP_LOGE(TAG, "sensor_acquisition_task WDT registration failed: %s",
                 esp_err_to_name(wdt_err));
        esp_restart();
    }

    slot_health_t health[APP_RS485_INTERFACE_COUNT] = {0};
    uint32_t seen_generation = 0U;
    bool seen_generation_valid = false;
    static device_cfg_t device;

    for (;;) {
        if (polling_suspended()) {
            (void)esp_task_wdt_reset();
            vTaskDelay(pdMS_TO_TICKS(100U));
            continue;
        }

        uint32_t generation = app_device_generation();
        app_device_get(&device);
        if (!seen_generation_valid || generation != seen_generation) {
            /* New configuration (enable, slave id, delete): forget OFFLINE and probe at once. */
            memset(health, 0, sizeof(health));
            seen_generation = generation;
            seen_generation_valid = true;
            unsigned active = 0;
            for (size_t p = 0; p < APP_SENSOR_INTERFACE_COUNT; p++) {
                if (device.sensor[p].configured && device.sensor[p].enabled) active++;
            }
            ESP_LOGI(TAG, "Sensor config changed: %u sensor(s) enabled and polled", active);
        }

        TickType_t cycle_start = xTaskGetTickCount();
        sensor_cycle_t cycle = {0};
        cycle.seq = ++s_cycle_sequence;
        cycle.uptime_ms = (uint32_t)(esp_timer_get_time() / 1000LL);
        cycle.count = APP_SENSOR_INTERFACE_COUNT;

        for (uint8_t i = 0U; i < APP_RS485_INTERFACE_COUNT; i++) {
            const sensor_port_cfg_t *port = &device.sensor[i];
            modbus_sensor_cfg_t config = {
                .slave_id = port->slave_id,
                .sensor_type = app_rs485_slot_type(i),
                .enabled = port->configured && port->enabled,
            };
            poll_slot(i, &config, &health[i], &cycle.s[i]);
            (void)esp_task_wdt_reset();
            if (config.enabled && i + 1U < APP_RS485_INTERFACE_COUNT) {
                vTaskDelay(pdMS_TO_TICKS(MODBUS_INTER_FRAME_DELAY_MS));
            }
        }

        for (uint8_t a = 0U; a < APP_ANALOG_4_20MA_INTERFACE_COUNT; a++) {
            uint8_t port = (uint8_t)(APP_PORT_ANALOG_FIRST + a);
            const sensor_port_cfg_t *cfg = &device.sensor[port];
            /* No 4-20 mA front end is read yet: an enabled port reports "not ready". */
            fill_disabled_sample(port, &cycle.s[port],
                                 cfg->configured && cfg->enabled ? SENSOR_SAMPLE_ERROR_NOT_READY
                                                                 : SENSOR_SAMPLE_ERROR_DISABLED);
        }

        for (uint8_t d = 0U; d < APP_DI_COUNT; d++) {
            uint8_t port = (uint8_t)(APP_PORT_DI_FIRST + d);
            read_digital_input(port, &device.sensor[port], &cycle.s[port]);
        }

        if (polling_suspended()) {
            continue;
        }

        update_system_errors(&cycle);
        send_cycle(&cycle);
        (void)esp_task_wdt_reset();
        /* A config change wakes the task early so a re-enabled sensor is read right away. */
        TickType_t elapsed = xTaskGetTickCount() - cycle_start;
        TickType_t period = pdMS_TO_TICKS(MODBUS_POLL_INTERVAL_MS);
        (void)ulTaskNotifyTake(pdTRUE, elapsed < period ? period - elapsed : 0);
    }
}

static esp_err_t uart_initialize(void)
{
    if (s_uart_installed) {
        return ESP_OK;
    }

    const uart_config_t uart_config = {
        .baud_rate = MODBUS_BAUD_RATE,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .rx_flow_ctrl_thresh = 0,
        .source_clk = UART_SCLK_DEFAULT,
    };
    esp_err_t err = uart_driver_install(MODBUS_UART_PORT, MODBUS_RX_BUFFER_SIZE,
                                        MODBUS_TX_BUFFER_SIZE, 0, NULL, 0);
    if (err != ESP_OK) {
        return err;
    }
    s_uart_installed = true;
    err = uart_param_config(MODBUS_UART_PORT, &uart_config);
    if (err == ESP_OK) {
        err = uart_set_pin(MODBUS_UART_PORT, APP_PIN_RS485_TX, APP_PIN_RS485_RX,
                           APP_PIN_RS485_DE_RE, UART_PIN_NO_CHANGE);
    }
    if (err == ESP_OK) {
        err = uart_set_mode(MODBUS_UART_PORT, UART_MODE_RS485_HALF_DUPLEX);
    }
    if (err != ESP_OK) {
        (void)uart_driver_delete(MODBUS_UART_PORT);
        s_uart_installed = false;
    }
    return err;
}

esp_err_t app_modbus_init(void)
{
    if (g_sys.modbus_uart_mutex == NULL || g_sys.sensor_data_queue == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (s_initialized) {
        return ESP_OK;
    }

    /* Digital inputs are plain GPIOs and work even when the RS485 UART cannot start. */
    uint64_t di_mask = 0;
    for (size_t i = 0; i < APP_DI_COUNT; i++) di_mask |= 1ULL << s_di_pins[i];
    const gpio_config_t di_config = {
        .pin_bit_mask = di_mask,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    esp_err_t di_err = gpio_config(&di_config);
    if (di_err == ESP_OK) {
        di_err = gpio_install_isr_service(0);
        if (di_err == ESP_ERR_INVALID_STATE) di_err = ESP_OK;
    }
    if (di_err == ESP_OK) {
        s_di_button_queue = xQueueCreate(DI_BUTTON_QUEUE_LENGTH, sizeof(di_button_event_t));
        if (s_di_button_queue == NULL) di_err = ESP_ERR_NO_MEM;
    }
    size_t handlers_added = 0U;
    if (di_err == ESP_OK) {
        for (size_t i = 0; i < APP_DI_COUNT; i++) {
            di_err = gpio_isr_handler_add(s_di_pins[i], di_button_isr, (void *)(uintptr_t)i);
            if (di_err != ESP_OK) break;
            handlers_added++;
            di_err = gpio_set_intr_type(s_di_pins[i], GPIO_INTR_NEGEDGE);
            if (di_err != ESP_OK) break;
        }
    }
    if (di_err != ESP_OK) {
        for (size_t i = 0; i < APP_DI_COUNT; i++) {
            (void)gpio_set_intr_type(s_di_pins[i], GPIO_INTR_DISABLE);
        }
        for (size_t i = 0; i < handlers_added; i++) {
            (void)gpio_isr_handler_remove(s_di_pins[i]);
        }
        if (s_di_button_queue != NULL) {
            vQueueDelete(s_di_button_queue);
            s_di_button_queue = NULL;
        }
    }
    s_di_button_isr_ready = di_err == ESP_OK;
    if (di_err != ESP_OK) {
        ESP_LOGE(TAG, "Digital input/interrupt setup failed: %s", esp_err_to_name(di_err));
    }

    esp_err_t err = uart_initialize();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "UART1 RS485 initialization failed: %s (RS485 sensors report errors)",
                 esp_err_to_name(err));
    } else {
        ESP_LOGI(TAG, "UART1 RS485 ready at %d baud, 8N1, DE/RE=GPIO%d",
                 MODBUS_BAUD_RATE, APP_PIN_RS485_DE_RE);
    }

    s_initialized = true;
    return err != ESP_OK ? err : di_err;
}

esp_err_t app_modbus_start_task(void)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }
    if (s_task != NULL) {
        return ESP_OK;
    }
    if (s_di_button_isr_ready && s_di_button_task == NULL) {
        if (xTaskCreatePinnedToCore(di_button_task, "di_button_task",
                                    DI_BUTTON_TASK_STACK_BYTES, NULL,
                                    DI_BUTTON_TASK_PRIORITY, &s_di_button_task,
                                    MODBUS_TASK_CORE) != pdPASS) {
            s_di_button_task = NULL;
            ESP_LOGE(TAG, "DI button task could not start");
            return ESP_ERR_NO_MEM;
        }
    }
    if (xTaskCreatePinnedToCore(sensor_acquisition_task, "sensor_acquisition_task",
                                MODBUS_TASK_STACK_BYTES, NULL, MODBUS_TASK_PRIORITY,
                                &s_task, MODBUS_TASK_CORE) != pdPASS) {
        s_task = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

void app_modbus_config_changed(void)
{
    if (s_task != NULL) {
        xTaskNotifyGive(s_task);
    }
}

void app_modbus_suspend(void)
{
    __atomic_store_n(&s_suspend_requested, 1U, __ATOMIC_RELAXED);
}

void app_modbus_resume(void)
{
    __atomic_store_n(&s_suspend_requested, 0U, __ATOMIC_RELAXED);
}
