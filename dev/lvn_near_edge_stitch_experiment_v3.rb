# frozen_string_literal: true

# v3 refinement of the selection-only near-edge stitch experiment.
#
# The v2 boundary-candidate branch retriangulated the two-owner quadrilateral
# without forbidding the old host edge. The generic ear triangulator could
# therefore choose the same diagonal again, yielding no change (e.g. ijn58ryq
# 20 -> 20). When the near vertex C is already a boundary/apex vertex of the
# two-owner patch, the topologically correct operation is an exact diagonal
# flip: remove host edge AB and replace it with the alternate diagonal between
# the two owner apex vertices.
#
# This file only affects the experimental subclass. Production LVN is untouched.

load File.join(__dir__, 'lvn_near_edge_stitch_experiment_v2.rb')

module LvnNearEdgeStitchExperiment
  class StitchNormalizer
    private

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
      owner_triangles = owner_records.map.with_index do |record, local_index|
        triangle = record[:points].map do |point|
          key = grid_indices(point)
          point_by_key[key] ||= point
          key
        end
        exact_triangle_edge_keys(triangle).each do |local_edge|
          local_edge_owners[local_edge] << local_index
        end
        triangle
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

      plane_key = exact_integer_plane_key(owner_triangles.first)
      drop_axis = plane_key.first(3).each_index.max_by do |axis|
        plane_key[axis].abs
      end
      expected_area2 = integer_polygon_area2(
        boundary.map { |point| integer_project_2d(point, drop_axis) }
      ).abs

      edge_a, edge_b = edge
      boundary_candidate = boundary.include?(candidate_key)

      replacement_keys = if boundary_candidate
                           exact_boundary_candidate_flip_keys(
                             owner_triangles,
                             edge,
                             candidate_key,
                             drop_axis
                           )
                         else
                           constrained_stitch_keys(
                             boundary,
                             edge_a,
                             edge_b,
                             candidate_key,
                             drop_axis
                           )
                         end

      # The whole purpose of this operation is to remove the offending host
      # edge. Reject any replacement that silently recreates it.
      replacement_edges = replacement_keys.flat_map do |triangle|
        exact_triangle_edge_keys(triangle)
      end
      if replacement_edges.include?(edge)
        raise TopologyChangedError,
              "Near-edge stitch retained forbidden host edge: #{edge.inspect}"
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
          mode: boundary_candidate ? :exact_edge_flip : :interior_constraint,
          candidate_on_old_boundary: boundary_candidate,
          owner_triangle_count: owner_records.length,
          replacement_triangle_count: replacements.length,
          boundary_edge_count: boundary_edges.length,
          expected_area2: expected_area2
        )
      ]
    end

    # Two triangles sharing AB form a four-edge disk boundary. If C is already
    # on that boundary, C is necessarily one of the two apex vertices because
    # near_edge_relation excludes A/B and exact collinearity. Splitting both
    # owners through C would create a degenerate C-A-C triangle. Instead flip
    # AB to the alternate apex-apex diagonal.
    def exact_boundary_candidate_flip_keys(owner_triangles, edge, candidate_key, drop_axis)
      unless owner_triangles.length == 2
        raise TopologyChangedError,
              "Near-edge boundary flip requires exactly two owners: #{owner_triangles.length}"
      end

      opposite_keys = owner_triangles.map do |triangle|
        opposite = triangle.find { |key| key != edge[0] && key != edge[1] }
        unless opposite
          raise ReconstructionError,
                "Near-edge boundary flip could not find owner apex: #{triangle.inspect}"
        end
        opposite
      end

      unless opposite_keys.include?(candidate_key)
        raise TopologyChangedError,
              "Near-edge boundary candidate is not an owner apex: #{candidate_key.inspect}"
      end
      if opposite_keys[0] == opposite_keys[1]
        raise TopologyChangedError,
              "Near-edge boundary flip owners share the same apex: #{opposite_keys[0].inspect}"
      end

      alternate_edge = canonical_edge_key(opposite_keys[0], opposite_keys[1])
      if alternate_edge == edge
        raise TopologyChangedError, 'Near-edge boundary flip alternate edge equals host edge'
      end

      replacement = exact_edge_flip_replacement(
        edge,
        opposite_keys[0],
        opposite_keys[1],
        drop_axis
      )
      unless replacement
        raise TopologyChangedError,
              "Near-edge boundary host edge is not exactly flippable: edge=#{edge.inspect} apexes=#{opposite_keys.inspect}"
      end

      replacement
    end
  end
end

nil
