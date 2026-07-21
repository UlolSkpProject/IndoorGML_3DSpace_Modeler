# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        BOUNDARY_INCIDENCE_SEARCH_MAX_CHANGED_VERTICES = 3 unless
          const_defined?(:BOUNDARY_INCIDENCE_SEARCH_MAX_CHANGED_VERTICES, false)
        BOUNDARY_INCIDENCE_SEARCH_MAX_ASSIGNMENTS = 20_000 unless
          const_defined?(:BOUNDARY_INCIDENCE_SEARCH_MAX_ASSIGNMENTS, false)
        BOUNDARY_INCIDENCE_MAX_REPAIRS = 1_000 unless
          const_defined?(:BOUNDARY_INCIDENCE_MAX_REPAIRS, false)

        private

        unless private_method_defined?(
          :axis_plane_normalization_plan_before_boundary_incidence_v2
        )
          alias_method(
            :axis_plane_normalization_plan_before_boundary_incidence_v2,
            :axis_plane_normalization_plan
          )
        end

        # Face-local validity and source-mesh triangle validity do not preserve
        # every topological incidence that later polygon retriangulation needs.
        # In particular, a source vertex can lie on another Face's boundary edge
        # while independent grid rounding moves the three points onto a slightly
        # non-collinear integer configuration. A later triangulation then exposes
        # that missed T-junction as a triangle intersection.
        #
        # Capture cross-Face vertex-on-edge incidences in source space and require
        # them to remain exact in grid space. Candidate floor/ceil assignments are
        # accepted only when they also preserve all impacted Face loops, target
        # collision invariants, and the source-mesh global shell embedding.
        def axis_plane_normalization_plan(entities)
          plan =
            axis_plane_normalization_plan_before_boundary_incidence_v2(entities)
          incidence =
            boundary_incidence_grid_target_plan(entities, plan)

          plan.merge(
            topology_target_overrides: incidence[:overrides],
            topology_target_report:
              Hash(plan[:topology_target_report]).merge(incidence[:report])
          )
        end

        def boundary_incidence_grid_target_plan(entities, axis_plane_plan)
          inventory =
            boundary_incidence_source_inventory(entities, axis_plane_plan)
          incidences = inventory[:incidences]
          existing_overrides =
            Hash(axis_plane_plan[:topology_target_overrides])

          if incidences.empty?
            return {
              overrides: existing_overrides,
              report: {
                boundary_incidence_source_count: 0,
                boundary_incidence_initial_invalid_count: 0,
                boundary_incidence_repaired_count: 0,
                boundary_incidence_repaired_source_point_count: 0,
                boundary_incidence_search_attempts: 0,
                boundary_incidence_max_repaired_target_displacement_mm: 0.0,
                boundary_incidence_repairs: []
              }
            }
          end

          face_records, face_source_mm, face_targets =
            topology_grid_source_inventory(entities, axis_plane_plan)
          triangle_records, triangle_source_mm, triangle_targets =
            global_shell_source_triangle_inventory(
              entities,
              axis_plane_plan
            )

          source_mm_by_key =
            face_source_mm
              .merge(triangle_source_mm)
              .merge(inventory[:source_mm_by_key])
          initial_targets =
            face_targets
              .merge(triangle_targets)
              .merge(inventory[:targets])

          existing_overrides.each do |key, target|
            initial_targets[key] = target
          end

          source_coordinates =
            source_mm_by_key.transform_values do |point|
              point.map do |coordinate|
                (coordinate * GLOBAL_SHELL_SOURCE_SCALE_PER_MM).round
              end
            end
          baseline_source_pairs =
            global_shell_intersection_pairs(
              triangle_records,
              source_coordinates
            )

          repaired_targets, repair_report =
            repair_boundary_incidence_grid_targets(
              incidences,
              face_records,
              triangle_records,
              initial_targets,
              source_mm_by_key,
              Hash(axis_plane_plan[:constraints]),
              baseline_source_pairs
            )

          overrides = existing_overrides.dup
          repaired_targets.each do |key, target|
            next if target == initial_targets[key]

            overrides[key] = target
          end

          {
            overrides: overrides,
            report: repair_report.merge(
              boundary_incidence_source_count: incidences.length,
              boundary_incidence_override_count: overrides.length
            )
          }
        end

        def boundary_incidence_source_inventory(entities, axis_plane_plan)
          source_mm_by_key = {}
          targets = {}
          vertex_faces = Hash.new { |hash, key| hash[key] = {} }
          edges = []

          entities.grep(@face_class).each do |face|
            next unless face&.valid?

            face_key = stable_entity_id(face)
            Array(face.respond_to?(:loops) ? face.loops : []).each do |loop|
              keys = loop.vertices.map do |vertex|
                point = vertex.position
                key = source_point_key(point)
                source_mm_by_key[key] ||= point_components_mm(point)
                targets[key] ||=
                  grid_indices(normalized_target(point, axis_plane_plan))
                vertex_faces[key][face_key] = true
                key
              end
              keys.each_index do |index|
                first = keys[index]
                second = keys[(index + 1) % keys.length]
                next if first == second

                edges << {
                  first_key: first,
                  second_key: second,
                  face_key: face_key
                }
              end
            end
          end

          incidences = []
          source_mm_by_key.each_key do |vertex_key|
            point = source_mm_by_key.fetch(vertex_key)
            edges.each do |edge|
              next if edge[:first_key] == vertex_key ||
                      edge[:second_key] == vertex_key
              next if vertex_faces[vertex_key][edge[:face_key]]

              first = source_mm_by_key.fetch(edge[:first_key])
              second = source_mm_by_key.fetch(edge[:second_key])
              distance, parameter =
                boundary_incidence_point_segment_distance_mm(
                  point,
                  first,
                  second
                )
              next unless parameter &&
                          parameter > 1.0e-12 &&
                          parameter < (1.0 - 1.0e-12)
              next if distance > STRICT_COPLANAR_TOLERANCE_MM

              incidences << {
                vertex_key: vertex_key,
                edge_first_key: edge[:first_key],
                edge_second_key: edge[:second_key],
                vertex_face_keys: vertex_faces[vertex_key].keys.sort,
                edge_face_key: edge[:face_key],
                source_distance_mm: distance,
                source_parameter: parameter
              }
            end
          end

          canonical = {}
          incidences.each do |entry|
            edge_keys = [
              entry[:edge_first_key],
              entry[:edge_second_key]
            ].sort
            signature = [entry[:vertex_key], *edge_keys]
            current = canonical[signature]
            if current.nil? ||
               entry[:source_distance_mm] < current[:source_distance_mm]
              canonical[signature] = entry
            end
          end

          {
            source_mm_by_key: source_mm_by_key,
            targets: targets,
            incidences: canonical.values.sort_by do |entry|
              [
                entry[:source_distance_mm],
                entry[:vertex_key],
                entry[:edge_first_key],
                entry[:edge_second_key]
              ]
            end
          }
        end

        def boundary_incidence_point_segment_distance_mm(point, first, second)
          direction = 3.times.map { |axis| second[axis] - first[axis] }
          length_squared = direction.sum { |value| value * value }
          return [Float::INFINITY, nil] unless length_squared.positive?

          offset = 3.times.map { |axis| point[axis] - first[axis] }
          parameter =
            offset.each_index.sum do |axis|
              offset[axis] * direction[axis]
            end / length_squared
          closest = 3.times.map do |axis|
            first[axis] + (parameter * direction[axis])
          end
          distance =
            Math.sqrt(
              3.times.sum do |axis|
                delta = point[axis] - closest[axis]
                delta * delta
              end
            )
          [distance, parameter]
        end

        def repair_boundary_incidence_grid_targets(
          incidences,
          face_records,
          triangle_records,
          initial_targets,
          source_mm_by_key,
          axis_constraints,
          baseline_source_pairs
        )
          targets = initial_targets.transform_values(&:dup)
          faces_by_source_key =
            global_shell_record_indices_by_source_key(face_records)
          triangles_by_source_key =
            global_shell_triangle_indices_by_source_key(triangle_records)
          incidences_by_source_key =
            boundary_incidences_by_source_key(incidences)
          baseline_collisions =
            topology_target_collision_signature(targets)

          invalid =
            boundary_invalid_incidence_indices(incidences, targets)
          initial_invalid_count = invalid.length
          repair_entries = []
          total_attempts = 0

          BOUNDARY_INCIDENCE_MAX_REPAIRS.times do
            invalid =
              boundary_invalid_incidence_indices(incidences, targets)
            break if invalid.empty?

            incidence_index = invalid.first
            assignment, attempts =
              boundary_incidence_target_assignment(
                incidences,
                incidence_index,
                face_records,
                triangle_records,
                targets,
                source_mm_by_key,
                axis_constraints,
                faces_by_source_key,
                triangles_by_source_key,
                incidences_by_source_key,
                baseline_collisions,
                baseline_source_pairs
              )
            total_attempts += attempts

            unless assignment
              incidence = incidences.fetch(incidence_index)
              raise TopologyChangedError,
                    "Grid projection cannot preserve cross-Face boundary " \
                    "vertex-edge incidence within adjacent floor/ceil targets: " \
                    "vertex=#{incidence[:vertex_key].inspect} " \
                    "edge=#{[
                      incidence[:edge_first_key],
                      incidence[:edge_second_key]
                    ].inspect}"
            end

            assignment.each { |key, target| targets[key] = target }
            repair_entries << {
              incidence_index: incidence_index,
              changed_source_points: assignment.keys,
              changed_targets: assignment,
              search_attempts: attempts
            }
          end

          remaining =
            boundary_invalid_incidence_indices(incidences, targets)
          unless remaining.empty?
            raise TopologyChangedError,
                  "Boundary-incidence grid target repair did not converge: " \
                  "remaining=#{remaining.first(20).inspect}"
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
              boundary_incidence_initial_invalid_count:
                initial_invalid_count,
              boundary_incidence_repaired_count:
                initial_invalid_count,
              boundary_incidence_repaired_source_point_count:
                changed_keys.length,
              boundary_incidence_search_attempts:
                total_attempts,
              boundary_incidence_max_repaired_target_displacement_mm:
                displacements.max || 0.0,
              boundary_incidence_repairs: repair_entries
            }
          ]
        end

        def boundary_incidences_by_source_key(incidences)
          result = Hash.new { |hash, key| hash[key] = [] }
          incidences.each_with_index do |incidence, index|
            [
              incidence[:vertex_key],
              incidence[:edge_first_key],
              incidence[:edge_second_key]
            ].each do |key|
              result[key] << index
            end
          end
          result.each_value(&:uniq!)
          result
        end

        def boundary_invalid_incidence_indices(incidences, targets)
          incidences.each_index.reject do |index|
            boundary_incidence_valid?(incidences[index], targets)
          end
        end

        def boundary_incidence_valid?(incidence, targets)
          point = targets.fetch(incidence[:vertex_key])
          first = targets.fetch(incidence[:edge_first_key])
          second = targets.fetch(incidence[:edge_second_key])
          integer_point_between?(point, first, second)
        end

        def boundary_incidence_target_assignment(
          incidences,
          incidence_index,
          face_records,
          triangle_records,
          targets,
          source_mm_by_key,
          axis_constraints,
          faces_by_source_key,
          triangles_by_source_key,
          incidences_by_source_key,
          baseline_collisions,
          baseline_source_pairs
        )
          incidence = incidences.fetch(incidence_index)
          problem_keys = [
            incidence[:vertex_key],
            incidence[:edge_first_key],
            incidence[:edge_second_key]
          ].uniq

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
            BOUNDARY_INCIDENCE_SEARCH_MAX_CHANGED_VERTICES,
            problem_keys.length
          ].min
          attempts = 0
          candidates = []

          1.upto(maximum_changed) do |changed_count|
            problem_keys.combination(changed_count) do |changed_keys|
              candidate_lists =
                changed_keys.map { |key| alternatives.fetch(key) }
              candidate_lists.first
                             .product(*candidate_lists.drop(1))
                             .each do |values|
                attempts += 1
                return [nil, attempts] if
                  attempts > BOUNDARY_INCIDENCE_SEARCH_MAX_ASSIGNMENTS

                assignment = changed_keys.zip(values).to_h
                temporary = targets.merge(assignment)
                next unless topology_target_collision_signature(
                  temporary
                ).all? do |pair|
                  baseline_collisions.include?(pair)
                end

                impacted_faces = changed_keys.flat_map do |key|
                  faces_by_source_key[key]
                end.uniq
                next unless impacted_faces.all? do |face_index|
                  topology_face_embedding_analysis(
                    face_records[face_index],
                    temporary
                  )[:valid]
                end

                impacted_incidences = changed_keys.flat_map do |key|
                  incidences_by_source_key[key]
                end.uniq
                next unless impacted_incidences.all? do |index|
                  boundary_incidence_valid?(
                    incidences[index],
                    temporary
                  )
                end
                next unless boundary_incidence_valid?(
                  incidence,
                  temporary
                )

                impacted_triangles = changed_keys.flat_map do |key|
                  triangles_by_source_key[key]
                end.uniq
                new_pairs =
                  global_shell_intersection_pairs(
                    triangle_records,
                    temporary,
                    impacted_triangles: impacted_triangles
                  ).reject do |pair, _value|
                    baseline_source_pairs.key?(pair)
                  end
                next unless new_pairs.empty?

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

            break unless candidates.empty?
          end

          best = candidates.min_by(&:first)
          [best && best[1], attempts]
        end
      end
    end
  end
end
