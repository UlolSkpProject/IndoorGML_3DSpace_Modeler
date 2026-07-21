# frozen_string_literal: true

# The geometry kernel is kept separate from the v2 orchestration policy. Loading
# this file installs the complete LocalVertexNormalizer implementation in the
# required order: legacy geometric primitives, safe coplanar edge grouping, the
# v2 normalization pipeline, runtime regression fixes from integration runs,
# the production coplanar-tolerance policy, Face-local topology-preserving grid
# targets, global shell-embedding grid targets, then source-Face provenance.
require_relative 'local_vertex_normalizer/legacy_kernel'
require_relative 'local_vertex_normalizer/coplanar_shared_edge_groups'
require_relative 'local_vertex_normalizer/pipeline_v2'
require_relative 'local_vertex_normalizer/runtime_regression_fixes_v2'
require_relative 'local_vertex_normalizer/coplanar_tolerance_policy_v2'
require_relative 'local_vertex_normalizer/topology_preserving_grid_targets_v2'
require_relative 'local_vertex_normalizer/global_shell_embedding_grid_targets_v2'
require_relative 'local_vertex_normalizer/source_face_boundary_constraints_v2'
