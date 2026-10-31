#ifndef MAIN_DATA_TYPES_H
#define MAIN_DATA_TYPES_H

#include <stdint.h>
#include <stdbool.h>

#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

#include "app_pins.h"

#define APP_SENSOR_COUNT APP_SENSOR_INTERFACE_COUNT

/* 1. Network interface */
typedef enum {
    NET_IF_NONE = 0,
    NET_IF_ETH,
    NET_IF_WIFI
} net_interface_t;

/* MQTT-reported system error mask. Low-severity faults blink; critical faults stay on. */
typedef enum {
    SYS_ERR_NONE = 0,
    SYS_ERR_MODBUS_TIMEOUT = (1 << 0),
    SYS_ERR_NET_LOST = (1 << 1),
    SYS_ERR_MQTT_BROKER = (1 << 2),
    SYS_ERR_NVM_FAIL = (1 << 3),
    SYS_ERR_SENSOR_OUT_RANGE = (1 << 4),
    SYS_ERR_ETH_INIT = (1U << 5),
    SYS_ERR_INIT_FAILURE = (1U << 6),
    SYS_ERR_RESOURCE_ALLOC = (1U << 7),
    SYS_ERR_LOAD_OUTPUT_DO1 = (1U << 8),
    SYS_ERR_LOAD_OUTPUT_DO2 = (1U << 9),
    SYS_ERR_LOAD_OUTPUT_DO3 = (1U << 10),
    SYS_ERR_LOAD_OUTPUT_DO4 = (1U << 11)
} sys_error_code_t;

/* 3. System state machine */
typedef enum {
    STATE_INIT = 0,
    STATE_BLE_PROV,
    STATE_NET_CONNECTING,
    STATE_OPERATIONAL,
    STATE_FAILOVER,
    STATE_FACTORY_RESET,
    STATE_MQTT_CONNECTING,  /* network up, MQTT not yet connected */
    STATE_NET_LOST,         /* no interface has WAN */
    STATE_BLE_PROV_RUNTIME  /* BLE provisioning while the system keeps running */
} sys_state_t;

/* Commands for net_mgmt_task, sent through g_sys.net_cmd_queue */
typedef enum {
    NET_CMD_NONE = 0,
    NET_CMD_START_BLE_PROV_RUNTIME,
    NET_CMD_FACTORY_RESET
} net_cmd_t;

/* 4. Event bits in sys_event_group */
#define BIT_NET_ETH_CONNECTED   (1U << 0)
#define BIT_NET_WIFI_CONNECTED  (1U << 1)
#define BIT_MQTT_CONNECTED      (1U << 2)
#define BIT_PROV_DONE           (1U << 3)
#define BIT_CONFIG_RELOAD       (1U << 4)
#define BIT_NET_ACTIVE_READY    (1U << 5)  /* active interface has IP and WAN OK */
#define BIT_NET_STANDBY_READY   (1U << 6)  /* other interface has IP and a fresh WAN OK */
#define BIT_SYS_NET_LOST        (1U << 7)  /* no interface has WAN */
#define BIT_NET_ETH_WAN_OK      (1U << 8)
#define BIT_NET_WIFI_WAN_OK     (1U << 9)
#define BIT_TIME_VALID          (1U << 10) /* SNTP has synchronised the clock */
#define BIT_SYS_INTERLOCK_TRIPPED (1U << 11) /* safety interlock forced all loads off */
#define BIT_PROV_RESULT_SENT    (1U << 12) /* app has read the provisioning result over BLE */
#define BIT_SYS_ESTOP            (1U << 13) /* EMERGENCY_STOP executed and nothing re-enabled yet */

/* 5. Sensor ports. Protocol ids: RS1..RS4 = port 0..3, AN1 = port 4, DI1..DI4 = port 5..8. */
#define APP_PORT_NONE 0xFFU
#define APP_PORT_RS485_FIRST 0U
#define APP_PORT_ANALOG_FIRST ((uint8_t)APP_RS485_INTERFACE_COUNT)
#define APP_PORT_DI_FIRST ((uint8_t)(APP_RS485_INTERFACE_COUNT + APP_ANALOG_4_20MA_INTERFACE_COUNT))

typedef enum {
    SENSOR_SHT40 = 0,
    SENSOR_DO = 1,
    SENSOR_PH = 2,
    SENSOR_ANALOG_4_20MA = 3,
    SENSOR_DIGITAL_INPUT = 4
} sensor_type_t;

/* Each RS485 slot has one fixed sensor model. The firmware reads the slot that way and the
 * app does not choose it (a sensor's model is only its name). Change a model here only. */
static inline sensor_type_t app_rs485_slot_type(uint8_t slot_index)
{
    static const sensor_type_t k_slot_type[4] = {SENSOR_SHT40, SENSOR_DO, SENSOR_PH, SENSOR_DO};
    return slot_index < 4U ? k_slot_type[slot_index] : SENSOR_SHT40;
}

typedef enum {
    SENSOR_INTERFACE_RS485 = 0,
    SENSOR_INTERFACE_ANALOG_4_20MA = 1,
    SENSOR_INTERFACE_DI = 2
} sensor_interface_type_t;

static inline sensor_interface_type_t app_port_interface(uint8_t port)
{
    if (port < APP_PORT_ANALOG_FIRST) return SENSOR_INTERFACE_RS485;
    if (port < APP_PORT_DI_FIRST) return SENSOR_INTERFACE_ANALOG_4_20MA;
    return SENSOR_INTERFACE_DI;
}

static inline uint8_t app_port_index(uint8_t port)
{
    if (port < APP_PORT_ANALOG_FIRST) return port;
    if (port < APP_PORT_DI_FIRST) return (uint8_t)(port - APP_PORT_ANALOG_FIRST);
    return (uint8_t)(port - APP_PORT_DI_FIRST);
}

static inline uint8_t app_port_make(sensor_interface_type_t type, uint8_t index)
{
    if (type == SENSOR_INTERFACE_RS485) return index;
    if (type == SENSOR_INTERFACE_ANALOG_4_20MA) return (uint8_t)(APP_PORT_ANALOG_FIRST + index);
    return (uint8_t)(APP_PORT_DI_FIRST + index);
}

static inline sensor_type_t app_port_sensor_type(uint8_t port)
{
    switch (app_port_interface(port)) {
    case SENSOR_INTERFACE_RS485: return app_rs485_slot_type(app_port_index(port));
    case SENSOR_INTERFACE_ANALOG_4_20MA: return SENSOR_ANALOG_4_20MA;
    default: return SENSOR_DIGITAL_INPUT;
    }
}

static inline uint8_t app_sensor_value_count(sensor_type_t type)
{
    switch (type) {
    case SENSOR_SHT40: return 2U;
    case SENSOR_DO: return 3U;
    case SENSOR_PH: return 2U;
    case SENSOR_ANALOG_4_20MA:
    case SENSOR_DIGITAL_INPUT: return 1U;
    default: return 0U;
    }
}

static inline const char *app_sensor_value_name(sensor_type_t type, uint8_t index)
{
    static const char *const sht40[] = {"Nhiệt độ không khí", "Độ ẩm không khí"};
    static const char *const dissolved_oxygen[] = {
        "Nồng độ oxy hòa tan", "Nhiệt độ nước", "Độ bão hòa",
    };
    static const char *const ph[] = {"Độ pH", "Nhiệt độ nước"};
    static const char *const analog[] = {"Dòng điện"};
    static const char *const digital[] = {"Trạng thái"};
    const char *const *names = NULL;
    uint8_t count = app_sensor_value_count(type);

    switch (type) {
    case SENSOR_SHT40: names = sht40; break;
    case SENSOR_DO: names = dissolved_oxygen; break;
    case SENSOR_PH: names = ph; break;
    case SENSOR_ANALOG_4_20MA: names = analog; break;
    case SENSOR_DIGITAL_INPUT: names = digital; break;
    default: return NULL;
    }
    return index < count ? names[index] : NULL;
}

/* What app_modbus needs to poll one RS485 slot. */
typedef struct {
    uint8_t slave_id;       /* 1-247 */
    sensor_type_t sensor_type;
    bool enabled;
} modbus_sensor_cfg_t;

/* 6. Persistent configuration */

/* Provisioning / network configuration (NVS blob "config"). */
typedef struct {
    char wifi_ssid[33];
    char wifi_password[64];
    char user_id[37];
    bool only_use_ethernet;

    char device_name[32];

    uint32_t safety_timeout_s;
    uint32_t telemetry_interval_s;
} app_config_t;

/* One sensor port (NVS blob "devcfg"). A port that was never added is not configured. */
typedef struct {
    bool configured;
    bool enabled;
    uint8_t slave_id;       /* RS485 only, 1..247 */
    char name[32];
} sensor_port_cfg_t;

/* CONn: compares one named value of a sensor with a threshold. */
typedef struct {
    bool present;           /* added with ADD_LOAD_CONDITION */
    bool enabled;
    bool action;            /* true = turn the load on when the comparison holds */
    bool op_gt;             /* false: value < threshold, true: value > threshold */
    uint8_t sensor_port;    /* APP_PORT_NONE until chosen */
    uint8_t value_index;    /* index in the sensor's telemetry values[] */
    float threshold;
} load_condition_cfg_t;

/* SHEn: weekly schedule, times in UTC. */
typedef struct {
    bool present;           /* added with ADD_LOAD_SCHEDULER */
    bool enabled;
    uint8_t days_mask;      /* bit 0 Monday .. bit 6 Sunday */
    uint16_t on_minute_utc;
    uint16_t off_minute_utc;
} load_scheduler_cfg_t;

typedef struct {
    char name[32];
    bool enabled;
    load_condition_cfg_t condition[APP_CONDITIONS_PER_LOAD];
    load_scheduler_cfg_t scheduler[APP_SCHEDULERS_PER_LOAD];
} load_cfg_t;

typedef struct {
    sensor_port_cfg_t sensor[APP_SENSOR_INTERFACE_COUNT];
    load_cfg_t load[APP_LOAD_COUNT];
} device_cfg_t;

typedef enum {
    SENSOR_SAMPLE_ERROR_NONE = 0,
    SENSOR_SAMPLE_ERROR_TIMEOUT,
    SENSOR_SAMPLE_ERROR_CRC,
    SENSOR_SAMPLE_ERROR_OUT_OF_RANGE,
    SENSOR_SAMPLE_ERROR_NOT_READY,
    SENSOR_SAMPLE_ERROR_DISABLED_MID_CYCLE,
    SENSOR_SAMPLE_ERROR_STOPPED,
    SENSOR_SAMPLE_ERROR_DISABLED,
    SENSOR_SAMPLE_ERROR_MODBUS_EXCEPTION,
    SENSOR_SAMPLE_ERROR_PROTOCOL,
    SENSOR_SAMPLE_ERROR_OFFLINE
} sensor_sample_error_t;

/* v1 is the primary value (what load conditions compare); digital inputs use v1 = 0.0 / 1.0. */
typedef struct {
    uint8_t interface_type;
    uint8_t interface_index;
    uint8_t sensor_type;
    uint8_t valid;
    uint8_t error;
    float v1;
    float v2;
    float v3;
} sensor_sample_t;

/* One sample per port, indexed by port (RS1..RS4, AN1, DI1..DI4). */
typedef struct {
    uint32_t seq;
    int64_t ts_ms;
    uint32_t uptime_ms;
    uint8_t count;
    sensor_sample_t s[APP_SENSOR_INTERFACE_COUNT];
} sensor_cycle_t;

/* 7. Load runtime (read by app_mqtt for the snapshot and by app_sysmon) */
typedef enum {
    LOAD_DELAY_IDLE = 0,
    LOAD_DELAY_WAIT_FIRST,
    LOAD_DELAY_WAIT_SECOND
} load_delay_phase_t;

typedef struct {
    bool output;
    bool delay_active;
    bool delay_mode;                /* false = ON_THEN_OFF, true = OFF_THEN_ON */
    load_delay_phase_t delay_phase;
    uint16_t delay_min;
    uint16_t delay_duration_min;
    uint32_t delay_remaining_s;     /* until the next transition of the delay */
    int64_t delay_start_epoch_s;    /* 0 while the clock was not valid when the delay started */
} load_runtime_t;

/* 8. Events published on the status topic */
typedef enum {
    MQTT_EVENT_LOAD_CHANGED = 0,
    MQTT_EVENT_INTERLOCK_TRIPPED,
    MQTT_EVENT_INTERLOCK_CLEARED,
    MQTT_EVENT_ERRORS_CHANGED,
    MQTT_EVENT_NET_SWITCHED,
    MQTT_EVENT_LOW_HEAP,
    MQTT_EVENT_TIME_SYNCED,
    MQTT_EVENT_REBOOT,
    MQTT_EVENT_EMERGENCY_STOP,
    MQTT_EVENT_DIAGNOSTIC
} mqtt_event_kind_t;

typedef struct {
    mqtt_event_kind_t kind;
    uint8_t load_id;        /* 1..APP_LOAD_COUNT */
    bool state;
    char source[12];        /* manual, delay, schedule, condition, disable, emergency, interlock */
    uint32_t after_s;
    uint32_t code_mask;
    uint32_t added;
    uint32_t cleared;
    char from[8];
    char to[8];
    uint8_t loads_off;
    uint32_t free_heap;
    uint32_t min_free_heap;
    uint32_t boot_count;
    uint32_t reset_reason;
    uint32_t mqtt_state;
    uint32_t network_state;
    uint32_t error_mask;
    uint32_t diagnostic_uptime_ms;
    bool diagnostic_interlock;
    bool diagnostic_emergency;
    char reason[16];
} mqtt_event_t;

/* 9. Shared RTOS resources created by main */
typedef struct {
    EventGroupHandle_t sys_event_group;
    QueueHandle_t sensor_data_queue;    /* sensor_cycle_t */
    QueueHandle_t mqtt_event_queue;     /* mqtt_event_t */
    QueueHandle_t net_cmd_queue;        /* net_cmd_t, consumed by net_mgmt_task */
    SemaphoreHandle_t modbus_uart_mutex;
    uint32_t sys_error_mask;            /* access with __atomic builtins across cores */
} sys_context_t;

extern sys_context_t g_sys;

#endif
