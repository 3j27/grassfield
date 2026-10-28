cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-portal-settings VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Qt Core and D-Bus only (ADR-0035 D-4, D-8, step 2b): no window and no Qt GUI platform, so the backend never waits on a
# portal itself (D-4's start-up loop). The accent palette is generated from the tokens (src/PaletteTokens.hpp).
find_package(Qt6 REQUIRED COMPONENTS Core DBus)

add_executable(grassfield-portal-settings src/main.cpp src/settingsbackend.cpp src/settingsbackend.h src/portalvalues.h
    src/PaletteTokens.hpp)
target_include_directories(grassfield-portal-settings PRIVATE src ..)
target_link_libraries(grassfield-portal-settings PRIVATE Qt6::Core Qt6::DBus)

# Started by its user unit or by D-Bus activation, never by the user: /usr/lib/grassfield, not bin.
install(TARGETS grassfield-portal-settings RUNTIME DESTINATION lib/grassfield)

find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(portal-settings-unit-tests ../../tests/unit/portal-settings/tst_portalvalues.cpp src/settingsbackend.cpp
        src/settingsbackend.h)
    target_include_directories(portal-settings-unit-tests PRIVATE src ..)
    target_link_libraries(portal-settings-unit-tests PRIVATE Qt6::Core Qt6::DBus GTest::gtest GTest::gtest_main)
    add_test(NAME portal-settings-unit-tests COMMAND portal-settings-unit-tests)
endif()
