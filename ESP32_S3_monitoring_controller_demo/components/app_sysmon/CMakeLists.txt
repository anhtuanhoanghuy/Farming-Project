idf_component_register(SRCS "app_sysmon.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES app_control app_network freertos
                       PRIV_REQUIRES app_log app_nvm driver esp_system esp_timer log)
