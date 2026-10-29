idf_component_register(SRCS "app_ble_prov.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES freertos
                       PRIV_REQUIRES app_log app_nvm bt esp_hw_support esp_wifi json log protocomm)
