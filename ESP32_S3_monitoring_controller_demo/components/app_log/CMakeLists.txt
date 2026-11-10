idf_component_register(SRCS "app_log.c" "app_errlog.c"
                       INCLUDE_DIRS "include"
                       REQUIRES log
                       PRIV_REQUIRES esp_partition espcoredump esp_timer)
