cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-store VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Grassfield Store (ADR-0037). Step 1: the read-only backend (the catalog's fetch, signature, rules and cache; Arch's
# AppStream, installed or fetched; pacman's databases; the merged model and search). The app, its QML and its package
# (package_grassfield-store in packaging/arch/PKGBUILD) come with step 2.
find_package(Qt6 REQUIRED COMPONENTS Core Network)
find_package(ZLIB REQUIRED)

add_library(grassfield-store-backend STATIC
    src/appstream.cpp src/appstream.h
    src/appstreamsource.cpp src/appstreamsource.h
    src/catalog.cpp src/catalog.h
    src/catalogstore.cpp src/catalogstore.h
    src/channel.cpp src/channel.h
    src/childprocess.cpp src/childprocess.h
    src/fetch.cpp src/fetch.h
    src/pacman.cpp src/pacman.h
    src/signature.cpp src/signature.h
    src/storeenv.h
    src/storemodel.cpp src/storemodel.h)
target_include_directories(grassfield-store-backend PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_link_libraries(grassfield-store-backend PUBLIC Qt6::Core Qt6::Network ZLIB::ZLIB)

# Unit tests (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(store-unit-tests
        ../../tests/unit/store/tst_appstream.cpp
        ../../tests/unit/store/tst_catalog.cpp
        ../../tests/unit/store/tst_catalogstore.cpp
        ../../tests/unit/store/tst_channel.cpp
        ../../tests/unit/store/tst_childprocess.cpp
        ../../tests/unit/store/tst_fetch.cpp
        ../../tests/unit/store/tst_pacman.cpp
        ../../tests/unit/store/tst_signature.cpp
        ../../tests/unit/store/tst_storemodel.cpp)
    target_link_libraries(store-unit-tests PRIVATE grassfield-store-backend GTest::gtest GTest::gtest_main)
    target_compile_definitions(store-unit-tests PRIVATE STORE_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/fixtures/store")
    add_test(NAME store-unit-tests COMMAND store-unit-tests)
endif()
