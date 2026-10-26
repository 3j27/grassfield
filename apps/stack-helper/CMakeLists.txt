cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-stack-helper VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Qt Core only (ADR-0025): no window, no network. The order of a Name stack is Files' own: filelogic.cpp is compiled in as it is.
find_package(Qt6 REQUIRED COMPONENTS Core)

add_executable(grassfield-stack-helper src/main.cpp src/helper.cpp src/helper.h src/stacklogic.cpp src/stacklogic.h ../files/src/filelogic.cpp ../files/src/filelogic.h)
target_include_directories(grassfield-stack-helper PRIVATE src ../files/src)
target_link_libraries(grassfield-stack-helper PRIVATE Qt6::Core)

# Run by the shell, never by the user: /usr/lib/grassfield, not bin.
install(TARGETS grassfield-stack-helper RUNTIME DESTINATION lib/grassfield)

find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(stack-helper-unit-tests ../../tests/unit/stack-helper/tst_stacklogic.cpp ../../tests/unit/stack-helper/tst_helper.cpp src/helper.cpp src/stacklogic.cpp ../files/src/filelogic.cpp)
    target_include_directories(stack-helper-unit-tests PRIVATE src ../files/src)
    target_link_libraries(stack-helper-unit-tests PRIVATE Qt6::Core GTest::gtest GTest::gtest_main)
    add_test(NAME stack-helper-unit-tests COMMAND stack-helper-unit-tests)
endif()
