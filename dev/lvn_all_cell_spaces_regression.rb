# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'time'

module ULOL
  module Indoor3DGmlModeler
    module Dev
      module LvnAllCellSpacesRegression
        TOLERANCE_MM = IndoorCore::LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
        LENGTH_EPSILON_MM = 0.0001
        TRANSFORM_EPSILON = 1.0e-12

        module_function

        def run
          model = Sketchup.active_model
          indoor_model = IndoorCore::IndoorModel.current
          finish_editing_performed = false

          if indoor_model.editing?
            finish_editing_performed = true
            raise 'IndoorGML Edit Mode 종료에 실패했습니다.' unless indoor_model.finish_editing
          end

          raise 'Root context에서 실행할 수 없습니다.' unless root_context?(model)

          targets = Array(indoor_model.cell_spaces).select { |cell_space| cell_space&.valid? }
          raise '검사할 CellSpace가 없습니다.' if targets.empty?

          before_context = context_snapshot(model, indoor_model)
          before_cells = targets.to_h do |cell_space|
            [cell_space.id.to_s, cell_snapshot(cell_space)]
          end

          started_at = monotonic_time
          report = indoor_model.local_vertex_normalize(
            TOLERANCE_MM,
            cell_spaces: targets,
            activate_edit_context: false,
            diagnostics: false,
            failure_policy: :continue
          )
          elapsed_seconds = monotonic_time - started_at

          after_context = context_snapshot(model, indoor_model)
          report_rows = Array(report[:cell_spaces]).to_h do |row|
            [row[:cell_space_id].to_s, row]
          end

          cell_results = targets.map do |cell_space|
            id = cell_space.id.to_s
            compare_cell(
              id,
              before_cells[id],
              cell_snapshot(cell_space),
              report_rows[id]
            )
          end

          context_checks = compare_context(before_context, after_context)
          status_counts = cell_results.each_with_object(Hash.new(0)) do |row, counts|
            counts[row[:status]] += 1
          end
          failed_rows = cell_results.select do |row|
            %i[failed skipped_previous_failure].include?(row[:status])
          end
          anomaly_rows = cell_results.reject { |row| row[:pass] }

          result = {
            schema: 'ulol.lvn.all_cell_spaces_regression.v1',
            generated_at: Time.now.iso8601(3),
            tolerance_mm: TOLERANCE_MM,
            elapsed_seconds: elapsed_seconds,
            target_count: targets.length,
            finish_editing_performed: finish_editing_performed,
            overall_pass: context_checks.values.all? && anomaly_rows.empty?,
            context_checks: context_checks,
            context_before: before_context,
            context_after: after_context,
            status_counts: status_counts,
            aggregate_report: compact_aggregate_report(report),
            maximums: aggregate_maximums(cell_results),
            failed_cell_spaces: failed_rows.map { |row| compact_result_row(row) },
            anomaly_cell_spaces: anomaly_rows.map { |row| compact_result_row(row) },
            cell_spaces: cell_results
          }

          output_path = write_result(result)
          result[:output_path] = output_path
          $lvn_all_cell_spaces_regression_report = result
          print_result(result)
          result
        end

        def root_context?(model)
          path = model.active_path
          path.nil? || path.empty?
        rescue StandardError
          false
        end
        private_class_method :root_context?

        def context_snapshot(model, indoor_model)
          diagnostic = indoor_model.respond_to?(:diagnostic_snapshot) ? indoor_model.diagnostic_snapshot : nil
          {
            active_path: entity_ids(model.active_path),
            selection: entity_ids(model.selection.to_a),
            editing: indoor_model.editing? == true,
            diagnostic: diagnostic
          }
        end
        private_class_method :context_snapshot

        def compare_context(before, after)
          before_diag = before[:diagnostic] || {}
          after_diag = after[:diagnostic] || {}
          {
            active_path_preserved: before[:active_path] == after[:active_path],
            selection_preserved: before[:selection] == after[:selection],
            edit_mode_preserved: before[:editing] == after[:editing],
            cell_space_count_preserved: before_diag[:cell_spaces] == after_diag[:cell_spaces],
            state_count_preserved: before_diag[:states] == after_diag[:states],
            transition_count_preserved: before_diag[:transitions] == after_diag[:transitions],
            dirty_topology_empty_after: after_diag[:dirty_topology_count].to_i.zero?,
            topology_sync_not_scheduled_after: after_diag[:topology_sync_scheduled] != true
          }
        end
        private_class_method :compare_context

        def entity_ids(entities)
          Array(entities).map do |entity|
            if entity.respond_to?(:persistent_id)
              entity.persistent_id
            elsif entity.respond_to?(:entityID)
              entity.entityID
            else
              entity.object_id
            end
          rescue StandardError
            entity.object_id
          end
        end
        private_class_method :entity_ids

        def cell_snapshot(cell_space)
          group = cell_space.valid_sketchup_group
          return { available: false } unless group&.valid?

          bounds = group.bounds
          {
            available: true,
            persistent_id: safe_persistent_id(group),
            name: group.respond_to?(:name) ? group.name.to_s : '',
            valid: group.valid? == true,
            manifold: group.respond_to?(:manifold?) && group.manifold? == true,
            locked: group.respond_to?(:locked?) ? group.locked? == true : nil,
            transformation: group.transformation.to_a.map(&:to_f),
            volume_mm3: volume_mm3(group),
            bounds_mm: bounds_mm(bounds),
            normalized: IndoorCore::LocalVertexNormalizer.normalized?(group, TOLERANCE_MM),
            lvn_failed: IndoorCore::PrecisionValidation::LvnState.failed?(group),
            geometry_signature: IndoorCore::PrecisionValidation::LvnState.geometry_signature(group)
          }
        rescue StandardError => error
          {
            available: false,
            error_class: error.class.name,
            error: error.message
          }
        end
        private_class_method :cell_snapshot

        def compare_cell(id, before, after, row)
          status = row && row[:status]
          checks = {
            group_available: before[:available] == true && after[:available] == true,
            persistent_id_preserved: before[:persistent_id] == after[:persistent_id],
            valid_after: after[:valid] == true,
            manifold_after: after[:manifold] == true,
            transformation_preserved: transformation_equal?(
              before[:transformation],
              after[:transformation]
            ),
            lock_state_preserved: before[:locked] == after[:locked]
          }

          case status
          when :normalized, :already_normalized
            checks[:normalized_after] = after[:normalized] == true
            checks[:lvn_failed_cleared] = after[:lvn_failed] == false
            checks[:normalization_complete] = row[:normalization_complete] != false
            checks[:bounds_within_reported_displacement] =
              bounds_delta_mm(before[:bounds_mm], after[:bounds_mm]) <=
              row[:max_displacement_mm].to_f + LENGTH_EPSILON_MM
          when :failed, :skipped_previous_failure
            checks[:lvn_failed_marked] = after[:lvn_failed] == true
            checks[:geometry_rolled_back_or_unchanged] =
              before[:geometry_signature] == after[:geometry_signature]
            checks[:bounds_rolled_back_or_unchanged] =
              bounds_delta_mm(before[:bounds_mm], after[:bounds_mm]) <= LENGTH_EPSILON_MM
          else
            checks[:recognized_status] = false
          end

          {
            cell_space_id: id,
            name: after[:name] || before[:name],
            status: status,
            pass: checks.values.all?,
            checks: checks,
            error_class: row && row[:error_class],
            error: row && row[:error],
            moved_vertex_count: row && row[:moved_vertex_count],
            max_displacement_mm: row && row[:max_displacement_mm],
            max_grid_residual_mm: row && row[:max_grid_residual_mm],
            bounds_delta_mm: bounds_delta_mm(before[:bounds_mm], after[:bounds_mm]),
            volume_delta_mm3: numeric_delta(before[:volume_mm3], after[:volume_mm3]),
            volume_relative_ppm: relative_ppm(before[:volume_mm3], after[:volume_mm3])
          }
        end
        private_class_method :compare_cell

        def aggregate_maximums(rows)
          {
            max_displacement_mm: finite_max(rows.map { |row| row[:max_displacement_mm] }),
            max_grid_residual_mm: finite_max(rows.map { |row| row[:max_grid_residual_mm] }),
            max_bounds_delta_mm: finite_max(rows.map { |row| row[:bounds_delta_mm] }),
            max_absolute_volume_delta_mm3: finite_max(
              rows.map { |row| row[:volume_delta_mm3]&.abs }
            ),
            max_absolute_volume_relative_ppm: finite_max(
              rows.map { |row| row[:volume_relative_ppm]&.abs }
            )
          }
        end
        private_class_method :aggregate_maximums

        def finite_max(values)
          Array(values).compact.map(&:to_f).select(&:finite?).max || 0.0
        end
        private_class_method :finite_max

        def compact_aggregate_report(report)
          keys = %i[
            failure_policy
            target_cell_space_count
            cell_space_count
            already_normalized_cell_space_count
            normalization_failed_cell_space_count
            skipped_previous_failure_cell_space_count
            failed_cell_space_ids
            moved_vertex_count
            max_displacement_mm
            max_grid_residual_mm
            incomplete_cell_space_count
            total_volume_delta_mm3
          ]
          keys.to_h { |key| [key, report[key]] }
        end
        private_class_method :compact_aggregate_report

        def compact_result_row(row)
          {
            cell_space_id: row[:cell_space_id],
            name: row[:name],
            status: row[:status],
            pass: row[:pass],
            failed_checks: row[:checks].select { |_key, value| value != true }.keys,
            error_class: row[:error_class],
            error: row[:error]
          }
        end
        private_class_method :compact_result_row

        def transformation_equal?(before, after)
          return false unless before.is_a?(Array) && after.is_a?(Array)
          return false unless before.length == after.length

          before.zip(after).all? do |first, second|
            (first.to_f - second.to_f).abs <= TRANSFORM_EPSILON
          end
        end
        private_class_method :transformation_equal?

        def safe_persistent_id(entity)
          entity.respond_to?(:persistent_id) ? entity.persistent_id : nil
        rescue StandardError
          nil
        end
        private_class_method :safe_persistent_id

        def volume_mm3(group)
          return nil unless group.respond_to?(:volume)

          group.volume.to_f * (25.4**3)
        rescue StandardError
          nil
        end
        private_class_method :volume_mm3

        def bounds_mm(bounds)
          {
            min: point_mm(bounds.min),
            max: point_mm(bounds.max)
          }
        rescue StandardError
          nil
        end
        private_class_method :bounds_mm

        def point_mm(point)
          [point.x.to_f * 25.4, point.y.to_f * 25.4, point.z.to_f * 25.4]
        end
        private_class_method :point_mm

        def bounds_delta_mm(before, after)
          return Float::INFINITY unless before && after

          first = Array(before[:min]) + Array(before[:max])
          second = Array(after[:min]) + Array(after[:max])
          return Float::INFINITY unless first.length == 6 && second.length == 6

          first.zip(second).map { |a, b| (a.to_f - b.to_f).abs }.max || 0.0
        end
        private_class_method :bounds_delta_mm

        def numeric_delta(before, after)
          return nil if before.nil? || after.nil?

          after.to_f - before.to_f
        end
        private_class_method :numeric_delta

        def relative_ppm(before, after)
          return nil if before.nil? || after.nil?
          return nil if before.to_f.abs <= Float::EPSILON

          ((after.to_f - before.to_f) / before.to_f) * 1_000_000.0
        end
        private_class_method :relative_ppm

        def write_result(result)
          timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
          path = File.join(
            Dir.tmpdir,
            "indoor_gml_lvn_all_cell_spaces_regression_#{timestamp}.json"
          )
          File.write(path, JSON.pretty_generate(json_safe(result)))
          path
        end
        private_class_method :write_result

        def print_result(result)
          puts
          puts '=' * 90
          puts '[LVN Regression] All CellSpaces'
          puts "overall_pass=#{result[:overall_pass]} targets=#{result[:target_count]} " \
               "elapsed=#{format('%.3f', result[:elapsed_seconds])}s"
          puts "status_counts=#{result[:status_counts].inspect}"
          puts "context=#{result[:context_checks].inspect}"
          puts "maximums=#{result[:maximums].inspect}"
          puts "failed_count=#{result[:failed_cell_spaces].length} " \
               "anomaly_count=#{result[:anomaly_cell_spaces].length}"
          result[:failed_cell_spaces].each do |row|
            puts "failed cell=#{row[:cell_space_id]} status=#{row[:status]} " \
                 "pass=#{row[:pass]} error=#{row[:error_class]}: #{row[:error]}"
          end
          result[:anomaly_cell_spaces].each do |row|
            puts "anomaly cell=#{row[:cell_space_id]} status=#{row[:status]} " \
                 "failed_checks=#{row[:failed_checks].join(',')}"
          end
          puts "report_path=#{result[:output_path]}"
          puts '=' * 90
        end
        private_class_method :print_result

        def json_safe(value)
          case value
          when Hash
            value.to_h { |key, item| [key.to_s, json_safe(item)] }
          when Array
            value.map { |item| json_safe(item) }
          when Symbol
            value.to_s
          when Float
            value.finite? ? value : value.to_s
          else
            value
          end
        end
        private_class_method :json_safe

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        private_class_method :monotonic_time
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::Dev::LvnAllCellSpacesRegression.run
nil
