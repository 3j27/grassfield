cmake_minimum_required(VERSION 3.21)
project(grassfield-i18n VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
# Backing library static: the plugin .so is then the only file to install.
set(BUILD_SHARED_LIBS OFF)

find_package(Qt6 REQUIRED COMPONENTS Core Qml LinguistTools)
qt_policy(SET QTP0001 NEW)

qt_add_qml_module(grassfield_i18n
    URI Grassfield.I18n
    VERSION 1.0
    PLUGIN_TARGET grassfield_i18nplugin
    OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/Grassfield/I18n
    SOURCES translator.h translator.cpp translationloader.h)
target_link_libraries(grassfield_i18n PRIVATE Qt6::Core Qt6::Qml)

# Catalogs: translations/grassfield_<lang>.ts -> grassfield_<lang>.qm
file(GLOB GRASSFIELD_TS ${CMAKE_CURRENT_SOURCE_DIR}/../../translations/grassfield_*.ts)
qt_add_lrelease(grassfield_i18n TS_FILES ${GRASSFIELD_TS} QM_FILES_OUTPUT_VARIABLE GRASSFIELD_QM)

install(DIRECTORY ${CMAKE_BINARY_DIR}/Grassfield/I18n/ DESTINATION lib/qt6/qml/Grassfield/I18n
        FILES_MATCHING PATTERN "qmldir" PATTERN "*.qmltypes" PATTERN "*.so")
install(FILES ${GRASSFIELD_QM} DESTINATION share/grassfield/translations)
