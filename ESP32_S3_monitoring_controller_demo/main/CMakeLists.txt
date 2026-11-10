idf_component_register(SRCS "main.c"
                       INCLUDE_DIRS "."
                       REQUIRES app_ble_prov app_control app_device app_log app_modbus app_mqtt app_network app_nvm app_sysmon esp_event)
