cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-memos VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Grassfield Memos (ADR-0051): desktop memos, one window each; packaged in grassfield-desktop like Activity Monitor.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick DBus)
# Qt 6.10+ defines the private module targets (Qt6::GuiPrivate, linked below for windowchrome.h) only when asked for.
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)

# The store, the frames read from Hyprland, the text formatter and the backend: shared by the app and its tests.
add_library(grassfield-memos-core STATIC
    src/hyprframes.cpp src/hyprframes.h
    src/memoformatter.cpp src/memoformatter.h
    src/memosapp.cpp src/memosapp.h
    src/memostore.cpp src/memostore.h)
target_include_directories(grassfield-memos-core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_link_libraries(grassfield-memos-core PUBLIC Qt6::Core Qt6::Gui Qt6::Quick)

add_executable(grassfield-memos src/main.cpp src/memosinstance.h)
target_include_directories(grassfield-memos PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../ui/i18n)
# windowchrome.h (ADR-0015): one Qt private header and the three xdg-toplevel-tag requests on libwayland-client.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(grassfield-memos PRIVATE grassfield-memos-core Qt6::GuiPrivate PkgConfig::WAYLAND_CLIENT
    Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus)
target_compile_definitions(grassfield-memos PRIVATE
    GRASSFIELD_MEMOS_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/memos/qml")

install(TARGETS grassfield-memos RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/memos/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Memos.desktop DESTINATION share/applications)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../branding/icons/apps/org.grassfield.Memos.svg
    DESTINATION share/icons/hicolor/scalable/apps)

# Unit tests (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(memos-unit-tests
        ../../tests/unit/memos/tst_hyprframes.cpp
        ../../tests/unit/memos/tst_memosapp.cpp
        ../../tests/unit/memos/tst_memostore.cpp
        ../../tests/unit/memos/tst_main.cpp)
    target_link_libraries(memos-unit-tests PRIVATE grassfield-memos-core GTest::gtest)
    add_test(NAME memos-unit-tests COMMAND memos-unit-tests)
endif()
