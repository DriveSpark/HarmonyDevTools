#include "log_capture.h"

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <hilog/log.h>
#include <memory>
#include <thread>
#include <time.h>

namespace devtools {
namespace {

std::mutex lifecycle;
size_t owners = 0;
std::unique_ptr<LogJournal> journal;
std::thread writer;
std::mutex queueMutex;
std::condition_variable wakeWriter;
std::deque<LogLine> pending;
bool accepting = false;
int64_t startedAtNs = 0;
std::atomic_bool writeFailed {false};

std::string BoundedText(const char *text, size_t limit) {
  return text == nullptr ? std::string() : std::string(text, strnlen(text, limit));
}

void OnLog(LogType, LogLevel level, unsigned int, const char *tag, const char *message) noexcept {
  // Called on arbitrary host threads. Never call HiLog, N-API or the filesystem here.
  static thread_local bool inCallback = false;
  if (inCallback) { return; }
  inCallback = true;
  const int64_t arrived = MonotonicNanos();
  timespec now {};
  clock_gettime(CLOCK_REALTIME, &now);
  try {
    std::lock_guard<std::mutex> lock(queueMutex);
    if (accepting && arrived >= startedAtNs) {
      if (pending.size() == kMaxEntries) { pending.pop_front(); }
      pending.push_back({ static_cast<int64_t>(now.tv_sec) * 1000 + now.tv_nsec / 1000000, arrived,
        static_cast<int>(level), BoundedText(tag, kTagBytes), BoundedText(message, kMessageBytes) });
      wakeWriter.notify_one();
    }
  } catch (...) {
    // The diagnostic tap must never unwind into the host's logging call.
    writeFailed.store(true);
  }
  inCallback = false;
}

void DrainQueue() noexcept {
  try {
    constexpr size_t batchLimit = 64;
    std::vector<LogLine> batch;
    batch.reserve(batchLimit);
    for (;;) {
      {
        std::unique_lock<std::mutex> lock(queueMutex);
        wakeWriter.wait(lock, [] { return !pending.empty() || !accepting; });
        if (pending.empty() && !accepting) { break; }
        while (!pending.empty() && batch.size() < batchLimit) {
          batch.push_back(std::move(pending.front()));
          pending.pop_front();
        }
      }
      if (!journal->Write(batch)) { writeFailed.store(true); }
      batch.clear();
    }
  } catch (...) {
    writeFailed.store(true);
  }
}

}  // namespace

bool AcquireLogCapture(const std::string &directory, const std::string &bundle, const std::string &process) {
  std::lock_guard<std::mutex> lock(lifecycle);
  if (owners > 0) {
    ++owners;
    return true;
  }
  auto opened = std::make_unique<LogJournal>();
  if (!opened->Open(directory, bundle, process)) { return false; }
  journal = std::move(opened);
  {
    std::lock_guard<std::mutex> queueLock(queueMutex);
    startedAtNs = MonotonicNanos();
    accepting = true;
    writeFailed.store(false);
  }
  try {
    writer = std::thread(DrainQueue);
  } catch (...) {
    std::lock_guard<std::mutex> queueLock(queueMutex);
    accepting = false;
    journal.reset();
    throw;
  }
  owners = 1;
  OH_LOG_SetCallback(OnLog);
  return true;
}

void ReleaseLogCapture() {
  std::lock_guard<std::mutex> lock(lifecycle);
  if (owners == 0 || --owners > 0) { return; }
  {
    std::lock_guard<std::mutex> queueLock(queueMutex);
    accepting = false;
  }
  OH_LOG_SetCallback(nullptr);
  wakeWriter.notify_one();
  writer.join();
  pending.clear();
  journal.reset();
}

bool ReadLogCapture(uint64_t after, LogUpdate &update) {
  std::lock_guard<std::mutex> lock(lifecycle);
  update.writeFailed = writeFailed.load();
  return owners > 0 && journal->Read(after, update);
}

bool ClearLogCapture() {
  std::lock_guard<std::mutex> lock(lifecycle);
  if (owners == 0 || !journal->Clear()) { return false; }
  writeFailed.store(false);
  return true;
}

}  // namespace devtools
