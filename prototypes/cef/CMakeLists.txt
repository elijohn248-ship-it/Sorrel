# Birch CEF prototype (throwaway; see REPORT.md). Builds against an official
# CEF binary distribution that CI downloads and verifies (tools/fetch_deps.py).
#
#   cmake -S prototypes/cef -B out -DCEF_ROOT=<unpacked cef_binary_...>
#   cmake --build out --config Release
#
cmake_minimum_required(VERSION 3.21)
project(birch_cef LANGUAGES C CXX)

if(NOT CEF_ROOT)
  message(FATAL_ERROR "Pass -DCEF_ROOT=<path to the unpacked CEF binary distribution>")
endif()
# Windows paths with backslashes break CEF's macros; use CMake's form.
file(TO_CMAKE_PATH "${CEF_ROOT}" CEF_ROOT)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

# CEF's C++ wrapper library (third-party code, built with CEF's own flags).
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

set(BIRCH_SRCS
  src/app.cc
  src/client.cc
  src/tests.cc
  src/util.cc
  src/window.cc
  src/birch.h
)

SET_CEF_TARGET_OUT_DIR()

if(OS_WINDOWS)
  ADD_LOGICAL_TARGET("libcef_lib" "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")
  if(NOT USE_SANDBOX)
    message(FATAL_ERROR "Birch never builds without the Chromium sandbox (USE_SANDBOX must stay ON).")
  endif()
  # Since M138 the Windows sandbox needs CEF's prebuilt bootstrap executable,
  # which loads the app as a DLL. We use the console bootstrap (bootstrapc.exe)
  # renamed to birch_cef.exe so test logs reach stderr.
  add_library(birch_cef SHARED ${BIRCH_SRCS} src/main_win.cc)
  SET_LIBRARY_TARGET_PROPERTIES(birch_cef)
  if(EXISTS "${CEF_BINARY_DIR_RELEASE}/bootstrapc.exe")
    set(BIRCH_BOOTSTRAP bootstrapc.exe)
  else()
    message(FATAL_ERROR "bootstrapc.exe missing from the CEF distribution")
  endif()
  COPY_SINGLE_FILE(birch_cef "${CEF_BINARY_DIR}/${BIRCH_BOOTSTRAP}" "${CEF_TARGET_OUT_DIR}/birch_cef.exe")
  add_dependencies(birch_cef libcef_dll_wrapper)
  target_link_libraries(birch_cef libcef_lib libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  COPY_FILES(birch_cef "${CEF_BINARY_FILES}" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  COPY_FILES(birch_cef "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}" "${CEF_TARGET_OUT_DIR}")
  # Grants "ALL RESTRICTED APPLICATION PACKAGES" read access so LPAC-sandboxed
  # processes (network service) can load the binaries.
  SET_LPAC_ACLS(birch_cef)
elseif(OS_LINUX)
  ADD_LOGICAL_TARGET("libcef_lib" "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")
  add_executable(birch_cef ${BIRCH_SRCS} src/main_linux.cc)
  SET_EXECUTABLE_TARGET_PROPERTIES(birch_cef)
  add_dependencies(birch_cef libcef_dll_wrapper)
  target_link_libraries(birch_cef libcef_lib libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(birch_cef PROPERTIES
    INSTALL_RPATH "$ORIGIN"
    BUILD_WITH_INSTALL_RPATH TRUE
    RUNTIME_OUTPUT_DIRECTORY ${CEF_TARGET_OUT_DIR})
  COPY_FILES(birch_cef "${CEF_BINARY_FILES}" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  COPY_FILES(birch_cef "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}" "${CEF_TARGET_OUT_DIR}")
  if(EXISTS "${CEF_BINARY_DIR}/libminigbm.so")
    COPY_FILES(birch_cef "libminigbm.so" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  endif()
else()
  message(FATAL_ERROR "The CEF prototype targets Windows and Linux only.")
endif()

# Birch's own code is held to a stricter standard than CEF's defaults: CEF
# turns off several warnings (/wd4100, -Wno-unused-parameter, ...). We drop
# those for our sources, add -Wextra, and treat CEF's headers as system /
# external headers so their unavoidable warnings stay out of the count.
set(_birch_flags ${CEF_COMPILER_FLAGS} ${CEF_CXX_COMPILER_FLAGS})
list(FILTER _birch_flags EXCLUDE REGEX "^/wd[0-9]+$")
list(FILTER _birch_flags EXCLUDE REGEX "^-Wno-")
if(MSVC)
  list(APPEND _birch_flags /W4 /WX /external:W0)
else()
  list(APPEND _birch_flags -Wall -Wextra -Werror)
endif()
set_property(TARGET birch_cef PROPERTY COMPILE_OPTIONS "")
target_compile_options(birch_cef PRIVATE
  $<$<COMPILE_LANGUAGE:CXX>:${_birch_flags}>
  $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Debug>>:${CEF_COMPILER_FLAGS_DEBUG} ${CEF_CXX_COMPILER_FLAGS_DEBUG}>
  $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Release>>:${CEF_COMPILER_FLAGS_RELEASE} ${CEF_CXX_COMPILER_FLAGS_RELEASE}>)
set_property(TARGET birch_cef PROPERTY INCLUDE_DIRECTORIES "")
target_include_directories(birch_cef SYSTEM PRIVATE ${CEF_INCLUDE_PATH})
