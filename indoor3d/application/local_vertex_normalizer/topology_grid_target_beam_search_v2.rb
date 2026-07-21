# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        TOPOLOGY_GRID_BEAM_WIDTH = 256 unless
          const_defined?(:TOPOLOGY_GRID_BEAM_WIDTH, false)
        TOPOLOGY_GRID_BEAM_MAX_PROCESSED_KEYS = 24 unless
          const_defined?(:TOPOLOGY_GRID_BEAM_MAX_PROCESSED_KEYS, false)
        TOPOLOGY_GRID_BEAM_MAX_CHANGED_VERTICES = 12 unless
          const_defined?(:TOPOLOGY_GRID_BEAM_MAX_CHANGED_VERTICES, false)
        TOPOLOGY_GRID_BEAM_MAX_STATES = 50_000 unless
          const_defined?(:TOPOLOGY_GRID_BEAM_MAX_STATES, false)

        private

        unless private_method_defined?(:topology_grid_target_assignment_before_beam_v2)
          alias_method(
            :topology_grid_target_assignment_before_beam_v2,
            :topology_grid_target_assignment
          )
        end

        unless private_method_defined?(:topology_preserving_grid_target_plan_before_beam_v2)
          alias_method(
            :topology_preserving_grid_target_plan_before_beam_v2,
            :topology_preserving_grid_target_plan
          )
        end

        unless private_method_defined?(:repair_topology_grid_targets_before_beam_v2)
          alias_method(
            :repair_topology_grid_targets_before_beam_v2,
            :repair_topology_grid_targets
          )
        end

        # Preserve the fast exact search for the ordinary case. Refined source-Face
        # loops can require more than four correlated floor/ceil choices, however,
        # so a bounded beam search is used only when the exact <=4-vertex search
        # cannot find a valid assignment.
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
          assignment, exact_attempts =
            topology_grid_target_assignment_before_beam_v2(
              face_records,
              invalid_face_index,
              analysis,
              targets,
              source_mm_by_key,
              axis_constraints,
              faces_by_source_key,
              baseline_collisions
            )
          return [assignment, exact_attempts] if assignment

          beam_assignment, beam_report = topology_grid_target_beam_assignment(
            face_records,
            invalid_face_index,
            analysis,
            targets,
            source_mm_by_key,
            axis_constraints,
            faces_by_source_key,
            baseline_collisions
          )
          @topology_grid_beam_search_entries ||= []
          @topology_grid_beam_search_entries << beam_report.merge(
            face_key: face_records[invalid_face_index][:face_key],
            exact_search_attempts: exact_attempts,
            solved: !beam_assignment.nil?
          )
          @topology_grid_last_beam_failure = beam_report unless beam_assignment

          [beam_assignment, exact_attempts + beam_report[:states_evaluated].to_i]
        end

        def topology_preserving_grid_target_plan(entities, axis_plane_plan)
          @topology_grid_beam_search_entries = []
          result = topology_preserving_grid_target_plan_before_beam_v2(
            entities,
            axis_plane_plan
          )
          entries = Array(@topology_grid_beam_search_entries)
          result[:report] = Hash(result[:report]).merge(
            beam_search_used: !entries.empty?,
            beam_search_face_count: entries.map { |entry| entry[:face_key] }.uniq.length,
            beam_search_states_evaluated:
              entries.sum { |entry| entry[:states_evaluated].to_i },
            beam_search_max_processed_keys:
              entries.map { |entry| entry[:processed_key_count].to_i }.max || 0,
            beam_search_max_changed_vertices:
              entries.map { |entry| entry[:max_changed_vertices].to_i }.max || 0,
            beam_search_entries: entries
          )
          result
        ensure
          @topology_grid_beam_search_entries = nil
          @topology_grid_last_beam_failure = nil
        end

        def repair_topology_grid_targets(*arguments)
          repair_topology_grid_targets_before_beam_v2(*arguments)
        rescue TopologyChangedError => error
          diagnostic = @topology_grid_last_beam_failure
          raise unless diagnostic && error.message.include?(
            'Grid projection cannot preserve source Face boundary topology'
          )

          raise TopologyChangedError,
                "#{error.message}; beam_search=" \
                "processed_keys=#{diagnostic[:processed_key_count]} " \
                "states=#{diagnostic[:states_evaluated]} " \
                "max_changed=#{diagnostic[:max_changed_vertices]} " \
                "best_invalid_faces=#{diagnostic[:best_invalid_face_count]} " \
                "best_issue_score=#{diagnostic[:best_issue_score]} " \
                "state_limit_reached=#{diagnostic[:state_limit_reached]}"
        end

        def topology_grid_target_beam_assignment(
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
          problem_keys = if issue_counts.empty?
                           face_records[invalid_face_index][:loops].flat_map do |loop|
                             loop[:source_keys]
                           end.uniq
                         else
                           issue_counts.keys
                         end
          problem_keys = problem_keys.sort_by do |key|
            [
              -issue_counts[key].to_i,
              -Array(faces_by_source_key[key]).length,
              key
            ]
          end

          alternatives = problem_keys.each_with_object({}) do |key, result|
            candidates = topology_grid_target_candidates(
              source_mm_by_key.fetch(key),
              Hash(axis_constraints[key]),
              targets.fetch(key)
            )
            result[key] = candidates unless candidates.empty?
          end
          ordered_keys = problem_keys.select { |key| alternatives.key?(key) }
                                     .first(TOPOLOGY_GRID_BEAM_MAX_PROCESSED_KEYS)

          impacted_indices = ordered_keys.flat_map do |key|
            faces_by_source_key[key]
          end.uniq
          impacted_indices << invalid_face_index unless
            impacted_indices.include?(invalid_face_index)

          initial_state = topology_grid_beam_state(
            {},
            targets,
            face_records,
            impacted_indices,
            source_mm_by_key
          )
          frontier = [initial_state]
          best_state = initial_state
          states_evaluated = 1
          processed_key_count = 0
          state_limit_reached = false

          ordered_keys.each do |key|
            processed_key_count += 1
            choices = [targets.fetch(key)] + alternatives.fetch(key)
            next_frontier = []

            frontier.each do |state|
              choices.each do |candidate|
                assignment = state[:assignment].dup
                if candidate == targets.fetch(key)
                  assignment.delete(key)
                else
                  assignment[key] = candidate
                end
                next if assignment.length > TOPOLOGY_GRID_BEAM_MAX_CHANGED_VERTICES

                temporary = targets.merge(assignment)
                next unless topology_target_collision_signature(temporary).all? do |pair|
                  baseline_collisions.include?(pair)
                end

                candidate_state = topology_grid_beam_state(
                  assignment,
                  temporary,
                  face_records,
                  impacted_indices,
                  source_mm_by_key
                )
                states_evaluated += 1
                best_state = candidate_state if
                  (candidate_state[:score] <=> best_state[:score]) == -1

                if candidate_state[:valid] &&
                   impacted_indices.include?(invalid_face_index)
                  return [
                    assignment,
                    topology_grid_beam_report(
                      processed_key_count,
                      states_evaluated,
                      candidate_state,
                      false
                    )
                  ]
                end

                next_frontier << candidate_state
                if states_evaluated >= TOPOLOGY_GRID_BEAM_MAX_STATES
                  state_limit_reached = true
                  break
                end
              end
              break if state_limit_reached
            end

            break if state_limit_reached || next_frontier.empty?

            frontier = topology_grid_beam_select_frontier(
              topology_grid_beam_compact_states(next_frontier)
            )
          end

          [
            nil,
            topology_grid_beam_report(
              processed_key_count,
              states_evaluated,
              best_state,
              state_limit_reached
            )
          ]
        end

        def topology_grid_beam_state(
          assignment,
          temporary_targets,
          face_records,
          impacted_indices,
          source_mm_by_key
        )
          analyses = impacted_indices.map do |face_index|
            [
              face_index,
              topology_face_embedding_analysis(
                face_records[face_index],
                temporary_targets
              )
            ]
          end
          invalid = analyses.reject { |_index, entry| entry[:valid] }
          issue_score = invalid.sum do |_index, entry|
            loop_intersections = entry[:loops].sum do |loop|
              Array(loop[:intersections]).length
            end
            entry[:issue_counts].values.sum +
              (loop_intersections * 4) +
              (Array(entry[:cross_loop_intersections]).length * 4) +
              (entry[:containment_valid] ? 0 : 8)
          end
          displacements = assignment.map do |key, target|
            topology_grid_target_displacement_mm(
              source_mm_by_key.fetch(key),
              target
            )
          end

          {
            assignment: assignment,
            valid: invalid.empty?,
            invalid_face_count: invalid.length,
            issue_score: issue_score,
            changed_count: assignment.length,
            score: [
              invalid.length,
              issue_score,
              assignment.length,
              displacements.max || 0.0,
              displacements.sum { |value| value * value },
              assignment.sort_by { |key, _target| key }
                        .flat_map { |_key, target| target }
            ]
          }
        end

        def topology_grid_beam_select_frontier(states)
          sorted = states.sort_by { |state| state[:score] }
          return sorted if sorted.length <= TOPOLOGY_GRID_BEAM_WIDTH

          quota = [
            8,
            TOPOLOGY_GRID_BEAM_WIDTH /
              (TOPOLOGY_GRID_BEAM_MAX_CHANGED_VERTICES + 1)
          ].max
          selected = []
          selected_signatures = {}

          sorted.group_by { |state| state[:changed_count] }.each_value do |group|
            group.first(quota).each do |state|
              signature = state[:assignment].sort_by { |key, _target| key }
              next if selected_signatures[signature]

              selected_signatures[signature] = true
              selected << state
            end
          end

          sorted.each do |state|
            break if selected.length >= TOPOLOGY_GRID_BEAM_WIDTH

            signature = state[:assignment].sort_by { |key, _target| key }
            next if selected_signatures[signature]

            selected_signatures[signature] = true
            selected << state
          end
          selected.first(TOPOLOGY_GRID_BEAM_WIDTH)
        end

        def topology_grid_beam_compact_states(states)
          best_by_signature = {}
          states.each do |state|
            signature = state[:assignment].sort_by { |key, _target| key }
            current = best_by_signature[signature]
            if current.nil? || (state[:score] <=> current[:score]) == -1
              best_by_signature[signature] = state
            end
          end
          best_by_signature.values
        end

        def topology_grid_beam_report(
          processed_key_count,
          states_evaluated,
          state,
          state_limit_reached
        )
          {
            processed_key_count: processed_key_count,
            states_evaluated: states_evaluated,
            max_changed_vertices: state[:changed_count],
            best_invalid_face_count: state[:invalid_face_count],
            best_issue_score: state[:issue_score],
            state_limit_reached: state_limit_reached
          }
        end
      end
    end
  end
end
