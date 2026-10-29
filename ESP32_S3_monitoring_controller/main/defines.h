#ifndef DEFINES_H
#define DEFINES_H

#define APP_RS485_INTERFACE_COUNT 4
#define APP_ANALOG_4_20MA_INTERFACE_COUNT 1
#define APP_DI_COUNT 4
#define APP_DO_COUNT 4

/* Every input port the protocol can address: RS1..RS4, AN1, DI1..DI4 (in that order). */
#define APP_SENSOR_INTERFACE_COUNT \
    (APP_RS485_INTERFACE_COUNT + APP_ANALOG_4_20MA_INTERFACE_COUNT + APP_DI_COUNT)
#define APP_LOAD_COUNT APP_DO_COUNT

/* Per-load limits of the protocol (CON1..CON2, SHE1..SHE3). */
#define APP_CONDITIONS_PER_LOAD 2
#define APP_SCHEDULERS_PER_LOAD 3

#endif