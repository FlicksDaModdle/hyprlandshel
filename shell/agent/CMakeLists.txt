cmake_minimum_required(VERSION 3.16)
project(hyprshell-agent VERSION 1.0 LANGUAGES CXX)

# The shell's helpers, built by install.sh:
#
#   hyprshell-agent    Bluetooth pairing agent and NetworkManager secret
#                      agent. QtCore and QtDBus only, both in qt6-base.
#   hyprshell-cursors  builds the accent-coloured cursor theme. Needs QtSvg
#                      (qt6-svg, which Quickshell itself depends on); skipped
#                      when it is not there. install.sh replaces it with the
#                      Rust one (../rust/cursors) when cargo is installed.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core DBus)

add_executable(hyprshell-agent main.cpp)
target_link_libraries(hyprshell-agent PRIVATE Qt6::Core Qt6::DBus)
install(TARGETS hyprshell-agent RUNTIME DESTINATION bin)

find_package(Qt6 QUIET COMPONENTS Gui Svg)
if(Qt6Svg_FOUND)
    add_executable(hyprshell-cursors cursors.cpp)
    target_link_libraries(hyprshell-cursors PRIVATE Qt6::Core Qt6::Gui Qt6::Svg)
    install(TARGETS hyprshell-cursors RUNTIME DESTINATION bin)
else()
    message(STATUS "QtSvg not found: not building hyprshell-cursors (the accent cursor)")
endif()
