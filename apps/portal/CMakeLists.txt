cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-portal VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# The Open and Save panels (ADR-0035 D-4, step 4b) are the Files browser: the Files library (one source list,
# files-core.cmake) and Files' QML, installed by apps/files. KWindowSystem makes a panel the child of the application's
# window (xdg-foreign v2); it is already a dependency of KIO's widgets.
include(${CMAKE_CURRENT_SOURCE_DIR}/../files/files-core.cmake)
find_package(KF6WindowSystem ${KF_MIN_VERSION} REQUIRED)

add_executable(grassfield-portal src/main.cpp src/filechooser.cpp src/filechooser.h src/chooserlogic.cpp src/chooserlogic.h
    src/panelstate.cpp src/panelstate.h)
target_include_directories(grassfield-portal PRIVATE src)
target_link_libraries(grassfield-portal PRIVATE grassfield-files-core KF6::WindowSystem)
target_compile_definitions(grassfield-portal PRIVATE
    GRASSFIELD_FILES_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/files/qml")

# Started by D-Bus activation through its user unit, never by the user: /usr/lib/grassfield, not bin.
install(TARGETS grassfield-portal RUNTIME DESTINATION lib/grassfield)

find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    # The option mapping and the panels' memory (pure), and the D-Bus service on a private bus (its own main).
    add_executable(portal-unit-tests ../../tests/unit/portal/tst_chooserlogic.cpp ../../tests/unit/portal/tst_panelstate.cpp
        ../../tests/unit/portal/tst_filechooser.cpp src/filechooser.cpp src/chooserlogic.cpp src/panelstate.cpp)
    target_include_directories(portal-unit-tests PRIVATE src)
    find_package(Qt6 REQUIRED COMPONENTS Test)
    target_link_libraries(portal-unit-tests PRIVATE grassfield-files-core KF6::WindowSystem Qt6::Test GTest::gtest)
    add_test(NAME portal-unit-tests COMMAND portal-unit-tests)
endif()
