# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'time'

module ULOL
  module Indoor3DGmlModeler
    module Dev
      module PrecisionValidationTransitionDiffProbe
        module_function

        def run
          model = Sketchup.active_model
          indoor_model = IndoorCore::IndoorModel.current

          raise 'IndoorGML Edit Mode를 종료한 뒤 실행하세요.' if indoor_model.editing?
          raise 'Root context에서 실행하세요.' unless root_context?(model)

          registry = indoor_model.instance_variable_get(:@feature_registry)
          before = topology_snapshot(indoor_model, registry)
          erased_pair_keys = []
          upserted_pair_keys = []
          metrics = nil

          indoor_model.with_indoor_model_operation('IndoorGML Transition Diff Probe') do
            indoor_model.send(:sync) do
              metrics = indoor_model.send(:topology_coordinator).synchronize_all(
                transition_builder: proc do |cell1, cell2|
                  pair_key = indoor_model.send(:cell_pair_key, cell1, cell2)
                  upserted_pair_keys << pair_key
                  indoor_model.send(:create_or_update_transition_for_pair, cell1, cell2)
                end,
                transition_eraser: proc do |pair_key|
                  erased_pair_keys << pair_key
                  indoor_model.send(:erase_transition_for_pair_key, pair_key)
                end
              )
            end
          end

          after = topology_snapshot(indoor_model, registry)
          result = {
            schema: 'ulol.precision_validation.transition_diff_probe.v1',
            generated_at: Time.now.iso8601(3),
            before: before,
            after: after,
            transition_count_delta: after[:transition_count] - before[:transition_count],
            adjacent_pair_count_delta: after[:adjacent_pair_keys].length - before[:adjacent_pair_keys].length,
            erased_pair_keys: erased_pair_keys.uniq.sort,
            upserted_pair_keys: upserted_pair_keys.uniq.sort,
            removed_transitions: removed_transitions(before[:transitions], after[:transitions]),
            added_transitions: removed_transitions(after[:transitions], before[:transitions]),
            metrics: metrics
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

        def print_result(result)
          puts
          puts '=' * 90
          puts '[Precision Validation] Transition diff probe'
          puts "transitions=#{result[:before][:transition_count]}->#{result[:after][:transition_count]} delta=#{result[:transition_count_delta]}"
          puts "adjacent_pairs=#{result[:before][:adjacent_pair_keys].length}->#{result[:after][:adjacent_pair_keys].length} delta=#{result[:adjacent_pair_count_delta]}"
          puts "erased_pair_keys=#{result[:erased_pair_keys].inspect}"
          puts "removed_transition_count=#{result[:removed_transitions].length}"
          result[:removed_transitions].each do |row|
            puts "removed pair=#{row[:pair_key]} transition=#{row[:transition_id]} " \
                 "cells=#{row[:cell1_name]} <-> #{row[:cell2_name]}"
          end
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
          else
            value
          end
        end
        private_class_method :json_safe
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::Dev::PrecisionValidationTransitionDiffProbe.run
nil
