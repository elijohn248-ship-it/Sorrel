# Birch Qt WebEngine prototype (wave 1, throwaway). Not the product.
# Built only in CI (.github/workflows/chromium-qt-proto.yml) for Windows x64 and Linux x64.
cmake_minimum_required(VERSION 3.24)
project(birch_qt_proto LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.12 REQUIRED COMPONENTS Core Gui Network Widgets WebEngineCore WebEngineWidgets)

qt_add_executable(birch-qt-proto
    src/main.cpp
    src/Log.h
    src/Engine.h src/Engine.cpp
    src/Sidebar.h src/Sidebar.cpp
    src/BrowserWindow.h src/BrowserWindow.cpp
    src/ProcInfo.h src/ProcInfo.cpp
    src/Gates.h src/Gates.cpp
)

target_link_libraries(birch-qt-proto PRIVATE
    Qt6::Core Qt6::Gui Qt6::Network Qt6::Widgets Qt6::WebEngineCore Qt6::WebEngineWidgets)

# Zero warnings in Birch's own code (shared rule 8). Qt's headers come in as
# system/external includes, so their warnings are not ours; any that still
# show are recorded in CLAUDE.md > Chromium edition.
if(MSVC)
    target_compile_options(birch-qt-proto PRIVATE /W4 /WX /permissive- /utf-8
        /external:anglebrackets /external:W0)
    target_link_libraries(birch-qt-proto PRIVATE advapi32 psapi)
else()
    target_compile_options(birch-qt-proto PRIVATE -Wall -Wextra -Werror)
endif()

# A console program on purpose: the test harness reads its stderr.
set_target_properties(birch-qt-proto PROPERTIES WIN32_EXECUTABLE OFF)
