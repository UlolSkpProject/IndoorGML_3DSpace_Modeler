# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_NEAR_EDGE_OWNER_FLIP_MAX_ATTEMPTS = 50 unless
          const_defined?(:GRID_NEAR_EDGE_OWNER_FLIP_MAX_ATTEMPTS, false)

        private

        unless private_method_defined?(:repair_grid_invalid_near_edge_splits_before_owner_flip_v2)
          alias_method :repair_grid_invalid_near_edge_splits_before_owner_flip_v2,
                       :repair_grid_invalid_near_edge_splits
        end

        # Handles the topology-safe near-edge case that a simple A-B -> A-P / P-B
        # split cannot represent: A-B is an internal diagonal with exactly two
        # owners, and P is already the opposite vertex of one owner.
        #
        #   old: (A,B,X) + (A,B,P)
        #   new: (A,P,X) + (P,B,X)
        #
        # This is a local diagonal flip. It keeps every existing grid vertex fixed
        # and preserves the exact boundary of the two-triangle cavity. We only try
        # it when the two current owners themselves form an exact invalid pair,
        # both belong to the same source Face and exact plane, and P lies within the
        # normalization tolerance of A-B. The final candidate still has to preserve
        # the complete closed 2-manifold topology, create no new invalid pair, and
        # remove at least one existing invalid pair.
        def repair_grid_invalid_near_edge_splits(triangle_records)
          flipped, flip_report = repair_grid_invalid_near_edge_owner_flips(
            triangle_records
          )
          repaired, split_report =
            repair_grid_invalid_near_edge_splits_before_owner_flip_v2(flipped)

          flip_count = flip_report[:accepted_flip_count].to_i
          split_count = split_report[:accepted_split_count].to_i
          attempted = flip_report[:attempted_flip_count].to_i +
            split_report[:attempted_split_count].to_i
          initial_invalid = flip_report[:initial_invalid_pair_count].to_i
          final_invalid = split_report[:final_invalid_pair_count].to_i
          any_repair = flip_count.positive? || split_count.positive?

          combined = split_report.merge(
            policy: :near_edge_owner_flip_then_grid_near_edge_split,
            input_triangle_count: triangle_records.length,
            output_triangle_count: repaired.length,
            initial_invalid_pair_count: initial_invalid,
            final_invalid_pair_count: final_invalid,
            invalid_pair_reduction: initial_invalid - final_invalid,
            attempted_split_count: attempted,
            accepted_split_count: flip_count + split_count,
            accepted_near_edge_owner_flip_count: flip_count,
            near_edge_owner_flip_repair: flip_report,
            affected_source_face_keys: (
              Array(flip_report[:affected_source_face_keys]) +
              Array(split_report[:affected_source_face_keys])
            ).compact.uniq,
            skipped: !any_repair,
            skip_reason: any_repair ? nil : :no_safe_near_edge_owner_flip_or_split
          )

          [repaired, combined]
        end

        def repair_grid_invalid_near_edge_owner_flips(triangle_records)
          initial_invalid = grid_invalid_pair_signatures(triangle_records)
          if initial_invalid.empty?
            return [
              triangle_records,
              empty_grid_near_edge_owner_flip_report(
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
            break if attempted >= GRID_NEAR_EDGE_OWNER_FLIP_MAX_ATTEMPTS

            invalid_pairs = grid_invalid_pairs(working)
            candidates = grid_near_edge_owner_flip_candidates(working, invalid_pairs)
            break if candidates.empty?

            best = nil
            candidates.each do |candidate|
              break if attempted >= GRID_NEAR_EDGE_OWNER_FLIP_MAX_ATTEMPTS

              attempted += 1
              begin
                tentative, details = apply_grid_near_edge_owner_flip_candidate(
                  working,
                  candidate
                )
                validate_normalized_triangle_topology!(tentative)

                tentative_invalid = grid_invalid_pair_signatures(tentative)
                new_invalid = tentative_invalid - current_invalid
                removed_invalid = current_invalid - tentative_invalid

                unless new_invalid.empty?
                  attempts << near_edge_owner_flip_attempt_report(
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
                  attempts << near_edge_owner_flip_attempt_report(
                    candidate,
                    accepted: false,
                    reason: :invalid_pairs_not_reduced,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length
                  )
                  next
                end

                report = near_edge_owner_flip_attempt_report(
                  candidate,
                  accepted: true,
                  before_invalid_pair_count: current_invalid.length,
                  after_invalid_pair_count: tentative_invalid.length,
                  removed_invalid_pair_count: removed_invalid.length,
                  replacement_triangle_count: details[:replacement_triangle_count],
                  affected_source_face_keys: details[:affected_source_face_keys]
                )
                score = [
                  removed_invalid.length,
                  -candidate[:distance_mm],
                  candidate[:edge_key],
                  candidate[:point_key]
                ]
                best = [score, tentative, tentative_invalid, report] if
                  best.nil? || (score <=> best[0]) == 1
              rescue Error, ArgumentError => error
                attempts << near_edge_owner_flip_attempt_report(
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
              policy: :invalid_pair_driven_near_edge_owner_flip,
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
              skip_reason: accepted.empty? ? :no_safe_near_edge_owner_flip : nil
            }
          ]
        end

        def empty_grid_near_edge_owner_flip_report(
          triangle_count,
          invalid_pair_count,
          reason
        )
          {
            policy: :invalid_pair_driven_near_edge_owner_flip,
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

        def grid_near_edge_owner_flip_candidates(records, invalid_pairs)
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, index|
            next if degenerate_triangle_record?(record)

            triangle = record[:points].map { |point| grid_indices(point) }
            exact_triangle_edge_keys(triangle).each do |edge|
              edge_owners[edge] << index
            end
          end

          invalid_lookup = invalid_pairs.each_with_object({}) do |pair, lookup|
            lookup[pair.sort] = true
          end
          candidates = {}

          invalid_pairs.each do |first_index, second_index|
            grid_near_edge_owner_flip_candidates_between_records(
              records,
              records[first_index],
              records[second_index],
              first_index,
              second_index,
              edge_owners,
              invalid_lookup,
              candidates
            )
            grid_near_edge_owner_flip_candidates_between_records(
              records,
              records[second_index],
              records[first_index],
              second_index,
              first_index,
              edge_owners,
              invalid_lookup,
              candidates
            )
          end

          candidates.values.sort_by do |candidate|
            [
              candidate[:distance_mm],
              candidate[:edge_key],
              candidate[:point_key]
            ]
          end
        end

        def grid_near_edge_owner_flip_candidates_between_records(
          records,
          point_record,
          edge_record,
          point_record_index,
          edge_record_index,
          edge_owners,
          invalid_lookup,
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
              next unless invalid_lookup[owner_indices.sort]

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
              source_face_key = thin_owner[:source_face_key]
              next if source_face_key.nil?
              next unless wide_owner[:source_face_key] == source_face_key

              begin
                thin_plane = exact_integer_plane_key(
                  thin_owner[:points].map { |entry| grid_indices(entry) }
                )
                wide_plane = exact_integer_plane_key(
                  wide_owner[:points].map { |entry| grid_indices(entry) }
                )
                next unless thin_plane == wide_plane
              rescue Error, ArgumentError
                next
              end

              key = [edge_key, point_key]
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
                owner_indices: owner_indices,
                thin_owner_index: thin_owner_index,
                wide_owner_index: wide_owner_index,
                source_face_key: source_face_key,
                trigger_pairs: [trigger]
              }
            end
          end
        end

        def apply_grid_near_edge_owner_flip_candidate(records, candidate)
          edge_key = candidate[:edge_key]
          point_key = candidate[:point_key]
          thin_index = candidate[:thin_owner_index]
          wide_index = candidate[:wide_owner_index]
          thin = records.fetch(thin_index)
          wide = records.fetch(wide_index)

          thin_points = thin[:points]
          wide_points = wide[:points]
          point = thin_points.find { |entry| grid_indices(entry) == point_key }
          unless point
            raise ReconstructionError,
                  "Near-edge owner flip lost its opposite point: #{point_key.inspect}"
          end

          wide_by_key = wide_points.each_with_object({}) do |entry, map|
            map[grid_indices(entry)] = entry
          end
          edge_start = wide_by_key[edge_key[0]]
          edge_end = wide_by_key[edge_key[1]]
          unless edge_start && edge_end
            raise ReconstructionError,
                  "Near-edge owner flip lost its host edge: #{edge_key.inspect}"
          end
          opposite = wide_points.find do |entry|
            key = grid_indices(entry)
            key != edge_key[0] && key != edge_key[1]
          end
          unless opposite
            raise ReconstructionError,
                  "Near-edge owner flip host triangle has no opposite vertex"
          end

          replacements = [
            wide.merge(
              points: orient_patch_triangle(
                [edge_start, point, opposite],
                wide[:source_normal]
              ),
              source_polygon_index: thin[:source_polygon_index],
              grid_near_edge_owner_flip_repaired: true
            ),
            wide.merge(
              points: orient_patch_triangle(
                [point, edge_end, opposite],
                wide[:source_normal]
              ),
              source_polygon_index: wide[:source_polygon_index],
              grid_near_edge_owner_flip_repaired: true
            )
          ]
          if replacements.any? { |entry| degenerate_triangle_record?(entry) }
            raise ReconstructionError,
                  "Near-edge owner flip produced a degenerate triangle: " \
                  "edge=#{edge_key.inspect} point=#{point_key.inspect}"
          end

          old_boundary = grid_triangle_patch_boundary_edges([thin, wide])
          new_boundary = grid_triangle_patch_boundary_edges(replacements)
          unless old_boundary == new_boundary
            raise TopologyChangedError,
                  "Near-edge owner flip changed its local boundary: " \
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
              affected_source_face_keys: [candidate[:source_face_key]].compact
            }
          ]
        end

        def grid_triangle_patch_boundary_edges(patch_records)
          incidence = Hash.new(0)
          patch_records.each do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            exact_triangle_edge_keys(triangle).each do |edge|
              incidence[edge] += 1
            end
          end
          incidence.filter_map { |edge, count| edge if count == 1 }.sort
        end

        def near_edge_owner_flip_attempt_report(candidate, **details)
          {
            edge: candidate[:edge_key],
            point: candidate[:point_key],
            distance_mm: candidate[:distance_mm],
            parameter: candidate[:parameter],
            owner_indices: candidate[:owner_indices],
            thin_owner_index: candidate[:thin_owner_index],
            wide_owner_index: candidate[:wide_owner_index],
            source_face_key: candidate[:source_face_key],
            trigger_pairs: candidate[:trigger_pairs],
            affected_source_face_keys: [candidate[:source_face_key]].compact
          }.merge(details)
        end
      end
    end
  end
end
