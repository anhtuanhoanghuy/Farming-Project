#include "app_log.h"

#ifdef CONFIG_APP_LOG_DEFAULT_ENABLED
#define LOG_DEFAULT true
#else
#define LOG_DEFAULT false
#endif

static volatile bool s_enabled = LOG_DEFAULT;

bool app_log_enabled(void)
{
    return s_enabled;
}

void app_log_set_enabled(bool enabled)
{
    s_enabled = enabled;
}

bool app_log_toggle(void)
{
    s_enabled = !s_enabled;
    return s_enabled;
}
