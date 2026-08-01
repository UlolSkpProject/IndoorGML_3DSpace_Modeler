# frozen_string_literal: true

# Lightweight one-shot smoke probe for the normal Local Grid V2 bulk Create path.
# It does not snapshot geometry vertices or time individual CellSpaces.
#
# SketchUp Ruby Console:
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#
#   load File.join(
#     root,
#     'dev',
#     'cell_space_direct_copy_bulk_smoke.rb'
#   )
#
# Then run the normal Local Grid V2 Create command/button once.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceDirectCopyBulkSmoke
        class << self
          def install!
            service = IndoorCore::BulkCellSpaceConversionService
            service.prepend(ServiceProbe) unless service.ancestors.include?(ServiceProbe)
            arm!
            puts '[CELLSPACE DIRECT COPY BULK SMOKE] armed for the next bulk CellSpace Create'
            puts "Log: #{log_path}"
            true
          rescue StandardError => e
            puts "[CELLSPACE DIRECT COPY BULK SMOKE] install failed: #{e.class}: #{e.message}"
            puts e.backtrace.first(10).join("\n")
            false
          end

          def arm!
            @armed = true
            true
          end

          def disarm!
            @armed = false
            true
          end

          def armed?
            @armed == true
          end

          def capture(service)
            return yield unless armed?

            disarm!
            model = service.instance_variable_get(:@model) || Sketchup.active_model
            jobs = Array(service.instance_variable_get(:@jobs))
            operation_name = service.instance_variable_get(:@operation_name).to_s
            primal_before = find_primal_group(model)
            before_cells = current_cell_groups(primal_before)
            before_cell_keys = before_cells.map { |entity| entity_key(entity) }
            before_components = direct_components(primal_before)
            before_component_keys = before_components.map { |entity| entity_key(entity) }

            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = yield
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

            report = build_report(
              model: model,
              jobs: jobs,
              operation_name: operation_name,
              result: result,
              elapsed: elapsed,
              before_cell_keys: before_cell_keys,
              before_component_keys: before_component_keys
            )
            print_report(report)
            write_log(report)
            result
          rescue StandardError => e
            puts "[CELLSPACE DIRECT COPY BULK SMOKE] probe failed: #{e.class}: #{e.message}"
            puts e.backtrace.first(15).join("\n")
            raise
          end

          def build_report(model:, jobs:, operation_name:, result:, elapsed:, before_cell_keys:, before_component_keys:)
            primal = find_primal_group(model)
            all_cells = current_cell_groups(primal)
            new_cells = all_cells.reject { |entity| before_cell_keys.include?(entity_key(entity)) }
            new_components = direct_components(primal).reject do |entity|
              before_component_keys.include?(entity_key(entity))
            end
            direct_cells = new_cells.select do |group|
              begin
                Utils::Transformation.direct_child_of_root?(group, primal)
              rescue StandardError
                primal&.valid? && primal.entities.to_a.include?(group)
              end
            end

            metrics = result&.metrics || {}
            converted = result&.converted_count.to_i
            errors = Array(result&.errors)
            job_count = jobs.length
            passed = converted == job_count &&
                     errors.empty? &&
                     new_cells.length == converted &&
                     direct_cells.length == new_cells.length &&
                     new_components.empty?

            {
              operation_name: operation_name,
              jobs: job_count,
              converted: converted,
              errors: errors,
              cells_before: before_cell_keys.length,
              cells_after: all_cells.length,
              new_cells: new_cells.length,
              direct_cells: direct_cells.length,
              new_components: new_components.map { |entity| label(entity) },
              elapsed: elapsed,
              preflight: metrics[:preflight_duration].to_f,
              create: metrics[:cell_space_state_duration].to_f,
              adjacency: metrics[:adjacency_transition_duration].to_f,
              total: metrics[:total_duration].to_f,
              pair_comparisons: metrics[:pair_comparison_count].to_i,
              passed: passed
            }
          end

          def print_report(report)
            lines = report_lines(report)
            puts
            lines.each { |line| puts line }
            puts "Log: #{log_path}"
          end

          def write_log(report)
            File.write(log_path, report_lines(report).join("\n") + "\n")
          rescue StandardError => e
            puts "[CELLSPACE DIRECT COPY BULK SMOKE] log write failed: #{e.class}: #{e.message}"
          end

          def report_lines(report)
            create_delta = delta(report[:create], 67.171)
            adjacency_delta = delta(report[:adjacency], 80.083)
            total_delta = delta(report[:total], 170.182)
            lines = []
            lines << '=' * 100
            lines << 'CellSpace Direct Copy Bulk Smoke — LIGHTWEIGHT'
            lines << '=' * 100
            lines << "Operation                 : #{report[:operation_name]}"
            lines << "Jobs                      : #{report[:jobs]}"
            lines << "Converted                 : #{report[:converted]}"
            lines << "Errors                    : #{report[:errors].length}"
            report[:errors].first(20).each do |error|
              lines << "  - #{error[:group]}: #{error[:reason]}"
            end
            lines << '-' * 100
            lines << "New CellSpaces            : #{report[:new_cells]}/#{report[:converted]} #{pass_fail(report[:new_cells] == report[:converted])}"
            lines << "Direct Primal children    : #{report[:direct_cells]}/#{report[:new_cells]} #{pass_fail(report[:direct_cells] == report[:new_cells])}"
            lines << "New ComponentInstances    : #{report[:new_components].length} #{pass_fail(report[:new_components].empty?)}"
            report[:new_components].first(20).each { |label| lines << "  - #{label}" }
            lines << "CellSpace total           : #{report[:cells_before]} -> #{report[:cells_after]}"
            lines << '-' * 100
            lines << format('Preflight                 : %10.3f sec', report[:preflight])
            lines << format('CellSpace/State           : %10.3f sec  vs 67.171  (%+.3f, %+.1f%%)', report[:create], create_delta[:seconds], create_delta[:percent])
            lines << format('Adjacency/Transition      : %10.3f sec  vs 80.083  (%+.3f, %+.1f%%)', report[:adjacency], adjacency_delta[:seconds], adjacency_delta[:percent])
            lines << format('Total metric              : %10.3f sec  vs 170.182 (%+.3f, %+.1f%%)', report[:total], total_delta[:seconds], total_delta[:percent])
            lines << format('Wrapper elapsed           : %10.3f sec', report[:elapsed])
            lines << "Pair comparisons          : #{report[:pair_comparisons]}"
            lines << '-' * 100
            lines << (report[:passed] ? 'OVERALL: PASS' : 'OVERALL: FAIL')
            lines << '=' * 100
            lines
          end

          def delta(current, baseline)
            seconds = current.to_f - baseline.to_f
            percent = baseline.to_f.zero? ? 0.0 : (seconds / baseline.to_f) * 100.0
            { seconds: seconds, percent: percent }
          end

          def pass_fail(value)
            value ? 'PASS' : 'FAIL'
          end

          def find_primal_group(model)
            return nil unless model

            dictionary = IndoorModel::ATTRIBUTE_DICTIONARY_NAME
            model.entities.grep(Sketchup::Group).find do |group|
              group&.valid? && (
                group.get_attribute(dictionary, 'feature') == 'PrimalSpaceFeatures' ||
                group.name.to_s == 'IndoorGML_PrimalSpaceFeatures'
              )
            end
          rescue StandardError
            model.entities.grep(Sketchup::Group).find do |group|
              group&.valid? && group.name.to_s == 'IndoorGML_PrimalSpaceFeatures'
            end
          end

          def current_cell_groups(primal)
            return [] unless primal&.valid?

            dictionary = IndoorModel::ATTRIBUTE_DICTIONARY_NAME
            primal.entities.grep(Sketchup::Group).select do |group|
              group&.valid? && group.get_attribute(dictionary, 'feature') == 'CellSpace'
            end
          rescue StandardError
            []
          end

          def direct_components(primal)
            return [] unless primal&.valid?
            return [] unless defined?(Sketchup::ComponentInstance)

            primal.entities.grep(Sketchup::ComponentInstance).select(&:valid?)
          rescue StandardError
            []
          end

          def entity_key(entity)
            if entity.respond_to?(:persistent_id)
              persistent_id = entity.persistent_id
              return [:persistent_id, persistent_id] if persistent_id && persistent_id != 0
            end
            return [:entity_id, entity.entityID] if entity.respond_to?(:entityID)

            [:object_id, entity.object_id]
          rescue StandardError
            [:object_id, entity.object_id]
          end

          def label(entity)
            name = entity.respond_to?(:name) ? entity.name.to_s : ''
            id = entity.respond_to?(:entityID) ? entity.entityID : nil
            base = name.empty? ? entity.class.name.to_s : name
            id ? "#{base} [entity #{id}]" : base
          rescue StandardError
            entity.to_s
          end

          def log_path
            @log_path ||= File.join(
              ENV['TEMP'] || ENV['TMP'] || '.',
              'IndoorGML_CellSpace_Direct_Copy_Bulk_Smoke.log'
            )
          end
        end

        module ServiceProbe
          def call
            CellSpaceDirectCopyBulkSmoke.capture(self) { super }
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceDirectCopyBulkSmoke.install!
