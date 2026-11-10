idf_component_register(SRCS "app_nvm.c"
                       INCLUDE_DIRS "include" "../../main"
                       REQUIRES app_log driver esp_hw_support esp_system freertos log nvs_flash)