#include "log_capture.h"

#include <cmath>
#include <memory>
#include <napi/native_api.h>

namespace {

struct Environment {
  size_t leases = 0;
};

napi_value Fail(napi_env env, const char *message) {
  napi_throw_error(env, nullptr, message);
  return nullptr;
}

napi_value Undefined(napi_env env) {
  napi_value result = nullptr;
  napi_get_undefined(env, &result);
  return result;
}

bool Arguments(napi_env env, napi_callback_info info, size_t count, napi_value *args, Environment *&state) {
  size_t actual = count;
  void *data = nullptr;
  if (napi_get_cb_info(env, info, &actual, args, nullptr, &data) != napi_ok || actual != count || !data) {
    return false;
  }
  state = static_cast<Environment *>(data);
  return true;
}

bool ReadString(napi_env env, napi_value input, std::string &output) {
  size_t size = 0;
  if (napi_get_value_string_utf8(env, input, nullptr, 0, &size) != napi_ok || size == 0 || size > 4096) {
    return false;
  }
  output.resize(size + 1);
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, input, output.data(), output.size(), &copied) != napi_ok || copied != size) {
    return false;
  }
  output.resize(copied);
  return output.find('\0') == std::string::npos;
}

napi_value Acquire(napi_env env, napi_callback_info info) {
  try {
    napi_value args[3];
    Environment *state = nullptr;
    std::string directory, bundle, process;
    if (!Arguments(env, info, 3, args, state) || !ReadString(env, args[0], directory) ||
        !ReadString(env, args[1], bundle) || !ReadString(env, args[2], process) ||
        !devtools::AcquireLogCapture(directory, bundle, process)) {
      return Fail(env, "Cannot open the application HiLog buffer");
    }
    ++state->leases;
    return Undefined(env);
  } catch (...) {
    return Fail(env, "Cannot start HiLog capture");
  }
}

bool SetNumber(napi_env env, napi_value object, const char *key, double number) {
  napi_value value = nullptr;
  return napi_create_double(env, number, &value) == napi_ok && napi_set_named_property(env, object, key, value) == napi_ok;
}

bool SetText(napi_env env, napi_value object, const char *key, const std::string &text) {
  napi_value value = nullptr;
  return napi_create_string_utf8(env, text.data(), text.size(), &value) == napi_ok &&
    napi_set_named_property(env, object, key, value) == napi_ok;
}

bool SetEntry(napi_env env, napi_value entries, uint32_t index, const devtools::LogEntry &entry) {
  napi_value object = nullptr;
  return napi_create_object(env, &object) == napi_ok && SetText(env, object, "id", std::to_string(entry.sequence)) &&
    SetNumber(env, object, "time", entry.timeMs) && SetNumber(env, object, "pid", entry.pid) &&
    SetNumber(env, object, "level", entry.level) && SetText(env, object, "bundleName", entry.bundle) &&
    SetText(env, object, "processName", entry.process) && SetText(env, object, "tag", entry.tag) &&
    SetText(env, object, "message", entry.message) && napi_set_element(env, entries, index, object) == napi_ok;
}

napi_value ReadSince(napi_env env, napi_callback_info info) {
  try {
    napi_value args[1];
    Environment *state = nullptr;
    double after = 0;
    devtools::LogUpdate update;
    if (!Arguments(env, info, 1, args, state) || state->leases == 0 ||
        napi_get_value_double(env, args[0], &after) != napi_ok || !std::isfinite(after) ||
        after < 0 || after > 9007199254740991.0 || after != std::floor(after) ||
        !devtools::ReadLogCapture(static_cast<uint64_t>(after), update)) {
      return Fail(env, "Cannot read the application HiLog buffer");
    }
    napi_value result = nullptr, entries = nullptr, failed = nullptr;
    if (napi_create_object(env, &result) != napi_ok || !SetNumber(env, result, "first", update.first) ||
        !SetNumber(env, result, "latest", update.latest) || napi_get_boolean(env, update.writeFailed, &failed) != napi_ok ||
        napi_set_named_property(env, result, "writeFailed", failed) != napi_ok ||
        napi_create_array_with_length(env, update.entries.size(), &entries) != napi_ok ||
        napi_set_named_property(env, result, "entries", entries) != napi_ok) {
      return Fail(env, "Cannot construct HiLog snapshot");
    }
    for (size_t i = 0; i < update.entries.size(); ++i) {
      // A full first read can contain 10,000 entries. Release transient N-API handles per row.
      napi_handle_scope scope = nullptr;
      if (napi_open_handle_scope(env, &scope) != napi_ok) { return Fail(env, "Cannot open HiLog handle scope"); }
      bool ok = SetEntry(env, entries, static_cast<uint32_t>(i), update.entries[i]);
      napi_close_handle_scope(env, scope);
      if (!ok) { return Fail(env, "Cannot construct HiLog record"); }
    }
    return result;
  } catch (...) {
    return Fail(env, "Cannot construct HiLog snapshot");
  }
}

napi_value Clear(napi_env env, napi_callback_info info) {
  Environment *state = nullptr;
  if (!Arguments(env, info, 0, nullptr, state) || state->leases == 0 || !devtools::ClearLogCapture()) {
    return Fail(env, "Cannot clear the application HiLog buffer");
  }
  return Undefined(env);
}

napi_value Release(napi_env env, napi_callback_info info) {
  Environment *state = nullptr;
  if (Arguments(env, info, 0, nullptr, state) && state->leases > 0) {
    --state->leases;
    devtools::ReleaseLogCapture();
  }
  return Undefined(env);
}

void Cleanup(void *data) {
  std::unique_ptr<Environment> state(static_cast<Environment *>(data));
  for (size_t i = 0; i < state->leases; ++i) { devtools::ReleaseLogCapture(); }
}

napi_value Init(napi_env env, napi_value exports) {
  auto state = std::unique_ptr<Environment>(new (std::nothrow) Environment());
  if (!state || napi_add_env_cleanup_hook(env, Cleanup, state.get()) != napi_ok) {
    return Fail(env, "Cannot initialize HiLog library");
  }
  Environment *data = state.release();
  napi_property_descriptor api[] = {
    { "acquire", nullptr, Acquire, nullptr, nullptr, nullptr, napi_default, data },
    { "readSince", nullptr, ReadSince, nullptr, nullptr, nullptr, napi_default, data },
    { "clear", nullptr, Clear, nullptr, nullptr, nullptr, napi_default, data },
    { "release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, data }
  };
  if (napi_define_properties(env, exports, sizeof(api) / sizeof(api[0]), api) != napi_ok) {
    return Fail(env, "Cannot export HiLog library");
  }
  return exports;
}

napi_module module = { 1, 0, nullptr, Init, "devtools_hilog", nullptr, {0} };

}  // namespace

extern "C" __attribute__((constructor)) void RegisterDevToolsHilog() {
  napi_module_register(&module);
}
