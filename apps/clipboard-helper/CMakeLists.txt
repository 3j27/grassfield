cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-clipboard-helper VERSION ${GF_VERSION_NUMERIC} LANGUAGES C CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Qt Core and Gui (the image worker's QImage), libwayland-client (ADR-0034). No network module.
find_package(Qt6 REQUIRED COMPONENTS Core Gui)
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

# Client code of the vendored protocol XML (ext-data-control-v1, MIT; hyprland-lock-notify-v1, BSD-3-Clause; THIRD_PARTY.md).
set(GF_PROTO_DIR ${CMAKE_CURRENT_BINARY_DIR}/protocols)
file(MAKE_DIRECTORY ${GF_PROTO_DIR})
set(GF_PROTO_SOURCES)
foreach(proto ext-data-control-v1 hyprland-lock-notify-v1)
    set(xml ${CMAKE_CURRENT_SOURCE_DIR}/protocols/${proto}.xml)
    add_custom_command(
        OUTPUT ${GF_PROTO_DIR}/${proto}-client-protocol.h ${GF_PROTO_DIR}/${proto}-protocol.c
        COMMAND ${WAYLAND_SCANNER} client-header ${xml} ${GF_PROTO_DIR}/${proto}-client-protocol.h
        COMMAND ${WAYLAND_SCANNER} private-code ${xml} ${GF_PROTO_DIR}/${proto}-protocol.c
        DEPENDS ${xml})
    list(APPEND GF_PROTO_SOURCES ${GF_PROTO_DIR}/${proto}-client-protocol.h ${GF_PROTO_DIR}/${proto}-protocol.c)
endforeach()

add_executable(grassfield-clipboard-helper
    src/main.cpp src/helper.cpp src/helper.h src/cliplogic.cpp src/cliplogic.h src/diskstore.cpp src/diskstore.h
    src/thumbnail.cpp src/thumbnail.h src/wlclient.cpp src/wlclient.h ${GF_PROTO_SOURCES})
target_include_directories(grassfield-clipboard-helper PRIVATE src ${GF_PROTO_DIR})
target_link_libraries(grassfield-clipboard-helper PRIVATE Qt6::Core Qt6::Gui PkgConfig::WAYLAND_CLIENT)

# Run by the shell, never by the user: /usr/lib/grassfield, not bin.
install(TARGETS grassfield-clipboard-helper RUNTIME DESTINATION lib/grassfield)

find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(clipboard-helper-unit-tests
        ../../tests/unit/clipboard-helper/tst_cliplogic.cpp ../../tests/unit/clipboard-helper/tst_diskstore.cpp
        ../../tests/unit/clipboard-helper/tst_thumbnail.cpp src/cliplogic.cpp src/diskstore.cpp src/thumbnail.cpp)
    target_include_directories(clipboard-helper-unit-tests PRIVATE src)
    target_link_libraries(clipboard-helper-unit-tests PRIVATE Qt6::Core Qt6::Gui GTest::gtest GTest::gtest_main)
    add_test(NAME clipboard-helper-unit-tests COMMAND clipboard-helper-unit-tests)
endif()
