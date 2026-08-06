# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_CROSS_SOURCE_SLIVER_FLIP_MAX_ATTEMPTS = 40 unless
          const_defined?(:GRID_CROSS_SOURCE_SLIVER_FLIP_MAX_ATTEMPTS, false)

        private

        unless private_method_defined?(:repair_grid_invalid_near_edge_splits_before_cross_source_sliver)
          alias_method :repair_grid_invalid_near_edge_splits_before_cross_source_sliver,
                       :repair_grid_invalid_near_edge_splits
        end

        # Keep the already-proven same-source repairs first. Only residual invalid
        # pairs are offered to this narrower cross-source fallback.
        #
        # This handles a post-conforming sliver where an internal edge A-B has two
        # owners from different source Faces and one owner is the sub-tolerance
        # triangle (A,B,P), while P lies within the normalization tolerance of A-B:
        #
        #   old: (A,B,Q) + (A,B,P)
        #   new: (A,P,Q) + (P,B,Q)
        #
        # No vertex moves and the exact two-triangle cavity boundary is unchanged.
        # Because the operation collapses one cross-source sliver into the other
        # owner, it is attempted only when the thin owner's minimum altitude is
        # below the normalization tolerance. The complete candidate must remain a
        # closed 2-manifold, create no new exact invalid pair, and remove at least
        # one existing invalid pair.
        def repair_grid_invalid_near_edge_splits(triangle_records)
          base_repaired, base_report =
            repair_grid_invalid_near_edge_splits_before_cross_source_sliver(
              triangle_records
            )
          repaired, cross_report =
            repair_grid_invalid_cross_source_sliver_flips(base_repaired)

          base_count = base_report[:accepted_split_count].to_i
          cross_count = cross_report[:accepted_flip_count].to_i
          initial_invalid = base_report[:initial_invalid_pair_count].to_i
          final_invalid = cross_report[:final_invalid_pair_count].to_i
          any_repair = base_count.positive? || cross_count.positive?

          combined = base_report.merge(
            policy: :local_cavity_near_edge_then_cross_source_sliver_flip,
            input_triangle_count: triangle_records.length,
            output_triangle_count: repaired.length,
            initial_invalid_pair_count: initial_invalid,
            final_invalid_pair_count: final_invalid,
            invalid_pair_reduction: initial_invalid - final_invalid,
            attempted_split_count:
              base_report[:attempted_split_count].to_i +
              cross_report[:attempted_flip_count].to_i,
            accepted_split_count: base_count + cross_count,
            accepted_cross_source_sliver_flip_count: cross_count,
            cross_source_sliver_flip_repair: cross_report,
            affected_source_face_keys: (
              Array(base_report[:affected_source_face_keys]) +
              Array(cross_report[:affected_source_face_keys])
            ).compact.uniq,
            skipped: !any_repair,
            skip_reason: any_repair ? nil : :no_safe_near_edge_or_cross_source_sliver_repair
          )

          [repaired, combined]
        end

        def repair_grid_invalid_cross_source_sliver_flips(triangle_records)
          initial_invalid = grid_invalid_pair_signatures(triangle_records)
          if initial_invalid.empty?
            return [
              triangle_records,
              empty_grid_cross_source_sliver_flip_report(
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
            break if attempted >= GRID_CROSS_SOURCE_SLIVER_FLIP_MAX_ATTEMPTS

            invalid_pairs = grid_invalid_pairs(working)
            candidates = grid_cross_source_sliver_flip_candidates(
              working,
              invalid_pairs
            )
            break if candidates.empty?

            best = nil
            candidates.each do |candidate|
              break if attempted >= GRID_CROSS_SOURCE_SLIVER_FLIP_MAX_ATTEMPTS

              attempted += 1
              begin
                tentative, details = apply_grid_cross_source_sliver_flip_candidate(
                  working,
                  candidate
                )
                validate_normalized_triangle_topology!(tentative)

                tentative_invalid = grid_invalid_pair_signatures(tentative)
                new_invalid = tentative_invalid - current_invalid
                removed_invalid = current_invalid - tentative_invalid

                unless new_invalid.empty?
                  attempts << grid_cross_source_sliver_flip_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :new_invalid_pairs,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    new_invalid_pair_count: new_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length
                  )
                  next
                end

                if removed_invalid.empty?
                  attempts << grid_cross_source_sliver_flip_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :invalid_pairs_not_reduced,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length
                  )
                  next
                end

                report = grid_cross_source_sliver_flip_attempt_report(
                  candidate,
                  accepted: true,
                  before_invalid_pair_count: current_invalid.length,
                  after_invalid_pair_count: tentative_invalid.length,
                  new_invalid_pair_count: 0,
                  removed_invalid_pair_count: removed_invalid.length,
                  replacement_triangle_count: details[:replacement_triangle_count],
                  affected_source_face_keys: details[:affected_source_face_keys]
                )
                score = [
                  removed_invalid.length,
                  -candidate[:distance_mm],
                  -candidate[:thin_altitude_mm],
                  candidate[:edge_key],
                  candidate[:point_key]
                ]
                best = [score, tentative, tentative_invalid, report] if
                  best.nil? || (score <=> best[0]) == 1
              rescue Error, ArgumentError => error
                attempts << grid_cross_source_sliver_flip_attempt_report(
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
              policy: :invalid_pair_driven_cross_source_sliver_flip,
              tolerance_mm: @tolerance_mm,
              input_triangle_count: triangle_records.length,
              output_triangle_count: working.length,
              initial_invalid_pair_count: initial_invalid.length,
              final_invalid_pair_count: current_invalid.length,
              invalid_pair_reduction: initial_invalid.length - current_invalid.length,
              attempted_flip_count: attempted,
              accepted_flip_count: accepted.length,
              affected_source_face_keys: affected_face_keys,
              accepted_flips: accepted.first(20),
              attempts: attempts.first(40),
              skipped: accepted.empty?,
              skip_reason: accepted.empty? ? :no_safe_cross_source_sliver_flip : nil
            }
          ]
        end

        def empty_grid_cross_source_sliver_flip_report(
          triangle_count,
          invalid_pair_count,
          reason
        )
          {
            policy: :invalid_pair_driven_cross_source_sliver_flip,
            tolerance_mm: @tolerance_mm,
            input_triangle_count: triangle_count,
            output_triangle_count: triangle_count,
            initial_invalid_pair_count: invalid_pair_count,
            final_invalid_pair_count: invalid_pair_count,
            invalid_pair_reduction: 0,
            attempted_flip_count: 0,
            accepted_flip_count: 0,
            affected_source_face_keys: [],
            accepted_flips: [],
            attempts: [],
            skipped: true,
            skip_reason: reason
          }
        end

        def grid_cross_source_sliver_flip_candidates(records, invalid_pairs)
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, index|
            next if degenerate_triangle_record?(record)

            triangle = record[:points].map { |point| grid_indices(point) }
            exact_triangle_edge_keys(triangle).each do |edge|
              edge_owners[edge] << index
            end
          end

          candidates = {}
          invalid_pairs.each do |first_index, second_index|
            grid_cross_source_sliver_flip_candidates_between_records(
              records,
              records[first_index],
              records[second_index],
              first_index,
              second_index,
              edge_owners,
              candidates
            )
            grid_cross_source_sliver_flip_candidates_between_records(
              records,
              records[second_index],
              records[first_index],
              second_index,
              first_index,
              edge_owners,
              candidates
            )
          end

          candidates.values.sort_by do |candidate|
            [
              candidate[:distance_mm],
              candidate[:thin_altitude_mm],
              candidate[:edge_key],
              candidate[:point_key]
            ]
          end
        end

        def grid_cross_source_sliver_flip_candidates_between_records(
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
              next if projection[:distance_mm] <= GRID_EPSILON_MM
              next if point_distance_mm(point, edge_start) <= @tolerance_mm
              next if point_distance_mm(point, edge_end) <= @tolerance_mm

              edge_key = canonical_edge_key(start_key, end_key)
              owner_indices = Array(edge_owners[edge_key]).uniq.sort
              next unless owner_indices.length == 2
              next unless owner_indices.include?(edge_record_index)

              containing = owner_indices.select do |owner_index|
                records.fetch(owner_index)[:points].any? do |owner_point|
                  grid_indices(owner_point) == point_key
                end
              end
              next unless containing.length == 1

              thin_owner_index = containing.first
              wide_owner_index = (owner_indices - containing).first
              thin_owner = records.fetch(thin_owner_index)
              wide_owner = records.fetch(wide_owner_index)
              thin_face_key = thin_owner[:source_face_key]
              wide_face_key = wide_owner[:source_face_key]
              next if thin_face_key.nil? || wide_face_key.nil?
              next if thin_face_key == wide_face_key

              thin_altitude_mm = grid_record_minimum_altitude_mm(thin_owner)
              next unless thin_altitude_mm < @tolerance_mm

              key = [edge_key, point_key, thin_owner_index, wide_owner_index]
              trigger = [point_record_index, edge_record_index]
              existing = candidates[key]
              if existing
                existing[:trigger_pairs] << trigger unless
                  existing[:trigger_pairs].include?(trigger)
                next
              end

              candidates[key] = {
                point_key: point_key,
                edge_key: edge_key,
                parameter: projection[:parameter],
                distance_mm: projection[:distance_mm],
                thin_altitude_mm: thin_altitude_mm,
                owner_indices: owner_indices,
                thin_owner_index: thin_owner_index,
                wide_owner_index: wide_owner_index,
                thin_source_face_key: thin_face_key,
                wide_source_face_key: wide_face_key,
                trigger_pairs: [trigger]
              }
            end
          end
        end

        def apply_grid_cross_source_sliver_flip_candidate(records, candidate)
          edge_key = candidate[:edge_key]
          point_key = candidate[:point_key]
          thin_index = candidate[:thin_owner_index]
          wide_index = candidate[:wide_owner_index]
          thin = records.fetch(thin_index)
          wide = records.fetch(wide_index)

          point = thin[:points].find { |entry| grid_indices(entry) == point_key }
          unless point
            raise ReconstructionError,
                  "Cross-source sliver flip lost its near-edge point: #{point_key.inspect}"
          end

          wide_by_key = wide[:points].each_with_object({}) do |entry, map|
            map[grid_indices(entry)] = entry
          end
          edge_start = wide_by_key[edge_key[0]]
          edge_end = wide_by_key[edge_key[1]]
          unless edge_start && edge_end
            raise ReconstructionError,
                  "Cross-source sliver flip lost its host edge: #{edge_key.inspect}"
          end

          opposite = wide[:points].find do |entry|
            key = grid_indices(entry)
            key != edge_key[0] && key != edge_key[1]
          end
          unless opposite
            raise ReconstructionError,
                  'Cross-source sliver flip host triangle has no opposite vertex'
          end

          metadata = {
            grid_cross_source_sliver_flip_repaired: true,
            collapsed_source_face_key: thin[:source_face_key],
            collapsed_source_polygon_index: thin[:source_polygon_index]
          }
          replacements = [
            wide.merge(
              metadata,
              points: orient_patch_triangle(
                [edge_start, point, opposite],
                wide[:source_normal]
              )
            ),
            wide.merge(
              metadata,
              points: orient_patch_triangle(
                [point, edge_end, opposite],
                wide[:source_normal]
              )
            )
          ]
          if replacements.any? { |entry| degenerate_triangle_record?(entry) }
            raise ReconstructionError,
                  "Cross-source sliver flip produced a degenerate triangle: " \
                  "edge=#{edge_key.inspect} point=#{point_key.inspect}"
          end

          old_boundary = grid_triangle_patch_boundary_edges([thin, wide])
          new_boundary = grid_triangle_patch_boundary_edges(replacements)
          unless old_boundary == new_boundary
            raise TopologyChangedError,
                  "Cross-source sliver flip changed its local boundary: " \
                  "old=#{old_boundary.inspect} new=#{new_boundary.inspect}"
          end

          tentative = replace_grid_patch(
            records,
            [thin_index, wide_index],
            replacements
          )
          [
            tentative,
            {
              replacement_triangle_count: replacements.length,
              affected_source_face_keys: [
                thin[:source_face_key],
                wide[:source_face_key]
              ].compact.uniq
            }
          ]
        end

        def grid_cross_source_sliver_flip_attempt_report(candidate, **details)
          {
            edge: candidate[:edge_key],
            point: candidate[:point_key],
            distance_mm: candidate[:distance_mm],
            thin_altitude_mm: candidate[:thin_altitude_mm],
            owner_indices: candidate[:owner_indices],
            thin_owner_index: candidate[:thin_owner_index],
            wide_owner_index: candidate[:wide_owner_index],
            thin_source_face_key: candidate[:thin_source_face_key],
            wide_source_face_key: candidate[:wide_source_face_key],
            trigger_pairs: candidate[:trigger_pairs],
            affected_source_face_keys: [
              candidate[:thin_source_face_key],
              candidate[:wide_source_face_key]
            ].compact.uniq
          }.merge(details)
        end
      end
    end
  end
end
