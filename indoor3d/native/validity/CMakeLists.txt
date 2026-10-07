set(RUBY_ROOT "${CMAKE_CURRENT_LIST_DIR}/../shared/third_party/ruby")
set(MANIFOLD_ROOT "${CMAKE_CURRENT_LIST_DIR}/../shared/third_party/manifold" CACHE PATH
    "Vendored Manifold root (include/manifold + lib/manifold.lib)"
)

if(NOT EXISTS "${MANIFOLD_ROOT}/include/manifold/manifold.h" OR
   NOT EXISTS "${MANIFOLD_ROOT}/lib/manifold.lib")
    message(WARNING
        "IndoorGML validity target expects Manifold at ${MANIFOLD_ROOT}. "
        "Vendor the same Manifold package used by SeoulSpace-Verify before building."
    )
endif()

add_library(indoor_gml_validity_native MODULE)

target_sources(indoor_gml_validity_native PRIVATE
    include/native_api.h
    include/validity_data.h
    include/validity_checker.h
    include/validity_session.h
    include/manifold_adapter.h
    include/overlap_thickness.h
    src/native_entry.cpp
    src/native_api.cpp
    src/validity_data.cpp
    src/validity_checker.cpp
    src/validity_session.cpp
    src/manifold_adapter.cpp
    src/overlap_thickness.cpp
)

target_include_directories(indoor_gml_validity_native PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/include"
    "${RUBY_ROOT}/include"
    "${MANIFOLD_ROOT}/include"
)

target_link_libraries(indoor_gml_validity_native PRIVATE
    indoor_gml_geometry
    "${RUBY_ROOT}/lib/x64-ucrt-ruby320.lib"
    "${MANIFOLD_ROOT}/lib/manifold.lib"
)

target_compile_features(indoor_gml_validity_native PRIVATE cxx_std_17)

if(MSVC)
    target_compile_definitions(indoor_gml_validity_native PRIVATE NOMINMAX)
    target_compile_options(indoor_gml_validity_native PRIVATE "/EHsc")
    target_link_options(indoor_gml_validity_native PRIVATE "/NOIMPLIB" "/NOEXP")
endif()

set_target_properties(indoor_gml_validity_native PROPERTIES
    PREFIX ""
    OUTPUT_NAME "indoor_gml_validity_native"
    SUFFIX ".so"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
)

foreach(CONFIGURATION Debug Release RelWithDebInfo MinSizeRel)
    string(TOUPPER "${CONFIGURATION}" CONFIGURATION_UPPER)
    set_target_properties(indoor_gml_validity_native PROPERTIES
        "LIBRARY_OUTPUT_DIRECTORY_${CONFIGURATION_UPPER}" "${CMAKE_CURRENT_LIST_DIR}"
        "RUNTIME_OUTPUT_DIRECTORY_${CONFIGURATION_UPPER}" "${CMAKE_CURRENT_LIST_DIR}"
    )
endforeach()
