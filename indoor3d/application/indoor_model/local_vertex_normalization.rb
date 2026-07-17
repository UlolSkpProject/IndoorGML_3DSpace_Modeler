# frozen_string_literal: true

require_relative '../local_vertex_normalizer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        # IndoorModel integration for LocalVertexNormalizer.
        #
        # Default behavior preserves the current SketchUp edit context. Geometry
        # is normalized through group.definition.entities, so entering the target
        # CellSpace edit path is not required.
        module LocalVertexNormalization
          def is_vertex_locally_normalized?(
            target = nil,
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
          )
            if target.is_a?(Numeric)
              tolerance_mm = target
              target = nil
            end

            targets = if target.nil?
                        valid_local_normalization_cell_spaces
                      else
                        Array(target)
                      end
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
            normalization_targets(cell_spaces).reject do |cell_space|
              group = local_normalization_group(cell_space)
              group && LocalVertexNormalizer.normalized?(group, tolerance_mm)
            end
          end

          # Export guard. Only CellSpaces that fail the fast normalized? predicate
          # are rebuilt.
          #
          # activate_edit_context defaults to false. In that mode this module does
          # not enter or leave edit mode and works directly on each definition.
          def ensure_vertices_locally_normalized_for_export(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil,
            activate_edit_context: false
          )
            targets = normalization_targets(cell_spaces)
            unnormalized = locally_unnormalized_cell_spaces(
              tolerance_mm,
              cell_spaces: targets
            )

            if unnormalized.empty?
              return empty_local_normalization_report(
                tolerance_mm,
                already_normalized_cell_space_count: targets.length,
                skipped: true,
                activate_edit_context: activate_edit_context
              )
            end

            # Preserve compatibility with test doubles and older overrides that do
            # not accept activate_edit_context when the default mode is used.
            report = if activate_edit_context
                       local_vertex_normalize(
                         tolerance_mm,
                         cell_spaces: unnormalized,
                         activate_edit_context: true
                       )
                     else
                       local_vertex_normalize(
                         tolerance_mm,
                         cell_spaces: unnormalized
                       )
                     end

            report[:already_normalized_cell_space_count] =
              targets.length - unnormalized.length
            report[:skipped] = false
            report
          end

          # Normalizes selected CellSpaces in one SketchUp operation.
          #
          # When activate_edit_context is false, the active edit path is never
          # read, changed, closed, or restored by this module.
          #
          # When activate_edit_context is true, each target CellSpace is activated
          # temporarily and the previous path is restored afterward. This mode is
          # retained only for callers that explicitly require the old behavior.
          def local_vertex_normalize(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil,
            activate_edit_context: false
          )
            targets = normalization_targets(cell_spaces)
            if targets.empty?
              raise 'No valid CellSpace found for local vertex normalization'
            end

            results = []
            topology_metrics = nil

            with_indoor_model_operation('IndoorGML Local Vertex Normalize') do
              sync do
                targets.each do |cell_space|
                  group = cell_space.valid_sketchup_group
                  unless group
                    raise "CellSpace geometry unavailable: #{cell_space.id}"
                  end

                  result = normalize_cell_space_group(
                    cell_space,
                    group,
                    tolerance_mm,
                    activate_edit_context: activate_edit_context
                  )

                  result[:cell_space_id] = cell_space.id
                  results << result
                  remember_cell_space_change_snapshot(cell_space.sketchup_group)
                end

                topology_metrics = topology_coordinator.synchronize_all
              end
            end

            invalidate_overlay_transition_points
            model = @model || Sketchup.active_model
            model.active_view.invalidate if model&.active_view

            report = aggregate_local_normalization_report(
              tolerance_mm,
              results,
              topology_metrics,
              activate_edit_context: activate_edit_context
            )
            log_local_normalization_report(report)
            report
          end

          private

          def normalization_targets(cell_spaces)
            source = cell_spaces.nil? ? valid_local_normalization_cell_spaces : Array(cell_spaces)
            source.select { |cell_space| cell_space&.valid? }
          end

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

          def normalize_cell_space_group(
            cell_space,
            group,
            tolerance_mm,
            activate_edit_context:
          )
            with_unlocked(group) do
              runner = proc do
                LocalVertexNormalizer.normalize(group, tolerance_mm)
              rescue StandardError => e
                name = group.respond_to?(:name) ? group.name.inspect : 'n/a'
                raise e.class,
                      "CellSpace local vertex normalization failed: " \
                      "id=#{cell_space.id.inspect} name=#{name}: #{e.message}",
                      e.backtrace
              end

              if activate_edit_context
                with_local_normalization_active_path(group) { runner.call }
              else
                runner.call
              end
            end
          end

          # Legacy opt-in path activation. Default normalization never calls this.
          def with_local_normalization_active_path(group)
            model = @model || Sketchup.active_model
            return yield unless model&.respond_to?(:active_path=)

            controller = ActivePathController.new(
              model,
              logger: IndoorCore::Logger
            )
            previous_path = controller.snapshot
            target_path = []
            target_path << @primal_group if @primal_group&.valid?
            target_path << group

            runner = proc do
              unless controller.set(target_path)
                label = group.respond_to?(:name) ? group.name : group
                raise "Could not activate CellSpace edit context: #{label}"
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

          def empty_local_normalization_report(
            tolerance_mm,
            already_normalized_cell_space_count:,
            skipped:,
            activate_edit_context:
          )
            {
              tolerance_mm: Float(tolerance_mm),
              cell_space_count: 0,
              already_normalized_cell_space_count: already_normalized_cell_space_count,
              skipped: skipped,
              activate_edit_context: activate_edit_context,
              edit_context_strategy: activate_edit_context ? :target : :preserve,
              vertex_count: 0,
              moved_vertex_count: 0,
              max_displacement_mm: 0.0,
              max_grid_residual_mm: 0.0,
              max_unprotected_grid_residual_mm: 0.0,
              protected_coincident_vertex_count: 0,
              incomplete_cell_space_count: 0,
              max_normalization_passes: 0,
              source_triangle_count: 0,
              added_face_count: 0,
              skipped_collinear_triangle_count: 0,
              surface_border_repair_count: 0,
              strict_coplanar_edge_removal_count: 0,
              coplanar_edge_removal_count: 0,
              collinear_vertex_removal_count: 0,
              reoriented_face_count: 0,
              total_volume_delta_mm3: 0.0,
              topology_metrics: nil,
              cell_spaces: []
            }
          end

          def aggregate_local_normalization_report(
            tolerance_mm,
            results,
            topology_metrics,
            activate_edit_context:
          )
            {
              tolerance_mm: Float(tolerance_mm),
              cell_space_count: results.length,
              already_normalized_cell_space_count: 0,
              skipped: false,
              activate_edit_context: activate_edit_context,
              edit_context_strategy: activate_edit_context ? :target : :preserve,
              vertex_count: sum_report_value(results, :vertex_count),
              moved_vertex_count: sum_report_value(results, :moved_vertex_count),
              max_displacement_mm: max_report_value(results, :max_displacement_mm),
              max_grid_residual_mm: max_report_value(results, :max_grid_residual_mm),
              max_unprotected_grid_residual_mm: max_report_value(
                results,
                :max_unprotected_grid_residual_mm
              ),
              protected_coincident_vertex_count: sum_report_value(
                results,
                :protected_coincident_vertex_count
              ),
              incomplete_cell_space_count: results.count do |row|
                row[:normalization_complete] == false
              end,
              max_normalization_passes: results.map do |row|
                Array(row[:normalization_passes]).length
              end.max || 0,
              source_triangle_count: sum_report_value(results, :source_triangle_count),
              added_face_count: sum_report_value(results, :added_face_count),
              skipped_collinear_triangle_count: sum_report_value(
                results,
                :skipped_collinear_triangle_count
              ),
              surface_border_repair_count: sum_report_value(
                results,
                :surface_border_repair_count
              ),
              strict_coplanar_edge_removal_count: sum_report_value(
                results,
                :strict_coplanar_edge_removal_count
              ),
              coplanar_edge_removal_count: sum_report_value(
                results,
                :coplanar_edge_removal_count
              ),
              collinear_vertex_removal_count: sum_report_value(
                results,
                :collinear_vertex_removal_count
              ),
              reoriented_face_count: sum_report_value(
                results,
                :reoriented_face_count
              ),
              total_volume_delta_mm3: results.sum do |row|
                row[:volume_after_mm3].to_f - row[:volume_before_mm3].to_f
              end,
              topology_metrics: topology_metrics,
              cell_spaces: results
            }
          end

          def sum_report_value(results, key)
            results.sum { |row| row[key].to_i }
          end

          def max_report_value(results, key)
            results.map { |row| row[key].to_f }.max || 0.0
          end

          def log_local_normalization_report(report)
            IndoorCore::Logger.puts(
              "[IndoorGML] Local vertex normalize: " \
              "tolerance=#{report[:tolerance_mm]}mm " \
              "cells=#{report[:cell_space_count]} " \
              "vertices=#{report[:vertex_count]} " \
              "moved=#{report[:moved_vertex_count]} " \
              "max_displacement=#{report[:max_displacement_mm]}mm " \
              "edit_context=#{report[:edit_context_strategy]}"
            )
          end
        end
      end
    end
  end
end
