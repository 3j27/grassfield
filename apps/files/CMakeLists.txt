cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-files VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Everything but main() is the Files library (files-core.cmake), shared with grassfield-portal's panels.
include(${CMAKE_CURRENT_SOURCE_DIR}/files-core.cmake)

add_executable(grassfield-files src/main.cpp)
target_link_libraries(grassfield-files PRIVATE grassfield-files-core)
target_compile_definitions(grassfield-files PRIVATE
    GRASSFIELD_FILES_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/files/qml")

install(TARGETS grassfield-files RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/files/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Files.desktop DESTINATION share/applications)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../branding/icons/apps/org.grassfield.Files.svg DESTINATION share/icons/hicolor/scalable/apps)

# Unit tests of the pure logic (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(files-unit-tests ../../tests/unit/files/tst_filelogic.cpp ../../tests/unit/files/tst_previewqueue.cpp
        ../../tests/unit/files/tst_tags.cpp ../../tests/unit/files/tst_folderstyle.cpp ../../tests/unit/files/tst_folderviews.cpp ../../tests/unit/files/tst_imagerotate.cpp ../../tests/unit/files/tst_imagesize.cpp ../../tests/unit/files/tst_recents.cpp ../../tests/unit/files/tst_appscope.cpp ../../tests/unit/files/tst_runmode.cpp ../../tests/unit/files/tst_autoappearance.cpp ../../tests/unit/files/tst_launchguard.cpp ../../tests/unit/files/tst_menushortcuts.cpp src/filelogic.cpp src/taglogic.cpp src/tagstore.cpp src/launchguard.cpp
        src/folderstylelogic.cpp src/folderstylestore.cpp src/folderviews.cpp src/imagerotate.cpp src/imagesize.cpp src/recents.cpp src/recents.h)
    target_include_directories(files-unit-tests PRIVATE src ..)
    # tst_menushortcuts runs Qt.labs.platform menus offscreen (Qml, Widgets, Test) and includes globalmenu.h (DBus).
    find_package(Qt6 REQUIRED COMPONENTS Test)
    target_link_libraries(files-unit-tests PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Qml Qt6::DBus Qt6::Test GTest::gtest GTest::gtest_main)
    add_test(NAME files-unit-tests COMMAND files-unit-tests)
    # Grassfield's KIO dialogs (ADR-0035 D-12 a): the logic and real KIO jobs; its own main (a scratch home, offscreen).
    add_executable(files-kio-tests ../../tests/unit/files/tst_kioprompts.cpp ../../tests/unit/files/tst_kiodialogs.cpp
        src/kioprompts.cpp src/kioprompts.h src/kiopromptlogic.cpp src/filelogic.cpp)
    target_include_directories(files-kio-tests PRIVATE src ..)
    target_compile_definitions(files-kio-tests PRIVATE KF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00
        FILES_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/src")
    target_link_libraries(files-kio-tests PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Network
        KF6::KIOCore KF6::KIOGui KF6::KIOWidgets KF6::CoreAddons GTest::gtest)
    add_test(NAME files-kio-tests COMMAND files-kio-tests)
endif()
