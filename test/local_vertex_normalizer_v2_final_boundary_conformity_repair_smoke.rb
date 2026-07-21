# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_EPSILON_MM = 0.000001
        class ReconstructionError < StandardError; end
        class TopologyChangedError < StandardError; end

        def initialize
          @tolerance_mm = 0.001
        end

        private

        def retriangulate_exact_coplanar_patches(
          triangle_records,
          forced_source_face_keys: [],
          force_all: false
        )
          [
            triangle_records,
            {
              forced_source_face_keys: forced_source_face_keys,
              force_all: force_all
            }
          ]
        end

        def sanitize_triangle_records(records)
          [
            records,
            {
              removed_collinear_triangle_count: 0,
              removed_duplicate_triangle_count: 0
            }
          ]
        end

        def grid_indices(point)
          point
        end

        def point_from_grid_indices(key)
          key
        end

        def canonical_edge_key(a, b)
          (a <=> b) <= 0 ? [a, b] : [b, a]
        end

        def canonical_triangle_key(triangle)
          triangle.sort
        end

        def integer_subtract(a, b)
          [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
        end

        def integer_dot(a, b)
          (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2])
        end

        def integer_cross(a, b)
          [
            (a[1] * b[2]) - (a[2] * b[1]),
            (a[2] * b[0]) - (a[0] * b[2]),
            (a[0] * b[1]) - (a[1] * b[0])
          ]
        end

        def integer_triangle_normal(triangle)
          integer_cross(
            integer_subtract(triangle[1], triangle[0]),
            integer_subtract(triangle[2], triangle[0])
          )
        end

        def integer_zero_vector?(vector)
          vector.all?(&:zero?)
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/final_boundary_conformity_repair_v2'

klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
normalizer = klass.new

record = lambda do |points, face, polygon|
  {
    points: points,
    source_normal: [0.0, 0.0, 1.0],
    source_face_key: face,
    source_polygon_index: polygon
  }
end

# Closed tetrahedron except that face BAD uses A-P-D + P-B-D while face ABC
# still uses the unsplit AB edge. P is one grid unit away from AB.
a = [0, 0, 0]
b = [10_000, 0, 0]
p = [5_000, 1, 0]
c = [0, 10_000, 0]
d = [0, 0, 10_000]
records = [
  record.call([a, b, c], 1, 0),
  record.call([a, p, d], 2, 0),
  record.call([p, b, d], 2, 1),
  record.call([a, c, d], 3, 0),
  record.call([b, d, c], 4, 0)
]

repaired, report = normalizer.send(:repair_final_boundary_conformity, records)
unless report[:repaired_component_count] == 1
  raise "expected one repair: #{report.inspect}"
end
unless report[:remaining_boundary_edge_count].zero?
  raise "boundary remained after repair: #{report.inspect}"
end
unless repaired.length == 6
  raise "expected one triangle to become two: #{repaired.length}"
end

inventory = normalizer.send(:final_boundary_inventory, repaired)
bad = inventory[:owners].select { |_edge, owners| owners.length != 2 }
unless bad.empty?
  raise "repaired fixture is not manifold: #{bad.inspect}"
end

# Use the first real A-P-Q-B coordinate chain from the runtime failure.
a = [-3_698_252, -18_484_507, 4_099_017]
p = [-3_384_106, -18_507_682, 4_099_017]
q = [3_207_979, -18_994_007, 4_099_017]
b = [3_522_126, -19_017_183, 4_099_017]
c = [0, -17_000_000, 4_099_017]
d = [0, -18_750_000, 5_099_017]
records = [
  record.call([a, b, c], 11, 0),
  record.call([a, p, d], 12, 0),
  record.call([p, q, d], 12, 1),
  record.call([q, b, d], 12, 2),
  record.call([a, c, d], 13, 0),
  record.call([b, d, c], 14, 0)
]

repaired, report = normalizer.send(:repair_final_boundary_conformity, records)
unless report[:repaired_component_count] == 1 &&
       report[:inserted_chain_vertex_count] == 2 &&
       report[:remaining_boundary_edge_count].zero?
  raise "real-coordinate chain repair failed: #{report.inspect}"
end

wrapped, patch_report = normalizer.send(
  :retriangulate_exact_coplanar_patches,
  records,
  forced_source_face_keys: [11],
  force_all: true
)
unless patch_report[:final_boundary_conformity_repair][:repaired_component_count] == 1 &&
       patch_report[:forced_source_face_keys] == [11] &&
       patch_report[:force_all] == true
  raise "wrapper did not preserve and merge reports: #{patch_report.inspect}"
end
unless normalizer.send(:final_boundary_inventory, wrapped)[:owners]
  .all? { |_edge, owners| owners.length == 2 }
  raise 'wrapper returned a non-manifold triangle set'
end

puts 'LocalVertexNormalizer final boundary conformity repair smoke test: OK'
