# frozen_string_literal: true

# v6: branch-safe final surface-equivalence descriptor experiment.
#
# v5 can remove the original exact invalid intersections, allowing normalization
# to reach the final surface-equivalence verification. A valid global 2-manifold
# may still have a COPLANAR SUBSET whose boundary graph has degree-4 vertices.
# The production descriptor currently forces every coplanar component boundary
# through exact_boundary_loops, which requires degree==2 at every boundary vertex.
#
# This experiment keeps v5 geometry repair unchanged and only changes the
# triangulation-independent surface descriptor. The descriptor becomes:
#   exact plane + canonical boundary segment set
# after collapsing only degree-2 collinear subdivision vertices.
#
# This preserves exact boundary geometry, supports outer/hole/branched boundaries,
# and does not accept any change to the validated triangle mesh itself.
# Production LVN remains untouched.

load File.join(__dir__, 'lvn_near_edge_stitch_experiment_v5.rb')

module LvnNearEdgeStitchExperiment
  class StitchNormalizer
    private

    def normalized_surface_descriptor(triangle_records)
      records = triangle_records.reject do |record|
        triangle = record[:points].map { |point| grid_indices(point) }
        triangle.uniq.length != 3 ||
          integer_zero_vector?(integer_triangle_normal(triangle))
      end

      descriptors = []
      surface_coplanar_clusters(records).each do |plane_records|
        coplanar_geometry_components(plane_records).each do |component|
          edge_owners = split_triangle_edge_owners(component)
          overused = edge_owners.select { |_edge, owners| owners.length > 2 }
          unless overused.empty?
            raise TopologyChangedError,
                  "Surface descriptor found overused coplanar edges: " \
                  "#{overused.first(5).inspect}"
          end

          boundary_edges = edge_owners.filter_map do |edge, owners|
            canonical_edge_key(edge[0], edge[1]) if owners.length == 1
          end.uniq
          if boundary_edges.empty?
            raise TopologyChangedError,
                  'Surface descriptor coplanar component has no boundary edges'
          end

          simplified_edges = simplify_surface_boundary_segments(boundary_edges)
          plane_key = surface_boundary_segment_plane_key(simplified_edges)
          descriptors << [plane_key, simplified_edges.sort]
        end
      end
      descriptors.sort
    end

    # Remove only a topologically unambiguous triangulation/subdivision artifact:
    # a degree-2 boundary vertex whose two incident segments are exactly collinear
    # and extend through the vertex in opposite directions. Branch vertices are
    # preserved, so their geometry remains part of the descriptor.
    def simplify_surface_boundary_segments(boundary_edges)
      edges = boundary_edges.each_with_object({}) do |edge, result|
        result[canonical_edge_key(edge[0], edge[1])] = true
      end

      loop do
        adjacency = Hash.new { |hash, key| hash[key] = [] }
        edges.each_key do |point_a, point_b|
          adjacency[point_a] << point_b
          adjacency[point_b] << point_a
        end
        adjacency.each_value(&:uniq!)

        merge = adjacency.keys.sort.filter_map do |vertex|
          neighbors = adjacency[vertex]
          next unless neighbors.length == 2

          first, second = neighbors
          first_vector = integer_subtract(first, vertex)
          second_vector = integer_subtract(second, vertex)
          next unless integer_zero_vector?(integer_cross(first_vector, second_vector))
          next unless integer_dot(first_vector, second_vector).negative?

          [vertex, first, second]
        end.first

        break unless merge

        vertex, first, second = merge
        edges.delete(canonical_edge_key(vertex, first))
        edges.delete(canonical_edge_key(vertex, second))
        edges[canonical_edge_key(first, second)] = true
      end

      edges.keys.sort
    end

    # Derive the exact plane from canonical boundary points without requiring the
    # boundary graph to be decomposable into non-touching degree-2 loops.
    def surface_boundary_segment_plane_key(edges)
      points = edges.flatten(1).uniq.sort
      origin = points.first
      if origin
        (1...points.length).each do |first_index|
          ((first_index + 1)...points.length).each do |second_index|
            triangle = [origin, points[first_index], points[second_index]]
            next if integer_zero_vector?(integer_triangle_normal(triangle))

            return exact_integer_plane_key(triangle)
          end
        end
      end

      raise TopologyChangedError,
            "Surface boundary segments cannot define a plane: #{edges.inspect}"
    end
  end
end

nil
