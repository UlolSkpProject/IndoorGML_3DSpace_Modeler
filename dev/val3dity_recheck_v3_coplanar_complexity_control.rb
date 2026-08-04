# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_v3_control_geometry_policy_fix'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only parametric benchmark for stressing SketchUp Solid Boolean and
        # the v3 clipped-mesh proxy with dense, mismatched coplanar subdivisions.
        #
        # The generated solids are ordinary closed manifold boxes. Their outer
        # shape and exact overlap volume are known; only surface subdivision,
        # triangulation pattern, operand order, and overlap depth are varied.
        # Every entity is created inside one rollback operation.
        module Val3dityRecheckV3CoplanarComplexityControl
          MODE = 'v3_coplanar_complexity_control'
          BOX_SIZE_MM = 1000.0
          DEFAULT_GRID_PAIRS = [[1, 1], [2, 3], [4, 5], [8, 9]].freeze
          DEFAULT_PATTERN_PAIRS = [
            %w[forward reverse],
            %w[checker row_stripes]
          ].freeze
          DEFAULT_DEPTHS_MM = [0.0, 0.0127, 0.0254, 0.03, 0.0508, 0.1].freeze
          DEFAULT_ORDERS = %w[ab ba].freeze
          ALLOWED_PATTERNS = %w[
            forward reverse checker row_stripes column_stripes
          ].freeze
          VOLUME_ABSOLUTE_EPSILON_MM3 = 1.0e-3
          VOLUME_RELATIVE_EPSILON = 1.0e-8

          OriginalHarness = Val3dityRecheckV3ControlGeometry::OriginalHarness
          V3Harness = Val3dityRecheckV3ControlGeometry::V3Harness

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
              unless indoor_model&.model == model
                raise 'IndoorModel.current is not bound to the active model.'
              end

              normalized_grid_pairs = normalize_grid_pairs(grid_pairs)
              normalized_pattern_pairs = normalize_pattern_pairs(pattern_pairs)
              normalized_depths = Array(depths_mm).map { |value| Float(value) }
              normalized_orders = normalize_orders(orders)
              repeat_count = Integer(repeats)
              raise ArgumentError, 'repeats must be at least 1.' if repeat_count < 1

              tolerance_in = Val3dityRunner::OVERLAP_RECHECK_TOLERANCE
              tolerance_mm = tolerance_in.to_f * 25.4
              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              output_dir = File.expand_path(
                output_dir || File.join(
                  __dir__, 'recheck_snapshots', 'control_geometry',
                  'coplanar_complexity', stamp
                )
              )
              FileUtils.mkdir_p(output_dir)
              name = sanitize_name(
                report_name || "v3_coplanar_complexity_#{stamp}"
              )
              @last_result_path = File.join(output_dir, "#{name}.json")
              @last_progress_path = File.join(output_dir, "#{name}_progress.jsonl")
              File.write(@last_progress_path, '', encoding: 'UTF-8')

              cases = enumerate_cases(
                normalized_grid_pairs,
                normalized_pattern_pairs,
                normalized_depths,
                normalized_orders,
                repeat_count
              )
              rows = []
              started = monotonic_now

              indoor_model.with_indoor_model_operation(
                'IndoorGML v3 coplanar complexity control', rollback: true
              ) do
                container = model.entities.add_group
                container.name = '__IndoorGML_V3_COPLANAR_COMPLEXITY_CONTROL__'

                cases.each_with_index do |definition, index|
                  row = run_case(
                    parent_entities: container.entities,
                    indoor_model: indoor_model,
                    model: model,
                    tolerance_in: tolerance_in,
                    tolerance_mm: tolerance_mm,
                    definition: definition,
                    case_index: index,
                    total_cases: cases.length
                  )
                  rows << row
                  append_progress(row)
                  if ((index + 1) % 10).zero? || index + 1 == cases.length
                    puts format(
                      '[V3 coplanar control] %d/%d hard_failures=%d',
                      index + 1,
                      cases.length,
                      rows.count { |entry| entry['hard_failure'] }
                    )
                  end
                end
              end

              summary = summarize(rows, tolerance_mm)
              report = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => MODE,
                'production_decision_modified' => false,
                'validation_report_modified' => false,
                'temporary_geometry_rolled_back' => true,
                'configured_tolerance_mm' => tolerance_mm,
                'box_size_mm' => BOX_SIZE_MM,
                'grid_pairs' => normalized_grid_pairs,
                'pattern_pairs' => normalized_pattern_pairs,
                'depths_mm' => normalized_depths,
                'orders' => normalized_orders,
                'repeats' => repeat_count,
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
              raise 'No coplanar-complexity report is available.' unless report

              summary = report.fetch('summary')
              puts
              puts '=' * 124
              puts 'V3 COPLANAR COMPLEXITY CONTROL'
              puts '=' * 124
              puts "configured_tolerance_mm       : #{report['configured_tolerance_mm']}"
              puts "case_count                    : #{report['case_count']}"
              puts "raw_status_agreement          : #{summary['raw_status_agreement_count']}"
              puts "original_reproduced_v3_missed : #{summary['original_reproduced_v3_missed_count']}"
              puts "nonpositive_false_positive    : #{summary['nonpositive_false_positive_count']}"
              puts "volume_mismatch               : #{summary['volume_mismatch_count']}"
              puts "generator_complexity_collapse : #{summary['generator_complexity_collapse_count']}"
              puts "v3_only_reproduced            : #{summary['v3_only_reproduced_count']}"
              puts "v3_fallback                   : #{summary['v3_fallback_count']}"
              puts "transition_groups             : #{summary['transition_group_count']}"
              puts "hard_failure_count            : #{summary['hard_failure_count']}"
              puts "PASS                          : #{report['pass']}"
              puts "result_path                   : #{@last_result_path}"
              puts "progress_path                 : #{@last_progress_path}"
              puts '-' * 124
              puts format(
                '%7s | %-19s | %9s | %8s | %8s | %8s | %8s | %8s',
                'grids', 'patterns', 'depth', 'rows', 'orig+', 'v3+', 'fallback', 'fail'
              )
              puts '-' * 124
              Array(summary['configuration_summaries']).each do |entry|
                puts format(
                  '%7s | %-19s | %9.5f | %8d | %8d | %8d | %8d | %8d',
                  "#{entry['source_grid']}x#{entry['target_grid']}",
                  "#{entry['source_pattern']}/#{entry['target_pattern']}",
                  entry['depth_mm'],
                  entry['row_count'],
                  entry['original_reproduced_count'],
                  entry['v3_reproduced_count'],
                  entry['v3_fallback_count'],
                  entry['hard_failure_count']
                )
              end
              puts '=' * 124
              nil
            end

            private

            def enumerate_cases(grid_pairs, pattern_pairs, depths, orders, repeats)
              cases = []
              grid_pairs.each do |source_grid, target_grid|
                pattern_pairs.each do |source_pattern, target_pattern|
                  depths.each do |depth_mm|
                    orders.each do |order|
                      repeats.times do |repeat_index|
                        cases << {
                          'source_grid' => source_grid,
                          'target_grid' => target_grid,
                          'source_pattern' => source_pattern,
                          'target_pattern' => target_pattern,
                          'depth_mm' => depth_mm,
                          'order' => order,
                          'repeat' => repeat_index + 1
                        }
                      end
                    end
                  end
                end
              end
              cases
            end

            def run_case(parent_entities:, indoor_model:, model:, tolerance_in:,
                         tolerance_mm:, definition:, case_index:, total_cases:)
              source = nil
              target = nil
              case_started = monotonic_now
              suffix = "#{case_index}_#{definition['repeat']}"
              depth_mm = definition.fetch('depth_mm')

              source = add_subdivided_box(
                parent_entities,
                name: "__V3_COPLANAR_SOURCE_#{suffix}__",
                min_mm: [0.0, 0.0, 0.0],
                max_mm: [BOX_SIZE_MM, BOX_SIZE_MM, BOX_SIZE_MM],
                grid: definition.fetch('source_grid'),
                pattern: definition.fetch('source_pattern')
              )
              target = add_subdivided_box(
                parent_entities,
                name: "__V3_COPLANAR_TARGET_#{suffix}__",
                min_mm: [BOX_SIZE_MM - depth_mm, 0.0, 0.0],
                max_mm: [(BOX_SIZE_MM * 2.0) - depth_mm,
                         BOX_SIZE_MM, BOX_SIZE_MM],
                grid: definition.fetch('target_grid'),
                pattern: definition.fetch('target_pattern')
              )

              source_metrics = control_group_metrics(source)
              target_metrics = control_group_metrics(target)
              validate_control_group!(source, source_metrics, 'source')
              validate_control_group!(target, target_metrics, 'target')

              expected_source_faces = expected_face_count(
                definition.fetch('source_grid')
              )
              expected_target_faces = expected_face_count(
                definition.fetch('target_grid')
              )
              generator_complexity_preserved =
                source_metrics['face_count'] == expected_source_faces &&
                target_metrics['face_count'] == expected_target_faces

              ordered_groups, ordered_ids = ordered_operands(
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

              original_result = original.send(
                :model_solid_intersection_for_pair,
                ordered_groups[0], ordered_groups[1],
                ordered_ids[0], ordered_ids[1]
              )
              v3_result = v3.send(
                :model_solid_intersection_for_pair,
                ordered_groups[0], ordered_groups[1],
                ordered_ids[0], ordered_ids[1]
              )
              proxy_record = v3.proxy_record(*ordered_ids) || {}
              original_row = normalize_intersection(original_result)
              v3_row = normalize_intersection(v3_result)
              expected_volume = expected_volume_mm3(depth_mm)

              original_reproduced = reproduced?(original_row)
              v3_reproduced = reproduced?(v3_row)
              original_reproduced_v3_missed =
                original_reproduced && !v3_reproduced
              nonpositive_false_positive =
                depth_mm <= 0.0 && v3_reproduced && !original_reproduced
              original_expected_volume_mismatch =
                original_reproduced &&
                !volume_close?(original_row['volume_mm3'], expected_volume)
              v3_expected_volume_mismatch =
                v3_reproduced &&
                !volume_close?(v3_row['volume_mm3'], expected_volume)
              original_v3_volume_mismatch =
                original_reproduced && v3_reproduced &&
                !volume_close?(
                  original_row['volume_mm3'], v3_row['volume_mm3']
                )
              volume_mismatch =
                original_expected_volume_mismatch ||
                v3_expected_volume_mismatch ||
                original_v3_volume_mismatch
              hard_failure =
                !generator_complexity_preserved ||
                original_reproduced_v3_missed ||
                nonpositive_false_positive ||
                volume_mismatch

              definition.merge(
                'case_index' => case_index + 1,
                'total_cases' => total_cases,
                'depth_to_tolerance_ratio' =>
                  tolerance_mm.zero? ? nil : depth_mm / tolerance_mm,
                'expected_overlap_volume_mm3' => expected_volume,
                'expected_source_face_count' => expected_source_faces,
                'expected_target_face_count' => expected_target_faces,
                'source' => source_metrics,
                'target' => target_metrics,
                'generator_complexity_preserved' =>
                  generator_complexity_preserved,
                'original' => original_row,
                'v3' => v3_row,
                'v3_proxy' => compact_proxy_record(proxy_record),
                'status_agreement' =>
                  original_row['status'] == v3_row['status'],
                'original_reproduced_v3_missed' =>
                  original_reproduced_v3_missed,
                'nonpositive_false_positive' => nonpositive_false_positive,
                'v3_only_reproduced' =>
                  v3_reproduced && !original_reproduced,
                'original_expected_volume_mismatch' =>
                  original_expected_volume_mismatch,
                'v3_expected_volume_mismatch' =>
                  v3_expected_volume_mismatch,
                'original_v3_volume_mismatch' =>
                  original_v3_volume_mismatch,
                'volume_mismatch' => volume_mismatch,
                'hard_failure' => hard_failure,
                'elapsed_ms' => elapsed_ms(case_started)
              )
            ensure
              [target, source].compact.each do |group|
                group.erase! if group.valid?
              rescue StandardError
                nil
              end
            end

            def add_subdivided_box(parent_entities, name:, min_mm:, max_mm:,
                                   grid:, pattern:)
              triangles_mm = box_triangles(
                min_mm.map(&:to_f), max_mm.map(&:to_f), grid, pattern
              )
              group = parent_entities.add_group
              group.name = name
              mesh = Geom::PolygonMesh.new
              triangles_mm.each do |triangle|
                mesh.add_polygon(
                  *triangle.map do |point|
                    Geom::Point3d.new(*point.map { |value| mm_to_in(value) })
                  end
                )
              end
              success = group.entities.fill_from_mesh(mesh, true, 0)
              raise "Failed to build subdivided box: #{name}" unless success

              group
            rescue StandardError
              group.erase! if group&.valid?
              raise
            end

            def box_triangles(min, max, grid, pattern)
              dx = max[0] - min[0]
              dy = max[1] - min[1]
              dz = max[2] - min[2]
              faces = [
                [[min[0], min[1], max[2]], [0.0, dy, 0.0], [0.0, 0.0, -dz]],
                [[max[0], min[1], min[2]], [0.0, dy, 0.0], [0.0, 0.0, dz]],
                [[min[0], min[1], min[2]], [dx, 0.0, 0.0], [0.0, 0.0, dz]],
                [[min[0], max[1], max[2]], [dx, 0.0, 0.0], [0.0, 0.0, -dz]],
                [[min[0], max[1], min[2]], [dx, 0.0, 0.0], [0.0, -dy, 0.0]],
                [[min[0], min[1], max[2]], [dx, 0.0, 0.0], [0.0, dy, 0.0]]
              ]
              faces.flat_map do |origin, u_vector, v_vector|
                subdivide_face(origin, u_vector, v_vector, grid, pattern)
              end
            end

            def subdivide_face(origin, u_vector, v_vector, grid, pattern)
              triangles = []
              grid.times do |u_index|
                grid.times do |v_index|
                  u0 = u_index.to_f / grid
                  u1 = (u_index + 1).to_f / grid
                  v0 = v_index.to_f / grid
                  v1 = (v_index + 1).to_f / grid
                  p00 = face_point(origin, u_vector, v_vector, u0, v0)
                  p10 = face_point(origin, u_vector, v_vector, u1, v0)
                  p11 = face_point(origin, u_vector, v_vector, u1, v1)
                  p01 = face_point(origin, u_vector, v_vector, u0, v1)
                  if reverse_diagonal?(pattern, u_index, v_index)
                    triangles << [p00, p10, p01]
                    triangles << [p10, p11, p01]
                  else
                    triangles << [p00, p10, p11]
                    triangles << [p00, p11, p01]
                  end
                end
              end
              triangles
            end

            def reverse_diagonal?(pattern, u_index, v_index)
              case pattern
              when 'forward'
                false
              when 'reverse'
                true
              when 'checker'
                (u_index + v_index).odd?
              when 'row_stripes'
                v_index.odd?
              when 'column_stripes'
                u_index.odd?
              else
                raise ArgumentError, "Unsupported triangulation pattern: #{pattern}"
              end
            end

            def face_point(origin, u_vector, v_vector, u, v)
              3.times.map do |axis|
                origin[axis] + u_vector[axis] * u + v_vector[axis] * v
              end
            end

            def control_group_metrics(group)
              entities = group.definition.entities
              {
                'manifold' => group.manifold? == true,
                'volume_in3' => group.volume.to_f.abs,
                'volume_mm3' => group.volume.to_f.abs * (25.4**3),
                'face_count' => entities.grep(Sketchup::Face).count(&:valid?),
                'edge_count' => entities.grep(Sketchup::Edge).count(&:valid?)
              }
            end

            def validate_control_group!(group, metrics, label)
              raise "#{label} control group is invalid." unless group&.valid?
              raise "#{label} control group is not manifold." unless metrics['manifold']
              raise "#{label} control group has nonpositive volume." unless
                metrics['volume_in3'].positive?
            end

            def ordered_operands(order, source, target, suffix)
              case order
              when 'ab'
                [[source, target], ["source_#{suffix}", "target_#{suffix}"]]
              when 'ba'
                [[target, source], ["target_#{suffix}", "source_#{suffix}"]]
              else
                raise ArgumentError, "Unsupported operand order: #{order}"
              end
            end

            def normalize_intersection(result)
              row = result.is_a?(Hash) ? result : {}
              volume_in3 = row[:volume]
              {
                'status' => row[:status].to_s,
                'reason' => row[:reason]&.to_s,
                'volume_in3' => volume_in3,
                'volume_mm3' =>
                  volume_in3 && volume_in3.to_f * (25.4**3),
                'component_count' => row[:component_count],
                'face_count' => row[:face_count],
                'edge_count' => row[:edge_count],
                'boundary_edge_count' => row[:boundary_edge_count],
                'nonmanifold_edge_count' => row[:nonmanifold_edge_count],
                'lower_dimensional' => row[:lower_dimensional]
              }
            end

            def compact_proxy_record(record)
              {
                'path' => record['path'],
                'fallback_reason' => record['fallback_reason'],
                'intersection_status' => record['intersection_status'],
                'intersection_reason' => record['intersection_reason'],
                'analysis_elapsed_ms' => record['analysis_elapsed_ms'],
                'target_boolean_elapsed_ms' => record['target_boolean_elapsed_ms'],
                'fallback_elapsed_ms' => record['fallback_elapsed_ms'],
                'total_elapsed_ms' => record['total_elapsed_ms'],
                'source_operand_index' => record['source_operand_index'],
                'proxy_face_count' => record['proxy_face_count'],
                'proxy_edge_count' => record['proxy_edge_count'],
                'non_solid_safety_gate' => record['non_solid_safety_gate']
              }
            end

            def summarize(rows, tolerance_mm)
              grouped = rows.group_by do |row|
                [
                  row['source_grid'], row['target_grid'],
                  row['source_pattern'], row['target_pattern'],
                  row['depth_mm']
                ]
              end
              transition_groups = grouped.count do |_key, group_rows|
                statuses = group_rows.flat_map do |row|
                  [
                    row.dig('original', 'status'),
                    row.dig('v3', 'status'),
                    row.dig('v3_proxy', 'non_solid_safety_gate', 'proxy_status')
                  ]
                end.compact.uniq
                statuses.include?('non_solid') || statuses.length > 2
              end

              {
                'row_count' => rows.length,
                'raw_status_agreement_count' =>
                  rows.count { |row| row['status_agreement'] },
                'original_reproduced_v3_missed_count' =>
                  rows.count { |row| row['original_reproduced_v3_missed'] },
                'nonpositive_false_positive_count' =>
                  rows.count { |row| row['nonpositive_false_positive'] },
                'volume_mismatch_count' =>
                  rows.count { |row| row['volume_mismatch'] },
                'generator_complexity_collapse_count' =>
                  rows.count { |row| !row['generator_complexity_preserved'] },
                'v3_only_reproduced_count' =>
                  rows.count { |row| row['v3_only_reproduced'] },
                'v3_fallback_count' => rows.count do |row|
                  row.dig('v3_proxy', 'path') ==
                    'original_full_recheck_fallback'
                end,
                'transition_group_count' => transition_groups,
                'hard_failure_count' =>
                  rows.count { |row| row['hard_failure'] },
                'failure_case_indices' => rows.filter_map do |row|
                  row['case_index'] if row['hard_failure']
                end,
                'configured_tolerance_mm' => tolerance_mm,
                'configuration_summaries' => grouped.map do |key, group_rows|
                  source_grid, target_grid,
                    source_pattern, target_pattern, depth_mm = key
                  {
                    'source_grid' => source_grid,
                    'target_grid' => target_grid,
                    'source_pattern' => source_pattern,
                    'target_pattern' => target_pattern,
                    'depth_mm' => depth_mm,
                    'row_count' => group_rows.length,
                    'original_reproduced_count' => group_rows.count do |row|
                      reproduced?(row['original'])
                    end,
                    'v3_reproduced_count' => group_rows.count do |row|
                      reproduced?(row['v3'])
                    end,
                    'v3_fallback_count' => group_rows.count do |row|
                      row.dig('v3_proxy', 'path') ==
                        'original_full_recheck_fallback'
                    end,
                    'hard_failure_count' => group_rows.count do |row|
                      row['hard_failure']
                    end
                  }
                end.sort_by do |entry|
                  [
                    entry['source_grid'], entry['target_grid'],
                    entry['source_pattern'], entry['target_pattern'],
                    entry['depth_mm']
                  ]
                end
              }
            end

            def expected_face_count(grid)
              12 * grid * grid
            end

            def expected_volume_mm3(depth_mm)
              return 0.0 unless depth_mm.positive?

              depth_mm * BOX_SIZE_MM * BOX_SIZE_MM
            end

            def reproduced?(row)
              row.is_a?(Hash) && row['status'] == 'reproduced'
            end

            def volume_close?(a, b)
              return false if a.nil? || b.nil?

              difference = (a.to_f - b.to_f).abs
              allowed = [
                VOLUME_ABSOLUTE_EPSILON_MM3,
                [a.to_f.abs, b.to_f.abs].max * VOLUME_RELATIVE_EPSILON
              ].max
              difference <= allowed
            end

            def normalize_grid_pairs(grid_pairs)
              Array(grid_pairs).map do |pair|
                values = Array(pair)
                raise ArgumentError, 'Each grid pair must have two values.' unless
                  values.length == 2

                normalized = values.map { |value| Integer(value) }
                unless normalized.all?(&:positive?)
                  raise ArgumentError, 'Grid sizes must be positive integers.'
                end
                normalized
              end
            end

            def normalize_pattern_pairs(pattern_pairs)
              Array(pattern_pairs).map do |pair|
                values = Array(pair).map(&:to_s)
                unless values.length == 2 &&
                       values.all? { |value| ALLOWED_PATTERNS.include?(value) }
                  raise ArgumentError,
                        "Pattern pairs must use: #{ALLOWED_PATTERNS.join(', ')}"
                end
                values
              end
            end

            def normalize_orders(orders)
              normalized = Array(orders).map(&:to_s)
              unless normalized.all? { |order| DEFAULT_ORDERS.include?(order) }
                raise ArgumentError, 'Orders must be ab and/or ba.'
              end
              normalized.uniq
            end

            def append_progress(row)
              File.open(@last_progress_path, 'a:UTF-8') do |file|
                file.puts(JSON.generate(row))
              end
            end

            def sanitize_name(value)
              name = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              name.empty? ? 'v3_coplanar_complexity' : name
            end

            def mm_to_in(value)
              value.to_f / 25.4
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
