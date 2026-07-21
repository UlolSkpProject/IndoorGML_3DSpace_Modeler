# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        TOPOLOGY_GRID_SEARCH_MAX_CHANGED_VERTICES = 4 unless
          const_defined?(:TOPOLOGY_GRID_SEARCH_MAX_CHANGED_VERTICES, false)
        TOPOLOGY_GRID_SEARCH_MAX_ASSIGNMENTS = 50_000 unless
          const_defined?(:TOPOLOGY_GRID_SEARCH_MAX_ASSIGNMENTS, false)
        TOPOLOGY_GRID_MAX_REPAIRS = 1_000 unless
          const_defined?(:TOPOLOGY_GRID_MAX_REPAIRS, false)

        private

        unless private_method_defined?(
          :axis_plane_normalization_plan_before_topology_grid_v2
        )
          alias_method(
            :axis_plane_normalization_plan_before_topology_grid_v2,
            :axis_plane_normalization_plan
          )
        end

        unless private_method_defined?(:normalized_target_before_topology_grid_v2)
          alias_method(
            :normalized_target_before_topology_grid_v2,
            :normalized_target
          )
        end

        # Ordinary nearest-grid rounding is coordinate-wise. Although every
        # displacement is bounded by half a grid cell per axis, independent
        # choices can reverse an orientation predicate or make two non-adjacent
        # boundary segments cross when the source clearance is smaller than the
        # grid. Build the ordinary axis-plane plan first, then solve only the
        # source Face loops whose embedding is not preserved.
        def axis_plane_normalization_plan(entities)
          plan = axis_plane_normalization_plan_before_topology_grid_v2(entities)
          topology = topology_preserving_grid_target_plan(entities, plan)

          plan.merge(
            topology_target_overrides: topology[:overrides],
            topology_target_report: topology[:report]
          )
        end

        def normalized_target(point, axis_plane_plan = nil)
          overrides =
            axis_plane_plan &&
            axis_plane_plan[:topology_target_overrides]
          override = overrides && overrides[source_point_key(point)]
          return point_from_grid_indices(override) if override

          normalized_target_before_topology_grid_v2(point, axis_plane_plan)
        end

        def topology_preserving_grid_target_plan(entities, axis_plane_plan)
          face_records, source_mm_by_key, initial_targets =
            topology_grid_source_inventory(entities, axis_plane_plan)

          initial_invalid_face_count =
            topology_invalid_face_analyses(
              face_records,
              initial_targets
            ).length

          repaired_targets, repair_report =
            repair_topology_grid_targets(
              face_records,
              initial_targets,
              source_mm_by_key,
              Hash(axis_plane_plan[:constraints])
            )

          overrides = repaired_targets.each_with_object({}) do |(key, target), result|
            result[key] = target unless target == initial_targets[key]
          end

          {
            overrides: overrides,
            report: repair_report.merge(
              override_count: overrides.length,
              initial_invalid_face_count: initial_invalid_face_count
            )
          }
        end

        def topology_grid_source_inventory(entities, axis_plane_plan)
          source_mm_by_key = {}
          initial_targets = {}
          face_records = entities.grep(@face_class).filter_map do |face|
            next unless face&.valid?

            source_normal = vector_components(face.normal)
            drop_axis = source_normal.each_index.max_by do |axis|
              source_normal[axis].abs
            end
            next if drop_axis.nil? || source_normal[drop_axis].abs <= 0.0

            outer_loop = face.respond_to?(:outer_loop) ? face.outer_loop : nil
            loops = Array(face.respond_to?(:loops) ? face.loops : []).map do |loop|
              source_keys = loop.vertices.map do |vertex|
                point = vertex.position
                key = source_point_key(point)
                source_mm_by_key[key] ||= point_components_mm(point)
                initial_targets[key] ||=
                  grid_indices(
                    normalized_target_before_topology_grid_v2(
                      point,
                      axis_plane_plan
                    )
                  )
                key
              end

              source_polygon = source_keys.map do |key|
                topology_project_2d(source_mm_by_key.fetch(key), drop_axis)
              end
              source_area2 = topology_numeric_polygon_area2(source_polygon)
              if source_area2.abs <= 1.0e-18
                raise TopologyChangedError,
                      "Source Face has a zero-area boundary before normalization: " \
                      "face=#{stable_entity_id(face).inspect}"
              end

              {
                outer: loop.equal?(outer_loop),
                source_keys: source_keys,
                source_orientation: source_area2.positive? ? 1 : -1
              }
            end
            next if loops.empty?

            {
              face_key: stable_entity_id(face),
              drop_axis: drop_axis,
              loops: loops
            }
          end

          [face_records, source_mm_by_key, initial_targets]
        end

        # Pure grid-target repair. The input hashes contain no SketchUp entities,
        # which makes the topology invariant independently regression-testable.
        def repair_topology_grid_targets(
          face_records,
          initial_targets,
          source_mm_by_key,
          axis_constraints
        )
          targets = initial_targets.transform_values(&:dup)
          faces_by_source_key = Hash.new { |hash, key| hash[key] = [] }
          face_records.each_with_index do |face, face_index|
            face[:loops].each do |loop|
              loop[:source_keys].each do |key|
                faces_by_source_key[key] << face_index
              end
            end
          end
          faces_by_source_key.each_value(&:uniq!)

          baseline_collisions = topology_target_collision_signature(targets)
          repair_entries = []
          total_attempts = 0

          TOPOLOGY_GRID_MAX_REPAIRS.times do
            invalid = topology_invalid_face_analyses(face_records, targets)
            break if invalid.empty?

            face_index, analysis = invalid.first
            assignment, attempts =
              topology_grid_target_assignment(
                face_records,
                face_index,
                analysis,
                targets,
                source_mm_by_key,
                axis_constraints,
                faces_by_source_key,
                baseline_collisions
              )
            total_attempts += attempts

            unless assignment
              raise TopologyChangedError,
                    "Grid projection cannot preserve source Face boundary " \
                    "topology within adjacent floor/ceil targets: " \
                    "face=#{face_records[face_index][:face_key].inspect}"
            end

            assignment.each { |key, target| targets[key] = target }
            repair_entries << {
              face_key: face_records[face_index][:face_key],
              changed_source_points: assignment.keys,
              changed_targets: assignment,
              search_attempts: attempts
            }
          end

          remaining = topology_invalid_face_analyses(face_records, targets)
          unless remaining.empty?
            raise TopologyChangedError,
                  "Topology-preserving grid target repair did not converge: " \
                  "remaining_faces=#{remaining.map { |index, _| face_records[index][:face_key] }.inspect}"
          end

          changed_keys = targets.keys.select do |key|
            targets[key] != initial_targets[key]
          end
          displacements = changed_keys.map do |key|
            topology_grid_target_displacement_mm(
              source_mm_by_key.fetch(key),
              targets.fetch(key)
            )
          end

          [
            targets,
            {
              repaired_face_count:
                repair_entries.map { |entry| entry[:face_key] }.uniq.length,
              repaired_source_point_count: changed_keys.length,
              search_attempts: total_attempts,
              max_repaired_target_displacement_mm: displacements.max || 0.0,
              repairs: repair_entries
            }
          ]
        end

        def topology_invalid_face_analyses(face_records, targets)
          face_records.each_with_index.filter_map do |face, index|
            analysis = topology_face_embedding_analysis(face, targets)
            [index, analysis] unless analysis[:valid]
          end
        end

        def topology_face_embedding_analysis(face, targets)
          issue_counts = Hash.new(0)
          loop_results = face[:loops].map do |loop|
            keys = loop[:source_keys]
            points = keys.map { |key| targets.fetch(key) }
            projected = points.map do |point|
              topology_project_2d(point, face[:drop_axis])
            end
            loop_analysis =
              topology_loop_embedding_analysis(
                keys,
                projected,
                loop[:source_orientation]
              )
            loop_analysis[:issue_source_keys].each do |key|
              issue_counts[key] += 1
            end
            loop_analysis.merge(
              outer: loop[:outer],
              source_keys: keys,
              projected: projected
            )
          end

          outer_entries = loop_results.select { |entry| entry[:outer] }
          if outer_entries.length != 1
            loop_results.flat_map { |entry| entry[:source_keys] }.each do |key|
              issue_counts[key] += 1
            end
          end

          cross_loop_intersections = []
          loop_results.each_with_index do |first, first_index|
            ((first_index + 1)...loop_results.length).each do |second_index|
              second = loop_results[second_index]
              topology_cross_loop_intersections(first, second).each do |entry|
                cross_loop_intersections << entry.merge(
                  first_loop_index: first_index,
                  second_loop_index: second_index
                )
                entry[:issue_source_keys].each do |key|
                  issue_counts[key] += 1
                end
              end
            end
          end

          containment_valid = true
          if outer_entries.length == 1
            outer = outer_entries.first
            loop_results.reject { |entry| entry[:outer] }.each do |hole|
              point = hole[:projected].first
              next if point &&
                      integer_point_in_polygon_2d?(point, outer[:projected])

              containment_valid = false
              (outer[:source_keys] + hole[:source_keys]).each do |key|
                issue_counts[key] += 1
              end
            end
          else
            containment_valid = false
          end

          valid =
            outer_entries.length == 1 &&
            loop_results.all? { |entry| entry[:valid] } &&
            cross_loop_intersections.empty? &&
            containment_valid

          {
            valid: valid,
            loops: loop_results,
            cross_loop_intersections: cross_loop_intersections,
            containment_valid: containment_valid,
            issue_counts: issue_counts
          }
        end

        def topology_loop_embedding_analysis(keys, polygon, source_orientation)
          issue_keys = []
          duplicate_indices = Hash.new { |hash, point| hash[point] = [] }
          polygon.each_with_index do |point, index|
            duplicate_indices[point] << index
          end
          duplicate_indices.each_value do |indices|
            next if indices.length == 1

            indices.each { |index| issue_keys << keys[index] }
          end

          area2 = polygon.length >= 3 ? integer_polygon_area2(polygon) : 0
          orientation =
            if area2.positive?
              1
            elsif area2.negative?
              -1
            else
              0
            end
          if orientation.zero? || orientation != source_orientation
            issue_keys.concat(keys)
          end

          intersections = []
          polygon.length.times do |first_index|
            first_next = (first_index + 1) % polygon.length
            ((first_index + 1)...polygon.length).each do |second_index|
              second_next = (second_index + 1) % polygon.length
              next if second_index == first_next
              next if first_index.zero? && second_next.zero?

              first_segment = [
                polygon[first_index],
                polygon[first_next]
              ]
              second_segment = [
                polygon[second_index],
                polygon[second_next]
              ]
              next unless (first_segment & second_segment).empty?
              next unless integer_segments_intersect_2d?(
                first_segment[0],
                first_segment[1],
                second_segment[0],
                second_segment[1]
              )

              involved = [
                keys[first_index],
                keys[first_next],
                keys[second_index],
                keys[second_next]
              ].uniq
              issue_keys.concat(involved)
              intersections << {
                first_segment_index: first_index,
                second_segment_index: second_index,
                issue_source_keys: involved
              }
            end
          end

          {
            valid:
              polygon.length >= 3 &&
              duplicate_indices.values.all? { |indices| indices.length == 1 } &&
              !area2.zero? &&
              orientation == source_orientation &&
              intersections.empty?,
            signed_area2: area2,
            intersections: intersections,
            issue_source_keys: issue_keys.uniq
          }
        end

        def topology_cross_loop_intersections(first, second)
          intersections = []
          first[:projected].each_index do |first_index|
            first_next = (first_index + 1) % first[:projected].length
            second[:projected].each_index do |second_index|
              second_next = (second_index + 1) % second[:projected].length
              next unless integer_segments_intersect_2d?(
                first[:projected][first_index],
                first[:projected][first_next],
                second[:projected][second_index],
                second[:projected][second_next]
              )

              involved = [
                first[:source_keys][first_index],
                first[:source_keys][first_next],
                second[:source_keys][second_index],
                second[:source_keys][second_next]
              ].uniq
              intersections << {
                first_segment_index: first_index,
                second_segment_index: second_index,
                issue_source_keys: involved
              }
            end
          end
          intersections
        end

        def topology_grid_target_assignment(
          face_records,
          invalid_face_index,
          analysis,
          targets,
          source_mm_by_key,
          axis_constraints,
          faces_by_source_key,
          baseline_collisions
        )
          issue_counts = analysis[:issue_counts]
          problem_keys =
            if issue_counts.empty?
              face_records[invalid_face_index][:loops].flat_map do |loop|
                loop[:source_keys]
              end.uniq
            else
              issue_counts.keys
            end
          problem_keys = problem_keys.sort_by do |key|
            [-issue_counts[key].to_i, key]
          end

          alternatives = problem_keys.to_h do |key|
            [
              key,
              topology_grid_target_candidates(
                source_mm_by_key.fetch(key),
                Hash(axis_constraints[key]),
                targets.fetch(key)
              )
            ]
          end
          problem_keys.select! { |key| !alternatives[key].empty? }
          return [nil, 0] if problem_keys.empty?

          maximum_changed = [
            TOPOLOGY_GRID_SEARCH_MAX_CHANGED_VERTICES,
            problem_keys.length
          ].min
          attempts = 0
          candidates = []

          1.upto(maximum_changed) do |changed_count|
            problem_keys.combination(changed_count) do |changed_keys|
              candidate_lists = changed_keys.map { |key| alternatives.fetch(key) }
              candidate_lists.first.product(*candidate_lists.drop(1)).each do |values|
                attempts += 1
                return [nil, attempts] if
                  attempts > TOPOLOGY_GRID_SEARCH_MAX_ASSIGNMENTS

                assignment = changed_keys.zip(values).to_h
                temporary = targets.merge(assignment)
                next unless topology_target_collision_signature(temporary).all? do |pair|
                  baseline_collisions.include?(pair)
                end

                impacted_indices = changed_keys.flat_map do |key|
                  faces_by_source_key[key]
                end.uniq
                next unless impacted_indices.include?(invalid_face_index)
                next unless impacted_indices.all? do |face_index|
                  topology_face_embedding_analysis(
                    face_records[face_index],
                    temporary
                  )[:valid]
                end

                displacements = assignment.map do |key, target|
                  topology_grid_target_displacement_mm(
                    source_mm_by_key.fetch(key),
                    target
                  )
                end
                candidates << [
                  [
                    displacements.max || 0.0,
                    displacements.sum { |value| value * value },
                    assignment.length,
                    assignment.sort_by { |key, _| key }
                              .flat_map { |_key, target| target }
                  ],
                  assignment
                ]
              end
            end
          end

          best = candidates.min_by(&:first)
          [best && best[1], attempts]
        end

        def topology_grid_target_candidates(source_mm, constraints, current_target)
          per_axis = 3.times.map do |axis|
            if constraints.key?(axis)
              [constraints.fetch(axis)]
            else
              scaled = source_mm[axis] / @tolerance_mm
              [scaled.floor, scaled.ceil].uniq
            end
          end

          per_axis[0].product(per_axis[1], per_axis[2])
                     .reject { |target| target == current_target }
                     .sort_by do |target|
            [
              topology_grid_target_displacement_mm(source_mm, target),
              target
            ]
          end
        end

        def topology_target_collision_signature(targets)
          owners = Hash.new { |hash, target| hash[target] = [] }
          targets.each { |source_key, target| owners[target] << source_key }
          owners.values.flat_map do |source_keys|
            next [] if source_keys.length < 2

            source_keys.sort.combination(2).map { |pair| pair }
          end
        end

        def topology_grid_target_displacement_mm(source_mm, target)
          Math.sqrt(
            3.times.sum do |axis|
              delta = source_mm[axis] - (target[axis] * @tolerance_mm)
              delta * delta
            end
          )
        end

        def topology_project_2d(point, drop_axis)
          point.each_index.filter_map do |axis|
            point[axis] unless axis == drop_axis
          end
        end

        def topology_numeric_polygon_area2(polygon)
          polygon.each_index.sum do |index|
            following = (index + 1) % polygon.length
            (polygon[index][0] * polygon[following][1]) -
              (polygon[following][0] * polygon[index][1])
          end
        end
      end
    end
  end
end
