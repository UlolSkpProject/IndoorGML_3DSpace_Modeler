# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GLOBAL_SHELL_SOURCE_SCALE_PER_MM = 1_000_000 unless
          const_defined?(:GLOBAL_SHELL_SOURCE_SCALE_PER_MM, false)
        GLOBAL_SHELL_GRID_SEARCH_MAX_CHANGED_VERTICES = 4 unless
          const_defined?(:GLOBAL_SHELL_GRID_SEARCH_MAX_CHANGED_VERTICES, false)
        GLOBAL_SHELL_GRID_SEARCH_MAX_ASSIGNMENTS = 50_000 unless
          const_defined?(:GLOBAL_SHELL_GRID_SEARCH_MAX_ASSIGNMENTS, false)
        GLOBAL_SHELL_GRID_MAX_REPAIRS = 1_000 unless
          const_defined?(:GLOBAL_SHELL_GRID_MAX_REPAIRS, false)

        private

        unless private_method_defined?(
          :axis_plane_normalization_plan_before_global_shell_grid_v2
        )
          alias_method(
            :axis_plane_normalization_plan_before_global_shell_grid_v2,
            :axis_plane_normalization_plan
          )
        end

        # Face-local loop validity is necessary but insufficient. Two individually
        # simple source Faces can acquire a new 3D intersection after independent
        # grid rounding. Preserve the source triangle-complex embedding as a second
        # target-planning invariant:
        #
        # - source-space disallowed triangle intersections form the baseline;
        # - only intersections newly introduced by grid projection are repaired;
        # - candidate floor/ceil targets must keep every impacted Face loop valid;
        # - candidate targets may not introduce target collisions;
        # - the set of new shell intersections must decrease monotonically.
        def axis_plane_normalization_plan(entities)
          plan =
            axis_plane_normalization_plan_before_global_shell_grid_v2(entities)
          shell = global_shell_embedding_grid_target_plan(entities, plan)

          plan.merge(
            topology_target_overrides: shell[:overrides],
            topology_target_report:
              Hash(plan[:topology_target_report]).merge(shell[:report])
          )
        end

        def global_shell_embedding_grid_target_plan(entities, axis_plane_plan)
          face_records, face_source_mm, face_targets =
            topology_grid_source_inventory(entities, axis_plane_plan)
          triangle_records, triangle_source_mm, triangle_targets =
            global_shell_source_triangle_inventory(
              entities,
              axis_plane_plan
            )

          source_mm_by_key = face_source_mm.merge(triangle_source_mm)
          initial_targets = face_targets.merge(triangle_targets)
          existing_overrides =
            Hash(axis_plane_plan[:topology_target_overrides])
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
            repair_global_shell_grid_targets(
              face_records,
              triangle_records,
              initial_targets,
              source_mm_by_key,
              Hash(axis_plane_plan[:constraints]),
              baseline_source_pairs
            )

          overrides = existing_overrides.dup
          repaired_targets.each do |key, target|
            base_target = initial_target_without_topology_override(
              key,
              face_targets,
              triangle_targets
            )
            if target == base_target
              overrides.delete(key)
            else
              overrides[key] = target
            end
          end

          {
            overrides: overrides,
            report: repair_report.merge(
              global_shell_source_intersection_count:
                baseline_source_pairs.length,
              global_shell_override_count:
                overrides.length
            )
          }
        end

        def initial_target_without_topology_override(
          key,
          face_targets,
          triangle_targets
        )
          face_targets[key] || triangle_targets.fetch(key)
        end

        def global_shell_source_triangle_inventory(
          entities,
          axis_plane_plan
        )
          source_mm_by_key = {}
          initial_targets = {}
          records = []

          entities.grep(@face_class).each do |face|
            next unless face&.valid?

            mesh = face.mesh(0)
            mesh.polygons.each_with_index do |polygon, polygon_index|
              points = polygon.map do |mesh_index|
                mesh.point_at(mesh_index.abs)
              end
              next unless points.length == 3

              keys = points.map do |point|
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

              records << {
                source_keys: keys,
                source_face_key: stable_entity_id(face),
                source_polygon_index: polygon_index
              }
            end
          end

          [records, source_mm_by_key, initial_targets]
        end

        def repair_global_shell_grid_targets(
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
            global_shell_triangle_indices_by_source_key(
              triangle_records
            )
          baseline_collisions =
            topology_target_collision_signature(targets)
          current_pairs =
            global_shell_new_intersection_pairs(
              triangle_records,
              targets,
              baseline_source_pairs
            )
          initial_pair_count = current_pairs.length
          repair_entries = []
          total_attempts = 0

          GLOBAL_SHELL_GRID_MAX_REPAIRS.times do
            break if current_pairs.empty?

            pair = current_pairs.keys.sort.first
            assignment, candidate_pairs, attempts =
              global_shell_target_assignment(
                face_records,
                triangle_records,
                pair,
                current_pairs,
                targets,
                source_mm_by_key,
                axis_constraints,
                faces_by_source_key,
                triangles_by_source_key,
                baseline_collisions,
                baseline_source_pairs
              )
            total_attempts += attempts

            unless assignment
              raise TopologyChangedError,
                    "Grid projection cannot preserve global shell embedding " \
                    "within adjacent floor/ceil targets: triangles=#{pair.inspect}"
            end

            before_count = current_pairs.length
            assignment.each { |key, target| targets[key] = target }
            current_pairs = candidate_pairs
            repair_entries << {
              triangle_pair: pair,
              changed_source_points: assignment.keys,
              changed_targets: assignment,
              new_intersections_before: before_count,
              new_intersections_after: current_pairs.length,
              search_attempts: attempts
            }
          end

          unless current_pairs.empty?
            raise TopologyChangedError,
                  "Topology-preserving global shell target repair did not converge: " \
                  "remaining_pairs=#{current_pairs.keys.sort.first(20).inspect}"
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
              global_shell_initial_new_intersection_count:
                initial_pair_count,
              global_shell_repaired_intersection_count:
                initial_pair_count,
              global_shell_repaired_source_point_count:
                changed_keys.length,
              global_shell_search_attempts: total_attempts,
              global_shell_max_repaired_target_displacement_mm:
                displacements.max || 0.0,
              global_shell_repairs: repair_entries
            }
          ]
        end

        def global_shell_record_indices_by_source_key(face_records)
          result = Hash.new { |hash, key| hash[key] = [] }
          face_records.each_with_index do |face, face_index|
            face[:loops].each do |loop|
              loop[:source_keys].each do |key|
                result[key] << face_index
              end
            end
          end
          result.each_value(&:uniq!)
          result
        end

        def global_shell_triangle_indices_by_source_key(
          triangle_records
        )
          result = Hash.new { |hash, key| hash[key] = [] }
          triangle_records.each_with_index do |record, triangle_index|
            record[:source_keys].each do |key|
              result[key] << triangle_index
            end
          end
          result.each_value(&:uniq!)
          result
        end

        def global_shell_target_assignment(
          face_records,
          triangle_records,
          problem_pair,
          current_pairs,
          targets,
          source_mm_by_key,
          axis_constraints,
          faces_by_source_key,
          triangles_by_source_key,
          baseline_collisions,
          baseline_source_pairs
        )
          first_record = triangle_records.fetch(problem_pair[0])
          second_record = triangle_records.fetch(problem_pair[1])
          shared_keys =
            first_record[:source_keys] & second_record[:source_keys]
          problem_keys = (
            (first_record[:source_keys] - shared_keys) +
            (second_record[:source_keys] - shared_keys) +
            shared_keys
          ).uniq

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
          return [nil, current_pairs, 0] if problem_keys.empty?

          maximum_changed = [
            GLOBAL_SHELL_GRID_SEARCH_MAX_CHANGED_VERTICES,
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
                return [nil, current_pairs, attempts] if
                  attempts > GLOBAL_SHELL_GRID_SEARCH_MAX_ASSIGNMENTS

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

                impacted_triangles = changed_keys.flat_map do |key|
                  triangles_by_source_key[key]
                end.uniq
                candidate_pairs =
                  global_shell_candidate_intersection_pairs(
                    triangle_records,
                    temporary,
                    baseline_source_pairs,
                    current_pairs,
                    impacted_triangles
                  )
                next unless candidate_pairs.length <
                            current_pairs.length
                next unless candidate_pairs.keys.all? do |pair|
                  current_pairs.key?(pair)
                end

                displacements = assignment.map do |key, target|
                  topology_grid_target_displacement_mm(
                    source_mm_by_key.fetch(key),
                    target
                  )
                end
                candidates << [
                  [
                    candidate_pairs.length,
                    displacements.max || 0.0,
                    displacements.sum { |value| value * value },
                    assignment.length,
                    assignment.sort_by { |key, _| key }
                              .flat_map { |_key, target| target }
                  ],
                  assignment,
                  candidate_pairs
                ]
              end
            end

            break unless candidates.empty?
          end

          best = candidates.min_by(&:first)
          [
            best && best[1],
            best ? best[2] : current_pairs,
            attempts
          ]
        end

        def global_shell_new_intersection_pairs(
          triangle_records,
          coordinates,
          baseline_source_pairs
        )
          pairs = global_shell_intersection_pairs(
            triangle_records,
            coordinates
          )
          pairs.reject do |pair, _value|
            baseline_source_pairs.key?(pair)
          end
        end

        def global_shell_candidate_intersection_pairs(
          triangle_records,
          coordinates,
          baseline_source_pairs,
          current_pairs,
          impacted_triangles
        )
          impacted = impacted_triangles.to_h { |index| [index, true] }
          candidate_pairs = current_pairs.reject do |pair, _value|
            impacted[pair[0]] || impacted[pair[1]]
          end
          candidate_pairs.merge!(
            global_shell_intersection_pairs(
              triangle_records,
              coordinates,
              impacted_triangles: impacted_triangles
            ).reject do |pair, _value|
              baseline_source_pairs.key?(pair)
            end
          )
          candidate_pairs
        end

        def global_shell_intersection_pairs(
          triangle_records,
          coordinates,
          impacted_triangles: nil
        )
          pairs = {}
          count = triangle_records.length

          if impacted_triangles
            tested = {}
            impacted_triangles.each do |first_index|
              count.times do |second_index|
                next if first_index == second_index

                pair = [first_index, second_index].sort
                next if tested[pair]

                tested[pair] = true
                if global_shell_triangle_pair_intersects?(
                  triangle_records,
                  coordinates,
                  pair[0],
                  pair[1]
                )
                  pairs[pair] = true
                end
              end
            end
          else
            triangle_records.each_index do |first_index|
              ((first_index + 1)...count).each do |second_index|
                if global_shell_triangle_pair_intersects?(
                  triangle_records,
                  coordinates,
                  first_index,
                  second_index
                )
                  pairs[[first_index, second_index]] = true
                end
              end
            end
          end

          pairs
        end

        def global_shell_triangle_pair_intersects?(
          triangle_records,
          coordinates,
          first_index,
          second_index
        )
          first = triangle_records[first_index][:source_keys].map do |key|
            coordinates.fetch(key)
          end
          second = triangle_records[second_index][:source_keys].map do |key|
            coordinates.fetch(key)
          end
          return false unless global_shell_valid_triangle?(first)
          return false unless global_shell_valid_triangle?(second)
          return false unless integer_aabbs_overlap?(first, second)

          !exact_triangle_intersection_allowed?(first, second)
        end

        def global_shell_valid_triangle?(triangle)
          triangle.uniq.length == 3 &&
            !integer_zero_vector?(integer_triangle_normal(triangle))
        end
      end
    end
  end
end
