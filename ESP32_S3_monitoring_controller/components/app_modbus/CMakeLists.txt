idf_component_register(SRCS "app_modbus.c" "app_modbus_proto.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES app_device app_sysmon driver esp_timer freertos
                       PRIV_REQUIRES app_control app_log esp_common esp_system log)
