cmake_minimum_required(VERSION 3.16)
project(hyprshell-agent VERSION 1.0 LANGUAGES CXX)

# The shell's Bluetooth pairing agent and NetworkManager secret agent. Only
# QtCore and QtDBus, both part of qt6-base, which Quickshell already needs.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core DBus)

add_executable(hyprshell-agent main.cpp)
target_link_libraries(hyprshell-agent PRIVATE Qt6::Core Qt6::DBus)

install(TARGETS hyprshell-agent RUNTIME DESTINATION bin)
