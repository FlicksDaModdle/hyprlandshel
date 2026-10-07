cmake_minimum_required(VERSION 3.21)
project(hyprshell-mail VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick Network)
# Full HTML mail needs Qt WebEngine (qt6-webengine). Without it the app
# still builds and shows mail in a reduced rendering.
find_package(Qt6 6.5 QUIET OPTIONAL_COMPONENTS WebEngineQuick)
qt_standard_project_setup(REQUIRES 6.5)

# Shared with Files and Tasks rather than copied: the palette that follows
# the shell's theme.json, the glyph pack, and the small pieces every window
# is made of.
set(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../files)
set(TASKS ${CMAKE_CURRENT_SOURCE_DIR}/../tasks)

# The daemon: mail/core, built with cargo into the build tree.
find_program(CARGO cargo REQUIRED)
set(MAILD_DIR ${CMAKE_CURRENT_BINARY_DIR}/core)
set(MAILD_BIN ${MAILD_DIR}/release/hyprshell-maild)
file(GLOB MAILD_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/core/src/*.rs)
add_custom_command(
    OUTPUT ${MAILD_BIN}
    COMMAND ${CARGO} build --release --locked
            --manifest-path ${CMAKE_CURRENT_SOURCE_DIR}/core/Cargo.toml
            --target-dir ${MAILD_DIR}
    DEPENDS ${MAILD_SOURCES}
            ${CMAKE_CURRENT_SOURCE_DIR}/core/Cargo.toml
            ${CMAKE_CURRENT_SOURCE_DIR}/core/Cargo.lock
    COMMENT "Building the mail daemon (cargo)"
    USES_TERMINAL
    VERBATIM)
add_custom_target(hyprshell-maild ALL DEPENDS ${MAILD_BIN})

qt_add_library(hyprshell-mail-backend STATIC)
qt_add_qml_module(hyprshell-mail-backend
    URI Hyprshell.Backend
    VERSION 1.0
    RESOURCE_PREFIX "/"
    SOURCES
        ${FILES}/src/sys.cpp ${FILES}/src/sys.h
        ${FILES}/src/watcher.cpp ${FILES}/src/watcher.h
        src/mailclient.cpp src/mailclient.h
        src/mailapp.cpp src/mailapp.h
)
target_include_directories(hyprshell-mail-backend PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src ${FILES}/src)
target_link_libraries(hyprshell-mail-backend PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network)
if(TARGET Qt6::WebEngineQuick)
    target_compile_definitions(hyprshell-mail-backend PRIVATE HAVE_WEBENGINE)
    target_link_libraries(hyprshell-mail-backend PRIVATE Qt6::WebEngineQuick)
    message(STATUS "Mail: full HTML with Qt WebEngine")
else()
    message(STATUS "Mail: no Qt WebEngine — HTML mail in a reduced rendering")
endif()

qt_add_executable(hyprshell-mail src/main.cpp)

set(SHARED_QML Appearance.qml MonoIcon.qml PanelSurface.qml StyledText.qml DialogButton.qml
               ScrollBar.qml SmoothScroll.qml)
set(SHARED_PATHS "")
foreach(f ${SHARED_QML})
    set_source_files_properties(${FILES}/qml/${f} PROPERTIES QT_RESOURCE_ALIAS qml/${f})
    list(APPEND SHARED_PATHS ${FILES}/qml/${f})
endforeach()
set(TASKS_QML ContextMenu.qml Toast.qml SearchField.qml Switch.qml Seg.qml ToolButton.qml Modal.qml)
foreach(f ${TASKS_QML})
    set_source_files_properties(${TASKS}/qml/${f} PROPERTIES QT_RESOURCE_ALIAS qml/${f})
    list(APPEND SHARED_PATHS ${TASKS}/qml/${f})
endforeach()
set_source_files_properties(${FILES}/qml/IconPaths.js PROPERTIES QT_RESOURCE_ALIAS qml/IconPaths.js)
set_source_files_properties(${FILES}/qml/Appearance.qml qml/Mail.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

file(GLOB MAIL_QML RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} qml/*.qml)
file(GLOB MAIL_JS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} qml/*.js)
# The WebEngine reader is only built in when WebEngine is there; the app
# asks for it by name at run time and falls back when it is absent.
set(WEB_QML "")
if(TARGET Qt6::WebEngineQuick)
    set(WEB_QML qml/web/WebBody.qml)
endif()

qt_add_qml_module(hyprshell-mail
    URI Hyprshell
    VERSION 1.0
    RESOURCE_PREFIX "/"
    QML_FILES ${MAIL_QML} ${SHARED_PATHS}
    RESOURCES ${FILES}/qml/IconPaths.js ${MAIL_JS} ${WEB_QML}
)

target_link_libraries(hyprshell-mail
    PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network hyprshell-mail-backendplugin)
if(TARGET Qt6::WebEngineQuick)
    target_compile_definitions(hyprshell-mail PRIVATE HAVE_WEBENGINE)
    target_link_libraries(hyprshell-mail PRIVATE Qt6::WebEngineQuick)
endif()

include(GNUInstallDirs)
configure_file(hyprshell-mail.desktop.in ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-mail.desktop @ONLY)
install(TARGETS hyprshell-mail RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(PROGRAMS ${MAILD_BIN} DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-mail.desktop
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/applications)
# Its own icon, so notifications and the launcher never ask the theme for a
# name it may not have.
install(FILES hyprshell-mail.svg
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor/scalable/apps)
# And as a PNG: a notification is given this one by path, which shows
# whether or not the notification server can draw SVG.
install(FILES hyprshell-mail.png
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor/256x256/apps)
