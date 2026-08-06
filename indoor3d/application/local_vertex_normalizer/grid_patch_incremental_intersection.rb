# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Avoids rescanning unchanged triangle pairs while evaluating a tentative
      # grid-space patch replacement. The optimization is scoped to one
      # normalize_entity call and never changes the exact intersection predicate.
      module LocalVertexNormalizerGridPatchIncrementalIntersection
        GRID_PATCH_INCREMENTAL_MIN_TRIANGLES = 64

        private

        def normalize_entity(entity)
          previous_cache = @local_vertex_normalizer_grid_invalid_signature_cache
          previous_stats = @local_vertex_normalizer_grid_patch_incremental_stats
          @local_vertex_normalizer_grid_invalid_signature_cache = {}
          @local_vertex_normalizer_grid_patch_incremental_stats = {
            signature_calls: 0,
            memo_hits: 0,
            full_scans: 0,
            incremental_calls: 0,
            duplicate_key_fallbacks: 0,
            reused_invalid_signatures: 0,
            replacement_triangles: 0,
            unchanged_triangles: 0,
            candidate_pair_space: 0,
            broad_phase_candidates: 0,
            exact_calls: 0,
            added_invalid_signatures: 0
          }

          super
        ensure
          stats = @local_vertex_normalizer_grid_patch_incremental_stats
          cache = @local_vertex_normalizer_grid_invalid_signature_cache
          if stats && @local_vertex_normalizer_diagnostic_profile &&
             respond_to?(:diagnostic_profile_log, true)
            diagnostic_profile_log(
              "WORK grid_patch_incremental_intersection " \
              "signature_calls=#{stats[:signature_calls]} " \
              "memo_hits=#{stats[:memo_hits]} full_scans=#{stats[:full_scans]} " \
              "incremental_calls=#{stats[:incremental_calls]} " \
              "duplicate_key_fallbacks=#{stats[:duplicate_key_fallbacks]} " \
              "reused_invalid=#{stats[:reused_invalid_signatures]} " \
              "replacements=#{stats[:replacement_triangles]} " \
              "unchanged=#{stats[:unchanged_triangles]} " \
              "pair_space=#{stats[:candidate_pair_space]} " \
              "broad_phase_candidates=#{stats[:broad_phase_candidates]} " \
              "exact_calls=#{stats[:exact_calls]} " \
              "added_invalid=#{stats[:added_invalid_signatures]} " \
              "entries=#{cache&.length.to_i}"
            )
          end
          @local_vertex_normalizer_grid_invalid_signature_cache = previous_cache
          @local_vertex_normalizer_grid_patch_incremental_stats = previous_stats
        end

        def replace_grid_patch(records, patch_indices, replacements)
          result = super
          cache = @local_vertex_normalizer_grid_invalid_signature_cache
          return result unless cache && records.length >= GRID_PATCH_INCREMENTAL_MIN_TRIANGLES

          base_key, unique = grid_patch_active_mesh_key(records)
          context = {
            base_records: records,
            base_key: base_key,
            base_unique_triangle_keys: unique,
            patch_indices: patch_indices.dup.freeze,
            replacements: replacements
          }
          result.instance_variable_set(:@lvn_grid_patch_incremental_context, context)
          result
        end

        def grid_invalid_pair_signatures(records)
          cache = @local_vertex_normalizer_grid_invalid_signature_cache
          stats = @local_vertex_normalizer_grid_patch_incremental_stats
          return super unless cache && stats &&
                              records.length >= GRID_PATCH_INCREMENTAL_MIN_TRIANGLES

          stats[:signature_calls] += 1
          mesh_key, unique = grid_patch_active_mesh_key(records)
          cached = cache[mesh_key]
          if cached
            stats[:memo_hits] += 1
            return grid_patch_invalid_signatures_dup(cached)
          end

          context = records.instance_variable_get(:@lvn_grid_patch_incremental_context)
          if context && context[:base_unique_triangle_keys] && unique
            base_invalid = cache[context[:base_key]]
            if base_invalid
              result = grid_patch_incremental_invalid_signatures(
                context,
                base_invalid,
                stats
              )
              stored = grid_patch_invalid_signatures_store(result)
              cache[mesh_key] = stored
              stats[:incremental_calls] += 1
              return grid_patch_invalid_signatures_dup(stored)
            end
          elsif context
            stats[:duplicate_key_fallbacks] += 1
          end

          result = super
          cache[mesh_key] = grid_patch_invalid_signatures_store(result)
          stats[:full_scans] += 1
          result
        end

        def grid_patch_incremental_invalid_signatures(context, base_invalid, stats)
          base_records = context.fetch(:base_records)
          patch_indices = context.fetch(:patch_indices)
          replacements = context.fetch(:replacements)
          patch_lookup = patch_indices.to_h { |index| [index, true] }

          removed_triangle_keys = patch_indices.filter_map do |index|
            grid_patch_active_triangle_key(base_records[index])
          end.to_h { |key| [key, true] }

          retained = base_invalid.reject do |signature|
            removed_triangle_keys.key?(signature[0]) ||
              removed_triangle_keys.key?(signature[1])
          end
          stats[:reused_invalid_signatures] += retained.length

          unchanged_triangles = base_records.each_index.filter_map do |index|
            next if patch_lookup[index]

            grid_patch_active_integer_triangle(base_records[index])
          end
          replacement_triangles = replacements.filter_map do |record|
            grid_patch_active_integer_triangle(record)
          end

          stats[:replacement_triangles] += replacement_triangles.length
          stats[:unchanged_triangles] += unchanged_triangles.length
          stats[:candidate_pair_space] +=
            replacement_triangles.length * unchanged_triangles.length +
            (replacement_triangles.length * (replacement_triangles.length - 1) / 2)

          triangles = unchanged_triangles + replacement_triangles
          aabbs = triangles.map { |triangle| integer_triangle_aabb(triangle) }
          replacement_start = unchanged_triangles.length
          added = []

          # Reuse the kernel sweep broad phase across the complete tentative mesh,
          # but discard unchanged/unchanged candidates before the exact predicate.
          # This preserves exactly the same replacement-related pair set as the
          # previous nested AABB loops without scanning their full Cartesian space.
          each_overlapping_integer_aabb_pair(aabbs) do |index_a, index_b|
            next if index_a < replacement_start && index_b < replacement_start

            stats[:broad_phase_candidates] += 1
            stats[:exact_calls] += 1
            triangle_a = triangles[index_a]
            triangle_b = triangles[index_b]
            next if exact_triangle_intersection_allowed?(triangle_a, triangle_b)

            added << grid_patch_invalid_pair_signature(triangle_a, triangle_b)
          end

          added.uniq!
          stats[:added_invalid_signatures] += added.length
          (retained + added).uniq.sort
        end

        def grid_patch_active_mesh_key(records)
          keys = records.filter_map do |record|
            grid_patch_active_triangle_key(record)
          end.sort
          unique = keys.each_cons(2).none? { |first, second| first == second }
          [grid_patch_freeze_mesh_key(keys), unique]
        end

        def grid_patch_active_triangle_key(record)
          triangle = grid_patch_active_integer_triangle(record)
          triangle && canonical_triangle_key(triangle)
        end

        def grid_patch_active_integer_triangle(record)
          return nil unless record
          return nil if degenerate_triangle_record?(record)

          record[:points].map { |point| grid_indices(point) }
        end

        def grid_patch_invalid_pair_signature(triangle_a, triangle_b)
          [
            canonical_triangle_key(triangle_a),
            canonical_triangle_key(triangle_b)
          ].sort
        end

        def grid_patch_freeze_mesh_key(keys)
          keys.map do |triangle|
            triangle.map { |point| point.dup.freeze }.freeze
          end.freeze
        end

        def grid_patch_invalid_signatures_store(signatures)
          Array(signatures).map do |signature|
            signature.map do |triangle|
              triangle.map { |point| point.dup.freeze }.freeze
            end.freeze
          end.freeze
        end

        def grid_patch_invalid_signatures_dup(signatures)
          signatures.map do |signature|
            signature.map do |triangle|
              triangle.map(&:dup)
            end
          end
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerGridPatchIncrementalIntersection unless
          ancestors.include?(LocalVertexNormalizerGridPatchIncrementalIntersection)
      end
    end
  end
end
