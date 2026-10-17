cmake_minimum_required(VERSION 3.21)
project(grassfield-settings VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Gui Qml Quick)

add_executable(grassfield-settings src/main.cpp src/backend.cpp src/backend.h)
target_link_libraries(grassfield-settings PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick)
target_compile_definitions(grassfield-settings PRIVATE
    GRASSFIELD_SETTINGS_VERSION="${PROJECT_VERSION}"
    GRASSFIELD_SETTINGS_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/settings/qml")

install(TARGETS grassfield-settings RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/settings/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Settings.desktop DESTINATION share/applications)
