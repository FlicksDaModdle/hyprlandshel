cmake_minimum_required(VERSION 3.21)
project(hyprshell-tasks VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick Network DBus)
qt_standard_project_setup(REQUIRES 6.2)

# Shared with Files rather than copied: the palette that follows the
# shell's theme.json, the glyph pack, and the small pieces both windows
# are made of. FILES is the file manager's directory beside this one.
set(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../files)

# The C++ in a module of its own, as Files has it — see its CMakeLists for
# why a singleton cannot share a module with the QML that imports it.
qt_add_library(hyprshell-tasks-backend STATIC)
qt_add_qml_module(hyprshell-tasks-backend
    URI Hyprshell.Backend
    VERSION 1.0
    RESOURCE_PREFIX "/"
    SOURCES
        ${FILES}/src/proc.cpp ${FILES}/src/proc.h
        ${FILES}/src/sys.cpp ${FILES}/src/sys.h
        ${FILES}/src/watcher.cpp ${FILES}/src/watcher.h
        src/monitor.cpp src/monitor.h
        src/procmodel.cpp src/procmodel.h
        src/appindex.cpp src/appindex.h
        src/graph.cpp src/graph.h
        src/tools.cpp src/tools.h
        src/recorder.cpp src/recorder.h
        src/bench.cpp src/bench.h
)
target_include_directories(hyprshell-tasks-backend PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src ${FILES}/src)
target_link_libraries(hyprshell-tasks-backend PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network Qt6::DBus)

qt_add_executable(hyprshell-tasks src/main.cpp)

set(SHARED_QML Appearance.qml MonoIcon.qml PanelSurface.qml StyledText.qml DialogButton.qml
               ScrollBar.qml SmoothScroll.qml SevenCombo.qml)
set(SHARED_PATHS "")
foreach(f ${SHARED_QML})
    set_source_files_properties(${FILES}/qml/${f} PROPERTIES QT_RESOURCE_ALIAS qml/${f})
    list(APPEND SHARED_PATHS ${FILES}/qml/${f})
endforeach()
set_source_files_properties(${FILES}/qml/IconPaths.js PROPERTIES QT_RESOURCE_ALIAS qml/IconPaths.js)
set_source_files_properties(${FILES}/qml/Appearance.qml qml/Tasks.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

file(GLOB TASKS_QML RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} qml/*.qml)
file(GLOB TASKS_JS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} qml/*.js)

qt_add_qml_module(hyprshell-tasks
    URI Hyprshell
    VERSION 1.0
    RESOURCE_PREFIX "/"
    QML_FILES ${TASKS_QML} ${SHARED_PATHS}
    RESOURCES ${FILES}/qml/IconPaths.js ${TASKS_JS}
)

target_link_libraries(hyprshell-tasks
    PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network hyprshell-tasks-backendplugin)

include(GNUInstallDirs)
configure_file(hyprshell-tasks.desktop.in ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-tasks.desktop @ONLY)
install(TARGETS hyprshell-tasks RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-tasks.desktop
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/applications)
