# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_v3_coplanar_tolerance_policy_control'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only positive control for the complete 701 extension policy.
        #
        # The target is offset in X/Y, so the exact overlap prism is
        # 800 mm * 850 mm * depth without fully coplanar side faces.
        # Every configured depth is required to be greater than tolerance.
        module Val3dityRecheckV3PositiveControl
          MODE = 'v3_partial_xy_positive_control'
          BOX_SIZE_MM = 1000.0
          OFFSET_X_MM = 200.0
          OFFSET_Y_MM = 150.0
          OVERLAP_AREA_MM2 =
            (BOX_SIZE_MM - OFFSET_X_MM) * (BOX_SIZE_MM - OFFSET_Y_MM)

          DEFAULT_GRID_PAIRS = [[1, 1], [2, 3], [4, 5]].freeze
          DEFAULT_PATTERN_PAIRS = [
            %w[forward reverse],
            %w[checker row_stripes]
          ].freeze
          DEFAULT_DEPTHS_MM = [0.03, 0.0508, 0.1, 0.5, 1.0].freeze
          DEFAULT_ORDERS = %w[ab ba].freeze
          ABS_VOLUME_EPSILON_MM3 = 1.0e-3
          REL_VOLUME_EPSILON = 1.0e-8
          DEPTH_EPSILON_MM = 1.0e-9

          Base = Val3dityRecheckV3CoplanarComplexityControl
          OriginalHarness = Val3dityRecheckV3ControlGeometry::OriginalHarness
          V3Harness = Val3dityRecheckV3ControlGeometry::V3Harness

          class PolicyHarness < Val3dityRunner
            def initialize(rechecker)
              @overlap_geometry_rechecker = rechecker
            end

            def decision(analysis)
              send(:overlap_recheck_701_decision, analysis)
            end
          end

          class << self
            attr_reader :last_result_path, :last_progress_path, :last_report

            def run(grid_pairs: DEFAULT_GRID_PAIRS,
                    pattern_pairs: DEFAULT_PATTERN_PAIRS,
                    depths_mm: DEFAULT_DEPTHS_MM,
                    orders: DEFAULT_ORDERS,
                    repeats: 2,
                    output_dir: nil,
                    report_name: nil,
                    indoor_model: nil)
              indoor_model ||= IndoorCore::IndoorModel.current
              model = indoor_model&.model || Sketchup.active_model
              raise 'Active SketchUp model is unavailable.' unless model
              raise 'IndoorModel.current is not bound to the active model.' unless
                indoor_model&.model == model

              grids = base(:normalize_grid_pairs, grid_pairs)
              patterns = base(:normalize_pattern_pairs, pattern_pairs)
              orders = base(:normalize_orders, orders)
              depths = Array(depths_mm).map { |value| Float(value) }
              repeats = Integer(repeats)
              raise ArgumentError, 'repeats must be at least 1.' if repeats < 1

              tolerance_in = Val3dityRunner::OVERLAP_RECHECK_TOLERANCE
              tolerance_mm = tolerance_in.to_f * 25.4
              unless depths.all? do |depth|
                       depth > tolerance_mm + DEPTH_EPSILON_MM
                     end
                raise ArgumentError,
                      "All positive-control depths must exceed #{tolerance_mm} mm."
              end

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              output_dir = File.expand_path(
                output_dir || File.join(
                  __dir__, 'recheck_snapshots', 'control_geometry',
                  'partial_xy_positive', stamp
                )
              )
              FileUtils.mkdir_p(output_dir)
              name = base(
                :sanitize_name,
                report_name || "v3_partial_xy_positive_#{stamp}"
              )
              @last_result_path = File.join(output_dir, "#{name}.json")
              @last_progress_path =
                File.join(output_dir, "#{name}_progress.jsonl")
              File.write(@last_progress_path, '', encoding: 'UTF-8')

              cases = base(
                :enumerate_cases, grids, patterns, depths, orders, repeats
              )
              rows = []
              started = monotonic_now

              indoor_model.with_indoor_model_operation(
                'IndoorGML v3 partial-XY positive control',
                rollback: true
              ) do
                container = model.entities.add_group
                container.name = '__INDOORGML_V3_POSITIVE_CONTROL__'

                cases.each_with_index do |definition, index|
                  row = run_case(
                    container.entities,
                    indoor_model,
                    model,
                    tolerance_in,
                    tolerance_mm,
                    definition,
                    index,
                    cases.length
                  )
                  rows << row
                  append_progress(row)
                  if ((index + 1) % 10).zero? || index + 1 == cases.length
                    puts format(
                      '[V3 positive control] %d/%d hard_failures=%d',
                      index + 1,
                      cases.length,
                      rows.count { |entry| entry['hard_failure'] }
                    )
                  end
                end
              end

              summary = summarize(rows)
              report = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => MODE,
                'production_decision_modified' => false,
                'validation_report_modified' => false,
                'temporary_geometry_rolled_back' => true,
                'configured_tolerance_mm' => tolerance_mm,
                'box_size_mm' => BOX_SIZE_MM,
                'target_offset_x_mm' => OFFSET_X_MM,
                'target_offset_y_mm' => OFFSET_Y_MM,
                'expected_overlap_area_mm2' => OVERLAP_AREA_MM2,
                'grid_pairs' => grids,
                'pattern_pairs' => patterns,
                'depths_mm' => depths,
                'orders' => orders,
                'repeats' => repeats,
                'case_count' => cases.length,
                'elapsed_ms' => elapsed_ms(started),
                'summary' => summary,
                'rows' => rows,
                'pass' => summary['hard_failure_count'].zero?
              }
              File.write(
                @last_result_path,
                JSON.pretty_generate(report),
                encoding: 'UTF-8'
              )
              @last_report = report
              report
            end

            def print_report(report = @last_report)
              raise 'No positive-control report is available.' unless report

              summary = report.fetch('summary')
              puts
              puts '=' * 104
              puts 'V3 PARTIAL-XY POSITIVE CONTROL'
              puts '=' * 104
              %w[
                row_count original_reproduced_count v3_reproduced_count
                original_positive_missed_count v3_positive_missed_count
                original_policy_false_suppression_count
                v3_policy_false_suppression_count volume_mismatch_count
                unexpected_tolerance_candidate_count policy_disagreement_count
                generator_complexity_collapse_count v3_fallback_count
                hard_failure_count
              ].each do |key|
                puts format('%42s : %s', key, summary[key])
              end
              puts format('%42s : %s', 'PASS', report['pass'])
              puts "result_path  : #{@last_result_path}"
              puts "progress_path: #{@last_progress_path}"
              puts '=' * 104
              nil
            end

            private

            def run_case(parent, indoor_model, model, tolerance_in,
                         tolerance_mm, definition, index, total)
              source = nil
              target = nil
              started = monotonic_now
              depth_mm = definition.fetch('depth_mm')
              suffix = "#{index}_#{definition['repeat']}"

              source = add_box(
                parent,
                "__V3_POSITIVE_SOURCE_#{suffix}__",
                [0.0, 0.0, 0.0],
                [BOX_SIZE_MM, BOX_SIZE_MM, BOX_SIZE_MM],
                definition.fetch('source_grid'),
                definition.fetch('source_pattern')
              )
              target = add_box(
                parent,
                "__V3_POSITIVE_TARGET_#{suffix}__",
                [OFFSET_X_MM, OFFSET_Y_MM, BOX_SIZE_MM - depth_mm],
                [
                  OFFSET_X_MM + BOX_SIZE_MM,
                  OFFSET_Y_MM + BOX_SIZE_MM,
                  (BOX_SIZE_MM * 2.0) - depth_mm
                ],
                definition.fetch('target_grid'),
                definition.fetch('target_pattern')
              )

              source_metrics = base(:control_group_metrics, source)
              target_metrics = base(:control_group_metrics, target)
              base(:validate_control_group!, source, source_metrics, 'source')
              base(:validate_control_group!, target, target_metrics, 'target')
              expected_source_faces =
                base(:expected_face_count, definition.fetch('source_grid'))
              expected_target_faces =
                base(:expected_face_count, definition.fetch('target_grid'))
              complexity_preserved =
                source_metrics['face_count'] == expected_source_faces &&
                target_metrics['face_count'] == expected_target_faces

              groups, ids = base(
                :ordered_operands,
                definition.fetch('order'), source, target, suffix
              )
              original = OriginalHarness.new(
                indoor_model: indoor_model,
                model: model,
                tolerance: tolerance_in,
                logger: nil
              )
              v3 = V3Harness.new(
                indoor_model: indoor_model,
                model: model,
                tolerance: tolerance_in,
                logger: nil
              )

              candidates = original.send(
                :shared_face_candidates,
                original.send(:entity_faces, groups[0]),
                original.send(:entity_faces, groups[1])
              )
              original_result = original.send(
                :model_solid_intersection_for_pair,
                groups[0], groups[1], ids[0], ids[1]
              )
              v3_result = v3.send(
                :model_solid_intersection_for_pair,
                groups[0], groups[1], ids[0], ids[1]
              )
              analysis = {
                status: :ok,
                cells: ids,
                adjacency_candidates: candidates
              }
              original_policy = PolicyHarness.new(original).decision(
                analysis.merge(intersection: original_result)
              )
              v3_policy = PolicyHarness.new(v3).decision(
                analysis.merge(intersection: v3_result)
              )

              original_row = base(:normalize_intersection, original_result)
              v3_row = base(:normalize_intersection, v3_result)
              original_policy_row = normalize_policy(original_policy)
              v3_policy_row = normalize_policy(v3_policy)
              expected_volume = OVERLAP_AREA_MM2 * depth_mm

              original_missed = !reproduced?(original_row)
              v3_missed = !reproduced?(v3_row)
              original_false_suppression = !kept?(original_policy_row)
              v3_false_suppression = !kept?(v3_policy_row)
              volume_mismatch =
                reproduced?(original_row) &&
                  !volume_close?(
                    original_row['volume_mm3'], expected_volume
                  ) ||
                reproduced?(v3_row) &&
                  !volume_close?(v3_row['volume_mm3'], expected_volume) ||
                reproduced?(original_row) && reproduced?(v3_row) &&
                  !volume_close?(
                    original_row['volume_mm3'], v3_row['volume_mm3']
                  )
              policy_disagreement =
                original_policy_row['tolerated'] !=
                  v3_policy_row['tolerated'] ||
                original_policy_row['status'] != v3_policy_row['status']
              unexpected_candidates = !candidates.empty?

              hard_failure =
                !complexity_preserved ||
                original_missed ||
                v3_missed ||
                original_false_suppression ||
                v3_false_suppression ||
                volume_mismatch ||
                policy_disagreement ||
                unexpected_candidates

              definition.merge(
                'case_index' => index + 1,
                'total_cases' => total,
                'depth_to_tolerance_ratio' => depth_mm / tolerance_mm,
                'expected_overlap_area_mm2' => OVERLAP_AREA_MM2,
                'expected_overlap_volume_mm3' => expected_volume,
                'source' => source_metrics,
                'target' => target_metrics,
                'generator_complexity_preserved' => complexity_preserved,
                'unexpected_tolerance_candidate' => unexpected_candidates,
                'adjacency_candidate_count' => candidates.length,
                'original' => original_row,
                'v3' => v3_row,
                'original_policy_701' => original_policy_row,
                'v3_policy_701' => v3_policy_row,
                'v3_proxy' => base(
                  :compact_proxy_record,
                  v3.proxy_record(*ids) || {}
                ),
                'original_positive_missed' => original_missed,
                'v3_positive_missed' => v3_missed,
                'original_policy_false_suppression' =>
                  original_false_suppression,
                'v3_policy_false_suppression' => v3_false_suppression,
                'volume_mismatch' => volume_mismatch,
                'policy_disagreement' => policy_disagreement,
                'hard_failure' => hard_failure,
                'elapsed_ms' => elapsed_ms(started)
              )
            ensure
              [target, source].compact.each do |group|
                group.erase! if group.valid?
              rescue StandardError
                nil
              end
            end

            def add_box(parent, name, min_mm, max_mm, grid, pattern)
              base(
                :add_subdivided_box,
                parent,
                name: name,
                min_mm: min_mm,
                max_mm: max_mm,
                grid: grid,
                pattern: pattern
              )
            end

            def normalize_policy(decision)
              row = decision.is_a?(Hash) ? decision : {}
              volume = row[:actual_overlap_volume]
              {
                'tolerated' => row[:tolerated] == true,
                'status' => row[:status]&.to_s,
                'reason' => row[:reason]&.to_s,
                'actual_overlap_volume_mm3' =>
                  volume.nil? ? nil : volume.to_f * (25.4**3),
                'intersection_component_count' =>
                  row[:intersection_component_count],
                'sketchup_intersection_reproduced' =>
                  row[:sketchup_intersection_reproduced]
              }
            end

            def summarize(rows)
              {
                'row_count' => rows.length,
                'original_reproduced_count' =>
                  rows.count { |row| reproduced?(row['original']) },
                'v3_reproduced_count' =>
                  rows.count { |row| reproduced?(row['v3']) },
                'original_positive_missed_count' =>
                  rows.count { |row| row['original_positive_missed'] },
                'v3_positive_missed_count' =>
                  rows.count { |row| row['v3_positive_missed'] },
                'original_policy_false_suppression_count' =>
                  rows.count do |row|
                    row['original_policy_false_suppression']
                  end,
                'v3_policy_false_suppression_count' =>
                  rows.count { |row| row['v3_policy_false_suppression'] },
                'volume_mismatch_count' =>
                  rows.count { |row| row['volume_mismatch'] },
                'unexpected_tolerance_candidate_count' =>
                  rows.count { |row| row['unexpected_tolerance_candidate'] },
                'policy_disagreement_count' =>
                  rows.count { |row| row['policy_disagreement'] },
                'generator_complexity_collapse_count' =>
                  rows.count do |row|
                    !row['generator_complexity_preserved']
                  end,
                'v3_fallback_count' => rows.count do |row|
                  row.dig('v3_proxy', 'path') ==
                    'original_full_recheck_fallback'
                end,
                'hard_failure_count' =>
                  rows.count { |row| row['hard_failure'] },
                'failure_case_indices' => rows.filter_map do |row|
                  row['case_index'] if row['hard_failure']
                end
              }
            end

            def reproduced?(row)
              row.is_a?(Hash) && row['status'] == 'reproduced'
            end

            def kept?(row)
              row.is_a?(Hash) &&
                row['tolerated'] == false &&
                row['status'] == 'kept'
            end

            def volume_close?(a, b)
              return false if a.nil? || b.nil?

              difference = (a.to_f - b.to_f).abs
              allowed = [
                ABS_VOLUME_EPSILON_MM3,
                [a.to_f.abs, b.to_f.abs].max * REL_VOLUME_EPSILON
              ].max
              difference <= allowed
            end

            def append_progress(row)
              File.open(@last_progress_path, 'a:UTF-8') do |file|
                file.puts(JSON.generate(row))
              end
            end

            def base(method_name, *args, **kwargs)
              Base.send(method_name, *args, **kwargs)
            end

            def monotonic_now
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end

            def elapsed_ms(started)
              ((monotonic_now - started) * 1000.0).round(3)
            end
          end
        end
      end
    end
  end
end
