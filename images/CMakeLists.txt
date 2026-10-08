cmake_minimum_required(VERSION 3.21)
project(hyprshell-images VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick)
qt_standard_project_setup(REQUIRES 6.2)

# Shared with Files, as the task manager does: the palette that follows
# the shell's theme.json, the glyph pack, and the pieces windows are made of.
set(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../files)

qt_add_library(hyprshell-images-backend STATIC)
qt_add_qml_module(hyprshell-images-backend
    URI Hyprshell.Backend
    VERSION 1.0
    RESOURCE_PREFIX "/"
    SOURCES
        ${FILES}/src/sys.cpp ${FILES}/src/sys.h
        ${FILES}/src/watcher.cpp ${FILES}/src/watcher.h
        src/gallery.cpp src/gallery.h
)
target_include_directories(hyprshell-images-backend PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src ${FILES}/src)
target_link_libraries(hyprshell-images-backend PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)

qt_add_executable(hyprshell-images src/main.cpp)

set(SHARED_QML Appearance.qml MonoIcon.qml StyledText.qml SmoothScroll.qml)
set(SHARED_PATHS "")
foreach(f ${SHARED_QML})
    set_source_files_properties(${FILES}/qml/${f} PROPERTIES QT_RESOURCE_ALIAS qml/${f})
    list(APPEND SHARED_PATHS ${FILES}/qml/${f})
endforeach()
set_source_files_properties(${FILES}/qml/IconPaths.js PROPERTIES QT_RESOURCE_ALIAS qml/IconPaths.js)
set_source_files_properties(${FILES}/qml/Appearance.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

file(GLOB IMAGES_QML RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} qml/*.qml)

qt_add_qml_module(hyprshell-images
    URI Hyprshell
    VERSION 1.0
    RESOURCE_PREFIX "/"
    QML_FILES ${IMAGES_QML} ${SHARED_PATHS}
    RESOURCES ${FILES}/qml/IconPaths.js
)

target_link_libraries(hyprshell-images
    PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick hyprshell-images-backendplugin)

include(GNUInstallDirs)
configure_file(hyprshell-images.desktop.in ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-images.desktop @ONLY)
install(TARGETS hyprshell-images RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hyprshell-images.desktop
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/applications)
