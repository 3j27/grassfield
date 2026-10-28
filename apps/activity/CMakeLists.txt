cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-activity VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Activity Monitor (ADR-0038). Step 1: the sampler only (plain C++17 and POSIX, no Qt), its unit tests and its bench
# (tests/apps/activity_cost.sh). The app, its window and its install rules come with step 2.
add_library(grassfield-activity-sampler STATIC
    src/netdiag.cpp src/netdiag.h
    src/procparse.cpp src/procparse.h
    src/sampler.cpp src/sampler.h
    src/textclean.cpp src/textclean.h
    src/units.cpp src/units.h)
target_include_directories(grassfield-activity-sampler PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)

# A dev and test tool, never installed.
add_executable(activity-sampler-bench src/bench.cpp)
target_link_libraries(activity-sampler-bench PRIVATE grassfield-activity-sampler pthread)

find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(activity-unit-tests
        ../../tests/unit/activity/tst_memory.cpp
        ../../tests/unit/activity/tst_netdiag.cpp
        ../../tests/unit/activity/tst_procparse.cpp
        ../../tests/unit/activity/tst_sampler.cpp
        ../../tests/unit/activity/tst_textclean.cpp
        ../../tests/unit/activity/tst_units.cpp)
    target_link_libraries(activity-unit-tests PRIVATE grassfield-activity-sampler GTest::gtest GTest::gtest_main)
    add_test(NAME activity-unit-tests COMMAND activity-unit-tests)
endif()
