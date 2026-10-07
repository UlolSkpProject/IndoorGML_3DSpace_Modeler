add_library(indoor_gml_geometry STATIC
    src/exact_face_adjacency.cpp
)

target_include_directories(indoor_gml_geometry PUBLIC
    "${CMAKE_CURRENT_LIST_DIR}/include"
)

target_compile_features(indoor_gml_geometry PUBLIC cxx_std_17)
set_target_properties(indoor_gml_geometry PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

if(MSVC)
    target_compile_definitions(indoor_gml_geometry PRIVATE NOMINMAX)
    target_compile_options(indoor_gml_geometry PRIVATE "/EHsc")
endif()
