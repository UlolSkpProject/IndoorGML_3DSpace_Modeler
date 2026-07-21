# frozen_string_literal: true

# The geometry kernel is kept separate from the v2 orchestration policy. Loading
# this file installs the complete LocalVertexNormalizer implementation in the
# required order: legacy geometric primitives, safe coplanar edge grouping, then
# the v2 normalization and repair pipeline.
require_relative 'local_vertex_normalizer/legacy_kernel'
require_relative 'local_vertex_normalizer/coplanar_shared_edge_groups'
require_relative 'local_vertex_normalizer/pipeline_v2'
