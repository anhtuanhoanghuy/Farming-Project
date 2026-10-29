#ifndef APP_NETWORK_ETH_H
#define APP_NETWORK_ETH_H

#include <stdbool.h>
#include <stdint.h>

#include "app_pins.h"
#include "driver/spi_master.h"
#include "esp_err.h"
#include "esp_netif.h"

#ifdef __cplusplus
extern "C" {
#endif

/* W5500 on FSPI (SPI2_HOST); these pins are the S3 IOMUX pins, so full-speed SPI is possible. */
#ifndef APP_ETH_SPI_HOST
#define APP_ETH_SPI_HOST SPI2_HOST
#endif
#ifndef APP_ETH_SPI_CLOCK_HZ
#define APP_ETH_SPI_CLOCK_HZ (20 * 1000 * 1000)
#endif
#define APP_ETH_PIN_SCLK APP_PIN_ETH_SCLK
#define APP_ETH_PIN_MOSI APP_PIN_ETH_MOSI
#define APP_ETH_PIN_MISO APP_PIN_ETH_MISO
#define APP_ETH_PIN_CS   APP_PIN_ETH_CS
#define APP_ETH_PIN_INT  APP_PIN_ETH_INT
/* -1 when RSTn is not wired to the MCU; recovery then relies on the W5500 software reset. */
#define APP_ETH_PIN_RST  APP_PIN_ETH_RST

#ifndef APP_ETH_LINK_CHECK_MS
#define APP_ETH_LINK_CHECK_MS 500U
#endif

/* VERSIONR (0x0039) health check and recovery policy, spec FINAL 3.8. */
#define APP_ETH_W5500_VERSION            0x04U
#define APP_ETH_HEALTH_FAIL_THRESHOLD    3U
#define APP_ETH_RESET_PULSE_MS           50U
#define APP_ETH_RESET_MAX_PER_HOUR       3U

/*
 * Creates the ETH netif (route priority above Wi-Fi STA), the SPI bus and the W5500 driver, and
 * registers the Ethernet/IP event handlers. Does not start the link. Idempotent after success.
 * Requires the W5500 driver (CONFIG_ETH_SPI_ETHERNET_W5500) and the default event loop.
 */
esp_err_t app_eth_w5500_init(void);

/* Starts the driver; link and DHCP progress is reported through events. */
esp_err_t app_eth_w5500_start(void);

/* Stops the driver and clears the link/IP state. */
esp_err_t app_eth_w5500_stop(void);

/* True while the cable is connected and the netif holds an IPv4 address. Any task may call it. */
bool app_eth_w5500_is_connected(void);

/* Returns the ETH netif, or NULL before app_eth_w5500_init() succeeds. */
esp_netif_t *app_eth_get_netif_handle(void);

/*
 * Reads VERSIONR over SPI. Intended for the periodic (5 s) check from net_mgmt_task; it blocks for
 * ~50 ms plus driver reinstall time when it has to recover, so never call it from the event loop.
 * Returns:
 *   ESP_OK                    VERSIONR == 0x04
 *   ESP_ERR_INVALID_RESPONSE  bad read (0x00/0xFF/other or SPI error), below the failure threshold
 *   ESP_ERR_NOT_FINISHED      threshold reached; hard reset + driver reinstall done, wait for events
 *   ESP_ERR_INVALID_STATE     not initialised, or ETH is FAULT (reset limit hit) until reboot
 *   other                     recovery itself failed
 */
esp_err_t app_eth_check_hardware_health(void);

/* True once the per-hour reset budget is exhausted; the system must run Wi-Fi only until reboot. */
bool app_eth_w5500_is_faulted(void);

/* Number of hardware recoveries since boot, for the w5500_reset_cnt diagnostic. */
uint32_t app_eth_w5500_get_reset_count(void);

#ifdef __cplusplus
}
#endif

#endif
