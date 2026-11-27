// Host Linux has no HiLog service. Keep this boundary separate from the real collector and ring.
#include <atomic>
#include <cstdarg>
#include <hilog/log.h>

namespace {
std::atomic<LogCallback> callback {nullptr};
}

extern "C" void OH_LOG_SetCallback(LogCallback target) { callback.store(target); }

extern "C" int OH_LOG_Print(LogType type, LogLevel level, unsigned int domain, const char *tag, const char *format, ...) {
  va_list args;
  va_start(args, format);
  const char *message = va_arg(args, const char *);
  va_end(args);
  const auto target = callback.load();
  if (target) { target(type, level, domain, tag, message); }
  return 0;
}
