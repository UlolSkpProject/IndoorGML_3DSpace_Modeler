# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_LOCAL_CAVITY_MAX_ATTEMPTS = 80 unless
          const_defined?(:GRID_LOCAL_CAVITY_MAX_ATTEMPTS, false)
        GRID_LOCAL_CAVITY_MAX_RING = 4 unless
          const_defined?(:GRID_LOCAL_CAVITY_MAX_RING, false)
        GRID_LOCAL_CAVITY_MAX_TRIANGLES = 64 unless
          const_defined?(:GRID_LOCAL_CAVITY_MAX_TRIANGLES, false)

        private

        unless private_method_defined?(:repair_grid_invalid_near_edge_splits_before_local_cavity_v2)
          alias_method :repair_grid_invalid_near_edge_splits_before_local_cavity_v2,
                       :repair_grid_invalid_near_edge_splits
        end

        # Post-conforming residual intersections can involve several diagonals from
        # one source Face at once. Repairing only one host edge may then duplicate an
        # already existing triangle or overuse a seam edge. Before the narrow
        # split/flip fallback, retriangulate a bounded same-source cavity around the
        # invalid triangles. The cavity keeps its exact current boundary, moves no
        # vertex, and is accepted only when the complete mesh remains a closed
        # 2-manifold, creates no new exact invalid pair, and removes at least one
        # existing invalid pair.
        def repair_grid_invalid_near_edge_splits(triangle_records)
          cavity_repaired, cavity_report =
            repair_grid_invalid_local_source_cavities(triangle_records)
          repaired, near_report =
            repair_grid_invalid_near_edge_splits_before_local_cavity_v2(
              cavity_repaired
            )

          cavity_count = cavity_report[:accepted_cavity_count].to_i
          near_count = near_report[:accepted_split_count].to_i
          initial_invalid = cavity_report[:initial_invalid_pair_count].to_i
          final_invalid = near_report[:final_invalid_pair_count].to_i
          any_repair = cavity_count.positive? || near_count.positive?

          combined = near_report.merge(
            policy: :local_source_cavity_then_near_edge,
            input_triangle_count: triangle_records.length,
            output_triangle_count: repaired.length,
            initial_invalid_pair_count: initial_invalid,
            final_invalid_pair_count: final_invalid,
            invalid_pair_reduction: initial_invalid - final_invalid,
            attempted_split_count:
              cavity_report[:attempted_cavity_count].to_i +
              near_report[:attempted_split_count].to_i,
            # Compatibility: callers currently use accepted_split_count only as an
            # "any near-stage repair" signal. Keep that behavior while reporting
            # cavity repairs separately below.
            accepted_split_count: cavity_count + near_count,
            accepted_local_cavity_count: cavity_count,
            local_cavity_repair: cavity_report,
            affected_source_face_keys: (
              Array(cavity_report[:affected_source_face_keys]) +
              Array(near_report[:affected_source_face_keys])
            ).compact.uniq,
            skipped: !any_repair,
            skip_reason: any_repair ? nil : :no_safe_local_cavity_or_near_edge_repair
          )

          [repaired, combined]
        end

        def repair_grid_invalid_local_source_cavities(triangle_records)
          initial_invalid = grid_invalid_pair_signatures(triangle_records)
          if initial_invalid.empty?
            return [
              triangle_records,
              empty_grid_local_cavity_report(
                triangle_records.length,
                0,
                :no_invalid_pairs
              )
            ]
          end

          working = triangle_records.dup
          current_invalid = initial_invalid
          attempted = 0
          accepted = []
          attempts = []

          loop do
            break if current_invalid.empty?
            break if attempted >= GRID_LOCAL_CAVITY_MAX_ATTEMPTS

            invalid_pairs = grid_invalid_pairs(working)
            candidates = grid_local_source_cavity_candidates(
              working,
              invalid_pairs
            )
            break if candidates.empty?

            best = nil
            candidates.each do |candidate|
              break if attempted >= GRID_LOCAL_CAVITY_MAX_ATTEMPTS

              attempted += 1
              patch_indices = candidate[:patch_indices]
              patch_records = patch_indices.map { |index| working.fetch(index) }

              begin
                replacements, details = retriangulate_grid_source_face_patch(
                  patch_records
                )
                if same_grid_triangle_set?(patch_records, replacements)
                  attempts << grid_local_cavity_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :triangle_set_unchanged,
                    replacement_triangle_count: replacements.length
                  )
                  next
                end

                tentative = replace_grid_patch(
                  working,
                  patch_indices,
                  replacements
                )
                validate_normalized_triangle_topology!(tentative)

                tentative_invalid = grid_invalid_pair_signatures(tentative)
                new_invalid = tentative_invalid - current_invalid
                removed_invalid = current_invalid - tentative_invalid

                unless new_invalid.empty?
                  attempts << grid_local_cavity_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :new_invalid_pairs,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    new_invalid_pair_count: new_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length,
                    replacement_triangle_count: replacements.length,
                    boundary_loops: details[:boundary_loops],
                    holes: details[:holes]
                  )
                  next
                end

                if removed_invalid.empty?
                  attempts << grid_local_cavity_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :invalid_pairs_not_reduced,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    replacement_triangle_count: replacements.length,
                    boundary_loops: details[:boundary_loops],
                    holes: details[:holes]
                  )
                  next
                end

                report = grid_local_cavity_attempt_report(
                  candidate,
                  accepted: true,
                  before_invalid_pair_count: current_invalid.length,
                  after_invalid_pair_count: tentative_invalid.length,
                  new_invalid_pair_count: 0,
                  removed_invalid_pair_count: removed_invalid.length,
                  replacement_triangle_count: replacements.length,
                  boundary_loops: details[:boundary_loops],
                  holes: details[:holes]
                )
                score = [
                  removed_invalid.length,
                  -patch_indices.length,
                  patch_indices.length - replacements.length,
                  -candidate[:ring]
                ]
                if best.nil? || (score <=> best[0]) == 1
                  best = [score, tentative, tentative_invalid, report]
                end
              rescue Error, ArgumentError => error
                attempts << grid_local_cavity_attempt_report(
                  candidate,
                  accepted: false,
                  reason: :cavity_retriangulation_rejected,
                  error: "#{error.class}: #{error.message}"
                )
              end
            end

            break unless best

            working = best[1]
            current_invalid = best[2]
            accepted << best[3]
            attempts << best[3]
          end

          affected_face_keys = accepted.map do |entry|
            entry[:source_face_key]
          end.compact.uniq

          [
            working,
            {
              policy: :invalid_pair_driven_local_source_cavity_retriangulation,
              input_triangle_count: triangle_records.length,
              output_triangle_count: working.length,
              initial_invalid_pair_count: initial_invalid.length,
              final_invalid_pair_count: current_invalid.length,
              invalid_pair_reduction: initial_invalid.length - current_invalid.length,
              attempted_cavity_count: attempted,
              accepted_cavity_count: accepted.length,
              affected_source_face_keys: affected_face_keys,
              accepted_cavities: accepted.first(20),
              attempts: attempts.first(60),
              skipped: accepted.empty?,
              skip_reason: accepted.empty? ? :no_safe_improving_local_cavity : nil
            }
          ]
        end

        def empty_grid_local_cavity_report(
          triangle_count,
          invalid_pair_count,
          reason
        )
          {
            policy: :invalid_pair_driven_local_source_cavity_retriangulation,
            input_triangle_count: triangle_count,
            output_triangle_count: triangle_count,
            initial_invalid_pair_count: invalid_pair_count,
            final_invalid_pair_count: invalid_pair_count,
            invalid_pair_reduction: 0,
            attempted_cavity_count: 0,
            accepted_cavity_count: 0,
            affected_source_face_keys: [],
            accepted_cavities: [],
            attempts: [],
            skipped: true,
            skip_reason: reason
          }
        end

        def grid_local_source_cavity_candidates(records, invalid_pairs)
          seeds_by_face = Hash.new { |hash, key| hash[key] = [] }
          invalid_pairs.each do |first_index, second_index|
            [first_index, second_index].each do |index|
              record = records.fetch(index)
              next if degenerate_triangle_record?(record)

              source_face_key = record[:source_face_key]
              next if source_face_key.nil?

              seeds_by_face[source_face_key] << index
            end
          end

          candidates = {}
          seeds_by_face.each do |source_face_key, seed_indices|
            seed_indices = seed_indices.uniq.sort
            adjacency = grid_local_same_source_edge_adjacency(
              records,
              source_face_key
            )
            components = grid_local_seed_components(seed_indices, adjacency)

            components.each do |component|
              0.upto(GRID_LOCAL_CAVITY_MAX_RING) do |ring|
                patch_indices = grid_local_grow_cavity(
                  component,
                  adjacency,
                  ring
                )
                next if patch_indices.length < 2
                next if patch_indices.length > GRID_LOCAL_CAVITY_MAX_TRIANGLES

                key = patch_indices
                existing = candidates[key]
                candidate = {
                  source_face_key: source_face_key,
                  seed_indices: component,
                  patch_indices: patch_indices,
                  ring: ring
                }
                if existing.nil? || ring < existing[:ring]
                  candidates[key] = candidate
                end
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

        def grid_local_same_source_edge_adjacency(records, source_face_key)
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

        def grid_local_seed_components(seed_indices, adjacency)
          seed_lookup = seed_indices.to_h { |index| [index, true] }
          unseen = seed_lookup.dup
          components = []

          until unseen.empty?
            start = unseen.keys.min
            queue = [start]
            unseen.delete(start)
            component = []

            until queue.empty?
              current = queue.shift
              component << current
              Array(adjacency[current]).each do |neighbor|
                next unless unseen.key?(neighbor)

                unseen.delete(neighbor)
                queue << neighbor
              end
            end

            components << component.sort
          end

          components
        end

        def grid_local_grow_cavity(seed_indices, adjacency, ring)
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

        def grid_local_cavity_attempt_report(candidate, **details)
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
