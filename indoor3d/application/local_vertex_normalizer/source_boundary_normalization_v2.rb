# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Prevents a tolerance-sized deviation in an otherwise straight source
      # boundary from becoming a needle triangle. The SketchUp vertex is moved
      # only in the in-memory source snapshot; its identity is retained as a
      # boundary split point after triangulation.
      module LocalVertexNormalizerSourceBoundaryNormalizationV2
        class BoundaryNormalizationFallback < StandardError; end

        def triangle_snapshot(entities)
          faces = entities.grep(@face_class)
          @source_boundary_normalization_plan_v2 =
            source_boundary_normalization_plan_v2(faces)
          records = super
          apply_source_boundary_constraint_aliases_v2!(
            @source_boundary_normalization_plan_v2
          )
          capture_source_boundary_snapshot_stats_v2(faces, records)
          records
        rescue BoundaryNormalizationFallback
          # Never mix projected and unprojected faces. If one normalized loop
          # cannot be reconstructed exactly, repeat the complete snapshot using
          # the established source-boundary implementation.
          @source_boundary_normalization_plan_v2 = nil
          records = super
          capture_source_boundary_snapshot_stats_v2(faces, records, fallback: true)
          records
        ensure
          @source_boundary_normalization_plan_v2 = nil
        end

        def source_boundary_triangle_records(face, source_face_key)
          plan = @source_boundary_normalization_plan_v2
          return super unless plan

          face_key = stable_entity_id(face)
          begin
            loop_entries = source_boundary_normalized_loop_entries_v2(face, plan)
            changed = loop_entries.any? do |entries|
              entries.any? { |entry| entry[:targeted] || entry[:redundant] }
            end
          rescue LocalVertexNormalizer::Error, ArgumentError => e
            raise BoundaryNormalizationFallback, e.message
          end
          return super unless changed

          begin
            source_boundary_normalized_triangle_records_v2(
              face,
              source_face_key,
              loop_entries
            )
          rescue LocalVertexNormalizer::Error, ArgumentError => e
            raise BoundaryNormalizationFallback, e.message
          end
        end

        def source_boundary_normalization_plan_v2(faces)
          loop_sets = faces.filter_map do |face|
            next unless face.respond_to?(:loops)

            loops = face.loops.map.with_index do |loop, loop_index|
              vertices = loop.vertices
              next if vertices.length < 4

              entries = vertices.map do |vertex|
                {
                  vertex_id: stable_entity_id(vertex),
                  point: vertex.position
                }
              end
              simplified = simplify_source_boundary_loop_v2(entries)
              next unless simplified

              {
                loop_index: loop_index,
                entries: entries,
                redundant_ids: simplified[:redundant_ids],
                projections: simplified[:projections]
              }
            end.compact
            next if loops.empty?

            { face: face, face_key: stable_entity_id(face), loops: loops }
          rescue LocalVertexNormalizer::Error, ArgumentError, RuntimeError
            nil
          end

          proposals = Hash.new { |hash, key| hash[key] = [] }
          occurrences = {}
          loop_sets.each do |face_entry|
            face_entry[:loops].each do |loop_entry|
              loop_entry[:projections].each do |vertex_id, projection|
                proposals[vertex_id] << projection
                occurrences[
                  [face_entry[:face_key], loop_entry[:loop_index], vertex_id]
                ] = true
              end
            end
          end
          candidate_occurrence_count = occurrences.length

          targets = proposals.filter_map do |vertex_id, candidates|
            selected = candidates.min_by do |candidate|
              [
                candidate[:displacement_mm],
                candidate[:point].x.to_f,
                candidate[:point].y.to_f,
                candidate[:point].z.to_f
              ]
            end
            consistent = candidates.all? do |candidate|
              point_distance_mm(selected[:point], candidate[:point]) <=
                LocalVertexNormalizer::GRID_EPSILON_MM
            end
            [vertex_id, selected[:point]] if consistent
          end.to_h

          occurrences.select! { |(_face, _loop, vertex_id), _| targets.key?(vertex_id) }
          targets = reject_conflicting_source_boundary_constraints_v2(
            loop_sets,
            targets
          )
          occurrences.select! { |(_face, _loop, vertex_id), _| targets.key?(vertex_id) }
          targets = reject_unsafe_source_boundary_targets_v2(faces, targets)
          occurrences.select! { |(_face, _loop, vertex_id), _| targets.key?(vertex_id) }
          constraint_aliases = source_boundary_constraint_aliases_v2(
            loop_sets,
            targets
          )

          @source_boundary_normalization_stats_v2 = {
            face_count: faces.length,
            raw_triangle_face_count: faces.count do |face|
              face.respond_to?(:vertices) && face.vertices.length == 3
            end,
            near_collinear_candidate_count: candidate_occurrence_count,
            near_collinear_candidate_vertex_count: proposals.length,
            normalized_vertex_count: targets.length,
            normalized_occurrence_count: occurrences.length
          }
          {
            targets: targets,
            occurrences: occurrences,
            constraint_aliases: constraint_aliases
          }
        end

        def reject_conflicting_source_boundary_constraints_v2(loop_sets, targets)
          constraints = @source_boundary_axis_plane_plan_v2 &&
            @source_boundary_axis_plane_plan_v2[:constraints]
          return targets unless constraints && !constraints.empty?

          entries_by_vertex = loop_sets.flat_map do |face_entry|
            face_entry[:loops].flat_map { |loop_entry| loop_entry[:entries] }
          end.group_by { |entry| entry[:vertex_id] }
          target_constraints = Hash.new do |hash, key|
            hash[key] = Hash.new { |axis_hash, axis| axis_hash[axis] = {} }
          end
          targets.each do |vertex_id, target|
            target_key = source_point_key(target)
            (constraints[target_key] || {}).each do |axis, target_index|
              target_constraints[target_key][axis][target_index] = true
            end
            entries_by_vertex.fetch(vertex_id, []).each do |entry|
              source_constraints = constraints[source_point_key(entry[:point])] || {}
              source_constraints.each do |axis, target_index|
                target_constraints[target_key][axis][target_index] = true
              end
            end
          end
          conflicting_target_keys = target_constraints.filter_map do |target_key, axes|
            target_key if axes.any? { |_axis, indices| indices.length > 1 }
          end.to_h { |target_key| [target_key, true] }

          targets.reject do |_vertex_id, target|
            conflicting_target_keys.key?(source_point_key(target))
          end
        end

        def source_boundary_constraint_aliases_v2(loop_sets, targets)
          aliases = {}
          loop_sets.each do |face_entry|
            face_entry[:loops].each do |loop_entry|
              loop_entry[:entries].each do |entry|
                target = targets[entry[:vertex_id]]
                next unless target

                aliases[source_point_key(entry[:point])] = source_point_key(target)
              end
            end
          end
          aliases
        end

        def apply_source_boundary_constraint_aliases_v2!(plan)
          axis_plan = @source_boundary_axis_plane_plan_v2
          constraints = axis_plan && axis_plan[:constraints]
          return unless constraints

          plan.fetch(:constraint_aliases, {}).each do |source_key, target_key|
            source_constraints = constraints[source_key]
            next unless source_constraints

            constraints[target_key] = (
              constraints[target_key] || {}
            ).merge(source_constraints)
          end
        end

        def capture_source_boundary_snapshot_stats_v2(
          faces,
          records,
          fallback: false
        )
          stats = (@source_boundary_normalization_stats_v2 || {}).dup
          metrics = records.filter_map do |record|
            points = record[:points]
            next unless points.length == 3

            edge_lengths = 3.times.map do |index|
              point_distance_mm(points[index], points[(index + 1) % 3])
            end
            longest_edge = edge_lengths.max
            next unless longest_edge&.positive?

            normal = vector_cross(
              vector_between(points[0], points[1]),
              vector_between(points[0], points[2])
            )
            altitude = vector_length(normal) *
              (LocalVertexNormalizer::MM_PER_INCH**2) / longest_edge
            {
              minimum_altitude_mm: altitude,
              aspect_ratio: longest_edge / [altitude, Float::MIN].max,
              source_face_key: record[:source_face_key],
              source_polygon_index: record[:source_polygon_index]
            }
          end
          slivers = metrics.select do |metric|
            metric[:minimum_altitude_mm] <=
              LocalVertexNormalizer::SHORT_EDGE_SLIVER_THRESHOLD_MM &&
              metric[:aspect_ratio] >=
                LocalVertexNormalizer::SHORT_EDGE_SLIVER_MIN_ASPECT_RATIO
          end
          stats.merge!(
            face_count: faces.length,
            source_triangle_count: records.length,
            low_altitude_sliver_count: slivers.length,
            worst_low_altitude_triangles: slivers.min_by(10) do |metric|
              metric[:minimum_altitude_mm]
            end,
            fallback_to_original_snapshot: fallback
          )
          if fallback
            stats[:normalized_vertex_count] = 0
            stats[:normalized_occurrence_count] = 0
          end
          @source_boundary_normalization_stats_v2 = stats
        end

        def simplify_source_boundary_loop_v2(entries)
          working = entries.map(&:dup)
          removed_ids = {}

          loop do
            break if working.length <= 3

            index = working.each_index.find do |candidate_index|
              previous = working[(candidate_index - 1) % working.length][:point]
              current = working[candidate_index][:point]
              following = working[(candidate_index + 1) % working.length][:point]
              source_boundary_redundant_point_v2?(
                current,
                previous,
                following
              )
            end
            break unless index

            removed_ids[working[index][:vertex_id]] = true
            working.delete_at(index)
          end
          return nil if removed_ids.empty? || working.length < 3

          survivor_ids = working.to_h { |entry| [entry[:vertex_id], true] }
          projections = {}
          entries.each_with_index do |entry, index|
            next if survivor_ids[entry[:vertex_id]]

            previous = source_boundary_surviving_neighbor_v2(
              entries,
              survivor_ids,
              index,
              -1
            )
            following = source_boundary_surviving_neighbor_v2(
              entries,
              survivor_ids,
              index,
              1
            )
            projection = source_boundary_projection_v2(
              entry[:point],
              previous[:point],
              following[:point]
            )
            return nil unless projection &&
                              source_boundary_redundant_point_v2?(
                                entry[:point],
                                previous[:point],
                                following[:point]
                              )

            projections[entry[:vertex_id]] = projection
          end

          {
            redundant_ids: removed_ids,
            projections: projections
          }
        end

        def source_boundary_surviving_neighbor_v2(
          entries,
          survivor_ids,
          start_index,
          direction
        )
          offset = direction
          loop do
            entry = entries[(start_index + offset) % entries.length]
            return entry if survivor_ids[entry[:vertex_id]]

            offset += direction
          end
        end

        def source_boundary_redundant_point_v2?(point, endpoint_a, endpoint_c)
          projection = source_boundary_projection_v2(point, endpoint_a, endpoint_c)
          return false unless projection
          return false if projection[:distance_mm] > @tolerance_mm

          adjacent_length = [
            point_distance_mm(point, endpoint_a),
            point_distance_mm(point, endpoint_c)
          ].min
          return false if adjacent_length <= @tolerance_mm
          return true if
            projection[:distance_mm] <= LocalVertexNormalizer::GRID_EPSILON_MM

          (adjacent_length / projection[:distance_mm]) >=
            LocalVertexNormalizer::SHORT_EDGE_SLIVER_MIN_ASPECT_RATIO
        end

        def source_boundary_projection_v2(point, endpoint_a, endpoint_c)
          direction = [
            endpoint_c.x.to_f - endpoint_a.x.to_f,
            endpoint_c.y.to_f - endpoint_a.y.to_f,
            endpoint_c.z.to_f - endpoint_a.z.to_f
          ]
          offset = [
            point.x.to_f - endpoint_a.x.to_f,
            point.y.to_f - endpoint_a.y.to_f,
            point.z.to_f - endpoint_a.z.to_f
          ]
          length_squared = vector_dot(direction, direction)
          return nil unless length_squared.positive?

          parameter = vector_dot(offset, direction) / length_squared
          return nil unless parameter > 1.0e-9 && parameter < (1.0 - 1.0e-9)

          coordinates = 3.times.map do |axis|
            point_coordinate(endpoint_a, axis) + (direction[axis] * parameter)
          end
          projected = @point_factory.call(*coordinates)
          {
            point: projected,
            parameter: parameter,
            distance_mm: point_distance_mm(point, projected),
            displacement_mm: point_distance_mm(point, projected)
          }
        end

        def reject_unsafe_source_boundary_targets_v2(faces, targets)
          accepted = targets.dup
          loop do
            rejected = {}
            faces.each do |face|
              next unless face.respond_to?(:loops)

              moved_ids = []
              loops = face.loops.map do |loop|
                keys = loop.vertices.map do |vertex|
                  vertex_id = stable_entity_id(vertex)
                  point = accepted[vertex_id] || vertex.position
                  moved_ids << vertex_id if accepted.key?(vertex_id)
                  source_precision_indices(point)
                end
                compact_integer_loop(keys)
              end
              next if moved_ids.empty?

              begin
                source_normal = vector_components(face.normal)
                drop_axis = source_normal.each_index.max_by do |axis|
                  source_normal[axis].abs
                end
                raise LocalVertexNormalizer::TopologyChangedError if
                  loops.empty? || loops.any? { |loop| loop.length < 3 }

                classify_exact_patch_loops(loops, drop_axis)
              rescue LocalVertexNormalizer::Error, ArgumentError, RuntimeError
                moved_ids.each { |vertex_id| rejected[vertex_id] = true }
              end
            rescue LocalVertexNormalizer::Error, ArgumentError, RuntimeError
              moved_ids.each { |vertex_id| rejected[vertex_id] = true }
            end
            break if rejected.empty?

            rejected.each_key { |vertex_id| accepted.delete(vertex_id) }
          end
          accepted
        end

        def source_boundary_normalized_loop_entries_v2(face, plan)
          face_key = stable_entity_id(face)
          face.loops.map.with_index do |loop, loop_index|
            entries = loop.vertices.map do |vertex|
              vertex_id = stable_entity_id(vertex)
              target = plan[:targets][vertex_id]
              {
                vertex_id: vertex_id,
                point: target || vertex.position,
                targeted: !target.nil?,
                redundant: plan[:occurrences].key?(
                  [face_key, loop_index, vertex_id]
                )
              }
            end
            compact_source_boundary_entries_v2(entries)
          end
        end

        def compact_source_boundary_entries_v2(entries)
          compact = []
          entries.each do |entry|
            compact << entry unless
              compact.last &&
              source_precision_indices(compact.last[:point]) ==
                source_precision_indices(entry[:point])
          end
          compact.pop if compact.length > 1 &&
                         source_precision_indices(compact.first[:point]) ==
                           source_precision_indices(compact.last[:point])
          compact
        end

        def source_boundary_normalized_triangle_records_v2(
          face,
          source_face_key,
          loop_entries
        )
          source_normal = vector_components(face.normal)
          drop_axis = source_normal.each_index.max_by do |axis|
            source_normal[axis].abs
          end
          topology_points = loop_entries.flatten.map { |entry| entry[:point] }
          topology_loops = loop_entries.map do |entries|
            entries.map { |entry| source_precision_indices(entry[:point]) }
          end
          simplified_entries = loop_entries.map do |entries|
            working = entries.map(&:dup)
            loop do
              break if working.length <= 3

              index = working.each_index.find do |candidate_index|
                entry = working[candidate_index]
                next false unless entry[:redundant]

                source_boundary_redundant_point_v2?(
                  entry[:point],
                  working[(candidate_index - 1) % working.length][:point],
                  working[(candidate_index + 1) % working.length][:point]
                )
              end
              break unless index

              working.delete_at(index)
            end
            working
          end
          if simplified_entries.any? { |entries| entries.length < 3 }
            raise LocalVertexNormalizer::TopologyChangedError,
                  'Boundary normalization left fewer than three geometric corners'
          end

          point_by_key = {}
          topology_points.each do |point|
            point_by_key[source_precision_indices(point)] ||= point
          end
          simplified_loops = simplified_entries.map do |entries|
            entries.map do |entry|
              key = source_precision_indices(entry[:point])
              point_by_key[key] ||= entry[:point]
              key
            end
          end
          outer, holes = classify_exact_patch_loops(simplified_loops, drop_axis)
          triangle_keys = triangulate_exact_polygon_with_holes(
            outer,
            holes,
            drop_axis
          )
          records = triangle_keys.map do |keys|
            points = keys.map { |key| point_by_key.fetch(key) }
            actual_normal = vector_cross(
              vector_between(points[0], points[1]),
              vector_between(points[0], points[2])
            )
            points = [points[0], points[2], points[1]] if
              vector_dot(actual_normal, source_normal).negative?
            {
              points: points,
              source_normal: source_normal,
              material: face.material,
              back_material: face.back_material,
              layer: face.layer,
              source_face_key: source_face_key,
              source_boundary_snapshot: true,
              source_boundary_normalized: true
            }
          end
          records = subdivide_source_boundary_records_v2(
            records,
            topology_points
          )
          records.each_with_index do |record, polygon_index|
            record[:source_polygon_index] = polygon_index
          end
          validate_source_boundary_retriangulation!(
            records,
            topology_loops
          )
          records
        end

        def subdivide_source_boundary_records_v2(records, candidates)
          signatures = {}
          edge_split_cache = {}
          records.flat_map do |record|
            boundary = triangle_boundary_with_segment_vertices(
              record[:points],
              candidates,
              coordinate_space: :source,
              edge_split_cache: edge_split_cache
            )
            triangles = if boundary.length == 3
                          [record[:points]]
                        else
                          triangulate_convex_boundary(
                            boundary,
                            candidates,
                            coordinate_space: :source
                          )
                        end
            triangles.map do |points|
              signature = triangle_signature_for_space(points, :source)
              if signatures.key?(signature)
                raise LocalVertexNormalizer::ReconstructionError,
                      "Duplicate normalized source-boundary triangle: #{signature.inspect}"
              end

              signatures[signature] = true
              record.merge(points: points)
            end
          end
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerSourceBoundaryNormalizationV2 unless
          ancestors.include?(LocalVertexNormalizerSourceBoundaryNormalizationV2)
      end
    end
  end
end
