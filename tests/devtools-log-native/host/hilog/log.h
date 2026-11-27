#ifndef DEVTOOLS_TEST_HOST_HILOG_H
#define DEVTOOLS_TEST_HOST_HILOG_H

// The Linux fixture only substitutes the HarmonyOS SDK boundary; IPC, clocks and PIDs are real.
typedef enum { LOG_APP = 0 } LogType;
typedef enum { LOG_DEBUG = 3, LOG_INFO, LOG_WARN, LOG_ERROR, LOG_FATAL } LogLevel;
using LogCallback = void (*)(LogType, LogLevel, unsigned int, const char *, const char *);
extern "C" void OH_LOG_SetCallback(LogCallback callback);
extern "C" int OH_LOG_Print(LogType type, LogLevel level, unsigned int domain, const char *tag, const char *format, ...);

#endif
