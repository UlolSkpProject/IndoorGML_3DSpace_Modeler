# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

require_relative '../indoor3d/validity/val3dity_overlap_geometry_rechecker'
require_relative 'val3dity_recheck_v3_mesh_proxy_non_solid_fallback'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only synthetic geometry benchmark for comparing the unchanged
        # production rechecker with the v3 clipped-mesh rechecker around the
        # SketchUp practical overlap-resolution boundary.
        #
        # All geometry is created inside one rollback operation. No CellSpace,
        # validation report, or production decision is modified.
        module Val3dityRecheckV3ControlGeometry
          MODE = 'v3_control_geometry_overlap_depth_sweep'
          DEFAULT_DEPTHS_MM = [
            -0.1,
            0.0,
            0.001,
            0.005,
            0.0127,
            0.0254,
            0.03,
            0.0508,
            0.1,
            0.5,
            1.0
          ].freeze
          SOURCE_SIZE_MM = 1000.0
          TARGET_Y_MIN_MM = 100.0
          TARGET_Y_MAX_MM = 900.0
          TARGET_Z_MIN_MM = 100.0
          TARGET_Z_MAX_MM = 900.0

          class OriginalHarness < Val3dityOverlapGeometryRechecker
            def initialize(indoor_model:, model:, tolerance:, logger: nil)
              @indoor_model = indoor_model
              @tolerance = tolerance
              @model = model
              @logger = logger
              @pair_analysis = {}
              @cell_geometry = {}
              @cell_spaces_by_report_id = nil
            end

            private

            def cache_intersection_overlay_geometry(*_arguments)
              false
            end
          end

          class V3Harness < Val3dityRecheckV3MeshProxy::Rechecker
            def initialize(indoor_model:, model:, tolerance:, logger: nil)
              @indoor_model = indoor_model
              @tolerance = tolerance
              @model = model
              @logger = logger
              @pair_analysis = {}
              @cell_geometry = {}
              @cell_spaces_by_report_id = nil
              @rebuild_analyzer =
                Val3dityRecheckV3MeshProxy::RebuildAnalyzer.new(tolerance)
              @mesh_cache = {}
              @proxy_records = {}
            end

            private

            def cache_intersection_overlay_geometry(*_arguments)
              false
            end
          end

          class << self
            attr_reader :last_result_path, :last_report

            def run(depths_mm: DEFAULT_DEPTHS_MM,
                    repeats: 3,
                    output_dir: nil,
                    report_name: nil,
                    indoor_model: nil)
              indoor_model ||= IndoorCore::IndoorModel.current
              model = indoor_model&.model || Sketchup.active_model
              raise 'Active SketchUp model is unavailable.' unless model
              unless indoor_model&.model == model
                raise 'IndoorModel.current is not bound to the active model.'
              end

              tolerance_in = Val3dityRunner::OVERLAP_RECHECK_TOLERANCE
              tolerance_mm = tolerance_in.to_f * 25.4
              normalized_depths = Array(depths_mm).map { |value| Float(value) }
              repeat_count = Integer(repeats)
              raise ArgumentError, 'repeats must be at least 1.' if repeat_count < 1

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              output_dir = File.expand_path(
                output_dir || File.join(
                  __dir__,
                  'recheck_snapshots',
                  'control_geometry',
                  stamp
                )
              )
              FileUtils.mkdir_p(output_dir)
              name = sanitize_name(
                report_name || "v3_control_geometry_#{stamp}"
              )
              @last_result_path = File.join(output_dir, "#{name}.json")

              rows = []
              started = monotonic_now
              indoor_model.with_indoor_model_operation(
                'IndoorGML v3 synthetic overlap control',
                rollback: true
              ) do
                container = model.entities.add_group
                container.name = '__IndoorGML_V3_CONTROL_GEOMETRY__'

                normalized_depths.each_with_index do |depth_mm, depth_index|
                  repeat_count.times do |repeat_index|
                    rows << run_case(
                      parent_entities: container.entities,
                      indoor_model: indoor_model,
                      model: model,
                      tolerance_in: tolerance_in,
                      tolerance_mm: tolerance_mm,
                      depth_mm: depth_mm,
                      depth_index: depth_index,
                      repeat_index: repeat_index
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
                'coordinate_unit' => 'inch',
                'tolerance_mm' => tolerance_mm,
                'depths_mm' => normalized_depths,
                'repeats' => repeat_count,
                'source_box_mm' => {
                  'min' => [0.0, 0.0, 0.0],
                  'max' => [SOURCE_SIZE_MM, SOURCE_SIZE_MM, SOURCE_SIZE_MM]
                },
                'target_cross_section_mm' => {
                  'y' => [TARGET_Y_MIN_MM, TARGET_Y_MAX_MM],
                  'z' => [TARGET_Z_MIN_MM, TARGET_Z_MAX_MM]
                },
                'elapsed_ms' => elapsed_ms(started),
                'summary' => summary,
                'rows' => rows,
                'pass' => summary['failure_count'].zero?
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
              raise 'No control-geometry report is available.' unless report

              puts
              puts '================================================================================================================='
              puts 'V3 CONTROL GEOMETRY — OVERLAP DEPTH SWEEP'
              puts '================================================================================================================='
              puts format(
                '%11s | %3s | %-14s | %-14s | %-29s | %12s | %s',
                'depth(mm)',
                'run',
                'original',
                'v3',
                'v3 path',
                'v3 vol(mm3)',
                'checks'
              )
              puts '-' * 113
              Array(report['rows']).each do |row|
                checks = []
                checks << 'REGRESSION' if row['original_kept_v3_missed']
                checks << '>TOL_MISSED' if row['above_tolerance_v3_missed']
                checks << 'FALSE_POSITIVE' if row['nonpositive_depth_v3_reproduced']
                checks << 'OK' if checks.empty?
                puts format(
                  '%11.6f | %3d | %-14s | %-14s | %-29s | %12.6f | %s',
                  row['depth_mm'],
                  row['repeat'],
                  row.dig('original', 'status'),
                  row.dig('v3', 'status'),
                  row.dig('v3_proxy', 'path').to_s,
                  row.dig('v3', 'volume_mm3').to_f,
                  checks.join(',')
                )
              end
              puts '================================================================================================================='
              summary = report.fetch('summary')
              puts "tolerance_mm                  : #{report['tolerance_mm']}"
              puts "row_count                     : #{summary['row_count']}"
              puts "status_agreement_count        : #{summary['status_agreement_count']}"
              puts "original_kept_v3_missed       : #{summary['original_kept_v3_missed_count']}"
              puts "above_tolerance_v3_missed     : #{summary['above_tolerance_v3_missed_count']}"
              puts "nonpositive_depth_false_pos   : #{summary['nonpositive_depth_v3_reproduced_count']}"
              puts "failure_count                 : #{summary['failure_count']}"
              puts "PASS                          : #{report['pass']}"
              puts "result_path                   : #{@last_result_path}"
              puts '================================================================================================================='
              nil
            end

            private

            def run_case(parent_entities:, indoor_model:, model:, tolerance_in:,
                         tolerance_mm:, depth_mm:, depth_index:, repeat_index:)
              source = nil
              target = nil
              case_started = monotonic_now
              suffix = "#{depth_index}_#{repeat_index}"
              source = add_box(
                parent_entities,
                name: "__V3_CONTROL_SOURCE_#{suffix}__",
                min_mm: [0.0, 0.0, 0.0],
                max_mm: [SOURCE_SIZE_MM, SOURCE_SIZE_MM, SOURCE_SIZE_MM]
              )
              target = add_box(
                parent_entities,
                name: "__V3_CONTROL_TARGET_#{suffix}__",
                min_mm: [
                  SOURCE_SIZE_MM - depth_mm,
                  TARGET_Y_MIN_MM,
                  TARGET_Z_MIN_MM
                ],
                max_mm: [
                  (SOURCE_SIZE_MM * 2.0) - depth_mm,
                  TARGET_Y_MAX_MM,
                  TARGET_Z_MAX_MM
                ]
              )
              validate_control_group!(source, 'source')
              validate_control_group!(target, 'target')

              pair_ids = [
                "control_source_#{suffix}",
                "control_target_#{suffix}"
              ]
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
                source,
                target,
                pair_ids[0],
                pair_ids[1]
              )
              v3_result = v3.send(
                :model_solid_intersection_for_pair,
                source,
                target,
                pair_ids[0],
                pair_ids[1]
              )
              proxy_record = v3.proxy_record(pair_ids[0], pair_ids[1]) || {}
              original_row = normalize_intersection(original_result)
              v3_row = normalize_intersection(v3_result)
              original_reproduced = original_row['status'] == 'reproduced'
              v3_reproduced = v3_row['status'] == 'reproduced'

              {
                'depth_mm' => depth_mm,
                'depth_to_tolerance_ratio' => depth_mm / tolerance_mm,
                'repeat' => repeat_index + 1,
                'expected_overlap_volume_mm3' => expected_volume_mm3(depth_mm),
                'source_manifold' => source.manifold? == true,
                'target_manifold' => target.manifold? == true,
                'original' => original_row,
                'v3' => v3_row,
                'v3_proxy' => compact_proxy_record(proxy_record),
                'status_agreement' => original_row['status'] == v3_row['status'],
                'original_kept_v3_missed' =>
                  original_reproduced && !v3_reproduced,
                'above_tolerance_v3_missed' =>
                  depth_mm > tolerance_mm && !v3_reproduced,
                'nonpositive_depth_v3_reproduced' =>
                  depth_mm <= 0.0 && v3_reproduced,
                'elapsed_ms' => elapsed_ms(case_started)
              }
            ensure
              [target, source].compact.each do |group|
                group.erase! if group.valid?
              rescue StandardError
                nil
              end
            end

            def add_box(parent_entities, name:, min_mm:, max_mm:)
              min = min_mm.map { |value| mm_to_in(value) }
              max = max_mm.map { |value| mm_to_in(value) }
              vertices = [
                [min[0], min[1], min[2]],
                [max[0], min[1], min[2]],
                [max[0], max[1], min[2]],
                [min[0], max[1], min[2]],
                [min[0], min[1], max[2]],
                [max[0], min[1], max[2]],
                [max[0], max[1], max[2]],
                [min[0], max[1], max[2]]
              ]
              triangles = [
                [0, 2, 1], [0, 3, 2],
                [4, 5, 6], [4, 6, 7],
                [0, 1, 5], [0, 5, 4],
                [3, 7, 6], [3, 6, 2],
                [0, 4, 7], [0, 7, 3],
                [1, 2, 6], [1, 6, 5]
              ]
              group = parent_entities.add_group
              group.name = name
              mesh = Geom::PolygonMesh.new(vertices.length, triangles.length)
              triangles.each do |triangle|
                mesh.add_polygon(
                  *triangle.map do |index|
                    Geom::Point3d.new(*vertices.fetch(index))
                  end
                )
              end
              success = group.entities.fill_from_mesh(mesh, true, 0)
              raise "Failed to build control box: #{name}" unless success

              group
            rescue StandardError
              group.erase! if group&.valid?
              raise
            end

            def validate_control_group!(group, label)
              raise "#{label} control group is invalid." unless group&.valid?
              raise "#{label} control group is not manifold." unless group.manifold?
              volume = group.volume.to_f.abs
              raise "#{label} control group has nonpositive volume." unless volume.positive?
            end

            def normalize_intersection(result)
              row = result.is_a?(Hash) ? result : {}
              volume_in3 = row[:volume]
              {
                'status' => row[:status].to_s,
                'reason' => row[:reason]&.to_s,
                'volume_in3' => volume_in3,
                'volume_mm3' => volume_in3 && volume_in3.to_f * (25.4**3),
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
              failures = rows.select do |row|
                row['original_kept_v3_missed'] ||
                  row['above_tolerance_v3_missed'] ||
                  row['nonpositive_depth_v3_reproduced']
              end
              {
                'row_count' => rows.length,
                'status_agreement_count' =>
                  rows.count { |row| row['status_agreement'] },
                'original_kept_v3_missed_count' =>
                  rows.count { |row| row['original_kept_v3_missed'] },
                'above_tolerance_v3_missed_count' =>
                  rows.count { |row| row['above_tolerance_v3_missed'] },
                'nonpositive_depth_v3_reproduced_count' =>
                  rows.count { |row| row['nonpositive_depth_v3_reproduced'] },
                'failure_count' => failures.length,
                'failure_depths_mm' =>
                  failures.map { |row| row['depth_mm'] }.uniq.sort,
                'tolerance_mm' => tolerance_mm,
                'first_original_reproduced_depth_mm' =>
                  first_reproduced_depth(rows, 'original'),
                'first_v3_reproduced_depth_mm' =>
                  first_reproduced_depth(rows, 'v3')
              }
            end

            def first_reproduced_depth(rows, field)
              rows.select do |row|
                row.dig(field, 'status') == 'reproduced'
              end.map { |row| row['depth_mm'] }.min
            end

            def expected_volume_mm3(depth_mm)
              return 0.0 unless depth_mm.positive?

              depth_mm *
                (TARGET_Y_MAX_MM - TARGET_Y_MIN_MM) *
                (TARGET_Z_MAX_MM - TARGET_Z_MIN_MM)
            end

            def sanitize_name(value)
              name = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              name.empty? ? 'v3_control_geometry' : name
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
