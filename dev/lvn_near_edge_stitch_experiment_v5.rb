# frozen_string_literal: true

# v5: minimum-valid-local-patch repair experiment.
#
# v4 proved whole same-source/same-plane connected components can be too broad:
# s8vadud8 produced a 131-triangle patch whose *subset boundary* was branched far
# away from the actual invalid intersection. This version therefore starts from
# an exact-invalid near-edge host relation and grows only its local exact-coplanar
# neighborhood until a preserved-boundary retriangulation is both valid and
# improves the complete mesh.
#
# Production LVN remains untouched. This file only reopens the experimental
# subclass and is intended for copied/unique selected solids.

load File.join(__dir__, 'lvn_near_edge_stitch_experiment_v4.rb')

module LvnNearEdgeStitchExperiment
  class StitchNormalizer
    LOCAL_PATCH_MAX_RINGS = 16 unless const_defined?(:LOCAL_PATCH_MAX_RINGS, false)
    LOCAL_PATCH_MAX_TRIANGLES = 80 unless const_defined?(:LOCAL_PATCH_MAX_TRIANGLES, false)
    LOCAL_PATCH_MAX_ACCEPTED_REPAIRS = 20 unless
      const_defined?(:LOCAL_PATCH_MAX_ACCEPTED_REPAIRS, false)

    private

    def collapse_short_edge_sliver_triangles(records, plan, baseline_inventory)
      # Call production short-edge logic. The v1-v4 experimental override is
      # intentionally replaced here; Ruby's super dispatches to LVN's superclass
      # implementation, not the previous definition in this same subclass.
      collapsed, short_edge_report = super
      repaired, @near_edge_stitch_report =
        repair_intersection_local_patches(collapsed)
      [repaired, short_edge_report]
    end

    def repair_intersection_local_patches(records)
      working = records.dup
      initial_invalid = invalid_pair_signatures(working)
      initial_low = low_altitude_signatures(working)
      attempts = []
      accepted = []

      if initial_invalid.empty?
        return [
          working,
          local_patch_report(
            records,
            working,
            initial_invalid,
            initial_invalid,
            initial_low,
            initial_low,
            accepted,
            attempts,
            :no_invalid_intersections
          )
        ]
      end

      LOCAL_PATCH_MAX_ACCEPTED_REPAIRS.times do
        current_invalid = invalid_pair_signatures(working)
        break if current_invalid.empty?

        candidates = stitch_host_edge_candidates(working)
        break if candidates.empty?

        best = nil

        candidates.each_value do |candidate|
          options = local_patch_options(working, candidate)
          if options.empty?
            attempts << local_candidate_summary(candidate).merge(
              accepted: false,
              reason: :no_local_patch_options
            )
            next
          end

          options.each do |option|
            patch_indices = option[:indices]
            patch_records = patch_indices.map { |index| working[index] }

            begin
              replacements, details = retriangulate_exact_coplanar_patch(patch_records)

              if same_grid_triangle_set?(patch_records, replacements)
                attempts << local_candidate_summary(candidate).merge(
                  accepted: false,
                  reason: :same_triangle_set,
                  ring: option[:ring],
                  patch_triangle_count: patch_indices.length
                )
                next
              end

              tentative = replace_grid_patch(working, patch_indices, replacements)

              # Full-mesh combinatorial invariants are checked before any
              # intersection acceptance decision.
              validate_normalized_triangle_shapes!(tentative)
              validate_normalized_triangle_topology!(tentative)

              tentative_invalid = invalid_pair_signatures(tentative)
              new_invalid = tentative_invalid - current_invalid
              removed_invalid = current_invalid - tentative_invalid

              unless new_invalid.empty?
                attempts << local_candidate_summary(candidate).merge(
                  accepted: false,
                  reason: :new_invalid_pairs,
                  ring: option[:ring],
                  patch_triangle_count: patch_indices.length,
                  replacement_triangle_count: replacements.length,
                  before_invalid_pair_count: current_invalid.length,
                  after_invalid_pair_count: tentative_invalid.length,
                  new_invalid_pair_count: new_invalid.length,
                  removed_invalid_pair_count: removed_invalid.length
                )
                next
              end

              if removed_invalid.empty?
                attempts << local_candidate_summary(candidate).merge(
                  accepted: false,
                  reason: :intersection_not_improved,
                  ring: option[:ring],
                  patch_triangle_count: patch_indices.length,
                  replacement_triangle_count: replacements.length,
                  before_invalid_pair_count: current_invalid.length,
                  after_invalid_pair_count: tentative_invalid.length
                )
                next
              end

              before_low = low_altitude_signatures(working)
              after_low = low_altitude_signatures(tentative)
              new_low = after_low - before_low

              unless new_low.empty?
                attempts << local_candidate_summary(candidate).merge(
                  accepted: false,
                  reason: :new_low_altitude_triangles,
                  ring: option[:ring],
                  patch_triangle_count: patch_indices.length,
                  replacement_triangle_count: replacements.length,
                  before_low_altitude_count: before_low.length,
                  after_low_altitude_count: after_low.length,
                  new_low_altitude_count: new_low.length
                )
                next
              end

              detail = local_candidate_summary(candidate).merge(
                accepted: true,
                ring: option[:ring],
                patch_triangle_count: patch_indices.length,
                replacement_triangle_count: replacements.length,
                before_invalid_pair_count: current_invalid.length,
                after_invalid_pair_count: tentative_invalid.length,
                removed_invalid_pair_count: removed_invalid.length,
                before_low_altitude_count: before_low.length,
                after_low_altitude_count: after_low.length,
                boundary_loops: details[:boundary_loops],
                holes: details[:holes]
              )

              # Primary goal: remove as many exact invalid pairs as possible.
              # For equal improvement, prefer the smallest/closest local patch,
              # then prefer reducing low-altitude triangles.
              score = [
                removed_invalid.length,
                -patch_indices.length,
                -option[:ring],
                before_low.length - after_low.length
              ]

              entry = {
                score: score,
                records: tentative,
                invalid: tentative_invalid,
                detail: detail
              }
              best = entry if best.nil? || (score <=> best[:score]) == 1

              # This ring is already a valid improving repair for this candidate.
              # Larger rings are less local, so do not consider them for the same
              # host relation.
              break
            rescue Error, ArgumentError => error
              attempts << local_candidate_summary(candidate).merge(
                accepted: false,
                reason: :local_retriangulation_rejected,
                ring: option[:ring],
                patch_triangle_count: patch_indices.length,
                error: "#{error.class}: #{error.message}"
              )
            end
          end
        end

        break unless best

        working = best[:records]
        accepted << best[:detail]
        attempts << best[:detail]
      end

      final_invalid = invalid_pair_signatures(working)
      final_low = low_altitude_signatures(working)
      skip_reason = if accepted.empty?
                      :no_safe_improving_local_patch
                    elsif final_invalid.empty?
                      nil
                    else
                      :remaining_invalid_intersections
                    end

      [
        working,
        local_patch_report(
          records,
          working,
          initial_invalid,
          final_invalid,
          initial_low,
          final_low,
          accepted,
          attempts,
          skip_reason
        )
      ]
    end

    # Builds a sequence of increasingly large local patches around one safe
    # near-edge host relation. Every triangle belongs to the same source face and
    # exact-coplanar patch as the host owners. The seed consists of:
    # - both host-edge owners, and
    # - same-patch triangles already using the candidate point C.
    #
    # The latter is important for s8vadud8: C is supplied by another surface in
    # the triggering invalid pair, but the horizontal host patch also contains C
    # elsewhere in its existing triangulation chain.
    def local_patch_options(records, candidate)
      group_indices = records.each_index.select do |index|
        record = records[index]
        next false if degenerate_triangle_record?(record)
        next false unless record[:source_face_key] == candidate[:source_face_key]

        exact_coplanar_patch_key(record) == candidate[:exact_patch_key]
      end
      return [] if group_indices.length < 2

      group_lookup = group_indices.to_h { |index| [index, true] }
      edge_owners = Hash.new { |hash, key| hash[key] = [] }
      triangle_keys = {}

      group_indices.each do |index|
        triangle = records[index][:points].map { |point| grid_indices(point) }
        triangle_keys[index] = triangle
        exact_triangle_edge_keys(triangle).each do |edge|
          edge_owners[edge] << index
        end
      end

      adjacency = Hash.new { |hash, key| hash[key] = [] }
      group_indices.each { |index| adjacency[index] }
      edge_owners.each_value do |owners|
        owners.uniq.combination(2) do |first, second|
          adjacency[first] << second
          adjacency[second] << first
        end
      end
      adjacency.each_value(&:uniq!)

      candidate_key = candidate[:points].values.first[:key]
      seed = candidate[:owners].select { |index| group_lookup[index] }
      seed.concat(
        group_indices.select do |index|
          triangle_keys.fetch(index).include?(candidate_key)
        end
      )
      seed.uniq!
      return [] if seed.empty?

      current = seed.to_h { |index| [index, true] }
      frontier = seed.dup
      options = []
      seen_signatures = {}

      0.upto(LOCAL_PATCH_MAX_RINGS) do |ring|
        indices = current.keys.sort
        break if indices.length > LOCAL_PATCH_MAX_TRIANGLES

        if indices.length >= 2
          signature = indices.join(',')
          unless seen_signatures[signature]
            options << {
              ring: ring,
              indices: indices
            }
            seen_signatures[signature] = true
          end
        end

        next_frontier = frontier.flat_map do |index|
          adjacency.fetch(index, [])
        end.reject { |index| current[index] }.uniq
        break if next_frontier.empty?

        next_frontier.each { |index| current[index] = true }
        frontier = next_frontier
      end

      options
    rescue Error, ArgumentError
      []
    end

    def local_candidate_summary(candidate)
      base = candidate_summary(candidate)
      point_entry = candidate[:points].values.first
      base.merge(
        candidate_point: point_entry && point_entry[:key],
        candidate_t: point_entry && point_entry[:t].to_f,
        candidate_distance_mm: point_entry && point_entry[:distance_mm]
      )
    end

    def local_patch_report(
      input_records,
      output_records,
      initial_invalid,
      final_invalid,
      initial_low,
      final_low,
      accepted,
      attempts,
      skip_reason
    )
      {
        policy: :intersection_triggered_minimum_valid_local_patch_retriangulation,
        threshold_mm: @tolerance_mm,
        input_triangle_count: input_records.length,
        output_triangle_count: output_records.length,
        initial_invalid_pair_count: initial_invalid.length,
        final_invalid_pair_count: final_invalid.length,
        invalid_pair_reduction: initial_invalid.length - final_invalid.length,
        initial_low_altitude_count: initial_low.length,
        final_low_altitude_count: final_low.length,
        accepted_stitch_count: accepted.length,
        accepted_stitches: accepted.first(20),
        attempts: attempts.first(100),
        skipped: accepted.empty?,
        skip_reason: skip_reason,
        local_patch_max_rings: LOCAL_PATCH_MAX_RINGS,
        local_patch_max_triangles: LOCAL_PATCH_MAX_TRIANGLES
      }
    end
  end
end

nil
