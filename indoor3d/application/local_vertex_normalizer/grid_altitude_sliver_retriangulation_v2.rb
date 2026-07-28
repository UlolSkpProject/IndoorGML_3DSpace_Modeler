# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_ALTITUDE_SLIVER_MAX_PATCH_ATTEMPTS = 50 unless
          const_defined?(:GRID_ALTITUDE_SLIVER_MAX_PATCH_ATTEMPTS, false)

        private

        unless private_method_defined?(:normalize_triangle_records_before_grid_altitude_sliver_v2)
          alias_method :normalize_triangle_records_before_grid_altitude_sliver_v2,
                       :normalize_triangle_records_allowing_collisions
        end

        def normalize_triangle_records_allowing_collisions(
          records,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          snapped, report = normalize_triangle_records_before_grid_altitude_sliver_v2(
            records,
            axis_plane_plan,
            duplicate_diagnostics: duplicate_diagnostics
          )

          repaired, repair_report = retriangulate_grid_altitude_slivers(snapped)
          @grid_altitude_sliver_retriangulation_stats_v2 = repair_report
          [repaired, report]
        end

        def retriangulate_grid_altitude_slivers(triangle_records)
          threshold_mm = @tolerance_mm
          input_slivers = grid_altitude_sliver_indices(triangle_records, threshold_mm)
          initial_invalid = grid_invalid_pair_signatures(triangle_records)

          if input_slivers.empty?
            return [
              triangle_records,
              empty_grid_altitude_sliver_retriangulation_report(
                triangle_records.length,
                threshold_mm,
                :no_low_altitude_triangles
              )
            ]
          end

          if initial_invalid.empty?
            report = empty_grid_altitude_sliver_retriangulation_report(
              triangle_records.length,
              threshold_mm,
              :no_invalid_intersections
            )
            report[:detected_sliver_count] = input_slivers.length
            report[:remaining_sliver_count] = input_slivers.length
            return [triangle_records, report]
          end

          working = triangle_records.dup
          current_invalid = initial_invalid
          attempts = []
          accepted = []
          attempted_patch_count = 0

          loop do
            break if attempted_patch_count >= GRID_ALTITUDE_SLIVER_MAX_PATCH_ATTEMPTS

            sliver_indices = grid_altitude_sliver_indices(working, threshold_mm)
            break if sliver_indices.empty? || current_invalid.empty?

            patches = grid_altitude_sliver_patches(working, sliver_indices)
            break if patches.empty?

            best = nil
            patches.each do |patch_indices|
              break if attempted_patch_count >= GRID_ALTITUDE_SLIVER_MAX_PATCH_ATTEMPTS

              attempted_patch_count += 1
              patch_records = patch_indices.map { |index| working[index] }
              before_low_count = patch_records.count do |record|
                grid_altitude_sliver_record?(record, threshold_mm)
              end
              next if before_low_count.zero? || patch_records.length < 2

              before_min_altitude = patch_records.map do |record|
                grid_record_minimum_altitude_mm(record)
              end.min

              begin
                replacements, details = retriangulate_exact_coplanar_patch(patch_records)
                next if same_grid_triangle_set?(patch_records, replacements)

                after_low_count = replacements.count do |record|
                  grid_altitude_sliver_record?(record, threshold_mm)
                end
                after_min_altitude = replacements.map do |record|
                  grid_record_minimum_altitude_mm(record)
                end.min

                unless after_low_count < before_low_count &&
                       after_min_altitude > before_min_altitude
                  attempts << {
                    source_face_key: patch_records.first[:source_face_key],
                    patch_triangle_count: patch_records.length,
                    accepted: false,
                    reason: :altitude_not_improved,
                    before_low_altitude_count: before_low_count,
                    after_low_altitude_count: after_low_count,
                    before_minimum_altitude_mm: before_min_altitude,
                    after_minimum_altitude_mm: after_min_altitude
                  }
                  next
                end

                tentative = replace_grid_patch(working, patch_indices, replacements)
                tentative_invalid = grid_invalid_pair_signatures(tentative)
                new_invalid = tentative_invalid - current_invalid
                removed_invalid = current_invalid - tentative_invalid

                unless new_invalid.empty? && tentative_invalid.length < current_invalid.length
                  attempts << {
                    source_face_key: patch_records.first[:source_face_key],
                    patch_triangle_count: patch_records.length,
                    accepted: false,
                    reason: :invalid_pairs_not_reduced,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    new_invalid_pair_count: new_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length
                  }
                  next
                end

                candidate = {
                  records: tentative,
                  invalid_pairs: tentative_invalid,
                  report: {
                    source_face_key: patch_records.first[:source_face_key],
                    patch_triangle_count: patch_records.length,
                    replacement_triangle_count: replacements.length,
                    accepted: true,
                    before_low_altitude_count: before_low_count,
                    after_low_altitude_count: after_low_count,
                    before_minimum_altitude_mm: before_min_altitude,
                    after_minimum_altitude_mm: after_min_altitude,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length,
                    boundary_loops: details[:boundary_loops],
                    holes: details[:holes]
                  }
                }

                score = [
                  removed_invalid.length,
                  before_low_count - after_low_count,
                  after_min_altitude - before_min_altitude
                ]
                best = [score, candidate] if best.nil? || (score <=> best[0]) == 1
              rescue Error, ArgumentError => error
                attempts << {
                  source_face_key: patch_records.first[:source_face_key],
                  patch_triangle_count: patch_records.length,
                  accepted: false,
                  reason: :retriangulation_rejected,
                  error: "#{error.class}: #{error.message}"
                }
              end
            end

            break unless best

            chosen = best[1]
            working = chosen[:records]
            current_invalid = chosen[:invalid_pairs]
            accepted << chosen[:report]
            attempts << chosen[:report]
          end

          remaining_slivers = grid_altitude_sliver_indices(working, threshold_mm)
          [
            working,
            {
              policy: :conflict_driven_exact_coplanar_retriangulation,
              threshold_mm: threshold_mm,
              input_triangle_count: triangle_records.length,
              output_triangle_count: working.length,
              detected_sliver_count: input_slivers.length,
              remaining_sliver_count: remaining_slivers.length,
              initial_invalid_pair_count: initial_invalid.length,
              final_invalid_pair_count: current_invalid.length,
              attempted_patch_count: attempted_patch_count,
              accepted_patch_count: accepted.length,
              invalid_pair_reduction: initial_invalid.length - current_invalid.length,
              affected_source_face_keys:
                accepted.map { |entry| entry[:source_face_key] }.compact.uniq,
              accepted_patches: accepted.first(20),
              attempts: attempts.first(40),
              skipped: accepted.empty?
            }
          ]
        end

        def empty_grid_altitude_sliver_retriangulation_report(
          input_triangle_count,
          threshold_mm,
          reason
        )
          {
            policy: :conflict_driven_exact_coplanar_retriangulation,
            threshold_mm: threshold_mm,
            input_triangle_count: input_triangle_count,
            output_triangle_count: input_triangle_count,
            detected_sliver_count: 0,
            remaining_sliver_count: 0,
            initial_invalid_pair_count: 0,
            final_invalid_pair_count: 0,
            attempted_patch_count: 0,
            accepted_patch_count: 0,
            invalid_pair_reduction: 0,
            affected_source_face_keys: [],
            accepted_patches: [],
            attempts: [],
            skipped: true,
            skip_reason: reason
          }
        end

        def grid_altitude_sliver_indices(records, threshold_mm)
          records.each_index.select do |index|
            grid_altitude_sliver_record?(records[index], threshold_mm)
          end
        end

        def grid_altitude_sliver_record?(record, threshold_mm)
          return false if degenerate_triangle_record?(record)

          grid_record_minimum_altitude_mm(record) < threshold_mm
        end

        def grid_record_minimum_altitude_mm(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          exact_triangle_minimum_altitude_mm(triangle)
        end

        def grid_altitude_sliver_patches(records, sliver_indices)
          sliver_lookup = sliver_indices.to_h { |index| [index, true] }
          indexed = records.each_index.filter_map do |index|
            record = records[index]
            next if degenerate_triangle_record?(record)

            [index, record]
          end

          groups = indexed.group_by do |_index, record|
            [record[:source_face_key], exact_coplanar_patch_key(record)]
          end

          patches = []
          groups.each_value do |entries|
            edge_owners = Hash.new { |hash, key| hash[key] = [] }
            entries.each do |index, record|
              triangle = record[:points].map { |point| grid_indices(point) }
              exact_triangle_edge_keys(triangle).each do |edge|
                edge_owners[edge] << index
              end
            end

            adjacency = Hash.new { |hash, key| hash[key] = [] }
            entries.each { |index, _record| adjacency[index] }
            edge_owners.each_value do |owners|
              next unless owners.length == 2

              first, second = owners
              adjacency[first] << second
              adjacency[second] << first
            end

            visited = {}
            entries.each do |seed, _record|
              next if visited[seed]

              visited[seed] = true
              queue = [seed]
              component = []
              until queue.empty?
                current = queue.shift
                component << current
                adjacency[current].each do |neighbor|
                  next if visited[neighbor]

                  visited[neighbor] = true
                  queue << neighbor
                end
              end

              next unless component.any? { |index| sliver_lookup[index] }
              patches << component.sort
            end
          end

          patches.sort_by do |indices|
            [
              indices.map do |index|
                grid_record_minimum_altitude_mm(records[index])
              end.min,
              indices.first
            ]
          end
        end

        def same_grid_triangle_set?(first_records, second_records)
          first = first_records.map do |record|
            canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
          end.sort
          second = second_records.map do |record|
            canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
          end.sort
          first == second
        end

        def replace_grid_patch(records, patch_indices, replacements)
          result = records.dup
          insertion_index = patch_indices.min
          patch_indices.sort.reverse_each { |index| result.delete_at(index) }
          replacements.reverse_each { |record| result.insert(insertion_index, record) }
          result
        end

        def grid_invalid_pair_signatures(records)
          triangles = records.filter_map do |record|
            next if degenerate_triangle_record?(record)

            record[:points].map { |point| grid_indices(point) }
          end
          failures = collect_triangle_intersection_failures(triangles)
          failures[:pairs].map do |first, second|
            [
              canonical_triangle_key(triangles[first]),
              canonical_triangle_key(triangles[second])
            ].sort
          end.uniq.sort
        end
      end
    end
  end
end
