# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_POST_CONFORMING_SLIVER_MAX_ATTEMPTS = 80 unless
          const_defined?(:GRID_POST_CONFORMING_SLIVER_MAX_ATTEMPTS, false)
        GRID_POST_CONFORMING_SLIVER_MAX_RING = 4 unless
          const_defined?(:GRID_POST_CONFORMING_SLIVER_MAX_RING, false)
        GRID_POST_CONFORMING_SLIVER_MAX_TRIANGLES = 64 unless
          const_defined?(:GRID_POST_CONFORMING_SLIVER_MAX_TRIANGLES, false)

        private

        unless private_method_defined?(:collapse_short_edge_sliver_triangles_before_post_conforming_altitude)
          alias_method :collapse_short_edge_sliver_triangles_before_post_conforming_altitude,
                       :collapse_short_edge_sliver_triangles
        end

        # The earlier altitude repair is not a blanket deletion pass: a non-zero-area
        # triangle can survive when its original patch has no safe improving
        # retriangulation. After exact grid conforming and the established
        # intersection repairs, try those remaining sub-tolerance triangles again as
        # bounded same-source cavities.
        #
        # This stage never moves a vertex and never relaxes the exact hard gate.
        # retriangulate_grid_source_face_patch preserves each candidate cavity's exact
        # boundary. A candidate is accepted only when:
        # - the global count of triangles below @tolerance_mm decreases,
        # - the complete mesh remains a closed 2-manifold,
        # - no new exact invalid intersection is introduced.
        def collapse_short_edge_sliver_triangles(
          triangle_records,
          plan,
          baseline_validation
        )
          repaired, sliver_report =
            collapse_short_edge_sliver_triangles_before_post_conforming_altitude(
              triangle_records,
              plan,
              baseline_validation
            )

          final_records, residual_report =
            repair_post_conforming_grid_altitude_slivers(repaired)
          @grid_post_conforming_altitude_sliver_repair_stats = residual_report

          if sliver_report.is_a?(Hash)
            sliver_report = sliver_report.merge(
              post_conforming_residual_altitude_sliver_repair: residual_report
            )
          end

          [final_records, sliver_report]
        end

        def repair_post_conforming_grid_altitude_slivers(triangle_records)
          threshold_mm = @tolerance_mm
          initial_slivers = grid_altitude_sliver_indices(triangle_records, threshold_mm)
          if initial_slivers.empty?
            return [
              triangle_records,
              empty_post_conforming_grid_altitude_sliver_report(
                triangle_records.length,
                threshold_mm,
                :no_sub_tolerance_triangles
              )
            ]
          end

          working = triangle_records.dup
          current_invalid = grid_invalid_pair_signatures(working)
          current_sliver_count = initial_slivers.length
          attempted = 0
          accepted = []
          attempts = []

          loop do
            break if current_sliver_count.zero?
            break if attempted >= GRID_POST_CONFORMING_SLIVER_MAX_ATTEMPTS

            candidates = post_conforming_grid_sliver_cavity_candidates(
              working,
              threshold_mm
            )
            break if candidates.empty?

            best = nil
            candidates.each do |candidate|
              break if attempted >= GRID_POST_CONFORMING_SLIVER_MAX_ATTEMPTS

              attempted += 1
              patch_indices = candidate[:patch_indices]
              patch_records = patch_indices.map { |index| working.fetch(index) }
              before_low_count = patch_records.count do |record|
                grid_altitude_sliver_record?(record, threshold_mm)
              end
              next if before_low_count.zero?

              before_minimum = patch_records.map do |record|
                grid_record_minimum_altitude_mm(record)
              end.min

              begin
                replacements, details = retriangulate_grid_source_face_patch(
                  patch_records
                )
                if same_grid_triangle_set?(patch_records, replacements)
                  attempts << post_conforming_grid_sliver_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :triangle_set_unchanged,
                    before_low_altitude_count: before_low_count,
                    replacement_triangle_count: replacements.length
                  )
                  next
                end

                after_low_count = replacements.count do |record|
                  grid_altitude_sliver_record?(record, threshold_mm)
                end
                after_minimum = replacements.map do |record|
                  grid_record_minimum_altitude_mm(record)
                end.min
                altitude_improved = after_low_count.zero? ||
                  (!after_minimum.nil? && after_minimum > before_minimum)

                unless after_low_count < before_low_count && altitude_improved
                  attempts << post_conforming_grid_sliver_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :altitude_not_improved,
                    before_low_altitude_count: before_low_count,
                    after_low_altitude_count: after_low_count,
                    before_minimum_altitude_mm: before_minimum,
                    after_minimum_altitude_mm: after_minimum,
                    replacement_triangle_count: replacements.length
                  )
                  next
                end

                tentative = replace_grid_patch(working, patch_indices, replacements)
                validate_normalized_triangle_topology!(tentative)

                tentative_invalid = grid_invalid_pair_signatures(tentative)
                new_invalid = tentative_invalid - current_invalid
                removed_invalid = current_invalid - tentative_invalid
                unless new_invalid.empty?
                  attempts << post_conforming_grid_sliver_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :new_invalid_pairs,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    new_invalid_pair_count: new_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length,
                    before_low_altitude_count: before_low_count,
                    after_low_altitude_count: after_low_count,
                    replacement_triangle_count: replacements.length
                  )
                  next
                end

                tentative_sliver_count = grid_altitude_sliver_indices(
                  tentative,
                  threshold_mm
                ).length
                unless tentative_sliver_count < current_sliver_count
                  attempts << post_conforming_grid_sliver_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :global_sliver_count_not_reduced,
                    before_sliver_count: current_sliver_count,
                    after_sliver_count: tentative_sliver_count,
                    replacement_triangle_count: replacements.length
                  )
                  next
                end

                report = post_conforming_grid_sliver_attempt_report(
                  candidate,
                  accepted: true,
                  before_sliver_count: current_sliver_count,
                  after_sliver_count: tentative_sliver_count,
                  before_invalid_pair_count: current_invalid.length,
                  after_invalid_pair_count: tentative_invalid.length,
                  new_invalid_pair_count: 0,
                  removed_invalid_pair_count: removed_invalid.length,
                  before_low_altitude_count: before_low_count,
                  after_low_altitude_count: after_low_count,
                  before_minimum_altitude_mm: before_minimum,
                  after_minimum_altitude_mm: after_minimum,
                  replacement_triangle_count: replacements.length,
                  boundary_loops: details[:boundary_loops],
                  holes: details[:holes]
                )
                score = [
                  current_sliver_count - tentative_sliver_count,
                  removed_invalid.length,
                  after_minimum.to_f - before_minimum.to_f,
                  -patch_indices.length,
                  -candidate[:ring]
                ]
                if best.nil? || (score <=> best[0]) == 1
                  best = [
                    score,
                    tentative,
                    tentative_invalid,
                    tentative_sliver_count,
                    report
                  ]
                end
              rescue Error, ArgumentError => error
                attempts << post_conforming_grid_sliver_attempt_report(
                  candidate,
                  accepted: false,
                  reason: :cavity_retriangulation_rejected,
                  before_low_altitude_count: before_low_count,
                  before_minimum_altitude_mm: before_minimum,
                  error: "#{error.class}: #{error.message}"
                )
              end
            end

            break unless best

            working = best[1]
            current_invalid = best[2]
            current_sliver_count = best[3]
            accepted << best[4]
            attempts << best[4]
          end

          remaining_slivers = grid_altitude_sliver_indices(working, threshold_mm)
          [
            working,
            {
              policy: :post_conforming_sub_tolerance_local_cavity_retriangulation,
              threshold_mm: threshold_mm,
              input_triangle_count: triangle_records.length,
              output_triangle_count: working.length,
              initial_sliver_count: initial_slivers.length,
              final_sliver_count: remaining_slivers.length,
              sliver_reduction: initial_slivers.length - remaining_slivers.length,
              initial_invalid_pair_count:
                grid_invalid_pair_signatures(triangle_records).length,
              final_invalid_pair_count: current_invalid.length,
              attempted_cavity_count: attempted,
              accepted_cavity_count: accepted.length,
              affected_source_face_keys:
                accepted.filter_map { |entry| entry[:source_face_key] }.uniq,
              accepted_cavities: accepted.first(20),
              attempts: attempts.first(60),
              skipped: accepted.empty?,
              skip_reason:
                accepted.empty? ? :no_safe_improving_post_conforming_sliver_cavity : nil
            }
          ]
        end

        def empty_post_conforming_grid_altitude_sliver_report(
          triangle_count,
          threshold_mm,
          reason
        )
          {
            policy: :post_conforming_sub_tolerance_local_cavity_retriangulation,
            threshold_mm: threshold_mm,
            input_triangle_count: triangle_count,
            output_triangle_count: triangle_count,
            initial_sliver_count: 0,
            final_sliver_count: 0,
            sliver_reduction: 0,
            initial_invalid_pair_count: 0,
            final_invalid_pair_count: 0,
            attempted_cavity_count: 0,
            accepted_cavity_count: 0,
            affected_source_face_keys: [],
            accepted_cavities: [],
            attempts: [],
            skipped: true,
            skip_reason: reason
          }
        end

        # Start from each residual sliver independently and grow through exact
        # shared-edge adjacency inside the same source Face. Independent seeds keep
        # the repair local; if two slivers need one cavity, their grown candidates
        # naturally converge to the same patch and are deduplicated.
        def post_conforming_grid_sliver_cavity_candidates(records, threshold_mm)
          sliver_indices = grid_altitude_sliver_indices(records, threshold_mm)
          candidates = {}

          sliver_indices.each do |seed_index|
            seed_record = records.fetch(seed_index)
            source_face_key = seed_record[:source_face_key]
            next if source_face_key.nil?

            adjacency = post_conforming_grid_same_source_adjacency(
              records,
              source_face_key
            )
            1.upto(GRID_POST_CONFORMING_SLIVER_MAX_RING) do |ring|
              patch_indices = post_conforming_grid_grow_cavity(
                [seed_index],
                adjacency,
                ring
              )
              next if patch_indices.length < 2
              next if patch_indices.length > GRID_POST_CONFORMING_SLIVER_MAX_TRIANGLES

              key = patch_indices
              existing = candidates[key]
              if existing
                existing[:seed_indices] |= [seed_index]
                existing[:ring] = [existing[:ring], ring].min
              else
                candidates[key] = {
                  source_face_key: source_face_key,
                  seed_indices: [seed_index],
                  patch_indices: patch_indices,
                  ring: ring
                }
              end
            end
          end

          candidates.values.sort_by do |candidate|
            [
              candidate[:patch_indices].length,
              candidate[:ring],
              candidate[:source_face_key].to_s,
              candidate[:patch_indices]
            ]
          end
        end

        def post_conforming_grid_same_source_adjacency(records, source_face_key)
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, index|
            next if degenerate_triangle_record?(record)
            next unless record[:source_face_key] == source_face_key

            triangle = record[:points].map { |point| grid_indices(point) }
            exact_triangle_edge_keys(triangle).each do |edge|
              edge_owners[edge] << index
            end
          end

          adjacency = Hash.new { |hash, key| hash[key] = [] }
          edge_owners.each_value do |owners|
            owners = owners.uniq.sort
            next unless owners.length == 2

            first, second = owners
            adjacency[first] << second
            adjacency[second] << first
          end
          adjacency.each_value(&:uniq!)
          adjacency.each_value(&:sort!)
          adjacency
        end

        def post_conforming_grid_grow_cavity(seed_indices, adjacency, ring)
          included = seed_indices.to_h { |index| [index, true] }
          frontier = seed_indices.dup

          ring.times do
            next_frontier = []
            frontier.each do |index|
              Array(adjacency[index]).each do |neighbor|
                next if included.key?(neighbor)

                included[neighbor] = true
                next_frontier << neighbor
              end
            end
            frontier = next_frontier.uniq
            break if frontier.empty?
          end

          included.keys.sort
        end

        def post_conforming_grid_sliver_attempt_report(candidate, **details)
          {
            source_face_key: candidate[:source_face_key],
            seed_indices: candidate[:seed_indices],
            ring: candidate[:ring],
            patch_triangle_count: candidate[:patch_indices].length,
            patch_indices: candidate[:patch_indices]
          }.merge(details)
        end
      end
    end
  end
end
