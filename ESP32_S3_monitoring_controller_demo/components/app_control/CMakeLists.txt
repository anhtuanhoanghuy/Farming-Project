idf_component_register(SRCS "app_control.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES app_device driver freertos esp_timer
                       PRIV_REQUIRES app_log esp_system log)