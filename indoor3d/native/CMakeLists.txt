cmake_minimum_required(VERSION 3.20)

project(IndoorGMLNative LANGUAGES CXX)

include(CTest)

set(NATIVE_ROOT "${CMAKE_CURRENT_LIST_DIR}")
set(CORE_ROOT "${NATIVE_ROOT}/core")
set(VALIDITY_ROOT "${NATIVE_ROOT}/validity")
set(SHARED_ROOT "${NATIVE_ROOT}/shared")
set(RUBY_ROOT "${SHARED_ROOT}/third_party/ruby")
set(MANIFOLD_ROOT "${SHARED_ROOT}/third_party/manifold")

function(indoor_gml_configure_cpp_target target)
    target_compile_features(${target} PRIVATE cxx_std_17)

    if(MSVC)
        target_compile_definitions(${target} PRIVATE NOMINMAX)
        target_compile_options(${target} PRIVATE "/EHsc")
    endif()
endfunction()

function(indoor_gml_configure_ruby_module target output_directory)
    target_include_directories(${target} PRIVATE
        "${RUBY_ROOT}/include"
    )
    target_link_libraries(${target} PRIVATE
        "${RUBY_ROOT}/lib/x64-ucrt-ruby320.lib"
    )

    if(MSVC)
        target_link_options(${target} PRIVATE "/NOIMPLIB" "/NOEXP")
    endif()

    set_target_properties(${target} PROPERTIES
        PREFIX ""
        SUFFIX ".so"
        LIBRARY_OUTPUT_DIRECTORY "${output_directory}"
        RUNTIME_OUTPUT_DIRECTORY "${output_directory}"
    )

    foreach(CONFIGURATION Debug Release RelWithDebInfo MinSizeRel)
        string(TOUPPER "${CONFIGURATION}" CONFIGURATION_UPPER)
        set_target_properties(${target} PROPERTIES
            "LIBRARY_OUTPUT_DIRECTORY_${CONFIGURATION_UPPER}" "${output_directory}"
            "RUNTIME_OUTPUT_DIRECTORY_${CONFIGURATION_UPPER}" "${output_directory}"
        )
    endforeach()
endfunction()

# Shared exact face-adjacency kernel. Both runtime adjacency and validity 704
# compile against this single implementation.
add_library(indoor_gml_geometry STATIC
    shared/geometry/src/exact_face_adjacency.cpp
)

target_include_directories(indoor_gml_geometry PUBLIC
    "${SHARED_ROOT}/geometry/include"
)

set_target_properties(indoor_gml_geometry PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

indoor_gml_configure_cpp_target(indoor_gml_geometry)

# Runtime Core Ruby extension: State + Adjacency.
add_library(indoor_gml_native MODULE
    core/include/native_api.h
    core/include/adjacency_data.h
    core/include/adjacency_checker.h
    core/include/adjacency_session.h
    core/include/cell_space_interior_point_locator.h
    core/include/floor_polygon_preparation.h
    core/src/floor_polygon_preparation.cpp
    core/include/floor_polygon_intersections.h
    core/src/floor_polygon_intersections.cpp
    core/include/floor_polygon_graph.h
    core/src/floor_polygon_graph.cpp
    core/include/floor_polygon_cycles.h
    core/src/floor_polygon_cycles.cpp
    core/include/floor_polygon_regions.h
    core/src/floor_polygon_regions.cpp
    core/include/floor_polygon_validation.h
    core/src/floor_polygon_validation.cpp
    core/include/floor_polygon_queue.h
    core/src/floor_polygon_queue.cpp
    core/include/floor_polygon_reference.h
    core/src/floor_polygon_reference.cpp
    core/src/native_entry.cpp
    core/src/native_api.cpp
    core/src/adjacency_data.cpp
    core/src/adjacency_checker.cpp
    core/src/adjacency_session.cpp
    core/src/cell_space_interior_point_locator.cpp
)

target_include_directories(indoor_gml_native PRIVATE
    "${CORE_ROOT}/include"
)

target_link_libraries(indoor_gml_native PRIVATE
    indoor_gml_geometry
)

indoor_gml_configure_cpp_target(indoor_gml_native)
indoor_gml_configure_ruby_module(indoor_gml_native "${CORE_ROOT}")

# Validity Ruby extension: 701 Manifold overlap + 704 exact adjacency.
add_library(indoor_gml_validity_native MODULE
    validity/include/native_api.h
    validity/include/validity_data.h
    validity/include/validity_checker.h
    validity/include/validity_session.h
    validity/include/manifold_adapter.h
    validity/include/overlap_thickness.h
    validity/src/native_entry.cpp
    validity/src/native_api.cpp
    validity/src/validity_data.cpp
    validity/src/validity_checker.cpp
    validity/src/validity_session.cpp
    validity/src/manifold_adapter.cpp
    validity/src/overlap_thickness.cpp
)

target_include_directories(indoor_gml_validity_native PRIVATE
    "${VALIDITY_ROOT}/include"
    "${MANIFOLD_ROOT}/include"
)

target_link_libraries(indoor_gml_validity_native PRIVATE
    indoor_gml_geometry
    "${MANIFOLD_ROOT}/lib/manifold.lib"
)

indoor_gml_configure_cpp_target(indoor_gml_validity_native)
indoor_gml_configure_ruby_module(
    indoor_gml_validity_native
    "${VALIDITY_ROOT}"
)

if(BUILD_TESTING)
    add_executable(indoor_gml_native_test
        core/test/adjacency_test.cpp
        core/src/adjacency_data.cpp
        core/src/adjacency_checker.cpp
        core/src/cell_space_interior_point_locator.cpp
    )

    target_include_directories(indoor_gml_native_test PRIVATE
        "${CORE_ROOT}/include"
    )

    target_link_libraries(indoor_gml_native_test PRIVATE
        indoor_gml_geometry
    )

    indoor_gml_configure_cpp_target(indoor_gml_native_test)

    add_test(
        NAME indoor_gml_native_equivalence
        COMMAND indoor_gml_native_test
    )

    # Isolated Phase 1/2 pure-geometry tests (no State/Adjacency call).
    add_executable(indoor_gml_floor_polygon_preparation_test
        core/test/floor_polygon_preparation_test.cpp
        core/src/floor_polygon_preparation.cpp
    )

    target_include_directories(indoor_gml_floor_polygon_preparation_test PRIVATE
        "${CORE_ROOT}/include"
    )

    target_link_libraries(indoor_gml_floor_polygon_preparation_test PRIVATE
        indoor_gml_geometry
    )

    indoor_gml_configure_cpp_target(indoor_gml_floor_polygon_preparation_test)

    add_test(
        NAME indoor_gml_floor_polygon_preparation_phase_1_2
        COMMAND indoor_gml_floor_polygon_preparation_test
    )

    # Phase 3-7 standalone transactional planar subdivision tests.
    # Deliberately not called by live State/BEFORE/Exact Adjacency yet.
    add_executable(indoor_gml_floor_polygon_partition_test
        core/test/floor_polygon_partition_test.cpp
        core/src/floor_polygon_preparation.cpp
        core/src/floor_polygon_intersections.cpp
        core/src/floor_polygon_graph.cpp
        core/src/floor_polygon_cycles.cpp
        core/src/floor_polygon_regions.cpp
        core/src/floor_polygon_validation.cpp
        core/src/floor_polygon_queue.cpp
        core/src/floor_polygon_reference.cpp
    )

    target_include_directories(indoor_gml_floor_polygon_partition_test PRIVATE
        "${CORE_ROOT}/include"
    )

    target_link_libraries(indoor_gml_floor_polygon_partition_test PRIVATE
        indoor_gml_geometry
    )

    indoor_gml_configure_cpp_target(indoor_gml_floor_polygon_partition_test)

    add_test(
        NAME indoor_gml_floor_polygon_partition_phase_3_7
        COMMAND indoor_gml_floor_polygon_partition_test
    )

    add_executable(indoor_gml_validity_native_test
        validity/test/validity_test.cpp
        validity/src/validity_checker.cpp
        validity/src/overlap_thickness.cpp
    )

    target_include_directories(indoor_gml_validity_native_test PRIVATE
        "${VALIDITY_ROOT}/include"
        "${MANIFOLD_ROOT}/include"
    )

    target_link_libraries(indoor_gml_validity_native_test PRIVATE
        indoor_gml_geometry
        "${MANIFOLD_ROOT}/lib/manifold.lib"
    )

    indoor_gml_configure_cpp_target(indoor_gml_validity_native_test)

    add_test(
        NAME indoor_gml_validity_native_semantics
        COMMAND indoor_gml_validity_native_test
    )
endif()
