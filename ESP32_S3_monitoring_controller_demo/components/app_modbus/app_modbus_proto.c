#include "app_modbus_proto.h"

#include <math.h>
#include <string.h>

#include "app_modbus.h"

#define MODBUS_READ_HOLDING 0x03U

_Static_assert(sizeof(float) == sizeof(uint32_t), "Modbus sensor map requires 32-bit float");

static float float_from_registers(const uint16_t *registers)
{
    uint32_t bits = ((uint32_t)registers[0] << 16U) | registers[1];
    float value;

    memcpy(&value, &bits, sizeof(value));
    return value;
}

bool app_modbus_get_register_map(sensor_type_t type, app_modbus_register_map_t *map)
{
    if (map == NULL) {
        return false;
    }

    switch (type) {
    case SENSOR_SHT40:
        *map = (app_modbus_register_map_t) {
            .start_register = APP_MODBUS_SHT40_HUMIDITY_REGISTER,
            .register_count = 2U,
            .function = MODBUS_READ_HOLDING,
        };
        return true;
    case SENSOR_DO:
        *map = (app_modbus_register_map_t) {
            .start_register = APP_MODBUS_DO_SATURATION_REGISTER,
            .register_count = 6U,
            .function = MODBUS_READ_HOLDING,
        };
        return true;
    case SENSOR_PH:
        *map = (app_modbus_register_map_t) {
            .start_register = APP_MODBUS_PH_REGISTER,
            .register_count = 2U,
            .function = MODBUS_READ_HOLDING,
        };
        return true;
    default:
        return false;
    }
}

static bool values_in_range(sensor_type_t type, float v1, float v2, float v3)
{
    switch (type) {
    case SENSOR_SHT40:
        return v1 >= -40.0f && v1 <= 60.0f && v2 >= 0.0f && v2 <= 100.0f;
    case SENSOR_DO:
        return v1 >= 0.0f && v1 <= 20.0f && v2 >= -20.0f && v2 <= 80.0f &&
               v3 >= 0.0f && v3 <= 200.0f;
    case SENSOR_PH:
        return v1 >= 0.0f && v1 <= 14.0f && v2 >= 0.0f && v2 <= 60.0f;
    default:
        return false;
    }
}

sensor_sample_error_t app_modbus_decode_registers(sensor_type_t type,
                                                   const uint16_t *registers, size_t count,
                                                   float *v1, float *v2, float *v3)
{
    app_modbus_register_map_t map;

    if (registers == NULL || v1 == NULL || v2 == NULL || v3 == NULL ||
        !app_modbus_get_register_map(type, &map) || count != map.register_count) {
        return SENSOR_SAMPLE_ERROR_PROTOCOL;
    }

    *v1 = 0.0f;
    *v2 = 0.0f;
    *v3 = 0.0f;

    switch (type) {
    case SENSOR_SHT40:
        *v1 = (float)(int16_t)registers[1] / 10.0f;
        *v2 = (float)registers[0] / 10.0f;
        break;
    case SENSOR_DO:
        *v1 = float_from_registers(&registers[2]);
        *v2 = float_from_registers(&registers[4]);
        *v3 = float_from_registers(&registers[0]);
        break;
    case SENSOR_PH:
        *v1 = (float)registers[0] / 100.0f;
        *v2 = (float)(int16_t)registers[1] / 10.0f;
        break;
    default:
        return SENSOR_SAMPLE_ERROR_PROTOCOL;
    }

    if (!isfinite(*v1) || !isfinite(*v2) || !isfinite(*v3) ||
        !values_in_range(type, *v1, *v2, *v3)) {
        return SENSOR_SAMPLE_ERROR_OUT_OF_RANGE;
    }
    return SENSOR_SAMPLE_ERROR_NONE;
}
