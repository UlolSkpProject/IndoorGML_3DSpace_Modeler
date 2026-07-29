# frozen_string_literal: true

# Diagnostic-only wrapper for the experimental near-edge repair layers.
# It does not change candidate selection or geometry. It only prints why a
# failing exact intersection does or does not produce repair candidates.
#
# SketchUp Ruby Console:
#   load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_near_edge_failure_probe.rb'
#   LvnNearEdgeFailureProbe.run

root = File.expand_path('..', __dir__)
require File.join(root, 'indoor3d', 'application', 'local_vertex_normalizer') unless
  defined?(ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer)
load File.join(root, 'dev', 'lvn_normalize_selected_solids.rb') unless
  defined?(LvnNormalizeSelectedSolids)

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(:grid_near_edge_owner_flip_candidates_before_failure_probe_v2)
          alias_method :grid_near_edge_owner_flip_candidates_before_failure_probe_v2,
                       :grid_near_edge_owner_flip_candidates

          def grid_near_edge_owner_flip_candidates(records, invalid_pairs)
            candidates = grid_near_edge_owner_flip_candidates_before_failure_probe_v2(
              records,
              invalid_pairs
            )
            diagnostics = near_edge_failure_probe_relations(records, invalid_pairs)
            puts format(
              '[LVN NEAR EDGE PROBE] invalid=%d near_relations=%d owner_flip_candidates=%d',
              invalid_pairs.length,
              diagnostics.length,
              candidates.length
            )
            diagnostics.first(12).each_with_index do |entry, index|
              puts format(
                '[LVN NEAR EDGE PROBE] relation=%d pair=%s point=%s edge=%s d=%.9fmm owners=%s containing=%s source_faces=%s same_source=%s same_plane=%s',
                index + 1,
                entry[:invalid_pair].inspect,
                entry[:point_key].inspect,
                entry[:edge_key].inspect,
                entry[:distance_mm],
                entry[:owner_indices].inspect,
                entry[:containing_owner_indices].inspect,
                entry[:owner_source_face_keys].inspect,
                entry[:same_source_face],
                entry[:same_exact_plane]
              )
            end
            candidates.first(8).each_with_index do |candidate, index|
              puts format(
                '[LVN NEAR EDGE PROBE] flip_candidate=%d point=%s edge=%s d=%.9fmm owners=%s source_face=%s',
                index + 1,
                candidate[:point_key].inspect,
                candidate[:edge_key].inspect,
                candidate[:distance_mm],
                candidate[:owner_indices].inspect,
                candidate[:source_face_key].inspect
              )
            end
            candidates
          end
        end

        unless private_method_defined?(:grid_near_edge_split_candidates_before_failure_probe_v2)
          alias_method :grid_near_edge_split_candidates_before_failure_probe_v2,
                       :grid_near_edge_split_candidates

          def grid_near_edge_split_candidates(records, invalid_pairs)
            candidates = grid_near_edge_split_candidates_before_failure_probe_v2(
              records,
              invalid_pairs
            )
            puts format(
              '[LVN NEAR EDGE PROBE] plain_split_candidates=%d',
              candidates.length
            )
            candidates.first(8).each_with_index do |candidate, index|
              puts format(
                '[LVN NEAR EDGE PROBE] split_candidate=%d point=%s edge=%s d=%.9fmm owners=%s',
                index + 1,
                candidate[:point_key].inspect,
                candidate[:edge_key].inspect,
                candidate[:distance_mm],
                candidate[:owner_indices].inspect
              )
            end
            candidates
          end
        end

        unless private_method_defined?(:repair_grid_invalid_near_edge_splits_before_failure_probe_v2)
          alias_method :repair_grid_invalid_near_edge_splits_before_failure_probe_v2,
                       :repair_grid_invalid_near_edge_splits

          def repair_grid_invalid_near_edge_splits(triangle_records)
            repaired, report = repair_grid_invalid_near_edge_splits_before_failure_probe_v2(
              triangle_records
            )
            flip = report[:near_edge_owner_flip_repair] || {}
            puts format(
              '[LVN NEAR EDGE PROBE] result invalid=%s->%s flip=%s/%s split_total=%s/%s skipped=%s reason=%s',
              report[:initial_invalid_pair_count],
              report[:final_invalid_pair_count],
              flip[:accepted_flip_count],
              flip[:attempted_flip_count],
              report[:accepted_split_count],
              report[:attempted_split_count],
              report[:skipped],
              report[:skip_reason]
            )
            Array(flip[:attempts]).first(8).each_with_index do |attempt, index|
              puts format(
                '[LVN NEAR EDGE PROBE] flip_attempt=%d accepted=%s reason=%s edge=%s point=%s error=%s',
                index + 1,
                attempt[:accepted],
                attempt[:reason],
                attempt[:edge].inspect,
                attempt[:point].inspect,
                attempt[:error]
              )
            end
            [repaired, report]
          end
        end

        def near_edge_failure_probe_relations(records, invalid_pairs)
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, index|
            next if degenerate_triangle_record?(record)

            triangle = record[:points].map { |point| grid_indices(point) }
            exact_triangle_edge_keys(triangle).each { |edge| edge_owners[edge] << index }
          end

          relations = []
          invalid_pairs.each do |first_index, second_index|
            [
              [first_index, second_index],
              [second_index, first_index]
            ].each do |point_index, edge_index|
              point_record = records.fetch(point_index)
              edge_record = records.fetch(edge_index)
              point_record[:points].each do |point|
                point_key = grid_indices(point)
                3.times do |local_edge_index|
                  edge_start = edge_record[:points][local_edge_index]
                  edge_end = edge_record[:points][(local_edge_index + 1) % 3]
                  start_key = grid_indices(edge_start)
                  end_key = grid_indices(edge_end)
                  next if point_key == start_key || point_key == end_key

                  projection = grid_near_edge_projection(point, edge_start, edge_end)
                  next unless projection
                  next if projection[:distance_mm] > @tolerance_mm

                  edge_key = canonical_edge_key(start_key, end_key)
                  owners = Array(edge_owners[edge_key]).uniq.sort
                  containing = owners.select do |owner_index|
                    records.fetch(owner_index)[:points].any? do |owner_point|
                      grid_indices(owner_point) == point_key
                    end
                  end
                  source_faces = owners.map do |owner_index|
                    records.fetch(owner_index)[:source_face_key]
                  end
                  same_source = !source_faces.empty? &&
                    source_faces.compact.length == source_faces.length &&
                    source_faces.uniq.length == 1
                  same_plane = near_edge_failure_probe_same_exact_plane?(records, owners)

                  relations << {
                    invalid_pair: [first_index, second_index],
                    point_record_index: point_index,
                    edge_record_index: edge_index,
                    point_key: point_key,
                    edge_key: edge_key,
                    distance_mm: projection[:distance_mm],
                    parameter: projection[:parameter],
                    owner_indices: owners,
                    containing_owner_indices: containing,
                    owner_source_face_keys: source_faces,
                    same_source_face: same_source,
                    same_exact_plane: same_plane
                  }
                end
              end
            end
          end

          relations.sort_by do |entry|
            [entry[:distance_mm], entry[:invalid_pair], entry[:edge_key], entry[:point_key]]
          end
        end

        def near_edge_failure_probe_same_exact_plane?(records, owner_indices)
          return false if owner_indices.empty?

          planes = owner_indices.map do |owner_index|
            exact_integer_plane_key(
              records.fetch(owner_index)[:points].map { |point| grid_indices(point) }
            )
          end
          planes.uniq.length == 1
        rescue Error, ArgumentError
          false
        end
      end
    end
  end
end

module LvnNearEdgeFailureProbe
  module_function

  def run(tolerance_mm: ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer::DEFAULT_TOLERANCE_MM)
    puts '[LVN NEAR EDGE PROBE] diagnostic wrappers installed; geometry policy unchanged'
    LvnNormalizeSelectedSolids.run(tolerance_mm: tolerance_mm)
    nil
  end
end

nil
