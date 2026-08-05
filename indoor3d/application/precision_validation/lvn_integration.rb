# frozen_string_literal: true

require_relative 'lvn_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        module CellSpaceLifecycleContextPatch
          def initialize_scene(cell_space, **options)
            result = super
            LvnState.set_failed(cell_space, false)
            result
          end
        end

        module IndoorModelPatch
          VALID_FAILURE_POLICIES = %i[rollback_all continue].freeze

          def local_vertex_normalize(
            tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
            cell_spaces: nil,
            activate_edit_context: false,
            debug: false,
            report: false,
            report_path: nil,
            failure_policy: :rollback_all
          )
            policy = failure_policy.to_sym
            unless VALID_FAILURE_POLICIES.include?(policy)
              raise ArgumentError, "Unsupported LVN failure_policy: #{failure_policy.inspect}"
            end

            if policy == :rollback_all
              return super(
                tolerance_mm,
                cell_spaces: cell_spaces,
                activate_edit_context: activate_edit_context,
                debug: debug,
                report: report,
                report_path: report_path
              )
            end

            atomic_runner = proc do |targets|
              super(
                tolerance_mm,
                cell_spaces: targets,
                activate_edit_context: activate_edit_context,
                debug: debug,
                report: report,
                report_path: report_path
              )
            end

            local_vertex_normalize_continue(
              tolerance_mm,
              cell_spaces: cell_spaces,
              activate_edit_context: activate_edit_context,
              debug: debug,
              report: report,
              report_path: report_path,
              atomic_runner: atomic_runner
            )
          end

          def cell_space_lvn_failed?(cell_space)
            LvnState.failed?(cell_space)
          end

          def cell_space_lvn_geometry_signature(cell_space)
            LvnState.geometry_signature(cell_space)
          end

          def cell_space_lvn_failure_signature(cell_space)
            LvnState.failure_signature(cell_space)
          end

          private

          def local_vertex_normalize_continue(
            tolerance_mm,
            cell_spaces:,
            activate_edit_context:,
            debug:,
            report:,
            report_path:,
            atomic_runner:
          )
            targets = normalization_targets(cell_spaces)
            raise 'No valid CellSpace found for local vertex normalization' if targets.empty?

            plan = build_continue_execution_plan(targets, tolerance_mm)

            if plan[:fallback_targets].empty? && plan[:atomic_targets].any?
              return local_vertex_normalize_continue_atomic(
                tolerance_mm,
                targets,
                plan,
                activate_edit_context: activate_edit_context,
                debug: debug,
                report: report,
                report_path: report_path,
                atomic_runner: atomic_runner
              )
            end

            if plan[:fallback_targets].empty? && plan[:atomic_targets].empty?
              return aggregate_continue_report(
                tolerance_mm,
                targets,
                plan[:rows],
                [],
                nil,
                activate_edit_context: activate_edit_context
              ).merge(
                undo_mode: :none,
                atomic_attempted: false,
                atomic_fallback: false
              )
            end

            local_vertex_normalize_continue_per_cell(
              tolerance_mm,
              targets,
              plan[:rows],
              plan[:atomic_targets] + plan[:fallback_targets],
              activate_edit_context: activate_edit_context,
              debug: debug,
              report: report,
              report_path: report_path,
              started_at: monotonic_time,
              atomic_attempted: false,
              atomic_error: nil
            )
          end

          def build_continue_execution_plan(targets, tolerance_mm)
            rows = []
            atomic_targets = []
            fallback_targets = []

            targets.each do |cell_space|
              group = cell_space.valid_sketchup_group
              unless group
                fallback_targets << cell_space
                next
              end

              if LvnState.failed_and_unchanged?(group)
                rows << skipped_previous_failure_row(cell_space, group)
                next
              end

              if LocalVertexNormalizer.normalized?(group, tolerance_mm)
                if LvnState.failed?(group) || LvnState.failure_signature(group)
                  fallback_targets << cell_space
                else
                  rows << already_normalized_row(cell_space, group)
                end
                next
              end

              if LvnState.failed?(group) || LvnState.failure_signature(group)
                fallback_targets << cell_space
              else
                atomic_targets << cell_space
              end
            end

            {
              rows: rows,
              atomic_targets: atomic_targets,
              fallback_targets: fallback_targets
            }
          end

          def local_vertex_normalize_continue_atomic(
            tolerance_mm,
            targets,
            plan,
            activate_edit_context:,
            debug:,
            report:,
            report_path:,
            atomic_runner:
          )
            started_at = monotonic_time
            runtime_snapshot = capture_lvn_runtime_snapshot
            atomic_report = atomic_runner.call(plan[:atomic_targets])
            rows = plan[:rows] + atomic_success_rows(atomic_report, plan[:atomic_targets])

            Hash(atomic_report).merge(
              failure_policy: :continue,
              target_cell_space_count: targets.length,
              cell_space_count: rows.count { |row| row[:status] == :normalized },
              already_normalized_cell_space_count: rows.count do |row|
                row[:status] == :already_normalized
              end,
              normalization_failed_cell_space_count: 0,
              skipped_previous_failure_cell_space_count: rows.count do |row|
                row[:status] == :skipped_previous_failure
              end,
              failed_cell_space_ids: rows.filter_map do |row|
                row[:cell_space_id] if row[:status] == :skipped_previous_failure
              end,
              cell_spaces: rows,
              undo_mode: :single_operation,
              atomic_attempted: true,
              atomic_fallback: false
            )
          rescue StandardError => error
            restore_lvn_runtime_snapshot!(runtime_snapshot)
            local_vertex_normalize_continue_per_cell(
              tolerance_mm,
              targets,
              plan[:rows],
              plan[:atomic_targets],
              activate_edit_context: activate_edit_context,
              debug: debug,
              report: report,
              report_path: report_path,
              started_at: started_at,
              atomic_attempted: true,
              atomic_error: error
            )
          end

          def local_vertex_normalize_continue_per_cell(
            tolerance_mm,
            targets,
            initial_rows,
            execution_targets,
            activate_edit_context:,
            debug:,
            report:,
            report_path:,
            started_at:,
            atomic_attempted:,
            atomic_error:
          )
            rows = Array(initial_rows).dup
            successful_results = []
            topology_metrics = nil
            topology_sync_seconds = 0.0

            Array(execution_targets).each do |cell_space|
              row = normalize_cell_space_continue(
                cell_space,
                tolerance_mm,
                activate_edit_context: activate_edit_context,
                debug: debug,
                report: report
              )
              rows << row
              successful_results << row if row[:status] == :normalized
            end

            if successful_results.any?
              topology_started_at = monotonic_time
              with_indoor_model_operation('IndoorGML LVN Topology Synchronize') do
                sync do
                  topology_metrics = topology_coordinator.synchronize_all
                end
              end
              topology_sync_seconds = monotonic_time - topology_started_at
              invalidate_overlay_transition_points
              model = @model || Sketchup.active_model
              model.active_view.invalidate if model&.active_view
            end

            normalization_report = aggregate_continue_report(
              tolerance_mm,
              targets,
              rows,
              successful_results,
              topology_metrics,
              activate_edit_context: activate_edit_context
            ).merge(
              undo_mode: Array(execution_targets).empty? ? :none : :per_cell_fallback,
              atomic_attempted: atomic_attempted,
              atomic_fallback: atomic_attempted && !atomic_error.nil?,
              atomic_error_class: atomic_error&.class&.name,
              atomic_error: atomic_error&.message
            )

            if debug == true || report == true
              timing_profile = {
                enabled: true,
                status: :success,
                failure_policy: :continue,
                total_seconds: monotonic_time - started_at,
                operation_total_seconds: nil,
                operation_body_seconds: nil,
                operation_boundary_overhead_seconds: nil,
                topology_sync_seconds: topology_sync_seconds,
                cell_spaces: successful_results.filter_map { |row| row[:debug_profile] }
              }
              normalization_report[:debug_profile] = timing_profile
              if report == true
                written_path = write_local_normalization_timing_report(
                  timing_profile,
                  normalization_report: normalization_report,
                  targets: targets,
                  report_path: report_path
                )
                normalization_report[:timing_report_path] = written_path
              end
            end

            normalization_report
          end

          def atomic_success_rows(report, targets)
            rows_by_id = Array(report && report[:cell_spaces]).to_h do |row|
              [row[:cell_space_id].to_s, row]
            end

            Array(targets).map do |cell_space|
              group = cell_space.valid_sketchup_group
              row = Hash(rows_by_id[cell_space.id.to_s]).dup
              row.merge(
                status: :normalized,
                cell_space_id: cell_space.id,
                persistent_id: persistent_id_for(group),
                lvn_failed: false
              )
            end
          end

          def capture_lvn_runtime_snapshot
            return nil unless respond_to?(:bulk_conversion_runtime_snapshot, true)

            send(:bulk_conversion_runtime_snapshot)
          rescue StandardError => error
            raise LocalVertexNormalizer::OperationError,
                  "Atomic LVN runtime snapshot failed: #{error.class}: #{error.message}"
          end

          def restore_lvn_runtime_snapshot!(snapshot)
            return true if snapshot.nil?
            return true unless respond_to?(:restore_bulk_conversion_runtime, true)

            send(:restore_bulk_conversion_runtime, snapshot)
            true
          rescue StandardError => error
            raise LocalVertexNormalizer::OperationError,
                  "Atomic LVN rollback runtime restore failed: #{error.class}: #{error.message}"
          end

          def already_normalized_row(cell_space, group)
            {
              status: :already_normalized,
              cell_space_id: cell_space.id,
              persistent_id: persistent_id_for(group),
              lvn_failed: false,
              normalization_complete: true
            }
          end

          def skipped_previous_failure_row(cell_space, group)
            {
              status: :skipped_previous_failure,
              cell_space_id: cell_space.id,
              persistent_id: persistent_id_for(group),
              lvn_failed: true,
              normalization_complete: false
            }
          end

          def normalize_cell_space_continue(
            cell_space,
            tolerance_mm,
            activate_edit_context:,
            debug:,
            report:
          )
            group = cell_space.valid_sketchup_group
            return failed_row(cell_space, nil, 'CellSpace geometry unavailable') unless group

            if LvnState.failed_and_unchanged?(group)
              return skipped_previous_failure_row(cell_space, group)
            end

            if LocalVertexNormalizer.normalized?(group, tolerance_mm)
              clear_lvn_failed_state(cell_space, group)
              return already_normalized_row(cell_space, group)
            end

            result = nil
            with_indoor_model_operation("IndoorGML LVN #{cell_space.id}") do
              sync do
                result = normalize_cell_space_group(
                  cell_space,
                  group,
                  tolerance_mm,
                  activate_edit_context: activate_edit_context,
                  debug: debug,
                  report: report
                )
                LvnState.set_failed(group, false)
                remember_cell_space_change_snapshot(group)
              end
            end

            Hash(result).merge(
              status: :normalized,
              cell_space_id: cell_space.id,
              persistent_id: persistent_id_for(group),
              lvn_failed: false
            )
          rescue StandardError => error
            mark_lvn_failure_after_rollback(cell_space, group)
            failed_row(cell_space, group, error)
          end

          def clear_lvn_failed_state(cell_space, group)
            return unless LvnState.failed?(group) || LvnState.failure_signature(group)

            with_indoor_model_operation("Reset CellSpace LVN Failure #{cell_space.id}") do
              sync do
                LvnState.set_failed(group, false)
                remember_cell_space_change_snapshot(group)
              end
            end
          end

          def mark_lvn_failure_after_rollback(cell_space, group)
            restored_group = cell_space&.valid_sketchup_group || group
            return false unless restored_group&.valid?

            with_indoor_model_operation("Mark CellSpace LVN Failure #{cell_space.id}") do
              sync do
                LvnState.set_failed(restored_group, true)
                remember_cell_space_change_snapshot(restored_group)
              end
            end
            true
          rescue StandardError => error
            IndoorCore::Logger.puts(
              "[IndoorGML] CellSpace LVN failure mark failed: " \
              "cell=#{cell_space&.id} #{error.class}: #{error.message}"
            )
            false
          end

          def aggregate_continue_report(
            tolerance_mm,
            targets,
            rows,
            successful_results,
            topology_metrics,
            activate_edit_context:
          )
            base = aggregate_local_normalization_report(
              tolerance_mm,
              successful_results,
              topology_metrics,
              activate_edit_context: activate_edit_context
            )
            base.merge(
              failure_policy: :continue,
              target_cell_space_count: targets.length,
              cell_space_count: successful_results.length,
              already_normalized_cell_space_count: rows.count { |row| row[:status] == :already_normalized },
              normalization_failed_cell_space_count: rows.count { |row| row[:status] == :failed },
              skipped_previous_failure_cell_space_count: rows.count do |row|
                row[:status] == :skipped_previous_failure
              end,
              failed_cell_space_ids: rows.filter_map do |row|
                row[:cell_space_id] if %i[failed skipped_previous_failure].include?(row[:status])
              end,
              cell_spaces: rows
            )
          end

          def failed_row(cell_space, group, error)
            message = if error.respond_to?(:message)
                        error.message
                      else
                        error.to_s
                      end
            error_class = error.class.name if error.respond_to?(:class)
            {
              status: :failed,
              cell_space_id: cell_space&.id,
              persistent_id: persistent_id_for(group),
              lvn_failed: true,
              normalization_complete: false,
              error_class: error_class,
              error: message
            }
          end

          def persistent_id_for(entity)
            return nil unless entity&.respond_to?(:persistent_id)

            entity.persistent_id
          rescue StandardError
            nil
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def cell_space_change_kind(changed_fields)
            return nil if Array(changed_fields).empty?

            super
          end

          def recenter_cell_space_geometry(cell_space_entity, **options)
            was_failed = LvnState.failed?(cell_space_entity)
            stored = LvnState.failure_signature(cell_space_entity) if was_failed
            before = LvnState.geometry_signature(cell_space_entity) if was_failed

            if was_failed && stored && before && stored != before
              LvnState.set_failed(cell_space_entity, false)
              was_failed = false
            end

            result = super
            if was_failed && LvnState.failed?(cell_space_entity) && before
              after = LvnState.geometry_signature(cell_space_entity)
              LvnState.set_failed(cell_space_entity, false) if after && before != after
            end
            result
          end

          def bake_cell_space_transform_scale(entity)
            result = super
            LvnState.set_failed(entity, false) if result
            result
          end

          def build_independent_cell_space(entity)
            cell_space = super
            LvnState.set_failed(entity, false)
            cell_space
          end
        end

        def self.install!
          unless CellSpaceLifecycleContext.ancestors.include?(CellSpaceLifecycleContextPatch)
            CellSpaceLifecycleContext.prepend(CellSpaceLifecycleContextPatch)
          end
          unless IndoorModel.ancestors.include?(IndoorModelPatch)
            IndoorModel.prepend(IndoorModelPatch)
          end
          true
        end
      end

      PrecisionValidation.install!
    end
  end
end
