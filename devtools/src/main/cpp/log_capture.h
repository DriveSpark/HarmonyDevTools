#ifndef DEVTOOLS_LOG_CAPTURE_H
#define DEVTOOLS_LOG_CAPTURE_H

#include "log_journal.h"

namespace devtools {

bool AcquireLogCapture(const std::string &directory, const std::string &bundle, const std::string &process);
void ReleaseLogCapture();
bool ReadLogCapture(uint64_t after, LogUpdate &update);
bool ClearLogCapture();

}  // namespace devtools
#endif
