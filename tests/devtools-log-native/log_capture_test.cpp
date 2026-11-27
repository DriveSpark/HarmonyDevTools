#include "log_capture.h"

#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <hilog/log.h>
#include <limits>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
const char *const bundle = "org.example.devtools.captureprobe";
const char *const worker = "org.example.devtools.captureprobe:worker";
const char *const tag = "DevToolsNativeProbe";

void Check(bool ok, const char *what) {
  if (ok) { return; }
  fprintf(stderr, "FAIL: %s\n", what);
  fflush(stderr);
  _exit(1);
}

void Print(const char *message) {
  OH_LOG_Print(LOG_APP, LOG_WARN, 0x2712, tag, "%{public}s", message);
}

devtools::LogEntry WaitFor(const std::string &text) {
  for (int tries = 0; tries < 200; ++tries) {
    devtools::LogUpdate update;
    Check(devtools::ReadLogCapture(0, update), "read native journal");
    for (const auto &entry : update.entries) {
      if (entry.tag == tag && entry.message == text) { return entry; }
    }
    usleep(10000);
  }
  Check(false, "timed out waiting for HiLog callback");
  return {};
}

pid_t Spawn(const char *command, const char *directory, const char *mode, int ready = -1, int go = -1) {
  const std::string readyArg = std::to_string(ready);
  const std::string goArg = std::to_string(go);
  const pid_t child = fork();
  Check(child >= 0, "fork child");
  if (child == 0) {
    execl(command, command, directory, mode, readyArg.c_str(), goArg.c_str(), nullptr);
    _exit(121);
  }
  return child;
}

void Wait(pid_t child, int expected = 0) {
  int status = 0;
  Check(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == expected, "child exit");
}

devtools::LogLine Line(const std::string &message) {
  return { 1234567890, devtools::MonotonicNanos(), LOG_INFO, tag, message };
}

int RunChild(const std::string &directory, const std::string &mode, int ready, int go) {
  if (mode == "deferred") {
    devtools::LogJournal journal;
    Check(journal.Open(directory, bundle, worker), "child open");
    const auto before = Line("before a remote clear");
    char marker = 'R';
    Check(write(ready, &marker, 1) == 1 && read(go, &marker, 1) == 1, "clear handshake");
    Check(journal.Write({ before, Line("after a remote clear") }), "commit after remote clear");
    return 0;
  }
  if (mode == "locked-exit") {
    devtools::LogJournal journal;
    Check(journal.Open(directory, bundle, worker), "crashing participant open");
    const int fd = open((directory + "/.devtools-hilog-v1.buffer").c_str(), O_RDWR);
    Check(fd >= 0 && flock(fd, LOCK_EX) == 0, "acquire kernel lock");
    _exit(23);  // Simulate death with the owner lease and ring lock held.
  }
  Check(devtools::AcquireLogCapture(directory, bundle, worker), "child callback registration");
  Print("native worker HiLog");
  const auto entry = WaitFor("native worker HiLog");
  Check(entry.pid == getpid() && entry.process == worker, "child identity");
  if (mode == "orphan") { _exit(19); }
  devtools::ReleaseLogCapture();
  return 0;
}

void TestCollector(const char *command, const char *directory) {
  devtools::LogUpdate inactive;
  Check(!devtools::ReadLogCapture(0, inactive), "capture requires explicit acquisition");
  Print("before registration");
  Check(devtools::AcquireLogCapture(directory, bundle, bundle), "start");
  Check(devtools::AcquireLogCapture(directory, bundle, bundle), "second owner");
  Print("host line contains other.bundle pid=999999");
  const auto own = WaitFor("host line contains other.bundle pid=999999");
  Check(own.pid == getpid() && own.bundle == bundle && own.process == bundle && own.level == LOG_WARN &&
    own.timeMs > 0, "identity is independent of log text");
  devtools::ReleaseLogCapture();
  Print("one owner remains");
  WaitFor("one owner remains");
  const pid_t child = Spawn(command, directory, "log");
  Wait(child);
  const auto other = WaitFor("native worker HiLog");
  Check(other.pid == child && other.pid != own.pid && other.bundle == bundle && other.process == worker,
        "shared real HiLog from second PID");
  printf("PASS two processes pid=%d, pid=%d; explicit enable and reference counting\n", own.pid, other.pid);

  int ready[2], go[2];
  Check(pipe(ready) == 0 && pipe(go) == 0, "pipes");
  const pid_t deferred = Spawn(command, directory, "deferred", ready[1], go[0]);
  char marker = 'G';
  Check(read(ready[0], &marker, 1) == 1 && devtools::ClearLogCapture(), "clear other writer's stale queue");
  Check(write(go[1], &marker, 1) == 1, "resume writer");
  Wait(deferred);
  for (int fd : { ready[0], ready[1], go[0], go[1] }) { close(fd); }
  devtools::LogUpdate cleared;
  Check(devtools::ReadLogCapture(0, cleared) && cleared.entries.size() == 1 &&
    cleared.entries[0].message == "after a remote clear" && cleared.entries[0].sequence > other.sequence,
    "only the post-clear line is visible");
  const auto last = cleared.latest;
  Wait(Spawn(command, directory, "locked-exit"), 23);
  Print("after writer death");
  WaitFor("after writer death");
  devtools::LogUpdate delta;
  Check(devtools::ReadLogCapture(last, delta) && delta.entries.size() == 1, "increment after lock owner death");
  devtools::ReleaseLogCapture();
  Check(!devtools::ReadLogCapture(0, inactive), "last release stops capture");
  struct stat state {};
  Check(stat((std::string(directory) + "/.devtools-hilog-v1.buffer").c_str(), &state) == 0 && state.st_size == 0,
        "clean last release truncates sandbox buffer");
  printf("PASS remote clear vs queued records, owner death unlock, incremental read, last release\n");

  Wait(Spawn(command, directory, "orphan"), 19);
  Check(devtools::AcquireLogCapture(directory, bundle, bundle), "reopen after all owners crashed");
  devtools::LogUpdate fresh;
  Check(devtools::ReadLogCapture(0, fresh) && fresh.entries.empty() && fresh.latest == 0, "no stale session data");
  devtools::ReleaseLogCapture();
  printf("PASS fresh session after unclean final process exit\n");
}

void TestWrap(const char *directory) {
  devtools::LogJournal journal;
  Check(journal.Open(directory, bundle, bundle), "capacity test open");
  std::vector<devtools::LogLine> rows;
  for (size_t i = 0; i < devtools::kMaxEntries + 3; ++i) { rows.push_back(Line(std::to_string(i))); }
  Check(journal.Write(rows), "ring write");
  devtools::LogUpdate full;
  Check(journal.Read(0, full) && full.entries.size() == 10000 && full.first == 4 &&
    full.entries.front().message == "3" && full.entries.back().message == "10002", "wrap retains last 10000");
  devtools::LogUpdate tail;
  Check(journal.Read(full.latest - 1, tail) && tail.entries.size() == 1 && tail.entries[0].sequence == full.latest,
        "incremental tail");
  printf("PASS capacity=10000, stable identities, incremental tail\n");

  const int fd = open((std::string(directory) + "/.devtools-hilog-v1.buffer").c_str(), O_RDWR);
  const uint64_t damaged = std::numeric_limits<uint64_t>::max();
  Check(fd >= 0 && pwrite(fd, &damaged, sizeof(damaged), 0) == sizeof(damaged), "place a damaged sequence");
  close(fd);
  devtools::LogUpdate invalid;
  Check(!journal.Read(0, invalid) && !journal.Clear() && !journal.Write({ Line("reject corrupted buffer") }),
        "damaged header is reported without enumeration or overwrite");
  printf("PASS damaged header rejected by read, write and clear\n");
}
}  // namespace

int main(int argc, char **argv) {
  if (argc == 5) { return RunChild(argv[1], argv[2], atoi(argv[3]), atoi(argv[4])); }
  Check(argc == 2, "usage: devtools_log_test <private test directory>");
#ifdef DEVTOOLS_TEST_LINUX_HOST
  puts("Linux host, HiLog callback stand-in");
#else
  puts("HarmonyOS, system HiLog callback");
#endif
  TestCollector(argv[0], argv[1]);
  TestWrap(argv[1]);
  return 0;
}
