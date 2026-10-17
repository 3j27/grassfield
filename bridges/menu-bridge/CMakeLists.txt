cmake_minimum_required(VERSION 3.21)
project(grassfield-menu-bridge VERSION 0.1.0 LANGUAGES CXX)

# ADR-0008: C++/Qt 6 (QtCore + QtDBus + QtNetwork), no other dependency.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core DBus Network)

set(MENU_BRIDGE_LOGIC
    src/Protocol.cpp src/Protocol.h
    src/Layout.cpp src/Layout.h
    src/Safety.cpp src/Safety.h
    src/DBusObjects.cpp src/DBusObjects.h)

add_executable(grassfield-menu-bridge
    src/main.cpp
    src/Bridge.cpp src/Bridge.h
    src/MenuClient.cpp src/MenuClient.h
    src/Log.h
    ${MENU_BRIDGE_LOGIC})
target_link_libraries(grassfield-menu-bridge PRIVATE Qt6::Core Qt6::DBus Qt6::Network)

install(TARGETS grassfield-menu-bridge RUNTIME DESTINATION bin)
install(FILES dbus/org.grassfield.MenuBridge1.xml DESTINATION share/dbus-1/interfaces)
install(FILES ../../packaging/systemd/grassfield-menu-bridge.service DESTINATION lib/systemd/user)

# Unit tests of the pure logic (gtest), also built by build-direct.sh --tests and run by scripts/dev/test.sh.
option(GRASSFIELD_BUILD_TESTS "Build the menu bridge unit tests" ON)
find_package(GTest)
if(GRASSFIELD_BUILD_TESTS AND GTest_FOUND)
    enable_testing()
    add_executable(menu-bridge-unit-tests ../../tests/unit/menu-bridge/tst_menubridge.cpp src/MenuClient.cpp src/MenuClient.h ${MENU_BRIDGE_LOGIC})
    target_include_directories(menu-bridge-unit-tests PRIVATE src)
    target_compile_definitions(menu-bridge-unit-tests PRIVATE
        GRASSFIELD_MENU_BRIDGE_DBUS_XML="${CMAKE_CURRENT_SOURCE_DIR}/dbus/org.grassfield.MenuBridge1.xml")
    target_link_libraries(menu-bridge-unit-tests PRIVATE Qt6::Core Qt6::DBus GTest::gtest)
    add_test(NAME menu-bridge-unit-tests COMMAND menu-bridge-unit-tests)
endif()
