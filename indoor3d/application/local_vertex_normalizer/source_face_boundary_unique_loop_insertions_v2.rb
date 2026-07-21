# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(
          :source_boundary_common_refinement_splits_before_unique_loop_v2
        )
          alias_method(
            :source_boundary_common_refinement_splits_before_unique_loop_v2,
            :source_boundary_common_refinement_splits
          )
        end

        # A simple Face loop may contain each source vertex only once (apart from
        # the implicit closing edge). Pairwise overlap discovery can otherwise add
        # a contributor endpoint to a host edge even when that endpoint already
        # occurs elsewhere in the host loop, or can assign the same new endpoint
        # to several near-coincident host edges. Both cases create an invalid loop
        # that no coordinate-only grid-target search can repair because every
        # occurrence shares the same source key and therefore moves together.
        #
        # Preserve common refinement while enforcing one insertion owner per
        # [Face, loop, source key]:
        #   * never insert a key already present in the original host loop;
        #   * when several host edges compete for one new key, keep the closest,
        #     strongest-overlap, most-interior candidate deterministically.
        def source_boundary_common_refinement_splits(edges)
          split_entries, relations =
            source_boundary_common_refinement_splits_before_unique_loop_v2(edges)

          original_keys_by_loop = Hash.new do |hash, key|
            hash[key] = {}
          end
          edges.each do |edge|
            loop_key = [edge[:face_key], edge[:loop_index]]
            original_keys_by_loop[loop_key][
              edge[:first][:source_key]
            ] = true
          end

          candidates = Hash.new { |hash, key| hash[key] = [] }
          suppressed_existing = 0

          split_entries.each do |edge_index, entries|
            edge = edges.fetch(edge_index)
            loop_key = [edge[:face_key], edge[:loop_index]]

            Array(entries).each do |entry|
              source_key = entry[:point_entry][:source_key]
              if original_keys_by_loop[loop_key][source_key]
                suppressed_existing += 1
                next
              end

              candidates[[*loop_key, source_key]] << [edge_index, entry]
            end
          end

          filtered = Hash.new { |hash, key| hash[key] = [] }
          selected_lookup = {}
          suppressed_competing = 0

          candidates.each do |(_face_key, _loop_index, source_key), choices|
            edge_index, entry = choices.min_by do |candidate_edge_index, candidate|
              parameter = candidate[:source_parameter].to_f
              endpoint_clearance = [parameter, 1.0 - parameter].min
              [
                candidate[:source_distance_mm].to_f,
                -candidate[:overlap_length_mm].to_f,
                -endpoint_clearance,
                candidate_edge_index
              ]
            end

            filtered[edge_index] << entry
            selected_lookup[[edge_index, source_key]] = true
            suppressed_competing += choices.length - 1
          end

          filtered.each_value do |entries|
            entries.sort_by! do |entry|
              [
                entry[:source_parameter].to_f,
                entry[:source_distance_mm].to_f,
                entry[:point_entry][:source_key]
              ]
            end
          end

          filtered_relations = relations.select do |entry|
            selected_lookup[[
              entry[:host_edge_index],
              entry[:inserted_source_key]
            ]]
          end

          @source_boundary_unique_loop_insertion_report = {
            suppressed_existing_loop_vertex_count: suppressed_existing,
            suppressed_competing_edge_count: suppressed_competing,
            selected_insertion_count:
              filtered.values.sum(&:length)
          }

          [filtered, filtered_relations]
        end
      end
    end
  end
end
