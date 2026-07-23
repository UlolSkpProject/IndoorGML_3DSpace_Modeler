# frozen_string_literal: true

require_relative '../local_vertex_normalizer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module LocalVertexNormalization
          def is_vertex_locally_normalized?(target = nil, tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM)
            if target.is_a?(Numeric)
              tolerance_mm = target
              target = nil
            end
            targets = target.nil? ? valid_local_normalization_cell_spaces : Array(target)
            return false if targets.empty?

            targets.all? do |candidate|
              group = local_normalization_group(candidate)
              group && LocalVertexNormalizer.normalized?(group, tolerance_mm)
            end
          end

          alias vertex_locally_normalized? is_vertex_locally_normalized?

          def locally_unnormalized_cell_spaces(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil
          )
            targets = cell_spaces.nil? ? valid_local_normalization_cell_spaces : Array(cell_spaces).select do |cell_space|
              cell_space&.valid?
            end
            targets.reject do |cell_space|
              group = local_normalization_group(cell_space)
              group && LocalVertexNormalizer.normalized?(group, tolerance_mm)
            end
          end

          def ensure_vertices_locally_normalized_for_export(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil
          )
            targets = cell_spaces.nil? ? valid_local_normalization_cell_spaces : Array(cell_spaces).select do |cell_space|
              cell_space&.valid?
            end
            unnormalized = locally_unnormalized_cell_spaces(tolerance_mm, cell_spaces: targets)
            if unnormalized.empty?
              return {
                tolerance_mm: Float(tolerance_mm),
                cell_space_count: 0,
                already_normalized_cell_space_count: targets.length,
                skipped: true,
                cell_spaces: []
              }
            end

            report = local_vertex_normalize(tolerance_mm, cell_spaces: unnormalized)
            report[:already_normalized_cell_space_count] = targets.length - unnormalized.length
            report[:skipped] = false
            report
          end

          def local_vertex_normalize(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil
          )
            target_cell_spaces = cell_spaces.nil? ? valid_local_normalization_cell_spaces : Array(cell_spaces).select do |cell_space|
              cell_space&.valid?
            end
            raise 'No valid CellSpace found for local vertex normalization' if target_cell_spaces.empty?

            results = []
            topology_metrics = nil
            target_cell_spaces.each do |cell_space|
              with_indoor_model_operation("IndoorGML Local Vertex Normalize #{cell_space.id}") do
                sync do
                  group = cell_space.valid_sketchup_group
                  raise "CellSpace geometry unavailable: #{cell_space.id}" unless group

                  result = with_unlocked(group) do
                    with_local_normalization_active_path(group) do
                      begin
                        LocalVertexNormalizer.normalize(group, tolerance_mm)
                      rescue StandardError => e
                        raise e.class,
                              "CellSpace local vertex normalization failed: id=#{cell_space.id.inspect} " \
                              "name=#{group.respond_to?(:name) ? group.name.inspect : 'n/a'}: #{e.message}",
                              e.backtrace
                      end
                    end
                  end
                  result[:cell_space_id] = cell_space.id
                  results << result
                  remember_cell_space_change_snapshot(cell_space.sketchup_group)
                end
              end
            end

            with_indoor_model_operation('IndoorGML Local Vertex Normalize Topology Sync') do
              sync do
                topology_metrics = topology_coordinator.synchronize_all
              end
            end

            invalidate_overlay_transition_points
            model = @model || Sketchup.active_model
            model.active_view.invalidate if model&.active_view

            report = {
              tolerance_mm: Float(tolerance_mm),
              cell_space_count: results.length,
              vertex_count: results.sum { |row| row[:vertex_count].to_i },
              moved_vertex_count: results.sum { |row| row[:moved_vertex_count].to_i },
              max_displacement_mm: results.map { |row| row[:max_displacement_mm].to_f }.max || 0.0,
              max_grid_residual_mm: results.map { |row| row[:max_grid_residual_mm].to_f }.max || 0.0,
              max_unprotected_grid_residual_mm: results.map { |row| row[:max_unprotected_grid_residual_mm].to_f }.max || 0.0,
              protected_coincident_vertex_count: results.sum { |row| row[:protected_coincident_vertex_count].to_i },
              incomplete_cell_space_count: results.count { |row| row[:normalization_complete] == false },
              max_normalization_passes: results.map { |row| Array(row[:normalization_passes]).length }.max || 0,
              source_triangle_count: results.sum { |row| row[:source_triangle_count].to_i },
              added_face_count: results.sum { |row| row[:added_face_count].to_i },
              skipped_collinear_triangle_count: results.sum { |row| row[:skipped_collinear_triangle_count].to_i },
              surface_border_repair_count: results.sum { |row| row[:surface_border_repair_count].to_i },
              strict_coplanar_edge_removal_count: results.sum { |row| row[:strict_coplanar_edge_removal_count].to_i },
              coplanar_edge_removal_count: results.sum { |row| row[:coplanar_edge_removal_count].to_i },
              collinear_vertex_removal_count: results.sum { |row| row[:collinear_vertex_removal_count].to_i },
              reoriented_face_count: results.sum { |row| row[:reoriented_face_count].to_i },
              total_volume_delta_mm3: results.sum do |row|
                row[:volume_after_mm3].to_f - row[:volume_before_mm3].to_f
              end,
              topology_metrics: topology_metrics,
              cell_spaces: results
            }
            IndoorCore::Logger.puts(
              "[IndoorGML] Local vertex normalize: tolerance=#{report[:tolerance_mm]}mm " \
              "cells=#{report[:cell_space_count]} vertices=#{report[:vertex_count]} " \
              "moved=#{report[:moved_vertex_count]} max_displacement=#{report[:max_displacement_mm]}mm"
            )
            report
          end

          private

          def valid_local_normalization_cell_spaces
            Array(@cell_spaces).select { |cell_space| cell_space&.valid? }
          end

          def local_normalization_group(candidate)
            if candidate.respond_to?(:valid_sketchup_group)
              candidate.valid_sketchup_group
            elsif candidate.respond_to?(:definition)
              candidate
            end
          rescue StandardError
            nil
          end

          def with_local_normalization_active_path(group)
            model = @model || Sketchup.active_model
            return yield unless model&.respond_to?(:active_path=)

            controller = ActivePathController.new(model, logger: IndoorCore::Logger)
            previous_path = controller.snapshot
            target_path = []
            target_path << @primal_group if @primal_group&.valid?
            target_path << group
            runner = proc do
              unless controller.set(target_path)
                raise "Could not activate CellSpace edit context: #{group.respond_to?(:name) ? group.name : group}"
              end
              yield
            ensure
              controller.restore(previous_path, close_when_nil: true)
            end

            if respond_to?(:with_active_path_enforcement_suspended)
              with_active_path_enforcement_suspended { runner.call }
            else
              runner.call
            end
          end
        end
      end
    end
  end
end
