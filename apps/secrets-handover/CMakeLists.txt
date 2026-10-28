cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-secrets-handover VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Qt Core and D-Bus only (ADR-0035 D-12, step 2c): no window, no network. The notice's text comes from Grassfield's own
# catalog (ui/i18n/translationloader.h).
find_package(Qt6 REQUIRED COMPONENTS Core DBus)

add_executable(grassfield-secrets-handover src/main.cpp src/handover.cpp src/handover.h src/peer.cpp src/peer.h src/logic.h)
target_include_directories(grassfield-secrets-handover PRIVATE src ../../ui/i18n)
target_link_libraries(grassfield-secrets-handover PRIVATE Qt6::Core Qt6::DBus)

# Run by its user unit, never by the user: /usr/lib/grassfield, not bin.
install(TARGETS grassfield-secrets-handover RUNTIME DESTINATION lib/grassfield)

find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(secrets-handover-unit-tests ../../tests/unit/secrets-handover/tst_logic.cpp src/peer.cpp)
    target_include_directories(secrets-handover-unit-tests PRIVATE src)
    target_link_libraries(secrets-handover-unit-tests PRIVATE Qt6::Core Qt6::DBus GTest::gtest GTest::gtest_main)
    add_test(NAME secrets-handover-unit-tests COMMAND secrets-handover-unit-tests)
endif()
