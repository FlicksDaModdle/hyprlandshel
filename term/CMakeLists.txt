cmake_minimum_required(VERSION 3.21)
project(hyprshell-term VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick)

# libvterm is the terminal emulation itself — MIT, C99, and no opinion
# about toolkits: it parses the stream and keeps the grid, and calls back
# for everything it cannot do itself. Found with pkg-config because that
# is all it ships; there is no CMake package.
find_package(PkgConfig REQUIRED)
pkg_check_modules(VTERM REQUIRED IMPORTED_TARGET vterm)

qt_standard_project_setup(REQUIRES 6.2)

# The C++ types live in a module of their own, for the same reason they do
# in the file manager: a QML singleton that imports the module it is part
# of makes every other singleton in that module depend on it, and QML
# calls that a cyclic dependency.
qt_add_library(hyprterm-backend STATIC)

qt_add_qml_module(hyprterm-backend
    URI Hyprterm.Backend
    VERSION 1.0
    RESOURCE_PREFIX "/"
    SOURCES
        src/sys.cpp src/sys.h
        src/watcher.cpp src/watcher.h
)

target_include_directories(hyprterm-backend PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(hyprterm-backend PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)

qt_add_executable(hyprshell-term
    src/main.cpp
    src/ptyproc.cpp src/ptyproc.h
    src/term.cpp src/term.h
    src/termview.cpp src/termview.h
    src/boxdraw.cpp src/boxdraw.h
)

set_source_files_properties(qml/Appearance.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(hyprshell-term
    URI Hyprterm
    VERSION 1.0
    RESOURCE_PREFIX "/"
    QML_FILES
        qml/Main.qml
        qml/Appearance.qml
        qml/TermFrame.qml
        qml/TermMenu.qml
        qml/MonoIcon.qml
        qml/StyledText.qml
    RESOURCES
        qml/IconPaths.js
)

target_include_directories(hyprshell-term PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(hyprshell-term
    PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick PkgConfig::VTERM util
            hyprterm-backendplugin)

include(GNUInstallDirs)
configure_file(hyprshell-term.desktop.in
               ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-term.desktop @ONLY)
install(TARGETS hyprshell-term RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-term.desktop
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/applications)
