cmake_minimum_required(VERSION 3.21)
project(hyprshell-files VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# 6.2 is the floor on purpose: everything here is core QtQuick, and pinning
# higher would rule out distributions that are otherwise perfectly able to
# run it.
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick DBus)

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
    src/filemanager1.cpp src/filemanager1.h
    src/portal.cpp src/portal.h
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
        qml/NameTip.qml
        qml/FileDialog.qml
        qml/DialogButton.qml
        qml/GroupHeading.qml
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
    PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus
            hyprshell-backendplugin)

include(GNUInstallDirs)

# The desktop entry's Exec is written as an absolute path, not a bare name.
#
# A bare name is resolved against PATH, and the PATH that matters is the one
# the *compositor* was started with — not the one an interactive shell has.
# Installing to ~/.local/bin, which is the default here, means anything
# launching through the desktop entry (an application menu, a launcher's
# search results, xdg-open on a folder) finds nothing, while typing the same
# name in a terminal works. An absolute path has no such ambiguity.

# D-Bus activation for org.freedesktop.FileManager1.
#
# Without this, "show in file manager" only reaches this program when it
# already happens to be running; with it, the bus starts one. The Exec is
# absolute for the same reason the desktop entry's is — the bus daemon's
# PATH is the session's, not an interactive shell's.
configure_file(org.freedesktop.FileManager1.service.in
               ${CMAKE_CURRENT_BINARY_DIR}/org.freedesktop.FileManager1.service @ONLY)

# And the same for the file-dialog portal backend, which xdg-desktop-portal
# starts the first time anything puts up a "Save as…" — by way of the user
# manager, which is where the session's environment is.
configure_file(portal.service.in
               ${CMAKE_CURRENT_BINARY_DIR}/org.freedesktop.impl.portal.desktop.hyprshell.service @ONLY)

configure_file(portal.systemd.service.in
               ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-files-portal.service @ONLY)

configure_file(hyprshell-files.desktop.in
               ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-files.desktop @ONLY)

# The dialog's own entry. Nothing launches it — it is there so the app id
# a file dialog carries resolves to a name and an icon.
configure_file(hyprshell-files-dialog.desktop.in
               ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-files-dialog.desktop @ONLY)

install(TARGETS hyprshell-files
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# The portal backend: a .portal file naming the interface it implements and
# the desktop it applies to, and a D-Bus service file so xdg-desktop-portal
# can start it on demand — it will, the first time anything asks for a file.
install(FILES hyprshell.portal
        DESTINATION ${CMAKE_INSTALL_DATADIR}/xdg-desktop-portal/portals)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/org.freedesktop.impl.portal.desktop.hyprshell.service
        DESTINATION ${CMAKE_INSTALL_DATADIR}/dbus-1/services)
# share/systemd/user, not lib/systemd/user: the user manager searches
# $XDG_DATA_HOME/systemd/user and each $XDG_DATA_DIRS/systemd/user, which
# covers both an install into ~/.local and one into a system prefix. The
# lib path is only searched under /usr and /usr/local.
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-files-portal.service
        DESTINATION ${CMAKE_INSTALL_DATADIR}/systemd/user)

install(FILES ${CMAKE_CURRENT_BINARY_DIR}/org.freedesktop.FileManager1.service
        DESTINATION ${CMAKE_INSTALL_DATADIR}/dbus-1/services)

install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-files.desktop
              ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-files-dialog.desktop
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/applications)
