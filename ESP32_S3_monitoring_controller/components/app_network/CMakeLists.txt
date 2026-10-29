idf_component_register(SRCS "app_network.c" "app_network_wifi.c" "app_network_eth.c"
                            "app_network_fsm.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES driver esp_eth esp_netif freertos
                       PRIV_REQUIRES app_log esp_event esp_system esp_timer esp_wifi log lwip)
