#ifndef APP_LOG_H
#define APP_LOG_H

#include <stdbool.h>

#include "esp_log.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Runtime switch for application logs; toggled by a double click on the user button. */
bool app_log_enabled(void);
void app_log_set_enabled(bool enabled);
bool app_log_toggle(void);

#ifdef __cplusplus
}
#endif

/* Prints only while the user has logging enabled. */
#define PRINT_LOG(level, tag, format, ...)                                  \
    do {                                                                    \
        if (app_log_enabled()) {                                            \
            ESP_LOG_LEVEL(level, tag, format, ##__VA_ARGS__);               \
        }                                                                   \
    } while (0)

#define PRINT_LOGV(tag, format, ...) PRINT_LOG(ESP_LOG_VERBOSE, tag, format, ##__VA_ARGS__)
#define PRINT_LOGD(tag, format, ...) PRINT_LOG(ESP_LOG_DEBUG, tag, format, ##__VA_ARGS__)
#define PRINT_LOGI(tag, format, ...) PRINT_LOG(ESP_LOG_INFO, tag, format, ##__VA_ARGS__)
#define PRINT_LOGW(tag, format, ...) PRINT_LOG(ESP_LOG_WARN, tag, format, ##__VA_ARGS__)

/*
 * Application code keeps using ESP_LOGV/D/I/W; including this header routes them through
 * PRINT_LOG. ESP_LOGE is left untouched so that errors are never hidden.
 */
#undef ESP_LOGV
#undef ESP_LOGD
#undef ESP_LOGI
#undef ESP_LOGW
#define ESP_LOGV PRINT_LOGV
#define ESP_LOGD PRINT_LOGD
#define ESP_LOGI PRINT_LOGI
#define ESP_LOGW PRINT_LOGW

#endif
