# frozen_string_literal: true

# The geometry kernel is kept separate from the v2 orchestration policy. Loading
# this file installs the complete LocalVertexNormalizer implementation in the
# required order: legacy geometric primitives, safe coplanar edge grouping, the
# v2 normalization pipeline, grid-space/runtime regression layers, then the final
# connected n-gon coplanar simplification. The profiler remains the outermost
# optional wrapper so the final simplification is included in timing.
require_relative 'local_vertex_normalizer/legacy_kernel'
require_relative 'local_vertex_normalizer/coplanar_shared_edge_groups'
require_relative 'local_vertex_normalizer/source_boundary_normalization_v2'
require_relative 'local_vertex_normalizer/source_collapsed_sliver_cleanup_v2'
require_relative 'local_vertex_normalizer/pipeline_v2'
require_relative 'local_vertex_normalizer/grid_altitude_sliver_retriangulation_v2'
require_relative 'local_vertex_normalizer/runtime_regression_fixes_v2'
require_relative 'local_vertex_normalizer/grid_near_edge_split_repair_v2'
require_relative 'local_vertex_normalizer/coplanar_patch_provenance_trace_v2'
require_relative 'local_vertex_normalizer/final_coplanar_face_merge_v2'
require_relative 'local_vertex_normalizer/debug_profiler_v2'
