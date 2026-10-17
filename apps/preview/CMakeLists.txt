cmake_minimum_required(VERSION 3.21)
project(grassfield-preview VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick)
# QtPdf/QtPdfQuick (qt6-webengine) and QtMultimedia are QML modules used at run time.
find_package(Qt6 COMPONENTS Pdf PdfQuick Multimedia)

add_executable(grassfield-preview
    src/main.cpp
    src/previewapp.cpp src/previewapp.h
    src/previewlogic.cpp src/previewlogic.h)
target_link_libraries(grassfield-preview PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)
target_compile_definitions(grassfield-preview PRIVATE
    GRASSFIELD_PREVIEW_VERSION="${PROJECT_VERSION}"
    GRASSFIELD_PREVIEW_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/preview/qml")

install(TARGETS grassfield-preview RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/preview/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Preview.desktop DESTINATION share/applications)

# Unit tests of the pure logic (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(preview-unit-tests ../../tests/unit/preview/tst_previewlogic.cpp src/previewlogic.cpp)
    target_include_directories(preview-unit-tests PRIVATE src)
    target_link_libraries(preview-unit-tests PRIVATE Qt6::Core Qt6::Gui GTest::gtest GTest::gtest_main)
    add_test(NAME preview-unit-tests COMMAND preview-unit-tests)
endif()
