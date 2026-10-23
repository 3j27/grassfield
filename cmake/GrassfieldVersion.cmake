# The single version source of Grassfield is the VERSION file at the repository root (one line, e.g. 1.0.0-rc1).
# Every CMake project includes this file before project() and gets:
#   GF_VERSION          the full version, e.g. 1.0.0-rc1 (passed to the code as the GRASSFIELD_VERSION definition)
#   GF_VERSION_NUMERIC  MAJOR.MINOR.PATCH, e.g. 1.0.0 (CMake's project(VERSION) takes digits only)
# scripts/dev/check-version.sh (just check) verifies that every other consumer (PKGBUILD, shell, docs) agrees.
# In the repository the file is ../VERSION; the shipped sources of the compositor rebuild (/usr/src/grassfield-compositor)
# carry cmake/GrassfieldVersion.cmake with cmake/VERSION next to it.
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/VERSION")
  set(GF_VERSION_FILE "${CMAKE_CURRENT_LIST_DIR}/VERSION")
else()
  set(GF_VERSION_FILE "${CMAKE_CURRENT_LIST_DIR}/../VERSION")
endif()
file(STRINGS "${GF_VERSION_FILE}" GF_VERSION LIMIT_COUNT 1)
string(STRIP "${GF_VERSION}" GF_VERSION)
if(NOT GF_VERSION MATCHES "^([0-9]+\\.[0-9]+\\.[0-9]+)(-[0-9A-Za-z.]+)?$")
  message(FATAL_ERROR "VERSION must look like 1.0.0 or 1.0.0-rc1, got '${GF_VERSION}'")
endif()
set(GF_VERSION_NUMERIC "${CMAKE_MATCH_1}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${GF_VERSION_FILE}")
