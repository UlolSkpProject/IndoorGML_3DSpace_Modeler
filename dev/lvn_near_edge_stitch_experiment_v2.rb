# frozen_string_literal: true

# Refines lvn_near_edge_stitch_experiment.rb.
# Each accepted operation handles ONE (host edge AB, near vertex C) relation.
# If C is already on the two-owner patch boundary, the whole two-triangle patch
# is retriangulated from that boundary. Otherwise A-C-B is installed as an
# internal constraint by triangulating the two boundary paths independently.

load File.join(__dir__, 'lvn_near_edge_stitch_experiment.rb')

module LvnNearEdgeStitchExperiment
  class StitchNormalizer
    private

    # Keep each (host edge, vertex) relation separate. After one accepted stitch
    # the exact invalid set is recomputed, so related vertices/edges are handled
    # incrementally rather than forcing an entire near-edge cluster at once.
    def stitch_host_edge_candidates(records)
      indexed = nondegenerate_indexed_triangles(records)
      valid_indices = indexed.map(&:first)
      triangles = indexed.map(&:last)
      failures = collect_triangle_intersection_failures(triangles)
      invalid_pairs = failures[:pairs].map do |first, second|
        [valid_indices[first], valid_indices[second]]
      end

      edge_owners = build_edge_owners(records)
      point_by_key = {}
      records.each do |record|
        record[:points].each do |point|
          point_by_key[grid_indices(point)] ||= point
        end
      end

      candidates = {}

      invalid_pairs.each do |first_index, second_index|
        [
          [first_index, second_index],
          [second_index, first_index]
        ].each do |vertex_index, host_index|
          vertex_record = records[vertex_index]
          host_record = records[host_index]
          host_triangle = host_record[:points].map { |point| grid_indices(point) }

          vertex_record[:points].each do |vertex_point|
            vertex_key = grid_indices(vertex_point)

            3.times do |edge_index|
              edge_a = host_triangle[edge_index]
              edge_b = host_triangle[(edge_index + 1) % 3]
              relation = near_edge_relation(vertex_key, edge_a, edge_b)
              next unless relation

              edge = canonical_edge_key(edge_a, edge_b)
              owners = edge_owners.fetch(edge, []).uniq.sort
              next unless owners.length == 2

              owner_records = owners.map { |index| records[index] }
              next unless owner_records.map { |record| record[:source_face_key] }.uniq.length == 1

              patch_keys = owner_records.map { |record| exact_coplanar_patch_key(record) }
              next unless patch_keys.uniq.length == 1

              plane_key = exact_integer_plane_key(
                owner_records.first[:points].map { |point| grid_indices(point) }
              )

              # Critical condition: the POINT C, not necessarily C's source
              # triangle, must lie exactly on the host patch plane.
              next unless exact_point_on_plane?(vertex_key, plane_key)

              candidate_key = [edge, vertex_key]
              entry = (candidates[candidate_key] ||= {
                edge: edge,
                owners: owners,
                source_face_key: owner_records.first[:source_face_key],
                exact_patch_key: patch_keys.first,
                points: {
                  vertex_key => {
                    key: vertex_key,
                    point: point_by_key.fetch(vertex_key),
                    t: relation[:t],
                    distance_mm: relation[:distance_mm],
                    trigger_pairs: []
                  }
                }
              })

              point_entry = entry[:points].fetch(vertex_key)
              point_entry[:distance_mm] = [
                point_entry[:distance_mm],
                relation[:distance_mm]
              ].min
              point_entry[:trigger_pairs] |= [[first_index, second_index]]
            end
          end
        end
      end

      candidates
    end

    def stitch_one_host_edge(records, candidate)
      edge = candidate[:edge]
      owner_indices = candidate[:owners]
      owner_records = owner_indices.map { |index| records[index] }
      candidate_entry = candidate[:points].values.first
      candidate_key = candidate_entry[:key]
      candidate_point = candidate_entry[:point]

      current_owners = build_edge_owners(records).fetch(edge, []).uniq.sort
      unless current_owners == owner_indices
        raise TopologyChangedError,
              "Near-edge stitch host ownership changed: #{owner_indices.inspect}->#{current_owners.inspect}"
      end

      local_edge_owners = Hash.new { |hash, key| hash[key] = [] }
      point_by_key = { candidate_key => candidate_point }
      owner_records.each_with_index do |record, local_index|
        triangle = record[:points].map do |point|
          key = grid_indices(point)
          point_by_key[key] ||= point
          key
        end
        exact_triangle_edge_keys(triangle).each do |local_edge|
          local_edge_owners[local_edge] << local_index
        end
      end

      boundary_edges = local_edge_owners.filter_map do |local_edge, owners|
        local_edge if owners.length == 1
      end
      loops = exact_boundary_loops(boundary_edges)
      unless loops.length == 1
        raise TopologyChangedError,
              "Near-edge stitch owner patch must have one boundary loop: #{loops.length}"
      end
      boundary = loops.first

      plane_key = exact_integer_plane_key(
        owner_records.first[:points].map { |point| grid_indices(point) }
      )
      drop_axis = plane_key.first(3).each_index.max_by do |axis|
        plane_key[axis].abs
      end
      expected_area2 = integer_polygon_area2(
        boundary.map { |point| integer_project_2d(point, drop_axis) }
      ).abs

      edge_a, edge_b = edge
      replacement_keys = if boundary.include?(candidate_key)
                           # Typical ijn58ryq case: C is already an apex/boundary
                           # vertex of one host owner. Remove AB by reconstructing
                           # the two-owner patch from its preserved outer boundary.
                           retriangulate_owner_boundary_keys(
                             boundary,
                             drop_axis
                           )
                         else
                           # C is an interior Steiner point of the two-owner patch.
                           # A-C-B becomes the new internal constraint. Each side
                           # keeps one of the two old A->B boundary paths.
                           constrained_stitch_keys(
                             boundary,
                             edge_a,
                             edge_b,
                             candidate_key,
                             drop_axis
                           )
                         end

      template = owner_records.first
      replacements = replacement_keys.each_with_index.map do |keys, index|
        points = keys.map { |key| point_by_key.fetch(key) }
        points = orient_patch_triangle(points, template[:source_normal])
        template.merge(
          points: points,
          source_polygon_index: index
        )
      end

      # Existing exact patch validator proves:
      # - unchanged outer boundary
      # - valid edge incidence / disk topology
      # - exact projected area preservation
      # - no intersections inside the replacement patch
      validate_exact_patch_replacement!(
        replacements,
        boundary_edges,
        1,
        drop_axis,
        expected_area2
      )

      owner_lookup = owner_indices.to_h { |index| [index, true] }
      tentative = records.each_with_index.filter_map do |record, index|
        record unless owner_lookup[index]
      end
      tentative.concat(replacements)

      [
        tentative,
        candidate_summary(candidate).merge(
          candidate_on_old_boundary: boundary.include?(candidate_key),
          owner_triangle_count: owner_records.length,
          replacement_triangle_count: replacements.length,
          boundary_edge_count: boundary_edges.length,
          expected_area2: expected_area2
        )
      ]
    end

    def retriangulate_owner_boundary_keys(boundary, drop_axis)
      polygon = orient_simple_polygon(boundary, drop_axis)
      triangulate_exact_polygon_with_holes(polygon, [], drop_axis)
    end

    def constrained_stitch_keys(boundary, edge_a, edge_b, candidate_key, drop_axis)
      unless boundary.include?(edge_a) && boundary.include?(edge_b)
        raise TopologyChangedError,
              'Near-edge stitch host endpoints are not on the owner patch boundary'
      end

      first_path = walk_boundary(boundary, edge_a, edge_b, 1)
      second_path = walk_boundary(boundary, edge_a, edge_b, -1)

      polygons = [
        first_path + [candidate_key],
        second_path + [candidate_key]
      ]

      polygons.flat_map do |polygon|
        oriented = orient_simple_polygon(polygon, drop_axis)
        triangulate_exact_polygon_with_holes(oriented, [], drop_axis)
      end
    end

    def walk_boundary(boundary, start_key, end_key, step)
      start_index = boundary.index(start_key)
      raise TopologyChangedError, 'Near-edge stitch boundary start not found' unless start_index

      path = [start_key]
      index = start_index
      boundary.length.times do
        index = (index + step) % boundary.length
        path << boundary[index]
        return path if boundary[index] == end_key
      end

      raise TopologyChangedError, 'Near-edge stitch boundary walk did not reach host endpoint'
    end

    def orient_simple_polygon(polygon, drop_axis)
      cleaned = polygon.each_with_object([]) do |point, result|
        result << point unless result.last == point
      end
      cleaned.pop if cleaned.length > 1 && cleaned.first == cleaned.last

      if cleaned.length < 3
        raise TopologyChangedError,
              "Near-edge stitch polygon has fewer than three vertices: #{cleaned.inspect}"
      end

      projected = cleaned.map { |point| integer_project_2d(point, drop_axis) }
      area2 = integer_polygon_area2(projected)
      if area2.zero?
        raise TopologyChangedError,
              "Near-edge stitch polygon has zero area: #{cleaned.inspect}"
      end
      unless simple_integer_polygon_2d?(projected)
        raise TopologyChangedError,
              "Near-edge stitch polygon self-intersects: #{cleaned.inspect}"
      end

      area2.positive? ? cleaned : cleaned.reverse
    end
  end
end

nil
