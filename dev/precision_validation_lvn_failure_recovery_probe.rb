# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'time'

module ULOL
  module Indoor3DGmlModeler
    module Dev
      module PrecisionValidationLvnFailureRecoveryProbe
        TOLERANCE_MM = IndoorCore::LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
        GEOMETRY_CHANGE_MM = 0.0004
        BOUNDS_EPSILON_MM = 0.000001
        VOLUME_EPSILON_MM3 = 0.001
        TRANSFORM_EPSILON = 1.0e-12

        class InjectedFailure < StandardError; end

        module_function

        def run(cell_space_id: nil)
          model = Sketchup.active_model
          indoor_model = IndoorCore::IndoorModel.current
          finish_editing_performed = false

          if indoor_model.editing?
            finish_editing_performed = true
            raise 'IndoorGML Edit Mode 종료에 실패했습니다.' unless indoor_model.finish_editing
          end

          raise 'Root context에서 실행하세요.' unless root_context?(model)

          cell_space = resolve_target(indoor_model, cell_space_id)
          group = cell_space.valid_sketchup_group
          raise '검사 대상 CellSpace geometry를 찾을 수 없습니다.' unless group&.valid?

          baseline = cell_snapshot(group)
          transition_count_before = Array(indoor_model.transitions).length
          injection_count = 0
          original_normalized = IndoorCore::LocalVertexNormalizer.method(:normalized?)
          original_normalize_group = indoor_model.method(:normalize_cell_space_group)
          target_id = cell_space.id.to_s
          target_pid = safe_persistent_id(group)
          singleton_class = indoor_model.singleton_class

          if singleton_class.instance_methods(false).include?(:normalize_cell_space_group) ||
             singleton_class.private_instance_methods(false).include?(:normalize_cell_space_group)
            raise 'IndoorModel singleton에 normalize_cell_space_group override가 이미 존재합니다.'
          end

          first_report = nil
          second_report = nil
          third_report = nil
          after_failure = nil
          after_skip = nil
          after_change = nil
          final = nil

          begin
            install_normalized_override(original_normalized, target_pid)

            indoor_model.define_singleton_method(:normalize_cell_space_group) do |candidate, candidate_group, tolerance_mm, **options|
              if candidate&.id.to_s == target_id && injection_count.zero?
                injection_count += 1
                Dev::PrecisionValidationLvnFailureRecoveryProbe.translate_definition_geometry(
                  candidate_group,
                  GEOMETRY_CHANGE_MM
                )
                raise InjectedFailure, 'Intentional LVN failure injection after geometry mutation'
              end

              original_normalize_group.call(
                candidate,
                candidate_group,
                tolerance_mm,
                **options
              )
            end
            singleton_class.send(:private, :normalize_cell_space_group)

            first_report = run_lvn(indoor_model, cell_space)
            group = cell_space.valid_sketchup_group
            after_failure = cell_snapshot(group)

            second_report = run_lvn(indoor_model, cell_space)
            group = cell_space.valid_sketchup_group
            after_skip = cell_snapshot(group)

            indoor_model.with_indoor_model_operation("LVN failure retry geometry change #{target_id}") do
              indoor_model.send(:sync) do
                translate_definition_geometry(group, GEOMETRY_CHANGE_MM)
                indoor_model.send(:remember_cell_space_change_snapshot, group)
              end
            end
            group = cell_space.valid_sketchup_group
            after_change = cell_snapshot(group)
            after_change[:changed_since_failure] =
              IndoorCore::PrecisionValidation::LvnState.geometry_changed_since_failure?(group)

            third_report = run_lvn(indoor_model, cell_space)
          ensure
            restore_normalized_override(original_normalized)
            singleton_class.send(:remove_method, :normalize_cell_space_group) if
              singleton_class.instance_methods(false).include?(:normalize_cell_space_group) ||
              singleton_class.private_instance_methods(false).include?(:normalize_cell_space_group)
          end

          group = cell_space.valid_sketchup_group
          final = cell_snapshot(group)
          transition_count_after = Array(indoor_model.transitions).length

          first_row = report_row(first_report, target_id)
          second_row = report_row(second_report, target_id)
          third_row = report_row(third_report, target_id)

          checks = {
            target_group_unique: baseline[:definition_instance_count] == 1,
            injected_once: injection_count == 1,
            first_status_failed: first_row[:status] == :failed,
            rollback_geometry_signature_preserved:
              baseline[:geometry_signature] == after_failure[:geometry_signature],
            rollback_bounds_preserved:
              bounds_delta_mm(baseline[:bounds_mm], after_failure[:bounds_mm]) <= BOUNDS_EPSILON_MM,
            rollback_volume_preserved:
              numeric_delta(baseline[:volume_mm3], after_failure[:volume_mm3]).abs <= VOLUME_EPSILON_MM3,
            rollback_persistent_id_preserved:
              baseline[:persistent_id] == after_failure[:persistent_id],
            rollback_transformation_preserved:
              transformation_equal?(baseline[:transformation], after_failure[:transformation]),
            rollback_manifold_preserved: after_failure[:manifold] == true,
            failure_marked: after_failure[:lvn_failed] == true,
            failure_signature_matches_geometry:
              after_failure[:failure_signature] == after_failure[:geometry_signature],
            second_status_skipped: second_row[:status] == :skipped_previous_failure,
            skip_geometry_signature_preserved:
              after_failure[:geometry_signature] == after_skip[:geometry_signature],
            skip_failure_state_preserved: after_skip[:lvn_failed] == true,
            controlled_geometry_change_applied:
              after_change[:geometry_signature] != after_skip[:geometry_signature],
            geometry_change_detected: after_change[:changed_since_failure] == true,
            third_status_normalized: third_row[:status] == :normalized,
            final_failure_cleared: final[:lvn_failed] == false,
            final_failure_signature_cleared: final[:failure_signature].nil?,
            final_normalized: final[:normalized] == true,
            final_manifold: final[:manifold] == true,
            final_persistent_id_preserved: baseline[:persistent_id] == final[:persistent_id],
            final_transformation_preserved:
              transformation_equal?(baseline[:transformation], final[:transformation])
          }

          result = {
            schema: 'ulol.precision_validation.lvn_failure_recovery_probe.v1',
            generated_at: Time.now.iso8601(3),
            tolerance_mm: TOLERANCE_MM,
            geometry_change_mm: GEOMETRY_CHANGE_MM,
            cell_space_id: target_id,
            cell_space_name: group.respond_to?(:name) ? group.name.to_s : nil,
            finish_editing_performed: finish_editing_performed,
            overall_pass: checks.values.all?,
            checks: checks,
            failed_checks: checks.select { |_key, value| value != true }.keys,
            injection_count: injection_count,
            phase_statuses: {
              failure: first_row[:status],
              unchanged_retry: second_row[:status],
              changed_retry: third_row[:status]
            },
            phase_errors: {
              failure: compact_error(first_row),
              unchanged_retry: compact_error(second_row),
              changed_retry: compact_error(third_row)
            },
            baseline: baseline,
            after_failure: after_failure,
            after_skip: after_skip,
            after_change: after_change,
            final: final,
            transition_count_before: transition_count_before,
            transition_count_after: transition_count_after,
            transition_count_delta: transition_count_after - transition_count_before
          }

          output_path = write_result(result)
          result[:output_path] = output_path
          $precision_validation_lvn_failure_recovery_report = result
          print_result(result)
          result
        end

        def resolve_target(indoor_model, cell_space_id)
          candidates = Array(indoor_model.cell_spaces).select do |cell_space|
            next false unless cell_space&.valid?

            group = cell_space.valid_sketchup_group
            next false unless group&.valid?
            next false if group.respond_to?(:locked?) && group.locked?
            next false unless group.respond_to?(:manifold?) && group.manifold?
            next false unless group.definition&.respond_to?(:entities)
            next false unless group.definition.entities.grep(Sketchup::Edge).any?

            definition_instances(group).length == 1
          rescue StandardError
            false
          end

          if cell_space_id
            target = candidates.find { |cell_space| cell_space.id.to_s == cell_space_id.to_s }
            raise "검사 가능한 CellSpace를 찾지 못했습니다: #{cell_space_id}" unless target

            return target
          end

          target = candidates.min_by do |cell_space|
            group = cell_space.valid_sketchup_group
            group.definition.entities.grep(Sketchup::Face).length
          rescue StandardError
            Float::INFINITY
          end
          raise '검사 가능한 독립 manifold CellSpace가 없습니다.' unless target

          target
        end
        private_class_method :resolve_target

        def run_lvn(indoor_model, cell_space)
          indoor_model.local_vertex_normalize(
            TOLERANCE_MM,
            cell_spaces: [cell_space],
            activate_edit_context: false,
            debug: false,
            failure_policy: :continue
          )
        end
        private_class_method :run_lvn

        def install_normalized_override(original, target_pid)
          normalizer = IndoorCore::LocalVertexNormalizer
          normalizer.define_singleton_method(:normalized?) do |candidate, *args, **kwargs, &block|
            group = if candidate.respond_to?(:valid_sketchup_group)
                      candidate.valid_sketchup_group
                    elsif candidate.respond_to?(:sketchup_group)
                      candidate.sketchup_group
                    else
                      candidate
                    end
            pid = begin
              group.persistent_id if group&.respond_to?(:persistent_id)
            rescue StandardError
              nil
            end

            return false if pid == target_pid

            original.call(candidate, *args, **kwargs, &block)
          end
        end
        private_class_method :install_normalized_override

        def restore_normalized_override(original)
          IndoorCore::LocalVertexNormalizer.define_singleton_method(:normalized?, original)
        end
        private_class_method :restore_normalized_override

        def translate_definition_geometry(group, delta_mm)
          raise 'CellSpace group is unavailable' unless group&.valid?

          entities = group.definition.entities
          edges = entities.grep(Sketchup::Edge).select(&:valid?)
          raise 'CellSpace definition has no movable edges' if edges.empty?

          vector = Geom::Vector3d.new(delta_mm.mm, 0.0, 0.0)
          entities.transform_entities(Geom::Transformation.translation(vector), edges)
          true
        end

        def cell_snapshot(group)
          return { available: false } unless group&.valid?

          bounds = group.bounds
          {
            available: true,
            persistent_id: safe_persistent_id(group),
            definition_instance_count: definition_instances(group).length,
            manifold: group.respond_to?(:manifold?) && group.manifold? == true,
            locked: group.respond_to?(:locked?) ? group.locked? == true : nil,
            transformation: group.transformation.to_a.map(&:to_f),
            volume_mm3: volume_mm3(group),
            bounds_mm: {
              min: point_mm(bounds.min),
              max: point_mm(bounds.max)
            },
            geometry_signature:
              IndoorCore::PrecisionValidation::LvnState.geometry_signature(group),
            lvn_failed: IndoorCore::PrecisionValidation::LvnState.failed?(group),
            failure_signature:
              IndoorCore::PrecisionValidation::LvnState.failure_signature(group),
            normalized: IndoorCore::LocalVertexNormalizer.normalized?(group, TOLERANCE_MM)
          }
        rescue StandardError => error
          {
            available: false,
            error_class: error.class.name,
            error: error.message
          }
        end
        private_class_method :cell_snapshot

        def report_row(report, target_id)
          row = Array(report && report[:cell_spaces]).find do |candidate|
            candidate[:cell_space_id].to_s == target_id.to_s
          end
          row || {}
        end
        private_class_method :report_row

        def compact_error(row)
          {
            error_class: row[:error_class],
            error: row[:error]
          }
        end
        private_class_method :compact_error

        def definition_instances(group)
          definition = group&.definition
          return [] unless definition&.respond_to?(:instances)

          Array(definition.instances).select { |instance| instance&.valid? }
        rescue StandardError
          []
        end
        private_class_method :definition_instances

        def root_context?(model)
          path = model.active_path
          path.nil? || path.empty?
        rescue StandardError
          false
        end
        private_class_method :root_context?

        def safe_persistent_id(entity)
          entity.respond_to?(:persistent_id) ? entity.persistent_id : nil
        rescue StandardError
          nil
        end
        private_class_method :safe_persistent_id

        def volume_mm3(group)
          group.volume.to_f * (25.4**3)
        rescue StandardError
          nil
        end
        private_class_method :volume_mm3

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
          return Float::INFINITY if before.nil? || after.nil?

          after.to_f - before.to_f
        end
        private_class_method :numeric_delta

        def transformation_equal?(before, after)
          return false unless before.is_a?(Array) && after.is_a?(Array)
          return false unless before.length == after.length

          before.zip(after).all? do |first, second|
            (first.to_f - second.to_f).abs <= TRANSFORM_EPSILON
          end
        end
        private_class_method :transformation_equal?

        def write_result(result)
          timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
          path = File.join(
            Dir.tmpdir,
            "indoor_gml_precision_lvn_failure_recovery_#{timestamp}.json"
          )
          File.write(path, JSON.pretty_generate(json_safe(result)))
          path
        end
        private_class_method :write_result

        def print_result(result)
          puts
          puts '=' * 90
          puts '[Precision Validation] LVN failure recovery probe'
          puts "overall_pass=#{result[:overall_pass]} cell=#{result[:cell_space_id]} " \
               "name=#{result[:cell_space_name]}"
          puts "statuses=#{result[:phase_statuses].inspect} injection_count=#{result[:injection_count]}"
          puts "failed_checks=#{result[:failed_checks].join(',')}"
          puts "transition_count=#{result[:transition_count_before]}->#{result[:transition_count_after]} " \
               "delta=#{result[:transition_count_delta]} (diagnostic only)"
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
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::Dev::PrecisionValidationLvnFailureRecoveryProbe.run
nil
