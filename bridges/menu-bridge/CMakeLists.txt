cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-menu-bridge VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

# ADR-0008: C++/Qt 6 (QtCore + QtDBus + QtNetwork), no other dependency.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core DBus Network)

set(MENU_BRIDGE_LOGIC
    src/Protocol.cpp src/Protocol.h
    src/Layout.cpp src/Layout.h
    src/Safety.cpp src/Safety.h
    src/Penalties.cpp src/Penalties.h
    src/Launcher.cpp src/Launcher.h
    src/DBusObjects.cpp src/DBusObjects.h
    src/ScreenSaver.cpp src/ScreenSaver.h
    src/Ongoing.cpp src/Ongoing.h
    src/OngoingObject.cpp src/OngoingObject.h
    src/Registrations.cpp src/Registrations.h)

add_executable(grassfield-menu-bridge
    src/main.cpp
    src/Bridge.cpp src/Bridge.h
    src/LauncherWatcher.cpp src/LauncherWatcher.h
    src/MenuClient.cpp src/MenuClient.h
    src/Log.h
    ${MENU_BRIDGE_LOGIC})
target_link_libraries(grassfield-menu-bridge PRIVATE Qt6::Core Qt6::DBus Qt6::Network)

install(TARGETS grassfield-menu-bridge RUNTIME DESTINATION bin)
install(FILES dbus/org.grassfield.MenuBridge1.xml dbus/org.grassfield.Ongoing1.xml DESTINATION share/dbus-1/interfaces)

# grassfield-ongoing (ADR-0052): scripts publish an ongoing activity (QtCore + QtDBus only).
# apps/ongoing.h is the apps' shared client (R5: one copy), ui/i18n/translationloader.h the shared catalog loader.
add_executable(grassfield-ongoing src/OngoingCli.cpp ../../apps/ongoing.h)
target_include_directories(grassfield-ongoing PRIVATE ../../apps ../../ui/i18n)
target_link_libraries(grassfield-ongoing PRIVATE Qt6::Core Qt6::DBus)
install(TARGETS grassfield-ongoing RUNTIME DESTINATION bin)
install(FILES ../../packaging/systemd/grassfield-menu-bridge.service DESTINATION lib/systemd/user)

# Unit tests of the pure logic (gtest), also built by build-direct.sh --tests and run by scripts/dev/test.sh.
option(GRASSFIELD_BUILD_TESTS "Build the menu bridge unit tests" ON)
find_package(GTest)
if(GRASSFIELD_BUILD_TESTS AND GTest_FOUND)
    enable_testing()
    add_executable(menu-bridge-unit-tests ../../tests/unit/menu-bridge/tst_menubridge.cpp ../../tests/unit/menu-bridge/tst_screensaver.cpp ../../tests/unit/menu-bridge/tst_ongoing.cpp ../../apps/ongoing.h src/MenuClient.cpp src/MenuClient.h ${MENU_BRIDGE_LOGIC})
    target_include_directories(menu-bridge-unit-tests PRIVATE src ../../apps)
    target_compile_definitions(menu-bridge-unit-tests PRIVATE
        GRASSFIELD_MENU_BRIDGE_DBUS_XML="${CMAKE_CURRENT_SOURCE_DIR}/dbus/org.grassfield.MenuBridge1.xml"
        GRASSFIELD_ONGOING_DBUS_XML="${CMAKE_CURRENT_SOURCE_DIR}/dbus/org.grassfield.Ongoing1.xml"
        GRASSFIELD_RUN_MODE_VECTORS="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/fixtures/run-mode-vectors.json")
    target_link_libraries(menu-bridge-unit-tests PRIVATE Qt6::Core Qt6::DBus GTest::gtest)
    add_test(NAME menu-bridge-unit-tests COMMAND menu-bridge-unit-tests)
endif()
