idf_component_register(SRCS "app_device.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES app_nvm freertos
                       PRIV_REQUIRES app_log log nvs_flash)
