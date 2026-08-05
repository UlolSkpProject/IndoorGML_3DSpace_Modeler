# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'time'

module ULOL
  module Indoor3DGmlModeler
    module Dev
      module PrecisionValidationTransitionDiffProbe
        TOLERANCE_MM = IndoorCore::LocalVertexNormalizer::DEFAULT_TOLERANCE_MM

        module_function

        def run
          model = Sketchup.active_model
          indoor_model = IndoorCore::IndoorModel.current
          finish_editing_performed = false

          if indoor_model.editing?
            finish_editing_performed = true
            raise 'IndoorGML Edit Mode 종료에 실패했습니다.' unless indoor_model.finish_editing
          end

          raise 'Root context에서 실행하세요.' unless root_context?(model)

          registry = indoor_model.instance_variable_get(:@feature_registry)
          targets = Array(indoor_model.cell_spaces).select { |cell_space| cell_space&.valid? }
          raise '검사할 CellSpace가 없습니다.' if targets.empty?

          before = topology_snapshot(indoor_model, registry)
          before_geometry = transition_geometry_snapshots(indoor_model, before[:transitions])
          normalized_before = targets.count do |cell_space|
            group = cell_space.valid_sketchup_group
            group && IndoorCore::LocalVertexNormalizer.normalized?(group, TOLERANCE_MM)
          end

          started_at = monotonic_time
          lvn_report = indoor_model.local_vertex_normalize(
            TOLERANCE_MM,
            cell_spaces: targets,
            activate_edit_context: false,
            debug: false,
            failure_policy: :continue
          )
          elapsed_seconds = monotonic_time - started_at

          after = topology_snapshot(indoor_model, registry)
          before_pair_keys = topology_pair_keys(before)
          after_pair_keys = topology_pair_keys(after)
          removed = removed_transitions(before[:transitions], after[:transitions])
          added = removed_transitions(after[:transitions], before[:transitions])
          cell_index = targets.to_h { |cell_space| [cell_space.id.to_s, cell_space] }

          result = {
            schema: 'ulol.precision_validation.transition_diff_probe.v2',
            generated_at: Time.now.iso8601(3),
            tolerance_mm: TOLERANCE_MM,
            elapsed_seconds: elapsed_seconds,
            target_count: targets.length,
            finish_editing_performed: finish_editing_performed,
            normalized_before_count: normalized_before,
            before: before,
            after: after,
            transition_count_delta: after[:transition_count] - before[:transition_count],
            adjacent_pair_count_delta: after[:adjacent_pair_keys].length - before[:adjacent_pair_keys].length,
            erased_pair_keys: (before_pair_keys - after_pair_keys).sort,
            added_pair_keys: (after_pair_keys - before_pair_keys).sort,
            removed_transitions: removed.map do |row|
              removed_transition_diagnostic(row, before_geometry, cell_index)
            end,
            added_transitions: added,
            lvn_report: compact_lvn_report(lvn_report)
          }

          path = File.join(
            Dir.tmpdir,
            "indoor_gml_precision_transition_diff_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
          )
          File.write(path, JSON.pretty_generate(json_safe(result)))
          result[:report_path] = path
          $precision_validation_transition_diff_report = result
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

        def topology_snapshot(indoor_model, registry)
          transitions = Array(indoor_model.transitions).filter_map do |transition|
            transition_snapshot(indoor_model, transition)
          end
          {
            transition_count: transitions.length,
            adjacent_pair_keys: registry.respond_to?(:adjacent_pair_keys) ? Array(registry.adjacent_pair_keys).map(&:to_s).sort : [],
            transition_pair_keys: registry.respond_to?(:transition_pair_keys) ? Array(registry.transition_pair_keys).map(&:to_s).sort : [],
            transitions: transitions.sort_by { |row| [row[:pair_key].to_s, row[:transition_id].to_s] }
          }
        end
        private_class_method :topology_snapshot

        def topology_pair_keys(snapshot)
          (Array(snapshot[:adjacent_pair_keys]) + Array(snapshot[:transition_pair_keys])).uniq
        end
        private_class_method :topology_pair_keys

        def transition_snapshot(indoor_model, transition)
          return nil unless transition

          cell1 = transition.respond_to?(:cell1) ? transition.cell1 : nil
          cell2 = transition.respond_to?(:cell2) ? transition.cell2 : nil
          cell1_id = cell1&.id || safe_call(transition, :cell1_id)
          cell2_id = cell2&.id || safe_call(transition, :cell2_id)
          pair_key = indoor_model.send(:transition_cell_pair_key, transition)
          pair_key ||= [cell1_id, cell2_id].compact.map(&:to_s).sort.join(':')

          {
            transition_id: safe_call(transition, :id),
            pair_key: pair_key,
            valid: transition.respond_to?(:valid?) ? transition.valid? == true : nil,
            cell1_id: cell1_id,
            cell1_name: cell_name(cell1),
            cell2_id: cell2_id,
            cell2_name: cell_name(cell2),
            state1_id: safe_nested_id(transition, :state1),
            state2_id: safe_nested_id(transition, :state2)
          }
        rescue StandardError => error
          {
            transition_id: safe_call(transition, :id),
            pair_key: nil,
            error_class: error.class.name,
            error: error.message
          }
        end
        private_class_method :transition_snapshot

        def transition_geometry_snapshots(indoor_model, transition_rows)
          cells = Array(indoor_model.cell_spaces).select { |cell_space| cell_space&.valid? }
          cell_index = cells.to_h { |cell_space| [cell_space.id.to_s, cell_space] }
          Array(transition_rows).each_with_object({}) do |row, snapshots|
            cell1 = cell_index[row[:cell1_id].to_s]
            cell2 = cell_index[row[:cell2_id].to_s]
            next unless cell1 && cell2

            group1 = cell1.valid_sketchup_group
            group2 = cell2.valid_sketchup_group
            next unless group1&.valid? && group2&.valid?

            snapshots[row[:pair_key].to_s] = {
              cell1: IndoorCore::Utils::Geometry.adjacency_snapshot(group1),
              cell2: IndoorCore::Utils::Geometry.adjacency_snapshot(group2)
            }
          rescue StandardError => error
            snapshots[row[:pair_key].to_s] = {
              error_class: error.class.name,
              error: error.message
            }
          end
        end
        private_class_method :transition_geometry_snapshots

        def removed_transition_diagnostic(row, before_geometry, cell_index)
          cell1 = cell_index[row[:cell1_id].to_s]
          cell2 = cell_index[row[:cell2_id].to_s]
          geometry = before_geometry[row[:pair_key].to_s] || {}
          pre_axis = if geometry[:cell1] && geometry[:cell2]
                       IndoorCore::Utils::Geometry.adjacency_axis_from_snapshots(
                         geometry[:cell1],
                         geometry[:cell2],
                         tolerance: IndoorCore::Utils::Geometry::ADJACENCY_TOLERANCE
                       )
                     end
          post_axis = if cell1&.valid? && cell2&.valid?
                        IndoorCore::Utils::Geometry.adjacency_axis(
                          cell1.valid_sketchup_group,
                          cell2.valid_sketchup_group
                        )
                      end

          row.merge(
            adjacency_axis_before_lvn: pre_axis,
            adjacency_axis_after_lvn: post_axis,
            geometry_snapshot_error_class: geometry[:error_class],
            geometry_snapshot_error: geometry[:error]
          )
        rescue StandardError => error
          row.merge(
            diagnostic_error_class: error.class.name,
            diagnostic_error: error.message
          )
        end
        private_class_method :removed_transition_diagnostic

        def cell_name(cell_space)
          group = cell_space&.valid_sketchup_group
          group&.respond_to?(:name) ? group.name.to_s : nil
        rescue StandardError
          nil
        end
        private_class_method :cell_name

        def safe_nested_id(object, method_name)
          nested = safe_call(object, method_name)
          nested&.respond_to?(:id) ? nested.id : nil
        rescue StandardError
          nil
        end
        private_class_method :safe_nested_id

        def safe_call(object, method_name)
          object&.respond_to?(method_name) ? object.public_send(method_name) : nil
        rescue StandardError
          nil
        end
        private_class_method :safe_call

        def removed_transitions(first, second)
          counts = Hash.new(0)
          Array(second).each { |row| counts[transition_identity(row)] += 1 }
          Array(first).each_with_object([]) do |row, removed|
            key = transition_identity(row)
            if counts[key].positive?
              counts[key] -= 1
            else
              removed << row
            end
          end
        end
        private_class_method :removed_transitions

        def transition_identity(row)
          [row[:transition_id].to_s, row[:pair_key].to_s]
        end
        private_class_method :transition_identity

        def compact_lvn_report(report)
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
        private_class_method :compact_lvn_report

        def print_result(result)
          puts
          puts '=' * 90
          puts '[Precision Validation] LVN transition diff probe'
          puts "targets=#{result[:target_count]} normalized_before=#{result[:normalized_before_count]} " \
               "elapsed=#{format('%.3f', result[:elapsed_seconds])}s"
          puts "transitions=#{result[:before][:transition_count]}->#{result[:after][:transition_count]} " \
               "delta=#{result[:transition_count_delta]}"
          puts "adjacent_pairs=#{result[:before][:adjacent_pair_keys].length}->#{result[:after][:adjacent_pair_keys].length} " \
               "delta=#{result[:adjacent_pair_count_delta]}"
          puts "erased_pair_keys=#{result[:erased_pair_keys].inspect}"
          puts "removed_transition_count=#{result[:removed_transitions].length}"
          result[:removed_transitions].each do |row|
            puts "removed pair=#{row[:pair_key]} transition=#{row[:transition_id]} " \
                 "cells=#{row[:cell1_name]} <-> #{row[:cell2_name]} " \
                 "axis=#{row[:adjacency_axis_before_lvn].inspect}->#{row[:adjacency_axis_after_lvn].inspect}"
          end
          puts "lvn=#{result[:lvn_report].inspect}"
          puts "report_path=#{result[:report_path]}"
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

ULOL::Indoor3DGmlModeler::Dev::PrecisionValidationTransitionDiffProbe.run
nil
