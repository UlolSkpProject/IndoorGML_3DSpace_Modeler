# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'
require 'time'

require_relative '../indoor3d/validity/val3dity_full_intersection_rechecker'
require_relative '../indoor3d/validity/val3dity_overlap_geometry_rechecker'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only microbenchmark for manifold CellSpaces with fewer than 30 faces.
        # Production recheck behavior is not modified.
        module Val3ditySimpleSolidMicrobenchmark
          CLOCK = Process::CLOCK_MONOTONIC
          FIXTURE_NAME = '__IndoorGML_SIMPLE_RECHECK_BENCHMARK__'
          SIDE_COUNTS = [4, 6, 8, 12, 20, 26].freeze
          RELATIONS = {
            'gap_1mm' => [:gap, 1.0],
            'gap_50mm' => [:gap, 50.0],
            'face_touching' => [:gap, 0.0],
            'overlap_1mm' => [:overlap, 1.0],
            'overlap_100mm' => [:overlap, 100.0]
          }.freeze
          OUTPUT_DIR = File.join(
            ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir,
            'IndoorGML_Recheck_Benchmarks'
          ).freeze

          Cell = Struct.new(:id, :sketchup_group)

          class Context
            attr_reader :model, :cell_spaces

            def initialize(model, cells, delegate)
              @model = model
              @cell_spaces = cells
              @delegate = delegate
            end

            def with_indoor_model_operation(*args, **kwargs, &block)
              @delegate.with_indoor_model_operation(*args, **kwargs, &block)
            end
          end

          class << self
            attr_reader :last_result, :last_result_path, :last_fixture

            def run!(iterations: 10, warmup: 2, keep_geometry: false)
              iterations = iterations.to_i
              warmup = warmup.to_i
              raise ArgumentError, 'iterations must be >= 3' if iterations < 3
              raise ArgumentError, 'warmup must be >= 1' if warmup < 1

              model = Sketchup.active_model
              raise 'SketchUp active model is unavailable.' unless model

              erase_old_fixture(model)
              root_count = model.entities.length
              raise "Run in a blank model. Root entity count=#{root_count}" unless root_count.zero?

              fixture, cases = create_fixture(model)
              @last_fixture = fixture
              rows = cases.map do |entry|
                benchmark_case(model, entry, iterations, warmup)
              end

              result = build_result(rows, iterations, warmup, keep_geometry)
              write_result(result)
              @last_result = result
              print_report(result)
              result
            rescue StandardError
              cleanup!
              raise
            ensure
              cleanup! unless keep_geometry
            end

            def cleanup!
              fixture = @last_fixture
              return true unless fixture&.valid?

              model = Sketchup.active_model
              operation_started = model.start_operation(
                'Remove simple recheck benchmark fixture', true
              )
              fixture.erase!
              model.commit_operation if operation_started
              @last_fixture = nil
              true
            rescue StandardError
              model.abort_operation if operation_started
              false
            end

            def print_report(result = @last_result)
              raise 'No benchmark result is available.' unless result

              puts
              puts('=' * 154)
              puts('SIMPLE CELLSPACE RECHECK — FULL-SOLID vs CANONICAL')
              puts('=' * 154)
              puts "iterations          : #{result['iterations']}"
              puts "warmup               : #{result['warmup']}"
              puts "face_counts          : #{result['face_counts'].inspect}"
              puts "result_equivalence   : #{result['result_equivalence']}"
              puts "result_mismatch_count: #{result['result_mismatch_count']}"
              puts "result_path          : #{@last_result_path}"
              puts('-' * 154)
              puts format(
                '%-15s %5s %11s %11s %9s %11s %11s %9s %-38s',
                'relation', 'faces', 'full cold', 'canon cold', 'speedup',
                'full warm', 'canon warm', 'speedup', 'canonical paths'
              )
              result.fetch('cases').each do |row|
                puts format(
                  '%-15s %5d %10.3fms %10.3fms %8.3fx %10.3fms %10.3fms %8.3fx %-38s',
                  row['relation'],
                  row['face_count'],
                  row.dig('cold', 'full_median_ms'),
                  row.dig('cold', 'canonical_median_ms'),
                  row.dig('cold', 'speedup_vs_full'),
                  row.dig('warm', 'full_median_ms'),
                  row.dig('warm', 'canonical_median_ms'),
                  row.dig('warm', 'speedup_vs_full'),
                  format_paths(row['canonical_path_counts'])
                )
              end
              puts('-' * 154)
              result.fetch('relation_summary').each do |relation, row|
                puts format(
                  '%-15s cold=%8.3fx %-17s warm=%8.3fx %-17s paths=%s',
                  relation,
                  row.dig('cold', 'speedup_vs_full'),
                  row.dig('cold', 'verdict'),
                  row.dig('warm', 'speedup_vs_full'),
                  row.dig('warm', 'verdict'),
                  format_paths(row['canonical_path_counts'])
                )
              end
              puts('-' * 154)
              puts "PASS                : #{result['pass']}"
              puts "fixture_kept        : #{result['fixture_kept']}"
              puts('=' * 154)
              result
            end

            private

            def create_fixture(model)
              operation_started = model.start_operation(
                'Create simple recheck benchmark fixture', true
              )
              raise 'Failed to start fixture operation.' unless operation_started

              root = model.entities.add_group
              root.name = FIXTURE_NAME
              cases = []
              radius = 1000.0.mm
              height = 3000.0.mm
              row_index = 0

              SIDE_COUNTS.each_with_index do |sides, column_index|
                RELATIONS.each do |relation, (kind, distance_mm)|
                  holder = root.entities.add_group
                  holder.name = "#{relation}_#{sides}_sides"
                  group_a = prism(
                    holder.entities, sides, radius, height,
                    "#{relation}_#{sides}_A"
                  )
                  group_b = prism(
                    holder.entities, sides, radius, height,
                    "#{relation}_#{sides}_B"
                  )

                  half_width = radius * Math.cos(Math::PI / sides)
                  separation = 2.0 * half_width
                  separation += distance_mm.mm if kind == :gap
                  separation -= distance_mm.mm if kind == :overlap
                  origin_x = column_index * 5000.0.mm
                  origin_y = row_index * 3500.0.mm
                  group_a.transform!(
                    Geom::Transformation.translation([origin_x, origin_y, 0])
                  )
                  group_b.transform!(
                    Geom::Transformation.translation(
                      [origin_x + separation, origin_y, 0]
                    )
                  )

                  expected_faces = sides + 2
                  actual_faces = [face_count(group_a), face_count(group_b)]
                  unless actual_faces == [expected_faces, expected_faces]
                    raise "Face count mismatch: expected=#{expected_faces}, actual=#{actual_faces.inspect}"
                  end
                  unless group_a.manifold? && group_b.manifold?
                    raise "Generated non-manifold prism: #{relation}/#{sides}"
                  end

                  cells = [
                    Cell.new("bench_#{relation}_#{sides}_a", group_a),
                    Cell.new("bench_#{relation}_#{sides}_b", group_b)
                  ]
                  cases << {
                    relation: relation,
                    side_count: sides,
                    face_count: expected_faces,
                    cells: cells
                  }
                  row_index += 1
                end
              end

              model.commit_operation
              [root, cases]
            rescue StandardError
              model.abort_operation if operation_started
              raise
            end

            def prism(entities, sides, radius, height, name)
              group = entities.add_group
              group.name = name
              points = sides.times.map do |index|
                angle = Math::PI / sides + (2.0 * Math::PI * index / sides)
                Geom::Point3d.new(
                  radius * Math.cos(angle),
                  radius * Math.sin(angle),
                  0
                )
              end
              face = group.entities.add_face(points)
              raise "Failed to create #{name}" unless face

              face.reverse! if face.normal.z.negative?
              face.pushpull(height)
              group
            end

            def benchmark_case(model, entry, iterations, warmup)
              ids = entry.fetch(:cells).map(&:id)
              context = Context.new(
                model,
                entry.fetch(:cells),
                IndoorCore::IndoorModel.current
              )
              full_warm = checker(Val3dityFullIntersectionRechecker, context)
              canonical_warm = checker(
                Val3dityOverlapGeometryRechecker, context
              )

              warmup.times do
                invoke(full_warm, ids)
                invoke(canonical_warm, ids)
              end

              samples = Hash.new { |hash, key| hash[key] = [] }
              paths = Hash.new(0)
              mismatch_count = 0

              iterations.times do |index|
                if index.even?
                  full_warm_result = timed(samples[:full_warm]) do
                    invoke(full_warm, ids)
                  end
                  canonical_warm_result = timed(samples[:canonical_warm]) do
                    invoke(canonical_warm, ids)
                  end
                else
                  canonical_warm_result = timed(samples[:canonical_warm]) do
                    invoke(canonical_warm, ids)
                  end
                  full_warm_result = timed(samples[:full_warm]) do
                    invoke(full_warm, ids)
                  end
                end

                full_cold = checker(Val3dityFullIntersectionRechecker, context)
                canonical_cold = checker(
                  Val3dityOverlapGeometryRechecker, context
                )
                full_cold_result = timed(samples[:full_cold]) do
                  invoke(full_cold, ids)
                end
                canonical_cold_result = timed(samples[:canonical_cold]) do
                  invoke(canonical_cold, ids)
                end

                mismatch_count += 1 unless equivalent?(
                  full_warm_result, canonical_warm_result
                )
                mismatch_count += 1 unless equivalent?(
                  full_cold_result, canonical_cold_result
                )
                paths[path(canonical_warm.proxy_record(*ids))] += 1
                paths[path(canonical_cold.proxy_record(*ids))] += 1
              end

              {
                'relation' => entry.fetch(:relation),
                'side_count' => entry.fetch(:side_count),
                'face_count' => entry.fetch(:face_count),
                'result_mismatch_count' => mismatch_count,
                'cold' => comparison(
                  samples[:full_cold], samples[:canonical_cold]
                ),
                'warm' => comparison(
                  samples[:full_warm], samples[:canonical_warm]
                ),
                'canonical_path_counts' => paths.sort.to_h,
                'samples_ms' => samples.transform_keys(&:to_s)
              }
            end

            def checker(klass, context)
              klass.new(
                indoor_model: context,
                model: context.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: nil
              )
            end

            def invoke(checker, ids)
              checker.send(:analyze_pair, ids[0], ids[1])
            end

            def timed(samples)
              started = Process.clock_gettime(CLOCK)
              result = yield
              samples << elapsed_ms(started)
              result
            end

            def elapsed_ms(started)
              (Process.clock_gettime(CLOCK) - started) * 1000.0
            end

            def intersection(result)
              return result unless result.is_a?(Hash)

              nested = result[:intersection]
              nested.is_a?(Hash) ? nested : result
            end

            def equivalent?(left, right)
              first = intersection(left)
              second = intersection(right)
              return false unless first.is_a?(Hash) && second.is_a?(Hash)
              return false unless first[:status].to_s == second[:status].to_s
              return false unless first[:component_count].to_i == second[:component_count].to_i

              first_volume = first[:volume].to_f
              second_volume = second[:volume].to_f
              scale = [first_volume.abs, second_volume.abs, 1.0].max
              (first_volume - second_volume).abs <= scale * 1.0e-6
            end

            def path(record)
              return 'missing_record' unless record.is_a?(Hash)

              name = record['path'].to_s
              reason = record['fallback_reason'].to_s
              if name == 'full_geometry_confirmation' && !reason.empty?
                "#{name}:#{reason}"
              else
                name.empty? ? 'missing_path' : name
              end
            end

            def comparison(full_samples, canonical_samples)
              full_median = median(full_samples)
              canonical_median = median(canonical_samples)
              speedup = canonical_median.positive? ?
                full_median / canonical_median : 0.0
              {
                'full_median_ms' => full_median.round(6),
                'canonical_median_ms' => canonical_median.round(6),
                'speedup_vs_full' => speedup.round(4),
                'verdict' => verdict(speedup)
              }
            end

            def median(values)
              sorted = Array(values).map(&:to_f).sort
              middle = sorted.length / 2
              return sorted[middle] if sorted.length.odd?

              (sorted[middle - 1] + sorted[middle]) / 2.0
            end

            def verdict(speedup)
              return 'canonical_faster' if speedup >= 1.05
              return 'full_faster' if speedup <= 0.95

              'similar'
            end

            def build_result(rows, iterations, warmup, keep_geometry)
              mismatch_count = rows.sum do |row|
                row['result_mismatch_count'].to_i
              end
              {
                'schema_version' => 2,
                'generated_at' => Time.now.iso8601(6),
                'mode' =>
                  'synthetic_simple_cellspace_full_vs_canonical_microbenchmark',
                'production_decision_modified' => false,
                'validation_report_modified' => false,
                'iterations' => iterations,
                'warmup' => warmup,
                'face_counts' => SIDE_COUNTS.map { |sides| sides + 2 },
                'face_count_limit_exclusive' => 30,
                'relations' => RELATIONS.keys,
                'case_count' => rows.length,
                'tolerance_mm' =>
                  (Utils::Geometry::VALIDATION_TOLERANCE.to_f * 25.4).round(9),
                'result_mismatch_count' => mismatch_count,
                'result_equivalence' => mismatch_count.zero?,
                'fixture_kept' => keep_geometry == true,
                'cases' => rows,
                'relation_summary' => relation_summary(rows),
                'pass' => mismatch_count.zero?
              }
            end

            def relation_summary(rows)
              RELATIONS.keys.to_h do |relation|
                selected = rows.select { |row| row['relation'] == relation }
                full_cold = selected.flat_map do |row|
                  row.dig('samples_ms', 'full_cold')
                end
                canonical_cold = selected.flat_map do |row|
                  row.dig('samples_ms', 'canonical_cold')
                end
                full_warm = selected.flat_map do |row|
                  row.dig('samples_ms', 'full_warm')
                end
                canonical_warm = selected.flat_map do |row|
                  row.dig('samples_ms', 'canonical_warm')
                end
                paths = Hash.new(0)
                selected.each do |row|
                  row['canonical_path_counts'].each do |name, count|
                    paths[name] += count.to_i
                  end
                end
                [
                  relation,
                  {
                    'cold' => comparison(full_cold, canonical_cold),
                    'warm' => comparison(full_warm, canonical_warm),
                    'canonical_path_counts' => paths.sort.to_h
                  }
                ]
              end
            end

            def write_result(result)
              FileUtils.mkdir_p(OUTPUT_DIR)
              @last_result_path = File.join(
                OUTPUT_DIR,
                "simple_cellspace_recheck_#{Time.now.strftime('%Y%m%d-%H%M%S')}.json"
              )
              File.write(
                @last_result_path,
                JSON.pretty_generate(result),
                encoding: 'UTF-8'
              )
            end

            def erase_old_fixture(model)
              old = []
              model.entities.each do |entity|
                next unless entity.is_a?(Sketchup::Group)
                next unless entity.valid?
                next unless entity.name.to_s == FIXTURE_NAME

                old << entity
              end
              return if old.empty?

              operation_started = model.start_operation(
                'Remove old simple recheck benchmark fixture', true
              )
              old.each { |group| group.erase! if group.valid? }
              model.commit_operation if operation_started
            rescue StandardError
              model.abort_operation if operation_started
              raise
            end

            def face_count(group)
              count = 0
              group.entities.each do |entity|
                count += 1 if entity.is_a?(Sketchup::Face) && entity.valid?
              end
              count
            end

            def format_paths(paths)
              paths.map { |name, count| "#{name}=#{count}" }.join(',')
            end
          end
        end
      end
    end
  end
end
