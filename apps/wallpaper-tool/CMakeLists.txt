cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-wallpaper VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Core and Gui only: the helper never opens a window. Its only network use is `fetch`, through the curl program (ADR-0016).
find_package(Qt6 REQUIRED COMPONENTS Core Gui)

add_executable(grassfield-wallpaper src/main.cpp src/wallpaperlogic.cpp src/wallpaperlogic.h src/commonsfetch.cpp src/commonsfetch.h src/videotool.cpp src/videotool.h)
target_include_directories(grassfield-wallpaper PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/..) # apps/runmode.h
target_link_libraries(grassfield-wallpaper PRIVATE Qt6::Core Qt6::Gui)

# Run by the shell and the Settings app, never by the user: /usr/lib/grassfield, not bin.
install(TARGETS grassfield-wallpaper RUNTIME DESTINATION lib/grassfield)

# Build only (ADR-0040 step 2c): shrinks the downloaded wallpaper photographs for the package (packaging/arch/PKGBUILD). No
# install rule: it writes wherever it is told, which the installed helper never does.
add_executable(grassfield-wallpaper-shrink src/shrink.cpp src/wallpaperlogic.cpp src/wallpaperlogic.h)
target_link_libraries(grassfield-wallpaper-shrink PRIVATE Qt6::Core Qt6::Gui)

find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(wallpaper-unit-tests ../../tests/unit/wallpaper-tool/tst_wallpaperlogic.cpp ../../tests/unit/wallpaper-tool/tst_commonsfetch.cpp ../../tests/unit/wallpaper-tool/tst_videotool.cpp src/wallpaperlogic.cpp src/commonsfetch.cpp src/videotool.cpp)
    target_include_directories(wallpaper-unit-tests PRIVATE src)
    target_compile_definitions(wallpaper-unit-tests PRIVATE FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/unit/wallpaper-tool/fixtures")
    target_link_libraries(wallpaper-unit-tests PRIVATE Qt6::Core Qt6::Gui GTest::gtest GTest::gtest_main)
    add_test(NAME wallpaper-unit-tests COMMAND wallpaper-unit-tests)
endif()
