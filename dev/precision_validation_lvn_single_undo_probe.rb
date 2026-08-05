# frozen_string_literal: true

require 'digest'
require 'json'
require 'tmpdir'
require 'time'

module ULOL
  module Indoor3DGmlModeler
    module Dev
      module PrecisionValidationLvnSingleUndoProbe
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

          targets = Array(indoor_model.cell_spaces).select { |cell_space| cell_space&.valid? }
          raise '검사할 CellSpace가 없습니다.' if targets.empty?

          before = model_snapshot(indoor_model, targets)
          unnormalized_before = before[:cell_spaces].count { |_id, row| row[:normalized] != true }
          if unnormalized_before.zero?
            raise '모든 CellSpace가 이미 normalized 상태입니다. LVN 전 원본 복사본에서 실행하세요.'
          end

          started_at = monotonic_time
          lvn_report = indoor_model.local_vertex_normalize(
            TOLERANCE_MM,
            cell_spaces: targets,
            activate_edit_context: false,
            debug: false,
            failure_policy: :continue
          )
          lvn_seconds = monotonic_time - started_at
          after_lvn = model_snapshot(indoor_model, targets)

          initial_checks = {
            single_operation_reported: lvn_report[:undo_mode] == :single_operation,
            atomic_attempted: lvn_report[:atomic_attempted] == true,
            atomic_fallback_not_used: lvn_report[:atomic_fallback] == false,
            no_lvn_failures: lvn_report[:normalization_failed_cell_space_count].to_i.zero?,
            no_previous_failure_skips:
              lvn_report[:skipped_previous_failure_cell_space_count].to_i.zero?,
            all_normalized_after_lvn:
              after_lvn[:cell_spaces].values.all? { |row| row[:normalized] == true },
            cell_space_ids_preserved:
              before[:cell_spaces].keys.sort == after_lvn[:cell_spaces].keys.sort
          }

          state = {
            finish_editing_performed: finish_editing_performed,
            before: before,
            after_lvn: after_lvn,
            lvn_report: compact_lvn_report(lvn_report),
            lvn_seconds: lvn_seconds,
            initial_checks: initial_checks,
            target_ids: targets.map { |cell_space| cell_space.id.to_s },
            phase: :awaiting_manual_undo
          }
          $precision_validation_lvn_single_undo_probe_state = state

          unless initial_checks.values.all?
            result = result_from_state(state).merge(
              overall_pass: false,
              phase: :before_undo,
              checks: initial_checks,
              failed_checks: failed_check_keys(initial_checks)
            )
            finish_result(result)
            return result
          end

          print_manual_undo_instruction(state)
          :awaiting_manual_undo
        end

        def inspect_after_undo
          state = require_state!(:awaiting_manual_undo)
          indoor_model = IndoorCore::IndoorModel.current
          after_undo = model_snapshot_by_ids(indoor_model, state[:target_ids])

          undo_checks = compare_snapshots(
            state[:before],
            after_undo,
            prefix: :undo,
            compare_normalized: true
          )
          undo_effect_observed = !snapshots_equivalent?(
            state[:after_lvn],
            after_undo,
            compare_normalized: true
          )
          undo_checks[:undo_effect_observed] = undo_effect_observed

          unless undo_effect_observed
            puts
            puts '[Precision Validation] Undo 변화가 아직 관측되지 않았습니다.'
            puts 'SketchUp 모델 창에서 Ctrl+Z를 1회 실행한 뒤 같은 확인 명령을 다시 실행하세요.'
            return :awaiting_manual_undo
          end

          state[:after_undo] = after_undo
          state[:undo_checks] = undo_checks

          unless undo_checks.values.all?
            result = result_from_state(state).merge(
              overall_pass: false,
              phase: :after_manual_undo,
              checks: merged_checks(state),
              failed_checks: failed_check_keys(merged_checks(state))
            )
            finish_result(result)
            return result
          end

          state[:phase] = :awaiting_manual_redo
          print_manual_redo_instruction
          :awaiting_manual_redo
        rescue StandardError => error
          finish_exception(:after_manual_undo, error)
        end

        def inspect_after_redo
          state = require_state!(:awaiting_manual_redo)
          indoor_model = IndoorCore::IndoorModel.current
          after_redo = model_snapshot_by_ids(indoor_model, state[:target_ids])

          redo_checks = compare_snapshots(
            state[:after_lvn],
            after_redo,
            prefix: :redo,
            compare_normalized: true
          ).merge(
            redo_all_normalized:
              after_redo[:cell_spaces].values.all? { |row| row[:normalized] == true }
          )
          redo_effect_observed = !snapshots_equivalent?(
            state[:after_undo],
            after_redo,
            compare_normalized: true
          )
          redo_checks[:redo_effect_observed] = redo_effect_observed

          unless redo_effect_observed
            puts
            puts '[Precision Validation] Redo 변화가 아직 관측되지 않았습니다.'
            puts 'SketchUp 모델 창에서 Ctrl+Y 또는 다시 실행을 1회 수행한 뒤 같은 확인 명령을 다시 실행하세요.'
            return :awaiting_manual_redo
          end

          state[:after_redo] = after_redo
          state[:redo_checks] = redo_checks
          state[:phase] = :complete

          checks = merged_checks(state)
          result = result_from_state(state).merge(
            overall_pass: checks.values.all?,
            phase: :complete,
            checks: checks,
            failed_checks: failed_check_keys(checks)
          )
          finish_result(result)
        rescue StandardError => error
          finish_exception(:after_manual_redo, error)
        end

        def reset
          $precision_validation_lvn_single_undo_probe_state = nil
          $precision_validation_lvn_single_undo_report = nil
          true
        end

        def require_state!(expected_phase)
          state = $precision_validation_lvn_single_undo_probe_state
          raise '진행 중인 LVN 단일 Undo probe가 없습니다.' unless state
          unless state[:phase] == expected_phase
            raise "probe 단계가 맞지 않습니다: expected=#{expected_phase} actual=#{state[:phase]}"
          end

          state
        end
        private_class_method :require_state!

        def print_manual_undo_instruction(state)
          puts
          puts '=' * 90
          puts '[Precision Validation] LVN single Undo probe v2'
          puts "LVN 완료: targets=#{state[:target_ids].length} " \
               "undo_mode=#{state[:lvn_report][:undo_mode].inspect} " \
               "elapsed=#{format('%.3f', state[:lvn_seconds].to_f)}s"
          puts '1) SketchUp 모델 창을 클릭합니다.'
          puts '2) Ctrl+Z를 정확히 1회 실행합니다.'
          puts '3) Ruby Console에서 아래 명령을 실행합니다.'
          puts
          puts 'ULOL::Indoor3DGmlModeler::Dev::PrecisionValidationLvnSingleUndoProbe.inspect_after_undo'
          puts 'nil'
          puts '=' * 90
        end
        private_class_method :print_manual_undo_instruction

        def print_manual_redo_instruction
          puts
          puts '=' * 90
          puts '[Precision Validation] Undo 1회 복원 통과'
          puts '1) SketchUp 모델 창을 클릭합니다.'
          puts '2) Ctrl+Y 또는 편집 > 다시 실행을 정확히 1회 수행합니다.'
          puts '3) Ruby Console에서 아래 명령을 실행합니다.'
          puts
          puts 'ULOL::Indoor3DGmlModeler::Dev::PrecisionValidationLvnSingleUndoProbe.inspect_after_redo'
          puts 'nil'
          puts '=' * 90
        end
        private_class_method :print_manual_redo_instruction

        def compare_snapshots(expected, actual, prefix:, compare_normalized:)
          expected_cells = expected[:cell_spaces]
          actual_cells = actual[:cell_spaces]
          ids_preserved = expected_cells.keys.sort == actual_cells.keys.sort
          shared_ids = expected_cells.keys & actual_cells.keys

          checks = {
            "#{prefix}_cell_space_ids_preserved".to_sym => ids_preserved,
            "#{prefix}_geometry_restored".to_sym => shared_ids.all? do |id|
              expected_cells[id][:geometry_fingerprint] == actual_cells[id][:geometry_fingerprint]
            end,
            "#{prefix}_persistent_ids_preserved".to_sym => shared_ids.all? do |id|
              expected_cells[id][:persistent_id] == actual_cells[id][:persistent_id]
            end,
            "#{prefix}_transformations_preserved".to_sym => shared_ids.all? do |id|
              expected_cells[id][:transformation] == actual_cells[id][:transformation]
            end,
            "#{prefix}_manifold_states_preserved".to_sym => shared_ids.all? do |id|
              expected_cells[id][:manifold] == actual_cells[id][:manifold]
            end,
            "#{prefix}_cell_space_count_preserved".to_sym =>
              expected[:cell_space_count] == actual[:cell_space_count],
            "#{prefix}_state_count_preserved".to_sym =>
              expected[:state_count] == actual[:state_count]
          }
          if compare_normalized
            checks["#{prefix}_normalized_states_preserved".to_sym] = shared_ids.all? do |id|
              expected_cells[id][:normalized] == actual_cells[id][:normalized]
            end
          end
          checks
        end
        private_class_method :compare_snapshots

        def snapshots_equivalent?(first, second, compare_normalized:)
          checks = compare_snapshots(
            first,
            second,
            prefix: :equivalent,
            compare_normalized: compare_normalized
          )
          checks.values.all?
        end
        private_class_method :snapshots_equivalent?

        def model_snapshot(indoor_model, targets)
          cells = Array(targets).to_h do |cell_space|
            [cell_space.id.to_s, cell_snapshot(cell_space)]
          end
          diagnostic = indoor_model.respond_to?(:diagnostic_snapshot) ? indoor_model.diagnostic_snapshot : {}
          {
            cell_space_count: diagnostic[:cell_spaces] || cells.length,
            state_count: diagnostic[:states] || Array(indoor_model.states).length,
            transition_count: diagnostic[:transitions] || Array(indoor_model.transitions).length,
            cell_spaces: cells
          }
        end
        private_class_method :model_snapshot

        def model_snapshot_by_ids(indoor_model, ids)
          index = Array(indoor_model.cell_spaces).select { |cell_space| cell_space&.valid? }
                                            .to_h { |cell_space| [cell_space.id.to_s, cell_space] }
          targets = Array(ids).filter_map { |id| index[id.to_s] }
          model_snapshot(indoor_model, targets)
        end
        private_class_method :model_snapshot_by_ids

        def cell_snapshot(cell_space)
          group = cell_space.valid_sketchup_group
          return { available: false } unless group&.valid?

          {
            available: true,
            persistent_id: safe_persistent_id(group),
            transformation: group.transformation.to_a.map { |value| float_key(value) },
            manifold: group.respond_to?(:manifold?) && group.manifold? == true,
            normalized: IndoorCore::LocalVertexNormalizer.normalized?(group, TOLERANCE_MM),
            geometry_fingerprint: geometry_fingerprint(group)
          }
        rescue StandardError => error
          {
            available: false,
            error_class: error.class.name,
            error: error.message
          }
        end
        private_class_method :cell_snapshot

        def geometry_fingerprint(group)
          entities = group.definition.entities
          edges = entities.grep(Sketchup::Edge).select(&:valid?)
          faces = entities.grep(Sketchup::Face).select(&:valid?)
          vertices = (
            edges.flat_map { |edge| Array(edge.vertices) } +
            faces.flat_map { |face| Array(face.vertices) }
          ).uniq

          records = []
          vertices.map { |vertex| "v|#{point_key(vertex.position)}" }.sort.each { |row| records << row }
          edges.filter_map { |edge| edge_record(edge) }.sort.each { |row| records << row }
          faces.filter_map { |face| face_record(face) }.sort.each { |row| records << row }
          Digest::SHA256.hexdigest(records.join("\n"))
        end
        private_class_method :geometry_fingerprint

        def edge_record(edge)
          points = Array(edge.vertices).map { |vertex| point_key(vertex.position) }
          return nil unless points.length == 2

          "e|#{points.sort.join('|')}"
        end
        private_class_method :edge_record

        def face_record(face)
          normal = face.respond_to?(:normal) ? vector_key(face.normal) : 'n/a'
          loops = Array(face.loops).filter_map do |loop|
            points = Array(loop.vertices).map { |vertex| point_key(vertex.position) }
            next if points.empty?

            type = face.respond_to?(:outer_loop) && loop == face.outer_loop ? 'outer' : 'inner'
            "#{type}|#{canonical_cycle(points).join('|')}"
          end.sort
          "f|n=#{normal}|#{loops.join('||')}"
        end
        private_class_method :face_record

        def canonical_cycle(values)
          rows = Array(values)
          return rows if rows.length <= 1

          forward = rows.each_index.map { |index| rows.rotate(index) }.min
          reversed_rows = rows.reverse
          reverse = reversed_rows.each_index.map { |index| reversed_rows.rotate(index) }.min
          [forward, reverse].min
        end
        private_class_method :canonical_cycle

        def point_key(point)
          [point.x, point.y, point.z].map { |value| float_key(value) }.join(',')
        end
        private_class_method :point_key

        def vector_key(vector)
          [vector.x, vector.y, vector.z].map { |value| float_key(value) }.join(',')
        end
        private_class_method :vector_key

        def float_key(value)
          [value.to_f].pack('G').unpack1('H*')
        end
        private_class_method :float_key

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
            undo_mode
            atomic_attempted
            atomic_fallback
            atomic_error_class
            atomic_error
          ]
          source = Hash(report)
          keys.to_h { |key| [key, source[key]] }
        end
        private_class_method :compact_lvn_report

        def base_result(state)
          {
            schema: 'ulol.precision_validation.lvn_single_undo_probe.v2',
            generated_at: Time.now.iso8601(3),
            tolerance_mm: TOLERANCE_MM,
            finish_editing_performed: state[:finish_editing_performed],
            lvn_seconds: state[:lvn_seconds],
            lvn_report: state[:lvn_report],
            before: state[:before],
            after_lvn: state[:after_lvn]
          }
        end
        private_class_method :base_result

        def result_from_state(state)
          base_result(state).merge(
            after_undo: state[:after_undo],
            after_redo: state[:after_redo]
          )
        end
        private_class_method :result_from_state

        def merged_checks(state)
          Hash(state[:initial_checks]).merge(Hash(state[:undo_checks])).merge(Hash(state[:redo_checks]))
        end
        private_class_method :merged_checks

        def failed_check_keys(checks)
          Hash(checks).select { |_key, value| value != true }.keys
        end
        private_class_method :failed_check_keys

        def finish_exception(phase, error)
          state = $precision_validation_lvn_single_undo_probe_state || {}
          result = result_from_state(state).merge(
            overall_pass: false,
            phase: phase,
            checks: merged_checks(state),
            failed_checks: [phase],
            error_class: error.class.name,
            error: error.message
          )
          finish_result(result)
        rescue StandardError => nested_error
          warn "[Precision Validation] LVN single Undo probe report failure: #{nested_error.class}: #{nested_error.message}"
        end
        private_class_method :finish_exception

        def finish_result(result)
          timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
          path = File.join(
            Dir.tmpdir,
            "indoor_gml_precision_lvn_single_undo_#{timestamp}.json"
          )
          File.write(path, JSON.pretty_generate(json_safe(result)))
          result[:report_path] = path
          $precision_validation_lvn_single_undo_report = result
          print_result(result)
          result
        end
        private_class_method :finish_result

        def print_result(result)
          puts
          puts '=' * 90
          puts '[Precision Validation] LVN single Undo probe v2'
          puts "overall_pass=#{result[:overall_pass]} phase=#{result[:phase]}"
          report = result[:lvn_report] || {}
          puts "undo_mode=#{report[:undo_mode].inspect} " \
               "atomic=#{report[:atomic_attempted].inspect}/#{report[:atomic_fallback].inspect} " \
               "elapsed=#{format('%.3f', result[:lvn_seconds].to_f)}s"
          puts "failed_checks=#{Array(result[:failed_checks]).join(',')}"
          if result[:before] && result[:after_undo] && result[:after_redo]
            puts "transitions=#{result[:before][:transition_count]}->" \
                 "#{result[:after_lvn][:transition_count]}->" \
                 "#{result[:after_undo][:transition_count]}->" \
                 "#{result[:after_redo][:transition_count]} (diagnostic only)"
          end
          puts "error=#{result[:error_class]}: #{result[:error]}" if result[:error]
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

ULOL::Indoor3DGmlModeler::Dev::PrecisionValidationLvnSingleUndoProbe.run
nil
