idf_component_register(SRCS "app_cellular.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES driver esp_timer esp_event esp_netif esp_modem)
