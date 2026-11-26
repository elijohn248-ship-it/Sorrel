# Birch, Chromium edition (Windows and Linux). See CLAUDE.md ▸ Chromium edition.
#
#   python3 -I tools/fetch_deps.py --dest deps --platform windows64|linux64
#   cmake -S chromium -B out -DBIRCH_DEPS=<deps> [-DCEF_ROOT=<deps>/cef]
#   cmake --build out --config Release
#
# Without CEF_ROOT only core/ and its spec tests build (no engine needed).
cmake_minimum_required(VERSION 3.22)
project(birch LANGUAGES C CXX)

if(NOT BIRCH_DEPS)
  message(FATAL_ERROR "Pass -DBIRCH_DEPS=<folder filled by tools/fetch_deps.py>")
endif()
file(TO_CMAKE_PATH "${BIRCH_DEPS}" BIRCH_DEPS)
set(BIRCH_JSON_INCLUDE "${BIRCH_DEPS}/nlohmann/include")
if(NOT EXISTS "${BIRCH_JSON_INCLUDE}/nlohmann/json.hpp")
  message(FATAL_ERROR "nlohmann/json missing; run tools/fetch_deps.py")
endif()
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(BIRCH_REPO "${CMAKE_CURRENT_SOURCE_DIR}/..")

set(BIRCH_WITH_CEF OFF)
if(CEF_ROOT)
  set(BIRCH_WITH_CEF ON)
  # Windows paths with backslashes break CEF's macros; use CMake's form.
  file(TO_CMAKE_PATH "${CEF_ROOT}" CEF_ROOT)
  list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
  find_package(CEF REQUIRED)
  # CEF's C++ wrapper library (third-party code, built with CEF's own flags).
  add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)
endif()

# Birch's own code is held to a stricter standard than CEF's defaults: CEF
# turns several warnings off (/wd4100, -Wno-unused-parameter, ...); we drop
# those for our sources and treat CEF's and nlohmann's headers as external
# (system) headers so their warnings stay out of the count.
function(birch_strict target)
  target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_include_directories(${target} SYSTEM PRIVATE "${BIRCH_JSON_INCLUDE}")
  if(BIRCH_WITH_CEF)
    set(_flags ${CEF_COMPILER_FLAGS} ${CEF_CXX_COMPILER_FLAGS})
    list(FILTER _flags EXCLUDE REGEX "^/wd[0-9]+$")
    list(FILTER _flags EXCLUDE REGEX "^-Wno-")
    if(MSVC)
      list(APPEND _flags /W4 /WX /external:W0)
    else()
      list(APPEND _flags -Wall -Wextra -Werror)
    endif()
    set_property(TARGET ${target} PROPERTY COMPILE_OPTIONS "")
    target_compile_options(${target} PRIVATE
      $<$<COMPILE_LANGUAGE:CXX>:${_flags}>
      $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Debug>>:${CEF_COMPILER_FLAGS_DEBUG} ${CEF_CXX_COMPILER_FLAGS_DEBUG}>
      $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Release>>:${CEF_COMPILER_FLAGS_RELEASE} ${CEF_CXX_COMPILER_FLAGS_RELEASE}>)
    target_compile_definitions(${target} PRIVATE ${CEF_COMPILER_DEFINES}
      $<$<CONFIG:Debug>:${CEF_COMPILER_DEFINES_DEBUG}>
      $<$<CONFIG:Release>:${CEF_COMPILER_DEFINES_RELEASE}>)
    target_include_directories(${target} SYSTEM PRIVATE ${CEF_INCLUDE_PATH})
  else()
    set_target_properties(${target} PROPERTIES
      CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    if(MSVC)
      target_compile_options(${target} PRIVATE /W4 /WX /utf-8 /permissive- /external:W0)
      target_compile_definitions(${target} PRIVATE NOMINMAX UNICODE _UNICODE)
    else()
      target_compile_options(${target} PRIVATE -Wall -Wextra -Werror)
    endif()
  endif()
endfunction()

# ---- core/: the spec model (engine-free, UI-free) and its fixture tests ----------
file(GLOB BIRCH_CORE_SRCS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/core/*.cc")
add_library(birch_core STATIC ${BIRCH_CORE_SRCS})
birch_strict(birch_core)

add_executable(birch_spec_tests tests/spec/spec_runner.cc)
birch_strict(birch_spec_tests)
target_link_libraries(birch_spec_tests birch_core)

# The UI-only channel's message checks (core/ui_channel), no engine needed.
add_executable(birch_ui_channel_tests tests/unit/ui_channel_tests.cc)
birch_strict(birch_ui_channel_tests)
target_link_libraries(birch_ui_channel_tests birch_core)

# Spaces, favorites, folders, archive and sleep policy (core/store, core/lifecycle).
add_executable(birch_sidebar_store_tests tests/unit/sidebar_store_tests.cc)
birch_strict(birch_sidebar_store_tests)
target_link_libraries(birch_sidebar_store_tests birch_core)

if(NOT BIRCH_WITH_CEF)
  return()
endif()

# ---- the browser ----------------------------------------------------------------------
SET_CEF_TARGET_OUT_DIR()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
# The spec runner beside the app, in out/Release on every generator.
set_target_properties(birch_spec_tests birch_ui_channel_tests birch_sidebar_store_tests PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CEF_TARGET_OUT_DIR}")

# Every module folder is globbed, so wave-3 agents add files without editing
# this list (fewer merge conflicts). Platform files are picked per OS.
file(GLOB_RECURSE BIRCH_APP_SRCS CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/ui/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/tests/hooks/*.cc")
list(APPEND BIRCH_APP_SRCS app/shell.cc platform/platform.cc)

# Birch's own UI pages (ui/web/) compiled into the app: the UI host serves
# them from memory, never from disk, the network or the profile.
file(GLOB_RECURSE BIRCH_UI_WEB CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ui/web/*")
set(BIRCH_UI_RES "${CMAKE_BINARY_DIR}/generated/ui_resources.cc")
add_custom_command(
  OUTPUT "${BIRCH_UI_RES}"
  COMMAND "${Python3_EXECUTABLE}" -I "${CMAKE_CURRENT_SOURCE_DIR}/tools/embed_ui.py"
          "${CMAKE_CURRENT_SOURCE_DIR}/ui/web" "${BIRCH_UI_RES}"
  DEPENDS ${BIRCH_UI_WEB} "${CMAKE_CURRENT_SOURCE_DIR}/tools/embed_ui.py"
  COMMENT "Building Birch's UI pages into the app"
  VERBATIM)
list(APPEND BIRCH_APP_SRCS "${BIRCH_UI_RES}")

# The icon: Resources/AppIcon.icns (the Mac app's, read only) -> .png/.ico.
set(BIRCH_ICON_DIR "${CMAKE_BINARY_DIR}/icons")
add_custom_command(
  OUTPUT "${BIRCH_ICON_DIR}/birch.png" "${BIRCH_ICON_DIR}/birch.ico"
  COMMAND "${Python3_EXECUTABLE}" -I "${CMAKE_CURRENT_SOURCE_DIR}/tools/make_icons.py"
          "${BIRCH_REPO}/Resources/AppIcon.icns" "${BIRCH_ICON_DIR}"
  DEPENDS "${BIRCH_REPO}/Resources/AppIcon.icns" "${CMAKE_CURRENT_SOURCE_DIR}/tools/make_icons.py"
  COMMENT "Making Birch's icon from Resources/AppIcon.icns"
  VERBATIM)
add_custom_target(birch_icons DEPENDS "${BIRCH_ICON_DIR}/birch.png" "${BIRCH_ICON_DIR}/birch.ico")

ADD_LOGICAL_TARGET("libcef_lib" "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")

if(OS_WINDOWS)
  if(NOT USE_SANDBOX)
    message(FATAL_ERROR "Birch never builds without the Chromium sandbox (USE_SANDBOX must stay ON).")
  endif()
  # Since M138 the Windows sandbox needs CEF's prebuilt bootstrap executable,
  # which loads the app from a DLL of the same name: birch.exe -> birch.dll.
  # The windowed bootstrap (no console) is the one shipped.
  if(NOT EXISTS "${CEF_BINARY_DIR_RELEASE}/bootstrap.exe")
    message(FATAL_ERROR "bootstrap.exe missing from the CEF distribution")
  endif()
  add_library(birch SHARED ${BIRCH_APP_SRCS} app/main_win.cc platform/platform_win.cc)
  SET_LIBRARY_TARGET_PROPERTIES(birch)
  COPY_SINGLE_FILE(birch "${CEF_BINARY_DIR}/bootstrap.exe" "${CEF_TARGET_OUT_DIR}/birch.exe")
  add_custom_command(TARGET birch POST_BUILD
    COMMAND "${Python3_EXECUTABLE}" -I "${CMAKE_CURRENT_SOURCE_DIR}/tools/set_exe_icon.py"
            "${CEF_TARGET_OUT_DIR}/birch.exe" "${BIRCH_ICON_DIR}/birch.ico"
    VERBATIM)
  target_link_libraries(birch libcef_lib libcef_dll_wrapper birch_core
    ${CEF_STANDARD_LIBS} shell32.lib ole32.lib advapi32.lib uuid.lib)
  COPY_FILES(birch "${CEF_BINARY_FILES}" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  COPY_FILES(birch "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}" "${CEF_TARGET_OUT_DIR}")
  # Grants "ALL RESTRICTED APPLICATION PACKAGES" read access so the
  # LPAC-sandboxed network service can load the binaries (the app also
  # does this at start for folders unpacked from a zip).
  SET_LPAC_ACLS(birch)
elseif(OS_LINUX)
  add_executable(birch ${BIRCH_APP_SRCS} app/main_linux.cc platform/platform_linux.cc)
  SET_EXECUTABLE_TARGET_PROPERTIES(birch)
  target_link_libraries(birch libcef_lib libcef_dll_wrapper birch_core ${CEF_STANDARD_LIBS})
  set_target_properties(birch PROPERTIES
    INSTALL_RPATH "$ORIGIN"
    BUILD_WITH_INSTALL_RPATH TRUE
    RUNTIME_OUTPUT_DIRECTORY ${CEF_TARGET_OUT_DIR})
  COPY_FILES(birch "${CEF_BINARY_FILES}" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  COPY_FILES(birch "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}" "${CEF_TARGET_OUT_DIR}")
  if(EXISTS "${CEF_BINARY_DIR_RELEASE}/libminigbm.so")
    COPY_FILES(birch "libminigbm.so" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  endif()
else()
  message(FATAL_ERROR "The Chromium edition targets Windows and Linux.")
endif()

add_dependencies(birch libcef_dll_wrapper birch_icons)
# SET_*_TARGET_PROPERTIES added CEF's flags; replace them with birch_strict's.
set_property(TARGET birch PROPERTY COMPILE_DEFINITIONS "")
set_property(TARGET birch PROPERTY INCLUDE_DIRECTORIES "")
birch_strict(birch)

# The icon beside the executable (the window loads birch.png at start), and
# the licences every build must carry.
add_custom_command(TARGET birch POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CEF_TARGET_OUT_DIR}/licenses"
  VERBATIM)
COPY_SINGLE_FILE(birch "${BIRCH_ICON_DIR}/birch.png" "${CEF_TARGET_OUT_DIR}/birch.png")
COPY_SINGLE_FILE(birch "${BIRCH_ICON_DIR}/birch.ico" "${CEF_TARGET_OUT_DIR}/birch.ico")
COPY_SINGLE_FILE(birch "${BIRCH_REPO}/LICENSE" "${CEF_TARGET_OUT_DIR}/licenses/Birch-LICENSE.txt")
COPY_SINGLE_FILE(birch "${BIRCH_DEPS}/nlohmann/LICENSE.MIT" "${CEF_TARGET_OUT_DIR}/licenses/nlohmann-json-LICENSE.txt")
foreach(_lic LICENSE.txt CREDITS.html)
  if(EXISTS "${CEF_ROOT}/${_lic}")
    COPY_SINGLE_FILE(birch "${CEF_ROOT}/${_lic}" "${CEF_TARGET_OUT_DIR}/licenses/CEF-${_lic}")
  endif()
endforeach()
