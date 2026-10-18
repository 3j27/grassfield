cmake_minimum_required(VERSION 3.21)
project(grassfield-files VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

set(KF_MIN_VERSION "6.17") # FileUndoManager::redo()
find_package(ECM ${KF_MIN_VERSION} NO_MODULE)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Qml Quick DBus)
# KDE Frameworks are separate CMake packages (there is no umbrella "KF6" package).
find_package(KF6KIO ${KF_MIN_VERSION} REQUIRED)
find_package(KF6CoreAddons ${KF_MIN_VERSION} REQUIRED)
find_package(KF6Service ${KF_MIN_VERSION} REQUIRED)
find_package(KF6Solid ${KF_MIN_VERSION} REQUIRED)

add_executable(grassfield-files
    src/main.cpp
    src/filesapp.cpp src/filesapp.h
    src/foldermodel.cpp src/foldermodel.h
    src/placesmodel.cpp src/placesmodel.h
    src/imageproviders.cpp src/imageproviders.h
    src/filelogic.cpp src/filelogic.h)
target_include_directories(grassfield-files PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../ui/i18n ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_link_libraries(grassfield-files PRIVATE
    Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Qml Qt6::Quick Qt6::DBus
    KF6::KIOCore KF6::KIOGui KF6::KIOWidgets KF6::CoreAddons KF6::Service KF6::Solid)
target_compile_definitions(grassfield-files PRIVATE
    KF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00
    GRASSFIELD_FILES_VERSION="${PROJECT_VERSION}"
    GRASSFIELD_FILES_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/files/qml")

install(TARGETS grassfield-files RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/files/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Files.desktop DESTINATION share/applications)

# Unit tests of the pure logic (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(files-unit-tests ../../tests/unit/files/tst_filelogic.cpp ../../tests/unit/files/tst_previewqueue.cpp src/filelogic.cpp)
    target_include_directories(files-unit-tests PRIVATE src)
    target_link_libraries(files-unit-tests PRIVATE Qt6::Core GTest::gtest GTest::gtest_main)
    add_test(NAME files-unit-tests COMMAND files-unit-tests)
endif()
