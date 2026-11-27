#include "log_journal.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

namespace devtools {
namespace {

struct Header {
  uint64_t latest;
  uint64_t clearedThrough;
  int64_t clearedAtNs;
};

constexpr uint64_t kMaxJsSequence = 9007199254740991ULL;

bool ValidHeader(const Header &header) {
  return header.latest <= kMaxJsSequence && header.clearedThrough <= header.latest && header.clearedAtNs >= 0;
}

struct Slot {
  uint64_t sequence;
  int64_t timeMs;
  int32_t pid;
  int32_t level;
  char bundle[256];
  char process[512];
  char tag[kTagBytes + 1];
  char message[kMessageBytes + 1];
};

struct JournalFile {
  Header header;
  Slot slots[kMaxEntries];
};

bool LockFile(int fd, int flags) {
  int result;
  do {
    result = flock(fd, flags);
  } while (result == -1 && errno == EINTR);
  return result == 0;
}

class FileLock {
public:
  FileLock(int fd, int flags) : fd_(fd), locked_(LockFile(fd, flags)) {}
  ~FileLock() { if (locked_) { LockFile(fd_, LOCK_UN); } }
  bool Held() const { return locked_; }
private:
  int fd_;
  bool locked_;
};

bool WriteAt(int fd, const void *source, size_t length, off_t offset) {
  const char *data = static_cast<const char *>(source);
  while (length > 0) {
    const ssize_t written = pwrite(fd, data, length, offset);
    if (written < 0 && errno == EINTR) { continue; }
    if (written <= 0) { return false; }
    data += written;
    length -= static_cast<size_t>(written);
    offset += written;
  }
  return true;
}

template<size_t N>
void CopyText(char (&field)[N], const std::string &text) {
  const size_t length = std::min(text.size(), N - 1);
  memcpy(field, text.data(), length);
  field[length] = '\0';
}

bool WriteSlot(int fd, size_t index, uint64_t sequence, const Slot &slot, size_t messageBytes) {
  const off_t offset = offsetof(JournalFile, slots) + index * sizeof(Slot);
  constexpr size_t start = offsetof(Slot, timeMs);
  const size_t end = offsetof(Slot, message) + messageBytes + 1;
  // Publish the sequence only after the whole payload is present. A process killed
  // mid-write leaves a hole, never a mixture of the previous and new records.
  return WriteAt(fd, reinterpret_cast<const char *>(&slot) + start, end - start, offset + start) &&
    WriteAt(fd, &sequence, sizeof(sequence), offset);
}

int OpenPrivateFile(const std::string &path) {
  return open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR);
}

template<size_t N>
std::string ReadText(const char (&field)[N]) {
  return std::string(field, strnlen(field, N));
}

}  // namespace

int64_t MonotonicNanos() {
  timespec now {};
  clock_gettime(CLOCK_MONOTONIC, &now);
  return static_cast<int64_t>(now.tv_sec) * 1000000000LL + now.tv_nsec;
}

bool LogJournal::Open(const std::string &directory, const std::string &bundle, const std::string &process) {
  if (directory.empty() || bundle.empty() || process.empty() ||
      bundle.size() >= sizeof(Slot::bundle) || process.size() >= sizeof(Slot::process)) {
    return false;
  }
  bundle_ = bundle;
  process_ = process;
  pid_ = getpid();
  dataFd_ = OpenPrivateFile(directory + "/.devtools-hilog-v1.buffer");
  ownerFd_ = OpenPrivateFile(directory + "/.devtools-hilog-v1.owners");
  if (dataFd_ < 0 || ownerFd_ < 0) { return false; }
  FileLock guard(dataFd_, LOCK_EX);
  if (!guard.Held()) { return false; }
  const bool firstOwner = LockFile(ownerFd_, LOCK_EX | LOCK_NB);
  if (!firstOwner && errno != EWOULDBLOCK) { return false; }
  if (firstOwner) {
    // Sparse allocation reserves address space. Only bytes actually logged consume storage.
    if (ftruncate(dataFd_, 0) != 0 || ftruncate(dataFd_, sizeof(JournalFile)) != 0) { return false; }
  }
  struct stat info {};
  if (!LockFile(ownerFd_, LOCK_SH) || fstat(dataFd_, &info) != 0 || info.st_size != sizeof(JournalFile)) {
    return false;
  }
  // Read-only mapping: writes use pwrite so low storage is an error, not a SIGBUS in the host.
  void *address = mmap(nullptr, sizeof(JournalFile), PROT_READ, MAP_SHARED, dataFd_, 0);
  if (address == MAP_FAILED) { return false; }
  mapping_ = address;
  return true;
}

LogJournal::~LogJournal() {
  if (mapping_ != nullptr) { munmap(const_cast<void *>(mapping_), sizeof(JournalFile)); }
  if (ownerFd_ >= 0 && dataFd_ >= 0) {
    FileLock guard(dataFd_, LOCK_EX);
    if (guard.Held()) {
      LockFile(ownerFd_, LOCK_UN);
      if (LockFile(ownerFd_, LOCK_EX | LOCK_NB)) { ftruncate(dataFd_, 0); }
      close(ownerFd_);
      ownerFd_ = -1;
    }
  }
  if (ownerFd_ >= 0) { close(ownerFd_); }
  if (dataFd_ >= 0) { close(dataFd_); }
}

bool LogJournal::Write(const std::vector<LogLine> &batch) {
  std::lock_guard<std::mutex> local(io_);
  FileLock guard(dataFd_, LOCK_EX);
  if (!guard.Held()) { return false; }
  const auto &file = *static_cast<const JournalFile *>(mapping_);
  const Header header = file.header;
  if (!ValidHeader(header)) { return false; }
  // Clear applies even to callbacks already queued in another participating process.
  const auto count = std::count_if(batch.begin(), batch.end(), [&](const LogLine &line) {
    return line.monotonicNs > header.clearedAtNs;
  });
  if (count == 0) { return true; }
  const uint64_t latest = header.latest + count;
  if (latest > kMaxJsSequence || !WriteAt(dataFd_, &latest, sizeof(latest), offsetof(Header, latest))) { return false; }
  uint64_t sequence = header.latest;
  Slot slot {};
  slot.pid = pid_;
  CopyText(slot.bundle, bundle_);
  CopyText(slot.process, process_);
  for (const auto &line : batch) {
    if (line.monotonicNs <= header.clearedAtNs) { continue; }
    ++sequence;
    slot.timeMs = line.timeMs;
    slot.level = line.level;
    CopyText(slot.tag, line.tag);
    CopyText(slot.message, line.message);
    if (!WriteSlot(dataFd_, (sequence - 1) % kMaxEntries, sequence, slot,
                   std::min(line.message.size(), kMessageBytes))) { return false; }
  }
  return true;
}

bool LogJournal::Read(uint64_t after, LogUpdate &update) {
  std::lock_guard<std::mutex> local(io_);
  FileLock guard(dataFd_, LOCK_SH);
  if (!guard.Held()) { return false; }
  const auto &file = *static_cast<const JournalFile *>(mapping_);
  const Header header = file.header;
  if (!ValidHeader(header)) { return false; }
  const uint64_t overwritten = header.latest > kMaxEntries ? header.latest - kMaxEntries : 0;
  update.first = std::max(overwritten, header.clearedThrough) + 1;
  update.latest = header.latest;
  const uint64_t begin = std::max(after + 1, update.first);
  for (uint64_t sequence = begin; sequence <= header.latest; ++sequence) {
    const Slot &slot = file.slots[(sequence - 1) % kMaxEntries];
    if (slot.sequence == sequence) {
      update.entries.push_back({ sequence, slot.timeMs, slot.pid, slot.level, ReadText(slot.bundle),
        ReadText(slot.process), ReadText(slot.tag), ReadText(slot.message) });
    }
  }
  return true;
}

bool LogJournal::Clear() {
  std::lock_guard<std::mutex> local(io_);
  FileLock guard(dataFd_, LOCK_EX);
  if (!guard.Held()) { return false; }
  Header header = static_cast<const JournalFile *>(mapping_)->header;
  if (!ValidHeader(header)) { return false; }
  header.clearedThrough = header.latest;
  header.clearedAtNs = MonotonicNanos();
  return WriteAt(dataFd_, &header, sizeof(header), 0);
}

}  // namespace devtools
