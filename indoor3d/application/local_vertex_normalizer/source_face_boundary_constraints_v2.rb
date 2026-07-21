# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        SOURCE_FACE_FOREIGN_SLIVER_MAX_NORMAL_ALIGNMENT = 0.5 unless
          const_defined?(:SOURCE_FACE_FOREIGN_SLIVER_MAX_NORMAL_ALIGNMENT, false)

        private

        unless private_method_defined?(:short_edge_sliver_collapse_plan_before_source_boundary_v2)
          alias_method :short_edge_sliver_collapse_plan_before_source_boundary_v2,
                       :short_edge_sliver_collapse_plan
        end

        unless private_method_defined?(:retriangulate_exact_coplanar_patches_before_source_boundary_v2)
          alias_method :retriangulate_exact_coplanar_patches_before_source_boundary_v2,
                       :retriangulate_exact_coplanar_patches
        end

        # The triangle mesh is not the authoritative description of a SketchUp
        # Face boundary. A later cleanup may legitimately remove a zero-area or
        # duplicate mesh triangle, but that triangle can still be the only record
        # carrying an ordered boundary vertex. Capture every source Face loop
        # before triangle cleanup and apply the same normalization/collapse map to
        # those loops. Step 6 can then reconstruct affected source Faces from the
        # preserved boundary constraints instead of inferring a new boundary from
        # surviving triangle incidence.
        def short_edge_sliver_collapse_plan(entities, axis_plane_plan = nil)
          plan = short_edge_sliver_collapse_plan_before_source_boundary_v2(
            entities,
            axis_plane_plan
          )
          @normalized_source_face_constraints =
            capture_normalized_source_face_constraints(
              entities,
              axis_plane_plan,
              plan
            )
          plan
        end

        def capture_normalized_source_face_constraints(
          entities,
          axis_plane_plan,
          short_edge_plan
        )
          point_targets = short_edge_plan.is_a?(Hash) ?
            Hash(short_edge_plan[:point_targets]) : {}

          entities.grep(@face_class).each_with_object({}) do |face, constraints|
            next unless face&.valid?

            face_key = stable_entity_id(face)
            outer_loop = face.respond_to?(:outer_loop) ? face.outer_loop : nil
            loops = Array(face.respond_to?(:loops) ? face.loops : []).map do |loop|
              points = loop.vertices.map do |vertex|
                normalized = normalized_target(vertex.position, axis_plane_plan)
                point_targets[grid_indices(normalized)] || normalized
              end
              {
                outer: loop.equal?(outer_loop),
                points: points
              }
            end
            next if loops.empty?

            constraints[face_key] = {
              source_face_key: face_key,
              source_normal: vector_components(face.normal),
              material: face.material,
              back_material: face.back_material,
              layer: face.layer,
              loops: loops
            }
          end
        end

        # Rebuild source Faces whose boundary provenance is no longer represented
        # by their surviving triangles. This runs before exact coplanar patch
        # reconstruction. It fixes the general information-loss defect rather
        # than accepting a self-intersecting patch after the fact.
        def retriangulate_exact_coplanar_patches(
          triangle_records,
          forced_source_face_keys: [],
          force_all: false
        )
          constraints = @normalized_source_face_constraints || {}
          return retriangulate_exact_coplanar_patches_before_source_boundary_v2(
            triangle_records,
            forced_source_face_keys: forced_source_face_keys,
            force_all: force_all
          ) if constraints.empty?

          rebuild_plan = source_face_constraint_rebuild_plan(
            triangle_records,
            constraints,
            forced_source_face_keys,
            force_all: force_all
          )
          constrained_records, constraint_report =
            rebuild_source_faces_from_constraints(
              triangle_records,
              constraints,
              rebuild_plan
            )

          # Re-establish conforming subdivisions after whole-Face reconstruction.
          # Adjacent source Faces may carry the same geometric edge with different
          # segmentation, and every boundary vertex must be represented on both
          # sides before the global mesh gate.
          constrained_records = conforming_triangle_snapshot(constrained_records)
          constrained_records, cleanup = sanitize_triangle_records(
            constrained_records,
            remove_collinear: true
          )

          remaining_forced = Array(forced_source_face_keys).compact.reject do |key|
            rebuild_plan[:keys].include?(key)
          end
          rebuilt_records, patch_report =
            retriangulate_exact_coplanar_patches_before_source_boundary_v2(
              constrained_records,
              forced_source_face_keys: remaining_forced,
              force_all: force_all
            )

          [
            rebuilt_records,
            patch_report.merge(
              source_boundary_constraint_rebuilds:
                constraint_report[:rebuilt_face_count],
              source_boundary_constraint_face_keys:
                constraint_report[:rebuilt_face_keys],
              source_boundary_constraint_reasons:
                constraint_report[:reasons],
              source_boundary_constraint_source_triangles:
                constraint_report[:source_triangle_count],
              source_boundary_constraint_rebuilt_triangles:
                constraint_report[:rebuilt_triangle_count],
              source_boundary_constraint_removed_collinear_triangles:
                cleanup[:removed_collinear_triangle_count],
              source_boundary_constraint_removed_duplicate_triangles:
                cleanup[:removed_duplicate_triangle_count]
            )
          ]
        ensure
          # Constraints belong to one normalize_entity invocation. Do not allow a
          # later debug/readback snapshot on the same normalizer instance to reuse
          # stale source Face entities.
          @normalized_source_face_constraints = nil
        end

        def source_face_constraint_rebuild_plan(
          records,
          constraints,
          forced_source_face_keys,
          force_all:
        )
          records_by_face = records.group_by { |record| record[:source_face_key] }
          forced_lookup = Array(forced_source_face_keys).compact.to_h do |key|
            [key, true]
          end
          reasons = Hash.new { |hash, key| hash[key] = [] }

          constraints.each do |face_key, constraint|
            face_records = Array(records_by_face[face_key])
            if force_all || forced_lookup[face_key]
              reasons[face_key] << :forced_triangle_repair
            end

            unless source_face_record_boundary_matches_constraint?(
              face_records,
              constraint
            )
              reasons[face_key] << :boundary_provenance_changed
            end

            if source_face_contains_foreign_sliver?(face_records, constraint)
              reasons[face_key] << :foreign_plane_sliver
            end
          end

          {
            keys: reasons.keys.sort,
            reasons: reasons.transform_values(&:uniq)
          }
        end

        def source_face_record_boundary_matches_constraint?(records, constraint)
          return false if records.empty?

          record_edges = exact_source_face_record_boundary_edges(records)
          constraint_edges = source_face_constraint_edges(constraint)
          points = (record_edges + constraint_edges).flatten(1).uniq

          split_record_edges = split_exact_edges_at_points(record_edges, points)
          split_constraint_edges = split_exact_edges_at_points(
            constraint_edges,
            points
          )
          split_record_edges.sort == split_constraint_edges.sort
        rescue ReconstructionError, TopologyChangedError
          false
        end

        def exact_source_face_record_boundary_edges(records)
          owners = Hash.new(0)
          records.each do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            3.times do |index|
              edge = canonical_edge_key(
                triangle[index],
                triangle[(index + 1) % 3]
              )
              owners[edge] += 1
            end
          end
          return [] if owners.any? { |_edge, count| count > 2 }

          owners.filter_map { |edge, count| edge if count == 1 }
        end

        def source_face_constraint_edges(constraint)
          Array(constraint[:loops]).flat_map do |loop|
            keys = normalized_constraint_loop_keys(loop[:points])
            keys.each_index.map do |index|
              canonical_edge_key(keys[index], keys[(index + 1) % keys.length])
            end
          end
        end

        def split_exact_edges_at_points(edges, points)
          edges.flat_map do |first, second|
            integer_points_on_segment_sorted(first, second, points)
              .each_cons(2)
              .filter_map do |segment_start, segment_end|
                next if segment_start == segment_end

                canonical_edge_key(segment_start, segment_end)
              end
          end.uniq
        end

        def source_face_contains_foreign_sliver?(records, constraint)
          source_normal = Array(constraint[:source_normal]).map(&:to_f)
          source_length = vector_length(source_normal)
          return false unless source_normal.length == 3 && source_length.positive?

          records.any? do |record|
            next false unless grid_triangle_sliver?(record[:points])

            triangle = record[:points].map { |point| grid_indices(point) }
            triangle_normal = integer_triangle_normal(triangle).map(&:to_f)
            triangle_length = vector_length(triangle_normal)
            next false unless triangle_length.positive?

            alignment = vector_dot(source_normal, triangle_normal).abs /
              (source_length * triangle_length)
            alignment <= SOURCE_FACE_FOREIGN_SLIVER_MAX_NORMAL_ALIGNMENT
          end
        end

        def rebuild_source_faces_from_constraints(records, constraints, plan)
          rebuild_lookup = plan[:keys].to_h { |key| [key, true] }
          return [
            records,
            {
              rebuilt_face_count: 0,
              rebuilt_face_keys: [],
              reasons: {},
              source_triangle_count: 0,
              rebuilt_triangle_count: 0
            }
          ] if rebuild_lookup.empty?

          records_by_face = records.group_by { |record| record[:source_face_key] }
          output = records.reject do |record|
            rebuild_lookup[record[:source_face_key]]
          end
          source_triangle_count = 0
          rebuilt_triangle_count = 0

          plan[:keys].each do |face_key|
            constraint = constraints.fetch(face_key)
            face_records = Array(records_by_face[face_key])
            source_triangle_count += face_records.length
            replacements = triangulate_source_face_constraint(
              constraint,
              face_records.first
            )
            output.concat(replacements)
            rebuilt_triangle_count += replacements.length
          end

          [
            output,
            {
              rebuilt_face_count: plan[:keys].length,
              rebuilt_face_keys: plan[:keys],
              reasons: plan[:reasons],
              source_triangle_count: source_triangle_count,
              rebuilt_triangle_count: rebuilt_triangle_count
            }
          ]
        end

        def triangulate_source_face_constraint(constraint, template_record)
          loops = Array(constraint[:loops]).map do |loop|
            keys = normalized_constraint_loop_keys(loop[:points])
            if keys.length < 3
              raise TopologyChangedError,
                    "Normalized source Face boundary collapsed below three vertices: " \
                    "face=#{constraint[:source_face_key].inspect}"
            end
            {
              outer: loop[:outer] == true,
              keys: keys
            }
          end

          outer_entries = loops.select { |loop| loop[:outer] }
          unless outer_entries.length == 1
            raise TopologyChangedError,
                  "Normalized source Face must have one outer boundary: " \
                  "face=#{constraint[:source_face_key].inspect} " \
                  "outer_loops=#{outer_entries.length}"
          end

          source_normal = Array(constraint[:source_normal]).map(&:to_f)
          drop_axis = source_normal.each_index.max_by do |axis|
            source_normal[axis].abs
          end
          if drop_axis.nil? || source_normal[drop_axis].abs <= 0.0
            raise ReconstructionError,
                  "Source Face boundary has no stable projection axis: " \
                  "face=#{constraint[:source_face_key].inspect}"
          end

          loops.each do |loop|
            polygon = loop[:keys].map do |point|
              integer_project_2d(point, drop_axis)
            end
            if integer_polygon_area2(polygon).zero?
              raise TopologyChangedError,
                    "Normalized source Face has a zero-area boundary: " \
                    "face=#{constraint[:source_face_key].inspect}"
            end
            unless simple_integer_polygon_2d?(polygon)
              raise TopologyChangedError,
                    "Normalized source Face boundary self-intersects: " \
                    "face=#{constraint[:source_face_key].inspect}"
            end
          end

          outer = outer_entries.first[:keys]
          outer_polygon = outer.map { |point| integer_project_2d(point, drop_axis) }
          outer = outer.reverse if integer_polygon_area2(outer_polygon).negative?

          holes = loops.reject { |loop| loop[:outer] }.map do |loop|
            polygon = loop[:keys].map do |point|
              integer_project_2d(point, drop_axis)
            end
            unless integer_point_in_polygon_2d?(polygon.first, outer_polygon)
              raise TopologyChangedError,
                    "Normalized source Face hole is outside its outer boundary: " \
                    "face=#{constraint[:source_face_key].inspect}"
            end
            integer_polygon_area2(polygon).positive? ? loop[:keys].reverse : loop[:keys]
          end

          triangle_keys = triangulate_exact_polygon_with_holes(
            outer,
            holes,
            drop_axis
          )
          point_by_key = Array(constraint[:loops]).flat_map do |loop|
            Array(loop[:points])
          end.each_with_object({}) do |point, points|
            points[grid_indices(point)] ||= point
          end

          template = template_record || {
            source_normal: constraint[:source_normal],
            material: constraint[:material],
            back_material: constraint[:back_material],
            layer: constraint[:layer],
            source_face_key: constraint[:source_face_key]
          }
          replacements = triangle_keys.each_with_index.map do |keys, index|
            points = keys.map do |key|
              point_by_key[key] || point_from_grid_indices(key)
            end
            points = orient_patch_triangle(points, constraint[:source_normal])
            template.merge(
              points: points,
              source_normal: constraint[:source_normal],
              source_face_key: constraint[:source_face_key],
              source_polygon_index: index
            )
          end

          boundary_edges = (outer.each_index.map do |index|
            canonical_edge_key(outer[index], outer[(index + 1) % outer.length])
          end + holes.flat_map do |hole|
            hole.each_index.map do |index|
              canonical_edge_key(hole[index], hole[(index + 1) % hole.length])
            end
          end)
          expected_area2 = integer_polygon_area2(
            outer.map { |point| integer_project_2d(point, drop_axis) }
          ).abs - holes.sum do |hole|
            integer_polygon_area2(
              hole.map { |point| integer_project_2d(point, drop_axis) }
            ).abs
          end
          validate_exact_patch_replacement!(
            replacements,
            boundary_edges,
            1 + holes.length,
            drop_axis,
            expected_area2
          )
          replacements
        end

        def normalized_constraint_loop_keys(points)
          keys = Array(points).map { |point| grid_indices(point) }
          compact = []
          keys.each do |key|
            compact << key if compact.empty? || compact.last != key
          end
          compact.pop if compact.length > 1 && compact.first == compact.last
          compact
        end
      end
    end
  end
end
