# frozen_string_literal: true

# The geometry kernel is kept separate from the orchestration policy. Loading
# this file installs the complete LocalVertexNormalizer implementation in the
# required order: base geometry/correctness layers first, then alias-based
# orchestration wrappers, then semantics-neutral performance acceleration layers.
# Profilers remain outermost so final simplification and performance wrappers are
# included in timing and workload diagnostics.
require_relative 'local_vertex_normalizer/geometry_kernel'
# Keep the strict triangle shortcut underneath source-boundary normalization.
# Changed source loops must still be reconstructed by the correctness wrapper;
# only unchanged exact triangular loops may reach this shortcut.
require_relative 'local_vertex_normalizer/source_boundary_triangle_fast_path'
require_relative 'local_vertex_normalizer/coplanar_shared_edge_groups'
require_relative 'local_vertex_normalizer/source_boundary_normalization'
require_relative 'local_vertex_normalizer/source_collapsed_sliver_cleanup'
require_relative 'local_vertex_normalizer/pipeline'
require_relative 'local_vertex_normalizer/grid_altitude_sliver_retriangulation'

# Correctness repair chain.
require_relative 'local_vertex_normalizer/grid_near_edge_split_repair'
require_relative 'local_vertex_normalizer/grid_near_edge_owner_flip_repair'
require_relative 'local_vertex_normalizer/grid_post_conforming_invalid_repair'
require_relative 'local_vertex_normalizer/grid_local_cavity_retriangulation'
require_relative 'local_vertex_normalizer/grid_cross_source_sliver_flip'
require_relative 'local_vertex_normalizer/grid_post_conforming_altitude_sliver_repair'
require_relative 'local_vertex_normalizer/rebuild_omission_vertex_collapse'
require_relative 'local_vertex_normalizer/surface_descriptor_boundary_graph'

# Alias-based normalize_entity wrappers. Fast-path must capture the completed
# correctness pipeline. The bounded horizontal Z repair remains
# intact. The independent shared-Edge horizontal cluster alignment then runs
# immediately before final coplanar Face merge without a cluster Z-spread gate.
require_relative 'local_vertex_normalizer/normalized_input_fast_path'
require_relative 'local_vertex_normalizer/horizontal_face_z_unification'
require_relative 'local_vertex_normalizer/shared_edge_horizontal_cluster_z_alignment'
require_relative 'local_vertex_normalizer/final_coplanar_face_merge'
# Reuse only the exact validated snapshot produced by the current normalize call.
# Any scope, entity, topology, manifold, or grid mismatch falls back to the
# independent final-coplanar rollback snapshot above.
require_relative 'local_vertex_normalizer/final_coplanar_baseline_handoff'

# Semantics-neutral performance layers from refactor/lvn-performance@0654aab.
require_relative 'local_vertex_normalizer/exact_polygon_triangulation_cache'
require_relative 'local_vertex_normalizer/exact_polygon_ear_broad_phase'
require_relative 'local_vertex_normalizer/conforming_candidate_broad_phase'
require_relative 'local_vertex_normalizer/surface_descriptor_segment_broad_phase'
require_relative 'local_vertex_normalizer/triangle_intersection_geometry_cache'
require_relative 'local_vertex_normalizer/coplanar_shared_edge_intersection_fast_path'
require_relative 'local_vertex_normalizer/coplanar_disjoint_shared_vertex_fast_path'
require_relative 'local_vertex_normalizer/triangle_intersection_clean_cache'
require_relative 'local_vertex_normalizer/grid_patch_incremental_intersection'

require_relative 'local_vertex_normalizer/performance_profiler'
require_relative 'local_vertex_normalizer/diagnostic_profiler'

# Outermost read-only preflight. Complex solids return an explicit skipped report
# before any operation, definition isolation, or geometry mutation begins.
require_relative 'local_vertex_normalizer/complex_face_skip'
