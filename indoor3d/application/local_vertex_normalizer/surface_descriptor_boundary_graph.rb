# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # Surface-equivalence verification normally represents each connected
        # coplanar component by exact boundary loops. A valid manifold shell can,
        # however, contain a coplanar component whose boundary is a pinched graph
        # (for example two regions meeting at an articulation vertex). In that case
        # every physical shell edge can still have incidence two while the coplanar
        # boundary vertex has degree four, so exact_boundary_loops correctly refuses
        # to pretend that the graph is one or more disjoint simple loops.
        #
        # Keep the established loop descriptor for ordinary components. Only when
        # the boundary is specifically branched, fall back to a canonical exact
        # boundary-graph descriptor. This changes verification representation only;
        # it never mutates geometry or relaxes the normalized-mesh hard gate.
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
                edge if owners.length == 1
              end
              if boundary_edges.empty?
                raise TopologyChangedError,
                      'Surface descriptor found a coplanar component with no boundary'
              end

              begin
                loops = exact_boundary_loops(boundary_edges).map do |loop|
                  canonical_exact_loop(simplify_exact_loop(loop))
                end.sort
                descriptors << [
                  surface_patch_plane_key(loops),
                  0,
                  loops
                ]
              rescue TopologyChangedError => error
                raise unless surface_descriptor_branched_boundary_error?(error)

                graph_edges = canonical_surface_boundary_graph(boundary_edges)
                boundary_points = graph_edges.flatten(1).uniq
                descriptors << [
                  surface_patch_plane_key([boundary_points]),
                  1,
                  graph_edges
                ]
              end
            end
          end
          descriptors.sort
        end

        def surface_descriptor_branched_boundary_error?(error)
          error.message.to_s.start_with?(
            'Exact coplanar patch boundary is branched:'
          )
        end

        # Canonicalizes an undirected boundary graph while ignoring harmless
        # collinear degree-2 subdivision. Branch/corner vertices are preserved, so
        # the descriptor still detects changed seams, pinches and disconnected
        # geometry instead of hiding them as a loop.
        def canonical_surface_boundary_graph(boundary_edges)
          edge_lookup = {}
          boundary_edges.each do |point_a, point_b|
            next if point_a == point_b

            edge_lookup[canonical_edge_key(point_a, point_b)] = true
          end

          loop do
            adjacency = Hash.new { |hash, key| hash[key] = [] }
            edge_lookup.each_key do |point_a, point_b|
              adjacency[point_a] << point_b
              adjacency[point_b] << point_a
            end
            adjacency.each_value(&:uniq!)

            collapsed = false
            adjacency.keys.sort.each do |point|
              neighbors = adjacency.fetch(point)
              next unless neighbors.length == 2

              point_a, point_b = neighbors.sort
              next if point_a == point_b

              incoming = integer_subtract(point, point_a)
              outgoing = integer_subtract(point_b, point)
              next unless integer_zero_vector?(integer_cross(incoming, outgoing))
              next unless integer_dot(incoming, outgoing).positive?

              first_edge = canonical_edge_key(point_a, point)
              second_edge = canonical_edge_key(point, point_b)
              replacement = canonical_edge_key(point_a, point_b)
              next if edge_lookup.key?(replacement)

              edge_lookup.delete(first_edge)
              edge_lookup.delete(second_edge)
              edge_lookup[replacement] = true
              collapsed = true
              break
            end
            break unless collapsed
          end

          graph_edges = edge_lookup.keys.sort
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          graph_edges.each do |point_a, point_b|
            adjacency[point_a] << point_b
            adjacency[point_b] << point_a
          end

          # A graph fallback is only for branched boundaries. Preserve strictness if
          # the loop failure was caused by some different malformed graph state.
          branch_vertices = adjacency.select do |_point, neighbors|
            neighbors.uniq.length > 2
          end
          if branch_vertices.empty?
            raise TopologyChangedError,
                  'Surface boundary graph fallback found no branch vertex'
          end

          graph_edges
        end
      end
    end
  end
end
