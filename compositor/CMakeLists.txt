cmake_minimum_required(VERSION 3.27)
project(grassfield-compositor VERSION 0.1.0 LANGUAGES CXX)

# Build against the INSTALLED Hyprland headers (master-prompt §5.6). Outputs:
#   build/grassfield-compositor.so      the plugin
#   build/grassfield-compositor-tests   unit tests for src/core (no Hyprland needed)
# Interim equivalent without CMake: build-direct.sh.

set(CMAKE_CXX_STANDARD 23) # Hyprland 0.56.2 headers use std::expected and string_view::contains
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON) # for clang-tidy (gate Q1)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(HYPRLAND REQUIRED IMPORTED_TARGET hyprland pixman-1 libdrm)
pkg_check_modules(LUA REQUIRED lua) # headers only: symbols resolve from Hyprland's liblua at load time

# Pure logic, no Hyprland includes (unit-testable).
add_library(gfcore STATIC src/core/Protocol.cpp src/core/TitlebarLayout.cpp src/core/PointerGesture.cpp src/core/Minimize.cpp)
target_include_directories(gfcore PUBLIC src)
set_target_properties(gfcore PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_options(gfcore PRIVATE -Wall -Wextra)

add_library(grassfield-compositor SHARED src/main.cpp src/Titlebar.cpp src/Ipc.cpp src/Minimize.cpp)
target_link_libraries(grassfield-compositor PRIVATE gfcore PkgConfig::HYPRLAND)
target_include_directories(grassfield-compositor PRIVATE ${LUA_INCLUDE_DIRS})
target_compile_options(grassfield-compositor PRIVATE -Wall -Wextra)
set_target_properties(grassfield-compositor PROPERTIES
  PREFIX ""
  LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/build)

option(GRASSFIELD_BUILD_TESTS "Build unit tests" ON)
if(GRASSFIELD_BUILD_TESTS)
  find_package(GTest REQUIRED)
  enable_testing()
  add_executable(grassfield-compositor-tests tests/ProtocolTest.cpp tests/TitlebarLayoutTest.cpp tests/PointerGestureTest.cpp tests/MinimizeTest.cpp)
  target_link_libraries(grassfield-compositor-tests PRIVATE gfcore GTest::gtest_main)
  target_compile_options(grassfield-compositor-tests PRIVATE -Wall -Wextra)
  set_target_properties(grassfield-compositor-tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/build)
  add_test(NAME grassfield-compositor-tests COMMAND grassfield-compositor-tests)
endif()
