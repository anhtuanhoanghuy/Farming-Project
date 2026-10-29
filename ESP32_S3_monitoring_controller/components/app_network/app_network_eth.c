#include "app_network_eth.h"

#include <stdlib.h>
#include <string.h>

#include "driver/gpio.h"
#include "esp_eth.h"
#include "esp_event.h"
#include "esp_mac.h"
#include "app_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define ETH_BIT_LINK    (1U << 0)
#define ETH_BIT_GOT_IP  (1U << 1)
#define ETH_BIT_STARTED (1U << 2)
#define ETH_BIT_FAULT   (1U << 3)

/* Must stay above the Wi-Fi STA route_prio (100) so ETH is the preferred default netif. */
#define ETH_NETIF_ROUTE_PRIO 120

/* W5500 SPI frame for VERSIONR (0x0039) in the common register block, read, variable length. */
#define W5500_VERSIONR_ADDR_PHASE 0x0039U
#define W5500_VERSIONR_CTRL_PHASE 0x00U
#define W5500_SPI_LOCK_TIMEOUT_MS 50U
#define ETH_RESET_WINDOW_US       (3600LL * 1000000LL)

typedef struct {
    spi_device_handle_t hdl;
    SemaphoreHandle_t lock;
} eth_spi_ctx_t;

static const char *TAG = "app_eth";

static const spi_device_interface_config_t s_spi_devcfg = {
    .command_bits = 16, /* W5500 address phase */
    .address_bits = 8,  /* W5500 control phase */
    .mode = 0,
    .clock_speed_hz = APP_ETH_SPI_CLOCK_HZ,
    .spics_io_num = APP_ETH_PIN_CS,
    .queue_size = 20,
};

static bool s_initialized;
static esp_netif_t *s_netif;
static esp_eth_handle_t s_eth;
static esp_eth_netif_glue_handle_t s_glue;
static eth_spi_ctx_t *s_spi;
static EventGroupHandle_t s_state;
static uint32_t s_bad_reads;
static uint32_t s_reset_count;
static int64_t s_reset_times_us[APP_ETH_RESET_MAX_PER_HOUR];

/* Custom SPI driver so the health check shares the bus device and lock with the MAC driver. */
static void *eth_spi_init(const void *config)
{
    const spi_device_interface_config_t *devcfg = config;
    eth_spi_ctx_t *spi = calloc(1, sizeof(*spi));

    if (spi == NULL) {
        return NULL;
    }
    spi->lock = xSemaphoreCreateMutex();
    if (spi->lock == NULL || spi_bus_add_device(APP_ETH_SPI_HOST, devcfg, &spi->hdl) != ESP_OK) {
        ESP_LOGE(TAG, "SPI device setup failed");
        if (spi->lock != NULL) {
            vSemaphoreDelete(spi->lock);
        }
        free(spi);
        return NULL;
    }
    s_spi = spi;
    return spi;
}

static esp_err_t eth_spi_deinit(void *ctx)
{
    eth_spi_ctx_t *spi = ctx;

    spi_bus_remove_device(spi->hdl);
    vSemaphoreDelete(spi->lock);
    if (s_spi == spi) {
        s_spi = NULL;
    }
    free(spi);
    return ESP_OK;
}

static esp_err_t eth_spi_read(void *ctx, uint32_t cmd, uint32_t addr, void *data, uint32_t len)
{
    eth_spi_ctx_t *spi = ctx;
    spi_transaction_t trans = {
        .cmd = cmd,
        .addr = addr,
        .length = 8U * len,
    };

    if (len <= 4U) {
        trans.flags = SPI_TRANS_USE_RXDATA;
    } else {
        trans.rx_buffer = data;
    }
    if (xSemaphoreTake(spi->lock, pdMS_TO_TICKS(W5500_SPI_LOCK_TIMEOUT_MS)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    esp_err_t err = spi_device_polling_transmit(spi->hdl, &trans);
    xSemaphoreGive(spi->lock);
    if (err != ESP_OK) {
        return ESP_FAIL;
    }
    if (len <= 4U) {
        memcpy(data, trans.rx_data, len);
    }
    return ESP_OK;
}

static esp_err_t eth_spi_write(void *ctx, uint32_t cmd, uint32_t addr, const void *data,
                               uint32_t len)
{
    eth_spi_ctx_t *spi = ctx;
    spi_transaction_t trans = {
        .cmd = cmd,
        .addr = addr,
        .length = 8U * len,
        .tx_buffer = data,
    };

    if (xSemaphoreTake(spi->lock, pdMS_TO_TICKS(W5500_SPI_LOCK_TIMEOUT_MS)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    esp_err_t err = spi_device_polling_transmit(spi->hdl, &trans);
    xSemaphoreGive(spi->lock);
    return err == ESP_OK ? ESP_OK : ESP_FAIL;
}

static void eth_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;

    if (base == ETH_EVENT) {
        switch (id) {
        case ETHERNET_EVENT_START:
            ESP_LOGI(TAG, "driver started");
            break;
        case ETHERNET_EVENT_STOP:
            xEventGroupClearBits(s_state, ETH_BIT_LINK | ETH_BIT_GOT_IP);
            ESP_LOGI(TAG, "driver stopped");
            break;
        case ETHERNET_EVENT_CONNECTED:
            xEventGroupSetBits(s_state, ETH_BIT_LINK);
            ESP_LOGI(TAG, "cable connected, waiting for DHCP");
            break;
        case ETHERNET_EVENT_DISCONNECTED:
            xEventGroupClearBits(s_state, ETH_BIT_LINK | ETH_BIT_GOT_IP);
            ESP_LOGW(TAG, "cable disconnected");
            break;
        default:
            break;
        }
    } else if (base == IP_EVENT) {
        if (id == IP_EVENT_ETH_GOT_IP) {
            const ip_event_got_ip_t *event = data;

            xEventGroupSetBits(s_state, ETH_BIT_GOT_IP);
            ESP_LOGI(TAG, "got IP " IPSTR, IP2STR(&event->ip_info.ip));
        } else if (id == IP_EVENT_ETH_LOST_IP) {
            xEventGroupClearBits(s_state, ETH_BIT_GOT_IP);
            ESP_LOGW(TAG, "lost IP");
        }
    }
}

static void hard_reset_pulse(void)
{
    const int rst = APP_ETH_PIN_RST;

    if (rst < 0) {
        ESP_LOGW(TAG, "no RST pin wired; relying on the W5500 software reset at driver init");
        return;
    }
    gpio_reset_pin(rst);
    gpio_set_direction(rst, GPIO_MODE_OUTPUT);
    gpio_set_level(rst, 0);
    vTaskDelay(pdMS_TO_TICKS(APP_ETH_RESET_PULSE_MS));
    gpio_set_level(rst, 1);
    vTaskDelay(pdMS_TO_TICKS(APP_ETH_RESET_PULSE_MS));
}

static esp_err_t eth_driver_create(void)
{
    const spi_bus_config_t bus_config = {
        .mosi_io_num = APP_ETH_PIN_MOSI,
        .miso_io_num = APP_ETH_PIN_MISO,
        .sclk_io_num = APP_ETH_PIN_SCLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
    };
    esp_err_t err = spi_bus_initialize(APP_ETH_SPI_HOST, &bus_config, SPI_DMA_CH_AUTO);

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SPI bus init failed: %s", esp_err_to_name(err));
        return err;
    }

    eth_w5500_config_t w5500_config = ETH_W5500_DEFAULT_CONFIG(APP_ETH_SPI_HOST,
                                                               (spi_device_interface_config_t *)&s_spi_devcfg);
    w5500_config.int_gpio_num = APP_ETH_PIN_INT;
    w5500_config.custom_spi_driver = (eth_spi_custom_driver_config_t){
        .config = (void *)&s_spi_devcfg,
        .init = eth_spi_init,
        .deinit = eth_spi_deinit,
        .read = eth_spi_read,
        .write = eth_spi_write,
    };

    eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
    esp_eth_mac_t *mac = esp_eth_mac_new_w5500(&w5500_config, &mac_config);
    if (mac == NULL) {
        ESP_LOGE(TAG, "W5500 MAC creation failed");
        err = ESP_FAIL;
        goto fail_bus;
    }

    eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
    phy_config.phy_addr = 1;
    phy_config.reset_gpio_num = APP_ETH_PIN_RST;
    esp_eth_phy_t *phy = esp_eth_phy_new_w5500(&phy_config);
    if (phy == NULL) {
        ESP_LOGE(TAG, "W5500 PHY creation failed");
        err = ESP_FAIL;
        goto fail_mac;
    }

    esp_eth_config_t eth_config = ETH_DEFAULT_CONFIG(mac, phy);
    eth_config.check_link_period_ms = APP_ETH_LINK_CHECK_MS;
    err = esp_eth_driver_install(&eth_config, &s_eth);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "driver install failed: %s", esp_err_to_name(err));
        s_eth = NULL;
        phy->del(phy);
        goto fail_mac;
    }

    uint8_t mac_addr[6];
    err = esp_read_mac(mac_addr, ESP_MAC_ETH);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "read Ethernet MAC from eFuse failed: %s", esp_err_to_name(err));
        goto fail_driver;
    }
    err = esp_eth_ioctl(s_eth, ETH_CMD_S_MAC_ADDR, mac_addr);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "set W5500 MAC address failed: %s", esp_err_to_name(err));
        goto fail_driver;
    }
    ESP_LOGI(TAG, "W5500 MAC " MACSTR, MAC2STR(mac_addr));

    s_glue = esp_eth_new_netif_glue(s_eth);
    if (s_glue == NULL) {
        ESP_LOGE(TAG, "netif glue creation failed");
        err = ESP_ERR_NO_MEM;
        goto fail_driver;
    }
    err = esp_netif_attach(s_netif, s_glue);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "netif attach failed: %s", esp_err_to_name(err));
        goto fail_glue;
    }
    return ESP_OK;

fail_glue:
    esp_eth_del_netif_glue(s_glue);
    s_glue = NULL;
fail_driver:
    esp_eth_driver_uninstall(s_eth);
    s_eth = NULL;
    spi_bus_free(APP_ETH_SPI_HOST);
    return err;
fail_mac:
    mac->del(mac);
fail_bus:
    spi_bus_free(APP_ETH_SPI_HOST);
    return err;
}

static esp_err_t eth_driver_destroy(void)
{
    if (s_glue != NULL) {
        esp_eth_del_netif_glue(s_glue);
        s_glue = NULL;
    }
    if (s_eth != NULL) {
        esp_err_t err = esp_eth_driver_uninstall(s_eth);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "driver uninstall failed: %s", esp_err_to_name(err));
            return err;
        }
        s_eth = NULL;
    }
    return spi_bus_free(APP_ETH_SPI_HOST);
}

static bool reset_budget_available(void)
{
    int64_t now = esp_timer_get_time();
    unsigned used = 0;

    for (size_t i = 0; i < APP_ETH_RESET_MAX_PER_HOUR; i++) {
        if (s_reset_times_us[i] != 0 && now - s_reset_times_us[i] < ETH_RESET_WINDOW_US) {
            used++;
        }
    }
    return used < APP_ETH_RESET_MAX_PER_HOUR;
}

static void record_reset(void)
{
    size_t oldest = 0;

    for (size_t i = 1; i < APP_ETH_RESET_MAX_PER_HOUR; i++) {
        if (s_reset_times_us[i] < s_reset_times_us[oldest]) {
            oldest = i;
        }
    }
    s_reset_times_us[oldest] = esp_timer_get_time();
    __atomic_fetch_add(&s_reset_count, 1U, __ATOMIC_RELAXED);
}

static void enter_fault(void)
{
    xEventGroupSetBits(s_state, ETH_BIT_FAULT);
    xEventGroupClearBits(s_state, ETH_BIT_STARTED | ETH_BIT_LINK | ETH_BIT_GOT_IP);
    if (s_eth != NULL) {
        (void)esp_eth_stop(s_eth);
    }
    ESP_LOGE(TAG, "reset limit (%u/h) reached; ETH disabled until reboot",
             (unsigned)APP_ETH_RESET_MAX_PER_HOUR);
}

static esp_err_t recover_hardware(void)
{
    if (!reset_budget_available()) {
        enter_fault();
        return ESP_ERR_INVALID_STATE;
    }
    record_reset();

    bool was_started = (xEventGroupGetBits(s_state) & ETH_BIT_STARTED) != 0U;

    /* An in-flight reset counts as link-down so the FSM can fail over immediately. */
    xEventGroupClearBits(s_state, ETH_BIT_LINK | ETH_BIT_GOT_IP);
    ESP_LOGW(TAG, "W5500 unresponsive, hardware recovery #%u",
             (unsigned)__atomic_load_n(&s_reset_count, __ATOMIC_RELAXED));

    if (s_eth != NULL) {
        esp_err_t err = esp_eth_stop(s_eth);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "esp_eth_stop: %s", esp_err_to_name(err));
        }
    }
    hard_reset_pulse();

    esp_err_t err = eth_driver_destroy();
    if (err != ESP_OK) {
        return err;
    }
    s_bad_reads = 0;
    err = eth_driver_create();
    if (err != ESP_OK) {
        return err;
    }
    if (was_started) {
        err = esp_eth_start(s_eth);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "restart after recovery failed: %s", esp_err_to_name(err));
            return err;
        }
    }
    ESP_LOGI(TAG, "W5500 recovered");
    return ESP_ERR_NOT_FINISHED;
}

esp_err_t app_eth_w5500_init(void)
{
    if (s_initialized) {
        return ESP_OK;
    }

    esp_err_t err = esp_netif_init();
    if (err != ESP_OK) {
        return err;
    }
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "event loop create failed: %s", esp_err_to_name(err));
        return err;
    }
    err = gpio_install_isr_service(0);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "GPIO ISR service failed: %s", esp_err_to_name(err));
        return err;
    }

    s_state = xEventGroupCreate();
    if (s_state == NULL) {
        return ESP_ERR_NO_MEM;
    }

    esp_netif_inherent_config_t base_config = ESP_NETIF_INHERENT_DEFAULT_ETH();
    base_config.route_prio = ETH_NETIF_ROUTE_PRIO;
    const esp_netif_config_t netif_config = {
        .base = &base_config,
        .driver = NULL,
        .stack = ESP_NETIF_NETSTACK_DEFAULT_ETH,
    };
    s_netif = esp_netif_new(&netif_config);
    if (s_netif == NULL) {
        ESP_LOGE(TAG, "ETH netif creation failed");
        err = ESP_FAIL;
        goto fail_group;
    }
    err = esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, eth_event_handler, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "ETH handler register failed: %s", esp_err_to_name(err));
        goto fail_netif;
    }
    err = esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, eth_event_handler, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "GOT_IP handler register failed: %s", esp_err_to_name(err));
        goto fail_eth_handler;
    }
    err = esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_LOST_IP, eth_event_handler, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "LOST_IP handler register failed: %s", esp_err_to_name(err));
        goto fail_got_ip_handler;
    }

    if (APP_ETH_PIN_RST >= 0) {
        hard_reset_pulse();
    }
    err = eth_driver_create();
    if (err != ESP_OK) {
        goto fail_lost_ip_handler;
    }

    s_initialized = true;
    ESP_LOGI(TAG, "W5500 initialised (SPI%d, %d Hz)", (int)APP_ETH_SPI_HOST + 1,
             (int)APP_ETH_SPI_CLOCK_HZ);
    return ESP_OK;

fail_lost_ip_handler:
    (void)esp_event_handler_unregister(IP_EVENT, IP_EVENT_ETH_LOST_IP, eth_event_handler);
fail_got_ip_handler:
    (void)esp_event_handler_unregister(IP_EVENT, IP_EVENT_ETH_GOT_IP, eth_event_handler);
fail_eth_handler:
    (void)esp_event_handler_unregister(ETH_EVENT, ESP_EVENT_ANY_ID, eth_event_handler);
fail_netif:
    esp_netif_destroy(s_netif);
    s_netif = NULL;
fail_group:
    vEventGroupDelete(s_state);
    s_state = NULL;
    return err;
}

esp_err_t app_eth_w5500_start(void)
{
    if (!s_initialized || s_eth == NULL || (xEventGroupGetBits(s_state) & ETH_BIT_FAULT) != 0U) {
        return ESP_ERR_INVALID_STATE;
    }
    if (xEventGroupGetBits(s_state) & ETH_BIT_STARTED) {
        return ESP_OK;
    }

    esp_err_t err = esp_eth_start(s_eth);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "start failed: %s", esp_err_to_name(err));
        return err;
    }
    xEventGroupSetBits(s_state, ETH_BIT_STARTED);
    return ESP_OK;
}

esp_err_t app_eth_w5500_stop(void)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }
    if (!(xEventGroupGetBits(s_state) & ETH_BIT_STARTED)) {
        return ESP_OK;
    }

    xEventGroupClearBits(s_state, ETH_BIT_STARTED | ETH_BIT_LINK | ETH_BIT_GOT_IP);
    if (s_eth == NULL) {
        return ESP_OK;
    }
    esp_err_t err = esp_eth_stop(s_eth);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "stop failed: %s", esp_err_to_name(err));
    }
    return err;
}

bool app_eth_w5500_is_connected(void)
{
    if (!s_initialized) {
        return false;
    }
    const EventBits_t want = ETH_BIT_LINK | ETH_BIT_GOT_IP;
    return (xEventGroupGetBits(s_state) & want) == want;
}

esp_netif_t *app_eth_get_netif_handle(void)
{
    return s_netif;
}

esp_err_t app_eth_check_hardware_health(void)
{
    if (!s_initialized || (xEventGroupGetBits(s_state) & ETH_BIT_FAULT) != 0U) {
        return ESP_ERR_INVALID_STATE;
    }
    if (s_eth == NULL) {
        /* A previous recovery left no driver; try again within the reset budget. */
        return recover_hardware();
    }

    uint8_t version = 0;
    esp_err_t err = s_spi != NULL ? eth_spi_read(s_spi, W5500_VERSIONR_ADDR_PHASE,
                                                 W5500_VERSIONR_CTRL_PHASE, &version, 1)
                                  : ESP_ERR_INVALID_STATE;

    if (err == ESP_OK && version == APP_ETH_W5500_VERSION) {
        s_bad_reads = 0;
        return ESP_OK;
    }

    s_bad_reads++;
    ESP_LOGW(TAG, "VERSIONR check failed (%u/%u): read=%s value=0x%02x", (unsigned)s_bad_reads,
             (unsigned)APP_ETH_HEALTH_FAIL_THRESHOLD, esp_err_to_name(err), version);
    if (s_bad_reads < APP_ETH_HEALTH_FAIL_THRESHOLD) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    return recover_hardware();
}

bool app_eth_w5500_is_faulted(void)
{
    return s_initialized && (xEventGroupGetBits(s_state) & ETH_BIT_FAULT) != 0U;
}

uint32_t app_eth_w5500_get_reset_count(void)
{
    return __atomic_load_n(&s_reset_count, __ATOMIC_RELAXED);
}
