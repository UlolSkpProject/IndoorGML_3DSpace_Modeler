# frozen_string_literal: true

require 'json'

module ULOL
  module Indoor3DGmlModeler
    module Dev
      module PrecisionValidationSelectedCellSpacesLvnSmokeTest
        TOLERANCE_MM = IndoorCore::LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
        LENGTH_EPSILON_MM = 0.0001
        TRANSFORM_EPSILON = 1.0e-12

        module_function

        def run
          model = Sketchup.active_model
          indoor_model = IndoorCore::IndoorModel.current
          targets = selected_cell_spaces(model, indoor_model)

          raise '선택된 CellSpace가 없습니다. CellSpace 그룹 자체를 선택하세요.' if targets.empty?
          raise 'IndoorGML Edit Mode를 종료한 뒤 실행하세요.' if indoor_model.editing?
          raise 'Root context에서 실행하세요. 현재 active_path를 닫아 주세요.' unless root_context?(model)

          before_context = context_snapshot(model, indoor_model)
          before_cells = targets.to_h { |cell_space| [cell_space.id, cell_snapshot(cell_space)] }

          started_at = monotonic_time
          report = indoor_model.local_vertex_normalize(
            TOLERANCE_MM,
            cell_spaces: targets,
            activate_edit_context: false,
            debug: true,
            failure_policy: :continue
          )
          elapsed_seconds = monotonic_time - started_at

          after_context = context_snapshot(model, indoor_model)
          after_cells = targets.to_h { |cell_space| [cell_space.id, cell_snapshot(cell_space)] }
          report_rows = Array(report[:cell_spaces]).to_h do |row|
            [row[:cell_space_id].to_s, row]
          end

          context_checks = compare_context(before_context, after_context)
          cell_results = targets.map do |cell_space|
            id = cell_space.id.to_s
            compare_cell(
              id,
              before_cells[id],
              after_cells[id],
              report_rows[id]
            )
          end

          result = {
            schema: 'ulol.precision_validation.selected_cell_spaces_lvn_smoke.v1',
            tolerance_mm: TOLERANCE_MM,
            elapsed_seconds: elapsed_seconds,
            target_count: targets.length,
            overall_pass: context_checks.values.all? && cell_results.all? { |row| row[:pass] },
            context_checks: context_checks,
            context_before: before_context,
            context_after: after_context,
            aggregate_report: compact_aggregate_report(report),
            cell_spaces: cell_results
          }

          $precision_validation_selected_lvn_smoke_report = result
          print_result(result)
          result
        end

        def selected_cell_spaces(model, indoor_model)
          selected = model.selection.to_a
          Array(indoor_model.cell_spaces).select do |cell_space|
            group = cell_space.valid_sketchup_group
            group && selected.include?(group)
          end
        end
        private_class_method :selected_cell_spaces

        def root_context?(model)
          path = model.active_path
          path.nil? || path.empty?
        rescue StandardError
          false
        end
        private_class_method :root_context?

        def context_snapshot(model, indoor_model)
          {
            active_path: entity_ids(model.active_path),
            selection: entity_ids(model.selection.to_a),
            editing: indoor_model.editing? == true,
            diagnostic: indoor_model.respond_to?(:diagnostic_snapshot) ? indoor_model.diagnostic_snapshot : nil
          }
        end
        private_class_method :context_snapshot

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

          entities = group.definition.entities
          faces = entities.grep(Sketchup::Face)
          edges = entities.grep(Sketchup::Edge)
          vertices = (edges.flat_map(&:vertices) + faces.flat_map(&:vertices)).uniq
          bounds = group.bounds

          {
            available: true,
            persistent_id: safe_persistent_id(group),
            name: group.respond_to?(:name) ? group.name.to_s : '',
            valid: group.valid? == true,
            manifold: group.respond_to?(:manifold?) && group.manifold? == true,
            locked: group.respond_to?(:locked?) ? group.locked? == true : nil,
            transformation: group.transformation.to_a.map(&:to_f),
            definition_id: definition_id(group.definition),
            faces: faces.length,
            edges: edges.length,
            vertices: vertices.length,
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

        def safe_persistent_id(entity)
          entity.respond_to?(:persistent_id) ? entity.persistent_id : nil
        rescue StandardError
          nil
        end
        private_class_method :safe_persistent_id

        def definition_id(definition)
          return definition.guid.to_s if definition.respond_to?(:guid)
          return definition.persistent_id if definition.respond_to?(:persistent_id)

          definition.object_id
        rescue StandardError
          definition.object_id
        end
        private_class_method :definition_id

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

        def compare_context(before, after)
          {
            active_path_preserved: before[:active_path] == after[:active_path],
            selection_preserved: before[:selection] == after[:selection],
            edit_mode_preserved: before[:editing] == after[:editing]
          }
        end
        private_class_method :compare_context

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
            status: status,
            pass: checks.values.all?,
            checks: checks,
            report: compact_cell_report(row),
            before: before,
            after: after,
            bounds_delta_mm: bounds_delta_mm(before[:bounds_mm], after[:bounds_mm]),
            volume_delta_mm3: numeric_delta(before[:volume_mm3], after[:volume_mm3])
          }
        end
        private_class_method :compare_cell

        def transformation_equal?(before, after)
          return false unless before.is_a?(Array) && after.is_a?(Array)
          return false unless before.length == after.length

          before.zip(after).all? do |first, second|
            (first.to_f - second.to_f).abs <= TRANSFORM_EPSILON
          end
        end
        private_class_method :transformation_equal?

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

        def compact_cell_report(row)
          return nil unless row

          keys = %i[
            status
            normalization_complete
            moved_vertex_count
            max_displacement_mm
            max_grid_residual_mm
            max_unprotected_grid_residual_mm
            volume_before_mm3
            volume_after_mm3
            source_triangle_count
            added_face_count
            error_class
            error
          ]
          keys.to_h { |key| [key, row[key]] }
        end
        private_class_method :compact_cell_report

        def print_result(result)
          puts
          puts '=' * 90
          puts '[Precision Validation] Selected CellSpace LVN smoke test'
          puts "overall_pass=#{result[:overall_pass]} targets=#{result[:target_count]} " \
               "elapsed=#{format('%.3f', result[:elapsed_seconds])}s"
          puts "context=#{result[:context_checks].inspect}"
          result[:cell_spaces].each do |row|
            failed_checks = row[:checks].select { |_key, value| value != true }.keys
            puts "cell=#{row[:cell_space_id]} status=#{row[:status]} pass=#{row[:pass]} " \
                 "failed_checks=#{failed_checks.join(',')}"
          end
          puts '-' * 90
          puts JSON.pretty_generate(json_safe(result))
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

ULOL::Indoor3DGmlModeler::Dev::PrecisionValidationSelectedCellSpacesLvnSmokeTest.run
nil
