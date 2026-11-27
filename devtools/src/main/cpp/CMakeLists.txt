cmake_minimum_required(VERSION 3.16)
project(devtools_hilog LANGUAGES CXX)

add_library(devtools_hilog SHARED hilog_napi.cpp log_capture.cpp log_journal.cpp)
target_compile_features(devtools_hilog PRIVATE cxx_std_17)
target_compile_options(devtools_hilog PRIVATE -Wall -Wextra -fvisibility=hidden)
target_link_options(devtools_hilog PRIVATE -Wl,--exclude-libs,ALL)
target_link_libraries(devtools_hilog PRIVATE libace_napi.z.so libhilog_ndk.z.so)
