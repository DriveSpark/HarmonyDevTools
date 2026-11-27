#ifndef DEVTOOLS_LOG_JOURNAL_H
#define DEVTOOLS_LOG_JOURNAL_H

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace devtools {

constexpr size_t kMaxEntries = 10000;
constexpr size_t kTagBytes = 32;
constexpr size_t kMessageBytes = 4096;

struct LogLine {
  int64_t timeMs;
  int64_t monotonicNs;
  int level;
  std::string tag;
  std::string message;
};

struct LogEntry {
  uint64_t sequence;
  int64_t timeMs;
  int32_t pid;
  int32_t level;
  std::string bundle;
  std::string process;
  std::string tag;
  std::string message;
};

struct LogUpdate {
  uint64_t first = 1;
  uint64_t latest = 0;
  bool writeFailed = false;
  std::vector<LogEntry> entries;
};

int64_t MonotonicNanos();

// Cooperating processes share a bounded, owner-only sandbox file. Kernel locks survive
// a writer dying and are automatically released when its process exits.
class LogJournal {
public:
  LogJournal() = default;
  LogJournal(const LogJournal &) = delete;
  LogJournal &operator=(const LogJournal &) = delete;
  ~LogJournal();
  bool Open(const std::string &directory, const std::string &bundle, const std::string &process);
  bool Write(const std::vector<LogLine> &batch);
  bool Read(uint64_t after, LogUpdate &update);
  bool Clear();

private:
  std::mutex io_;
  int dataFd_ = -1;
  int ownerFd_ = -1;
  const void *mapping_ = nullptr;
  std::string bundle_;
  std::string process_;
  int pid_ = 0;
};

}  // namespace devtools
#endif
