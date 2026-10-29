#ifndef APP_PINS_H
#define APP_PINS_H

#include "defines.h"

/* PROVISIONAL pin map for ESP32-S3-WROOM-1U; confirm against the schematic (P0).
 * Avoids USB (19/20), SPI flash (26-32), octal PSRAM (33-37) and strapping pins (0/3/45/46). */

/* W5500 on SPI2_HOST; pins taken from the schematic (MCU.SchDoc). RSTn is only pulled up by R17 on
 * this board and is not routed to the MCU, hence no RST GPIO. */
 #define APP_PIN_ETH_CS     10
 #define APP_PIN_ETH_MOSI   11
#define APP_PIN_ETH_SCLK    12
#define APP_PIN_ETH_MISO    13
#define APP_PIN_ETH_INT     14
#define APP_PIN_ETH_RST     (-1)

/* RS485 on UART1 */
#define APP_PIN_RS485_TX    17
#define APP_PIN_RS485_RX    18
#define APP_PIN_RS485_DE_RE  8

/* Relay outputs DO0..DO3 (opto-SSR drivers, active high), pins taken from the schematic */
#define APP_PIN_RELAY_4     5
#define APP_PIN_RELAY_3     6
#define APP_PIN_RELAY_2     7
#define APP_PIN_RELAY_1     15

/* Digital inputs DI1..DI4 (pulled up, active low: contact closed to GND reads true). PROVISIONAL
 * pins: not on the current schematic, confirm before wiring real inputs. */
#define APP_PIN_DI_1        45
#define APP_PIN_DI_2        46
#define APP_PIN_DI_3        47
#define APP_PIN_DI_4        48

/* Status LEDs (active high through 330 R), pins taken from the schematic. IO36/IO37 are also the
 * octal PSRAM pins of the N8R8 module: do not enable PSRAM while these LEDs are fitted. The relay
 * LEDs are driven by the DO lines, so there is no separate load LED. */
#define APP_PIN_LED_WIFI    36
#define APP_PIN_LED_ETH     37
#define APP_PIN_LED_ERROR   38
#define APP_PIN_LED_LOAD    (-1)

/* User push button SW3 on IO4: pulled up by R62, pressed = LOW (schematic MCU.SchDoc) */
#define APP_PIN_BUTTON_RESET 4

#endif
