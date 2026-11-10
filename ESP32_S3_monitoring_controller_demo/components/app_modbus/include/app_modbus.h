#ifndef APP_MODBUS_H
#define APP_MODBUS_H

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define APP_MODBUS_SHT40_TEMP_REGISTER       0x0001U
#define APP_MODBUS_SHT40_HUMIDITY_REGISTER   0x0000U
#define APP_MODBUS_DO_SATURATION_REGISTER    0x0000U
#define APP_MODBUS_DO_CONCENTRATION_REGISTER 0x0002U
#define APP_MODBUS_DO_TEMPERATURE_REGISTER   0x0004U
#define APP_MODBUS_PH_REGISTER               0x0000U
#define APP_MODBUS_PH_TEMPERATURE_REGISTER   0x0001U
#define APP_MODBUS_SENSOR_SLAVE_ID_REGISTER  0x07D0U

#define APP_MODBUS_FUNCTION_READ_HOLDING     0x03U
#define APP_MODBUS_FUNCTION_READ_INPUT       0x04U
#define APP_MODBUS_FUNCTION_WRITE_SINGLE     0x06U

/* Prepares the RS485 UART and the digital input pins. A UART failure is returned but the
 * module stays usable: digital inputs keep working and RS485 sensors report errors. The sensor
 * and load configuration is read from app_device on every cycle. */
esp_err_t app_modbus_init(void);
esp_err_t app_modbus_start_task(void);

/* Call after app_device_commit() changed a sensor: wakes the task so a sensor that was enabled
 * is read right away (disabled sensors are never polled). */
void app_modbus_config_changed(void);

/* Changes the address of the single sensor currently responding at old_slave_id. */
esp_err_t app_modbus_change_slave_id(uint8_t old_slave_id, uint8_t new_slave_id);

/* Stops/resumes polling. */
void app_modbus_suspend(void);
void app_modbus_resume(void);

uint16_t app_modbus_crc16(const uint8_t *data, size_t length);

#ifdef __cplusplus
}
#endif

#endif
