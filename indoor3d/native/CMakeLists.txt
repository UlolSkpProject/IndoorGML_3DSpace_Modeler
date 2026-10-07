cmake_minimum_required(VERSION 3.20)

project(IndoorGMLNative LANGUAGES CXX)

include(CTest)

add_subdirectory(shared/geometry)
add_subdirectory(core)
add_subdirectory(validity)
