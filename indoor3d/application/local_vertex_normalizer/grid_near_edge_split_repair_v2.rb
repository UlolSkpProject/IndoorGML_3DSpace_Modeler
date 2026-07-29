# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_NEAR_EDGE_SPLIT_MAX_ATTEMPTS = 50 unless
          const_defined?(:GRID_NEAR_EDGE_SPLIT_MAX_ATTEMPTS, false)

        private

        unless private_method_defined?(:retriangulate_grid_invalid_source_faces_before_near_edge_split_v2)
          alias_method :retriangulate_grid_invalid_source_faces_before_near_edge_split_v2,
                       :retriangulate_grid_invalid_source_faces
        end

        # Before the source-Face retriangulation fallback, try the narrower repair
        # implied by the failing exact intersection itself: when a grid vertex P is
        # within the normalization tolerance of an invalid pair's edge A-B, keep P
        # fixed on the grid and replace the physical edge A-B with A-P / P-B for
        # every current owner of A-B. No off-grid projection point is introduced.
        #
        # A candidate is accepted only when the whole tentative triangle complex:
        # - preserves exact normalized triangle topology,
        # - creates no new invalid intersection pair, and
        # - removes at least one pre-existing invalid pair.
        #
        # Rejected candidates leave the mesh untouched and fall through to the
        # existing source-Face retriangulation logic.
        def retriangulate_grid_invalid_source_faces(triangle_records)
          near_repaired, near_report = repair_grid_invalid_near_edge_splits(
            triangle_records
          )
          source_repaired, source_report =
            retriangulate_grid_invalid_source_faces_before_near_edge_split_v2(
              near_repaired
            )

          initial_invalid_count = near_report[:initial_invalid_pair_count].to_i
          final_invalid_count = source_report[:final_invalid_pair_count].to_i
          near_count = near_report[:accepted_split_count].to_i
          source_count = source_report[:accepted_face_count].to_i
          any_repair = near_count.positive? || source_count.positive?

          combined_report = source_report.merge(
            policy: :near_edge_split_then_invalid_pair_driven_source_face_retriangulation,
            input_triangle_count: triangle_records.length,
            output_triangle_count: source_repaired.length,
            initial_invalid_pair_count: initial_invalid_count,
            final_invalid_pair_count: final_invalid_count,
            invalid_pair_reduction: initial_invalid_count - final_invalid_count,
            attempted_near_edge_split_count: near_report[:attempted_split_count].to_i,
            accepted_near_edge_split_count: near_count,
            near_edge_split_repair: near_report,
            affected_source_face_keys: (
              Array(near_report[:affected_source_face_keys]) +
              Array(source_report[:affected_source_face_keys])
            ).compact.uniq,
            # Compatibility with grid_altitude_sliver_retriangulation_v2: its
            # caller currently uses accepted_face_count only as an "any repair"
            # signal. Keep the old key while reporting near-edge repairs separately.
            accepted_face_count: source_count + near_count,
            skipped: !any_repair,
            skip_reason: any_repair ? nil : :no_safe_near_edge_or_source_face_repair
          )

          [source_repaired, combined_report]
        end

        def repair_grid_invalid_near_edge_splits(triangle_records)
          initial_invalid = grid_invalid_pair_signatures(triangle_records)
          if initial_invalid.empty?
            return [
              triangle_records,
              empty_grid_near_edge_split_report(
                triangle_records.length,
                0,
                :no_invalid_pairs
              )
            ]
          end

          working = triangle_records.dup
          current_invalid = initial_invalid
          attempted = 0
          attempts = []
          accepted = []

          loop do
            break if current_invalid.empty?
            break if attempted >= GRID_NEAR_EDGE_SPLIT_MAX_ATTEMPTS

            invalid_pairs = grid_invalid_pairs(working)
            candidates = grid_near_edge_split_candidates(working, invalid_pairs)
            break if candidates.empty?

            best = nil
            candidates.each do |candidate|
              break if attempted >= GRID_NEAR_EDGE_SPLIT_MAX_ATTEMPTS

              attempted += 1
              begin
                tentative, details = apply_grid_near_edge_split_candidate(
                  working,
                  candidate
                )
                validate_normalized_triangle_topology!(tentative)

                tentative_invalid = grid_invalid_pair_signatures(tentative)
                new_invalid = tentative_invalid - current_invalid
                removed_invalid = current_invalid - tentative_invalid

                unless new_invalid.empty?
                  attempts << near_edge_split_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :new_invalid_pairs,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    new_invalid_pair_count: new_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length,
                    owner_count: details[:owner_count]
                  )
                  next
                end

                if removed_invalid.empty?
                  attempts << near_edge_split_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :invalid_pairs_not_reduced,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    owner_count: details[:owner_count]
                  )
                  next
                end

                report = near_edge_split_attempt_report(
                  candidate,
                  accepted: true,
                  before_invalid_pair_count: current_invalid.length,
                  after_invalid_pair_count: tentative_invalid.length,
                  removed_invalid_pair_count: removed_invalid.length,
                  owner_count: details[:owner_count],
                  replacement_triangle_count: details[:replacement_triangle_count],
                  affected_source_face_keys: details[:affected_source_face_keys]
                )
                score = [
                  removed_invalid.length,
                  -candidate[:distance_mm],
                  -candidate[:owner_indices].length,
                  candidate[:edge_key],
                  candidate[:point_key]
                ]
                best = [score, tentative, tentative_invalid, report] if
                  best.nil? || (score <=> best[0]) == 1
              rescue Error, ArgumentError => error
                attempts << near_edge_split_attempt_report(
                  candidate,
                  accepted: false,
                  reason: :candidate_rejected,
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

          affected_face_keys = accepted.flat_map do |entry|
            Array(entry[:affected_source_face_keys])
          end.compact.uniq

          [
            working,
            {
              policy: :invalid_pair_driven_grid_near_edge_split,
              tolerance_mm: @tolerance_mm,
              input_triangle_count: triangle_records.length,
              output_triangle_count: working.length,
              initial_invalid_pair_count: initial_invalid.length,
              final_invalid_pair_count: current_invalid.length,
              invalid_pair_reduction: initial_invalid.length - current_invalid.length,
              attempted_split_count: attempted,
              accepted_split_count: accepted.length,
              affected_source_face_keys: affected_face_keys,
              accepted_splits: accepted.first(20),
              attempts: attempts.first(40),
              skipped: accepted.empty?,
              skip_reason: accepted.empty? ? :no_safe_near_edge_split : nil
            }
          ]
        end

        def empty_grid_near_edge_split_report(
          triangle_count,
          invalid_pair_count,
          reason
        )
          {
            policy: :invalid_pair_driven_grid_near_edge_split,
            tolerance_mm: @tolerance_mm,
            input_triangle_count: triangle_count,
            output_triangle_count: triangle_count,
            initial_invalid_pair_count: invalid_pair_count,
            final_invalid_pair_count: invalid_pair_count,
            invalid_pair_reduction: 0,
            attempted_split_count: 0,
            accepted_split_count: 0,
            affected_source_face_keys: [],
            accepted_splits: [],
            attempts: [],
            skipped: true,
            skip_reason: reason
          }
        end

        def grid_near_edge_split_candidates(records, invalid_pairs)
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, index|
            next if degenerate_triangle_record?(record)

            keys = record[:points].map { |point| grid_indices(point) }
            exact_triangle_edge_keys(keys).each do |edge|
              edge_owners[edge] << index
            end
          end

          candidates = {}
          invalid_pairs.each do |first_index, second_index|
            first = records[first_index]
            second = records[second_index]
            grid_near_edge_candidates_between_records(
              records,
              first,
              second,
              first_index,
              second_index,
              edge_owners,
              candidates
            )
            grid_near_edge_candidates_between_records(
              records,
              second,
              first,
              second_index,
              first_index,
              edge_owners,
              candidates
            )
          end

          candidates.values.sort_by do |candidate|
            [
              candidate[:distance_mm],
              candidate[:owner_indices].length,
              candidate[:edge_key],
              candidate[:point_key]
            ]
          end
        end

        def grid_near_edge_candidates_between_records(
          records,
          point_record,
          edge_record,
          point_record_index,
          edge_record_index,
          edge_owners,
          candidates
        )
          edge_points = edge_record[:points]
          point_record[:points].each do |point|
            point_key = grid_indices(point)

            3.times do |edge_index|
              edge_start = edge_points[edge_index]
              edge_end = edge_points[(edge_index + 1) % 3]
              start_key = grid_indices(edge_start)
              end_key = grid_indices(edge_end)
              next if point_key == start_key || point_key == end_key

              projection = grid_near_edge_projection(point, edge_start, edge_end)
              next unless projection
              next if projection[:distance_mm] > @tolerance_mm

              # Avoid replacing one near-endpoint condition with a sub-tolerance
              # edge/sliver. The projection is strictly interior, and both new
              # physical edges must remain longer than the normalization tolerance.
              next if point_distance_mm(point, edge_start) <= @tolerance_mm
              next if point_distance_mm(point, edge_end) <= @tolerance_mm

              edge_key = canonical_edge_key(start_key, end_key)
              owner_indices = Array(edge_owners[edge_key]).uniq.sort
              next if owner_indices.empty? || owner_indices.length > 2
              next if owner_indices.any? do |owner_index|
                records.fetch(owner_index)[:points].any? do |owner_point|
                  grid_indices(owner_point) == point_key
                end
              end

              affected_source_face_keys = owner_indices.filter_map do |owner_index|
                records.fetch(owner_index)[:source_face_key]
              end.uniq
              key = [edge_key, point_key]
              trigger = [point_record_index, edge_record_index]
              existing = candidates[key]
              if existing
                existing[:trigger_pairs] << trigger unless
                  existing[:trigger_pairs].include?(trigger)
                next
              end

              candidates[key] = {
                point: point,
                point_key: point_key,
                edge_key: edge_key,
                parameter: projection[:parameter],
                distance_mm: projection[:distance_mm],
                owner_indices: owner_indices,
                affected_source_face_keys: affected_source_face_keys,
                trigger_pairs: [trigger]
              }
            end
          end
        end

        def grid_near_edge_projection(point, edge_start, edge_end)
          direction = vector_between(edge_start, edge_end)
          offset = vector_between(edge_start, point)
          length_squared = vector_dot(direction, direction)
          return nil unless length_squared.positive?

          parameter = vector_dot(offset, direction) / length_squared
          return nil unless parameter > 1.0e-9 && parameter < (1.0 - 1.0e-9)

          projection = 3.times.map do |axis|
            point_coordinate(edge_start, axis) + (direction[axis] * parameter)
          end
          point_coordinates = [point.x.to_f, point.y.to_f, point.z.to_f]
          distance_mm = Math.sqrt(
            3.times.sum do |axis|
              (point_coordinates[axis] - projection[axis])**2
            end
          ) * MM_PER_INCH

          {
            parameter: parameter,
            distance_mm: distance_mm
          }
        end

        def apply_grid_near_edge_split_candidate(records, candidate)
          point = candidate[:point]
          point_key = candidate[:point_key]
          edge_key = candidate[:edge_key]
          owner_indices = candidate[:owner_indices]

          replacements = []
          affected_source_face_keys = []
          owner_indices.each do |owner_index|
            record = records.fetch(owner_index)
            points = record[:points]
            keys = points.map { |entry| grid_indices(entry) }
            endpoint_indices = edge_key.map { |key| keys.index(key) }
            if endpoint_indices.any?(&:nil?)
              raise ReconstructionError,
                    "Near-edge split owner no longer contains host edge: " \
                    "edge=#{edge_key.inspect} owner=#{owner_index}"
            end
            if keys.include?(point_key)
              raise ReconstructionError,
                    "Near-edge split point already belongs to host triangle: " \
                    "point=#{point_key.inspect} owner=#{owner_index}"
            end

            first_index, second_index = endpoint_indices
            opposite_index = (0...3).find do |index|
              index != first_index && index != second_index
            end
            opposite = points.fetch(opposite_index)
            edge_start = points.fetch(first_index)
            edge_end = points.fetch(second_index)

            split_records = [
              record.merge(
                points: orient_patch_triangle(
                  [edge_start, point, opposite],
                  record[:source_normal]
                ),
                grid_near_edge_split_repaired: true
              ),
              record.merge(
                points: orient_patch_triangle(
                  [point, edge_end, opposite],
                  record[:source_normal]
                ),
                grid_near_edge_split_repaired: true
              )
            ]
            if split_records.any? { |entry| degenerate_triangle_record?(entry) }
              raise ReconstructionError,
                    "Near-edge split produced a degenerate triangle: " \
                    "edge=#{edge_key.inspect} point=#{point_key.inspect}"
            end

            replacements.concat(split_records)
            affected_source_face_keys << record[:source_face_key]
          end

          tentative = replace_grid_patch(records, owner_indices, replacements)
          [
            tentative,
            {
              owner_count: owner_indices.length,
              replacement_triangle_count: replacements.length,
              affected_source_face_keys: affected_source_face_keys.compact.uniq
            }
          ]
        end

        def near_edge_split_attempt_report(candidate, **details)
          {
            edge: candidate[:edge_key],
            point: candidate[:point_key],
            distance_mm: candidate[:distance_mm],
            parameter: candidate[:parameter],
            trigger_pairs: candidate[:trigger_pairs],
            owner_count: candidate[:owner_indices].length,
            affected_source_face_keys:
              Array(candidate[:affected_source_face_keys]).compact.uniq
          }.merge(details)
        end
      end
    end
  end
end
