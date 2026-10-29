#include <assert.h>
#include <math.h>

#include "app_modbus_proto.h"

static void test_register_maps(void)
{
    app_modbus_register_map_t map;

    assert(app_modbus_get_register_map(SENSOR_SHT40, &map));
    assert(map.start_register == 0x0000U && map.register_count == 2U && map.function == 0x03U);
    assert(app_modbus_get_register_map(SENSOR_DO, &map));
    assert(map.start_register == 0x0000U && map.register_count == 6U && map.function == 0x03U);
    assert(app_modbus_get_register_map(SENSOR_PH, &map));
    assert(map.start_register == 0x0000U && map.register_count == 2U && map.function == 0x03U);
    assert(!app_modbus_get_register_map(SENSOR_ANALOG_4_20MA, &map));
    assert(!app_modbus_get_register_map(SENSOR_DO, NULL));
}

static void test_sht40_decoding(void)
{
    const uint16_t registers[] = {654U, 0xFF85U};
    float temperature, humidity, unused;

    assert(app_modbus_decode_registers(SENSOR_SHT40, registers, 2U,
                                       &temperature, &humidity, &unused) ==
           SENSOR_SAMPLE_ERROR_NONE);
    assert(fabsf(temperature - (-12.3f)) < 0.001f);
    assert(fabsf(humidity - 65.4f) < 0.001f);
    assert(unused == 0.0f);

    const uint16_t datasheet_registers[] = {0x0102U, 0xFF33U};
    assert(app_modbus_decode_registers(SENSOR_SHT40, datasheet_registers, 2U,
                                       &temperature, &humidity, &unused) ==
           SENSOR_SAMPLE_ERROR_NONE);
    assert(fabsf(temperature - (-20.5f)) < 0.001f);
    assert(fabsf(humidity - 25.8f) < 0.001f);
}

static void test_sht40_boundaries(void)
{
    const uint16_t valid[][2] = {{0U, 0xFE70U}, {1000U, 600U}, {500U, 250U}};
    const uint16_t invalid[][2] = {{500U, 0xFE6FU}, {500U, 601U}, {1001U, 250U}};
    float temperature, humidity, unused;

    for (size_t i = 0; i < sizeof(valid) / sizeof(valid[0]); i++) {
        assert(app_modbus_decode_registers(SENSOR_SHT40, valid[i], 2U,
                                           &temperature, &humidity, &unused) ==
               SENSOR_SAMPLE_ERROR_NONE);
    }
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        assert(app_modbus_decode_registers(SENSOR_SHT40, invalid[i], 2U,
                                           &temperature, &humidity, &unused) ==
               SENSOR_SAMPLE_ERROR_OUT_OF_RANGE);
    }
}

static void test_do_decoding(void)
{
    const uint16_t registers[] = {
        0x42ADU, 0x0000U, 0x40DAU, 0x3D71U, 0x41CCU, 0x0000U,
    };
    float concentration, temperature, saturation;

    assert(app_modbus_decode_registers(SENSOR_DO, registers, 6U,
                                       &concentration, &temperature, &saturation) ==
           SENSOR_SAMPLE_ERROR_NONE);
    assert(fabsf(concentration - 6.82f) < 0.001f);
    assert(fabsf(temperature - 25.5f) < 0.001f);
    assert(fabsf(saturation - 86.5f) < 0.001f);
    assert(app_modbus_decode_registers(SENSOR_DO, registers, 2U,
                                       &concentration, &temperature, &saturation) ==
           SENSOR_SAMPLE_ERROR_PROTOCOL);
}

static void test_ph_decoding(void)
{
    const uint16_t registers[] = {725U, 265U};
    float ph, temperature, unused;

    assert(app_modbus_decode_registers(SENSOR_PH, registers, 2U,
                                       &ph, &temperature, &unused) ==
           SENSOR_SAMPLE_ERROR_NONE);
    assert(fabsf(ph - 7.25f) < 0.001f);
    assert(fabsf(temperature - 26.5f) < 0.001f);
}

static void test_datasheet_range_boundaries(void)
{
    const uint16_t do_saturation_200[] = {
        0x4348U, 0x0000U, 0x40DAU, 0x3D71U, 0x41CCU, 0x0000U,
    };
    const uint16_t do_saturation_over_200[] = {
        0x4348U, 0x4000U, 0x40DAU, 0x3D71U, 0x41CCU, 0x0000U,
    };
    const uint16_t ph_temperature_0[] = {700U, 0U};
    const uint16_t ph_temperature_60[] = {700U, 600U};
    const uint16_t ph_temperature_below_0[] = {700U, 0xFFFFU};
    const uint16_t ph_temperature_above_60[] = {700U, 601U};
    float v1, v2, v3;

    assert(app_modbus_decode_registers(SENSOR_DO, do_saturation_200, 6U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_NONE);
    assert(fabsf(v3 - 200.0f) < 0.001f);
    assert(app_modbus_decode_registers(SENSOR_DO, do_saturation_over_200, 6U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_OUT_OF_RANGE);

    assert(app_modbus_decode_registers(SENSOR_PH, ph_temperature_0, 2U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_NONE);
    assert(fabsf(v2) < 0.001f);
    assert(app_modbus_decode_registers(SENSOR_PH, ph_temperature_60, 2U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_NONE);
    assert(fabsf(v2 - 60.0f) < 0.001f);
    assert(app_modbus_decode_registers(SENSOR_PH, ph_temperature_below_0, 2U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_OUT_OF_RANGE);
    assert(app_modbus_decode_registers(SENSOR_PH, ph_temperature_above_60, 2U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_OUT_OF_RANGE);
}

static void test_reject_invalid_readings(void)
{
    const uint16_t ph_out_of_range[] = {1501U, 250U};
    const uint16_t do_nan[] = {0x42ADU, 0x0000U, 0x40DAU, 0x3D71U, 0x7FC0U, 0x0000U};
    float v1, v2, v3;

    assert(app_modbus_decode_registers(SENSOR_PH, ph_out_of_range, 2U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_OUT_OF_RANGE);
    assert(app_modbus_decode_registers(SENSOR_DO, do_nan, 6U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_OUT_OF_RANGE);
    assert(app_modbus_decode_registers(SENSOR_SHT40,
                                       (const uint16_t[]){200U, 500U}, 1U,
                                       &v1, &v2, &v3) == SENSOR_SAMPLE_ERROR_PROTOCOL);
}

int main(void)
{
    test_register_maps();
    test_sht40_decoding();
    test_sht40_boundaries();
    test_do_decoding();
    test_ph_decoding();
    test_datasheet_range_boundaries();
    test_reject_invalid_readings();
    return 0;
}
