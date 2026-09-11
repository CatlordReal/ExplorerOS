cmake_minimum_required(VERSION 3.21)
project(ExplorerLinkQtSimulator LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.2 REQUIRED COMPONENTS Widgets)

qt_add_executable(explorerlink-qt MACOSX_BUNDLE main.cpp)
target_link_libraries(explorerlink-qt PRIVATE Qt6::Widgets)
set_target_properties(explorerlink-qt PROPERTIES MACOSX_BUNDLE_GUI_IDENTIFIER "org.exploreros.linkqt")
