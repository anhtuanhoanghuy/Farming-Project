idf_component_register(SRCS "app_mqtt.c" "app_mqtt_cmd.c" "app_mqtt_proto.c" "app_telemetry_buffer.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES app_network esp_netif freertos
                       PRIV_REQUIRES app_control app_device app_log app_modbus app_nvm driver esp-tls esp_event esp_hw_support esp_timer json log mqtt)
