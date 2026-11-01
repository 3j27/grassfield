cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-prompter VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

# ADR-0035 D-9: C++/Qt 6 (QtCore) and libgcr-4 for gcr's protocol and its exchange; GDBus (GIO, which gcr-4 and qt6-base's
# GLib event dispatcher already bring) for the bus, because gcr's prompter needs a GDBusConnection. No QtDBus, no
# QtNetwork (decision 9-5: the bridge reads the shell into gcr's secure memory itself). No C source of Grassfield's own.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Core)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GCR REQUIRED IMPORTED_TARGET gcr-4 gio-unix-2.0)

# gcr-4's headers stay behind this definition (gcr.h); Qt's signals/slots keywords clash with GIO's struct members.
add_compile_definitions(GCR_API_SUBJECT_TO_CHANGE QT_NO_KEYWORDS)

set(PROMPTER_LOGIC
    src/Text.cpp src/Text.h
    src/Protocol.cpp src/Protocol.h
    src/Requests.cpp src/Requests.h
    src/Peer.cpp src/Peer.h
    src/Identity.cpp src/Identity.h
    src/Filter.cpp src/Filter.h
    src/Prompt.cpp src/Prompt.h
    src/Askpass.cpp src/Askpass.h)

add_executable(grassfield-prompter
    src/main.cpp
    src/Bridge.cpp src/Bridge.h
    src/Log.h
    ${PROMPTER_LOGIC})
# apps/runmode.h and apps/testbus.h: the run-mode rule (ADR-0019) and the private test bus, header-only, shared with the apps.
target_include_directories(grassfield-prompter PRIVATE src ${CMAKE_CURRENT_SOURCE_DIR}/../../apps)
target_link_libraries(grassfield-prompter PRIVATE Qt6::Core PkgConfig::GCR)

# grassfield-askpass (step 9c): udiskie's password command, a gcr client (grassfield-automount.service). Qt Core for its
# French message (ui/i18n/translationloader.h, the system catalog), libgcr-4 for the prompt; no C source of its own.
add_executable(grassfield-askpass src/askpass.cpp src/Askpass.cpp src/Askpass.h src/Text.cpp src/Text.h)
target_include_directories(grassfield-askpass PRIVATE src ${CMAKE_CURRENT_SOURCE_DIR}/../../ui/i18n)
target_link_libraries(grassfield-askpass PRIVATE Qt6::Core PkgConfig::GCR)

install(TARGETS grassfield-prompter grassfield-askpass RUNTIME DESTINATION lib/grassfield)
install(FILES ../../packaging/systemd/grassfield-prompter.service DESTINATION lib/systemd/user)

# Unit tests of the pure logic and of the GcrPrompt object (gtest), also built by build-direct.sh --tests and run by
# scripts/dev/test.sh; the process on a private bus is tests/security/prompter_bridge.sh.
option(GRASSFIELD_BUILD_TESTS "Build the prompter unit tests" ON)
find_package(GTest)
if(GRASSFIELD_BUILD_TESTS AND GTest_FOUND)
    enable_testing()
    add_executable(prompter-unit-tests ../../tests/unit/prompter/tst_prompter.cpp ${PROMPTER_LOGIC})
    target_include_directories(prompter-unit-tests PRIVATE src)
    target_link_libraries(prompter-unit-tests PRIVATE Qt6::Core PkgConfig::GCR GTest::gtest)
    add_test(NAME prompter-unit-tests COMMAND prompter-unit-tests)
endif()
