cmake_minimum_required(VERSION 3.21)
project(hyprshell-files VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# 6.2 is the floor on purpose: everything here is core QtQuick, and pinning
# higher would rule out distributions that are otherwise perfectly able to
# run it.
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick)

qt_standard_project_setup(REQUIRES 6.2)

# The C++ types live in a module of their own.
#
# Not because they have to, but because a QML singleton that imports the
# module it is itself part of makes every other singleton in that module a
# dependency of it — and QML then reports Appearance and FilesService as a
# cyclic dependency, since each needs the module the other is in. Separate
# module, no cycle, and the ownership is clearer besides: this is the
# platform, that is the application.
qt_add_library(hyprshell-backend STATIC)

qt_add_qml_module(hyprshell-backend
    URI Hyprshell.Backend
    VERSION 1.0
    RESOURCE_PREFIX "/"
    SOURCES
        src/proc.cpp src/proc.h
        src/sys.cpp src/sys.h
        src/watcher.cpp src/watcher.h
)

target_include_directories(hyprshell-backend PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(hyprshell-backend PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)

qt_add_executable(hyprshell-files
    src/main.cpp
)

# The QML is a resource rather than files on disk, so the installed binary
# has no runtime dependency on where it was built from.
# QML singletons have to be declared as such to the module system, or they
# are registered as ordinary types and `Appearance.ink` is a syntax error at
# every use site.
set_source_files_properties(qml/Appearance.qml qml/FilesService.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

# RESOURCE_PREFIX is pinned because the default moved: Qt 6.4 puts the
# module at :/Hyprshell/..., 6.5 and later at :/qt/qml/Hyprshell/... . Saying
# it here means main.cpp's path is right on both.
qt_add_qml_module(hyprshell-files
    URI Hyprshell
    VERSION 1.0
    RESOURCE_PREFIX "/"
    QML_FILES
        qml/Main.qml
        qml/Appearance.qml
        qml/FilesService.qml
        qml/Files.qml
        qml/FilesFrame.qml
        qml/FileMenu.qml
        qml/FileTile.qml
        qml/FileRow.qml
        qml/PlaceRow.qml
        qml/ListHeader.qml
        qml/DragBadge.qml
        qml/Properties.qml
        qml/NameField.qml
        qml/NewNameTile.qml
        qml/PanelSurface.qml
        qml/StyledText.qml
        qml/MonoIcon.qml
    RESOURCES
        qml/IconPaths.js
)

# The generated type registrations include the headers by bare name.
target_include_directories(hyprshell-files PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)

target_link_libraries(hyprshell-files
    PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick hyprshell-backendplugin)

include(GNUInstallDirs)

# The desktop entry's Exec is written as an absolute path, not a bare name.
#
# A bare name is resolved against PATH, and the PATH that matters is the one
# the *compositor* was started with — not the one an interactive shell has.
# Installing to ~/.local/bin, which is the default here, means anything
# launching through the desktop entry (an application menu, a launcher's
# search results, xdg-open on a folder) finds nothing, while typing the same
# name in a terminal works. An absolute path has no such ambiguity.
configure_file(hyprshell-files.desktop.in
               ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-files.desktop @ONLY)

install(TARGETS hyprshell-files
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-files.desktop
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/applications)
