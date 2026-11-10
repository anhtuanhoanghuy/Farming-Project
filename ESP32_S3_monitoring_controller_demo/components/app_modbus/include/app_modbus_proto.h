#ifndef APP_MODBUS_PROTO_H
#define APP_MODBUS_PROTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "main_data_types.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint16_t start_register;
    uint8_t register_count;
    uint8_t function;
} app_modbus_register_map_t;

bool app_modbus_get_register_map(sensor_type_t type, app_modbus_register_map_t *map);

sensor_sample_error_t app_modbus_decode_registers(sensor_type_t type,
                                                   const uint16_t *registers, size_t count,
                                                   float *v1, float *v2, float *v3);

#ifdef __cplusplus
}
#endif

#endif
