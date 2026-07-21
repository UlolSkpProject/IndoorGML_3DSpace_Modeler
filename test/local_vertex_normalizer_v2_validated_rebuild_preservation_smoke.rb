# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        MM_PER_INCH = 25.4
        class Error < StandardError; end

        attr_reader :legacy_merge_called

        def initialize
          @snapshot = []
          @legacy_merge_called = false
          @surface_equivalent = true
        end

        def snapshot=(records)
          @snapshot = records
        end

        def surface_equivalent=(value)
          @surface_equivalent = value
        end

        private

        def orient_and_merge_rebuilt_surface(_entities, _validated_triangles)
          @legacy_merge_called = true
          [:legacy_orientation, { legacy: true }]
        end

        def normalized_triangle_snapshot(_entities, duplicate_diagnostics:)
          duplicate_diagnostics[:duplicate_count] = 0
          @snapshot
        end

        def repair_degenerate_source_triangles(records)
          [records, { repaired_triangles: 0, replaced_pairs: 0 }]
        end

        def validate_normalized_triangle_mesh!(_records)
          { valid: true }
        end

        def verify_normalized_surface_equivalence!(_expected, _actual)
          raise Error, 'different surface' unless @surface_equivalent

          { equivalent: true }
        end

        def grid_indices(point)
          point
        end

        def geometry_counts(_entities)
          { faces: 4, edges: 6, boundary_edges: 0, non_manifold_edges: 0 }
        end

        def repair_reverse_faces(_entities)
          {
            reversed_faces: 0,
            consistency_reversed_faces: 0,
            component_count: 1,
            outward_reversed_faces: 0,
            signed_volume_before_in3: 1.0,
            signed_volume_after_in3: 1.0
          }
        end

        def closed_surface?(_topology)
          true
        end

        def empty_coplanar_cleanup_report(fallback_reason: nil)
          {
            removed_edges: 0,
            removed_groups: 0,
            fallback_reason: fallback_reason
          }
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/validated_rebuild_triangulation_preservation_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
record = lambda do |points|
  { points: points, source_normal: [0.0, 0.0, 1.0] }
end

validated = [
  record.call([[0, 0, 0], [10, 0, 0], [0, 10, 0]]),
  record.call([[10, 0, 0], [10, 10, 0], [0, 10, 0]])
]

normalizer = klass.new
normalizer.snapshot = validated.map(&:dup)
orientation, cleanup = normalizer.send(
  :orient_and_merge_rebuilt_surface,
  Object.new,
  validated
)

if normalizer.legacy_merge_called
  raise 'legacy coplanar merge ran for an exact validated rebuild'
end
unless cleanup[:preserved_validated_surface] == true &&
       cleanup[:preserved_constrained_edges] == true &&
       cleanup[:fallback_reason] == :preserved_validated_surface
  raise "validated surface preservation report mismatch: #{cleanup.inspect}"
end
unless orientation[:shell_component_count] == 1
  raise "orientation report mismatch: #{orientation.inspect}"
end

# A different diagonal over the same square is a surface-equivalent rebuild and
# must also preserve the rebuilt edges instead of invoking n-gon cleanup.
normalizer = klass.new
normalizer.snapshot = [
  record.call([[0, 0, 0], [10, 0, 0], [10, 10, 0]]),
  record.call([[0, 0, 0], [10, 10, 0], [0, 10, 0]])
]
normalizer.surface_equivalent = true
_orientation, cleanup = normalizer.send(
  :orient_and_merge_rebuilt_surface,
  Object.new,
  validated
)
if normalizer.legacy_merge_called || cleanup[:preserved_validated_surface] != true
  raise 'surface-equivalent alternate diagonal was not preserved'
end

# A genuinely different surface must fall back to the legacy path. The pipeline
# hard checkpoint normally stops before this branch, but the wrapper remains
# conservative when called independently.
normalizer = klass.new
normalizer.snapshot = [record.call([[0, 0, 0], [10, 0, 0], [0, 11, 0]])]
normalizer.surface_equivalent = false
orientation, cleanup = normalizer.send(
  :orient_and_merge_rebuilt_surface,
  Object.new,
  validated
)
unless normalizer.legacy_merge_called &&
       orientation == :legacy_orientation &&
       cleanup == { legacy: true }
  raise 'different rebuilt surface did not use the legacy cleanup path'
end

puts 'LocalVertexNormalizer validated rebuild surface preservation smoke test: OK'
