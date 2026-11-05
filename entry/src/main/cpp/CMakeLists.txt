# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(StrollAndShoot)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(entry SHARED napi_init.cpp ptp_engine.cpp)
target_link_libraries(entry PUBLIC libace_napi.z.so)

# DevEco 工具链在 macOS 主机上会注入 --gcc-toolchain（指向 BiSheng 目录），
# clang 对本次编译未使用该参数会报 -Wunused-command-line-argument。
# 这是工具链自带的噪声，与本项目源码无关，直接关掉该诊断。
target_compile_options(entry PRIVATE -Wno-unused-command-line-argument)