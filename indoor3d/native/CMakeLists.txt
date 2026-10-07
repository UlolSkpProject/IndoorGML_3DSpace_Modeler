cmake_minimum_required(VERSION 3.20)

project(IndoorGMLNative LANGUAGES CXX)

set(RUBY_ROOT "${CMAKE_CURRENT_LIST_DIR}/shared/third_party/ruby")

add_library(indoor_gml_native MODULE)

target_sources(indoor_gml_native PRIVATE
    include/native_api.h
    include/adjacency_data.h
    include/adjacency_checker.h
    include/adjacency_session.h
    include/state_locator.h
    src/native_entry.cpp
    src/native_api.cpp
    src/adjacency_data.cpp
    src/adjacency_checker.cpp
    src/adjacency_session.cpp
    src/state_locator.cpp
)

target_include_directories(indoor_gml_native PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/include"
    "${RUBY_ROOT}/include"
)

target_link_libraries(indoor_gml_native PRIVATE
    "${RUBY_ROOT}/lib/x64-ucrt-ruby320.lib"
)

target_compile_features(indoor_gml_native PRIVATE cxx_std_17)

if(MSVC)
    target_compile_definitions(indoor_gml_native PRIVATE NOMINMAX)
    target_compile_options(indoor_gml_native PRIVATE "/EHsc")
    target_link_options(indoor_gml_native PRIVATE "/NOIMPLIB" "/NOEXP")
endif()

set_target_properties(indoor_gml_native PROPERTIES
    PREFIX ""
    OUTPUT_NAME "indoor_gml_native"
    SUFFIX ".so"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
)

foreach(CONFIGURATION Debug Release RelWithDebInfo MinSizeRel)
    string(TOUPPER "${CONFIGURATION}" CONFIGURATION_UPPER)
    set_target_properties(indoor_gml_native PROPERTIES
        "LIBRARY_OUTPUT_DIRECTORY_${CONFIGURATION_UPPER}" "${CMAKE_CURRENT_SOURCE_DIR}"
        "RUNTIME_OUTPUT_DIRECTORY_${CONFIGURATION_UPPER}" "${CMAKE_CURRENT_SOURCE_DIR}"
    )
endforeach()

include(CTest)

if(BUILD_TESTING)
    add_executable(indoor_gml_native_test
        test/adjacency_test.cpp
        src/adjacency_data.cpp
        src/adjacency_checker.cpp
        src/state_locator.cpp
    )
    target_include_directories(indoor_gml_native_test PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
    )
    target_compile_features(indoor_gml_native_test PRIVATE cxx_std_17)
    if(MSVC)
        target_compile_definitions(indoor_gml_native_test PRIVATE NOMINMAX)
        target_compile_options(indoor_gml_native_test PRIVATE "/EHsc")
    endif()
    add_test(NAME indoor_gml_native_equivalence COMMAND indoor_gml_native_test)
endif()
