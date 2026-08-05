# frozen_string_literal: true

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

            def run!(iterations: 10, warmup: 2, keep_geometry: true)
              raise ArgumentError, 'iterations must be >= 3' if iterations.to_i < 3
              raise ArgumentError, 'warmup must be >= 1' if warmup.to_i < 1

              model = Sketchup.active_model
              raise 'SketchUp active model is unavailable.' unless model

              erase_old_fixture(model)
              unless model.entities.empty?
                raise "Run in a blank model. Root entity count=#{model.entities.length}"
              end

              fixture, cases = create_fixture(model)
              @last_fixture = fixture
              rows = cases.map do |entry|
                benchmark_case(model, entry, iterations.to_i, warmup.to_i)
              end
              result = build_result(rows, iterations.to_i, warmup.to_i, keep_geometry)
              write_result(result)
              @last_result = result
              print_report(result)
              cleanup! unless keep_geometry
              result
            rescue StandardError
              cleanup! unless keep_geometry
              raise
            end

            def cleanup!
              return true unless @last_fixture&.valid?

              model = Sketchup.active_model
              model.start_operation('Remove simple recheck benchmark fixture', true)
              @last_fixture.erase!
              model.commit_operation
              @last_fixture = nil
              true
            rescue StandardError
              model.abort_operation rescue nil
              false
            end

            def print_report(result = @last_result)
              raise 'No benchmark result is available.' unless result

              puts
              puts('=' * 150)
              puts('SIMPLE CELLSPACE RECHECK — FULL-SOLID vs CANONICAL')
              puts('=' * 150)
              puts "iterations        : #{result['iterations']}"
              puts "warmup             : #{result['warmup']}"
              puts "face_counts        : #{result['face_counts'].inspect}"
              puts "result_equivalence : #{result['result_equivalence']}"
              puts "result_path        : #{@last_result_path}"
              puts('-' * 150)
              puts format(
                '%-15s %5s %10s %10s %8s %10s %10s %8s %-34s',
                'relation', 'faces', 'full cold', 'canon cold', 'ratio',
                'full warm', 'canon warm', 'ratio', 'canonical paths'
              )
              result.fetch('cases').each do |row|
                puts format(
                  '%-15s %5d %9.3fms %9.3fms %7.3fx %9.3fms %9.3fms %7.3fx %-34s',
                  row['relation'], row['face_count'],
                  row.dig('cold', 'full_median_ms'),
                  row.dig('cold', 'canonical_median_ms'),
                  row.dig('cold', 'speedup_vs_full'),
                  row.dig('warm', 'full_median_ms'),
                  row.dig('warm', 'canonical_median_ms'),
                  row.dig('warm', 'speedup_vs_full'),
                  row['canonical_path_counts'].map { |k, v| "#{k}=#{v}" }.join(',')
                )
              end
              puts('-' * 150)
              result.fetch('relation_summary').each do |relation, row|
                puts format(
                  '%-15s cold=%7.3fx %-17s warm=%7.3fx %-17s paths=%s',
                  relation,
                  row.dig('cold', 'speedup_vs_full'), row.dig('cold', 'verdict'),
                  row.dig('warm', 'speedup_vs_full'), row.dig('warm', 'verdict'),
                  row['canonical_path_counts'].map { |k, v| "#{k}=#{v}" }.join(',')
                )
              end
              puts('-' * 150)
              puts "PASS               : #{result['pass']}"
              puts "fixture_kept       : #{result['fixture_kept']}"
              puts('=' * 150)
              result
            end

            private

            def create_fixture(model)
              model.start_operation('Create simple recheck benchmark fixture', true)
              root = model.entities.add_group
              root.name = FIXTURE_NAME
              cases = []
              radius = 1000.0.mm
              height = 3000.0.mm
              row = 0

              SIDE_COUNTS.each_with_index do |sides, column|
                RELATIONS.each do |relation, (kind, distance_mm)|
                  holder = root.entities.add_group
                  holder.name = "#{relation}_#{sides}_sides"
                  a = prism(holder.entities, sides, radius, height, "#{relation}_#{sides}_A")
                  b = prism(holder.entities, sides, radius, height, "#{relation}_#{sides}_B")
                  half_width = radius * Math.cos(Math::PI / sides)
                  separation = 2.0 * half_width
                  separation += distance_mm.mm if kind == :gap
                  separation -= distance_mm.mm if kind == :overlap
                  x = column * 5000.0.mm
                  y = row * 3500.0.mm
                  a.transform!(Geom::Transformation.translation([x, y, 0]))
                  b.transform!(Geom::Transformation.translation([x + separation, y, 0]))
                  expected = sides + 2
                  actual = [face_count(a), face_count(b)]
                  raise "Face count mismatch #{expected}/#{actual.inspect}" unless actual == [expected, expected]
                  raise "Generated non-manifold prism: #{relation}/#{sides}" unless a.manifold? && b.manifold?

                  cells = [
                    Cell.new("bench_#{relation}_#{sides}_a", a),
                    Cell.new("bench_#{relation}_#{sides}_b", b)
                  ]
                  cases << {
                    relation: relation,
                    side_count: sides,
                    face_count: expected,
                    cells: cells
                  }
                  row += 1
                end
              end
              model.commit_operation
              [root, cases]
            rescue StandardError
              model.abort_operation
              raise
            end

            def prism(entities, sides, radius, height, name)
              group = entities.add_group
              group.name = name
              points = sides.times.map do |index|
                angle = Math::PI / sides + 2.0 * Math::PI * index / sides
                Geom::Point3d.new(radius * Math.cos(angle), radius * Math.sin(angle), 0)
              end
              face = group.entities.add_face(points)
              raise "Failed to create #{name}" unless face

              face.reverse! if face.normal.z.negative?
              face.pushpull(height)
              group
            end

            def benchmark_case(model, entry, iterations, warmup)
              ids = entry.fetch(:cells).map(&:id)
              context = Context.new(model, entry.fetch(:cells), IndoorCore::IndoorModel.current)
              full_warm = checker(Val3dityFullIntersectionRechecker, context)
              canonical_warm = checker(Val3dityOverlapGeometryRechecker, context)
              warmup.times do
                invoke(full_warm, ids)
                invoke(canonical_warm, ids)
              end

              samples = Hash.new { |hash, key| hash[key] = [] }
              paths = Hash.new(0)
              mismatch = 0
              iterations.times do |index|
                if index.even?
                  full_warm_result, samples[:full_warm] = timed_append(samples[:full_warm]) { invoke(full_warm, ids) }
                  canonical_warm_result, samples[:canonical_warm] = timed_append(samples[:canonical_warm]) { invoke(canonical_warm, ids) }
                else
                  canonical_warm_result, samples[:canonical_warm] = timed_append(samples[:canonical_warm]) { invoke(canonical_warm, ids) }
                  full_warm_result, samples[:full_warm] = timed_append(samples[:full_warm]) { invoke(full_warm, ids) }
                end

                full_cold = checker(Val3dityFullIntersectionRechecker, context)
                canonical_cold = checker(Val3dityOverlapGeometryRechecker, context)
                full_cold_result, samples[:full_cold] = timed_append(samples[:full_cold]) { invoke(full_cold, ids) }
                canonical_cold_result, samples[:canonical_cold] = timed_append(samples[:canonical_cold]) { invoke(canonical_cold, ids) }

                mismatch += 1 unless equivalent?(full_warm_result, canonical_warm_result)
                mismatch += 1 unless equivalent?(full_cold_result, canonical_cold_result)
                paths[path(canonical_warm.proxy_record(*ids))] += 1
                paths[path(canonical_cold.proxy_record(*ids))] += 1
              end

              {
                'relation' => entry.fetch(:relation),
                'side_count' => entry.fetch(:side_count),
                'face_count' => entry.fetch(:face_count),
                'result_mismatch_count' => mismatch,
                'cold' => comparison(samples[:full_cold], samples[:canonical_cold]),
                'warm' => comparison(samples[:full_warm], samples[:canonical_warm]),
                'canonical_path_counts' => paths.sort.to_h,
                '_samples' => samples.transform_keys(&:to_s)
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

            def timed_append(samples)
              started = Process.clock_gettime(CLOCK)
              result = yield
              samples << (Process.clock_gettime(CLOCK) - started) * 1000.0
              [result, samples]
            end

            def intersection(result)
              return result unless result.is_a?(Hash)
              result[:intersection].is_a?(Hash) ? result[:intersection] : result
            end

            def equivalent?(left, right)
              a = intersection(left)
              b = intersection(right)
              return false unless a.is_a?(Hash) && b.is_a?(Hash)
              return false unless a[:status].to_s == b[:status].to_s
              return false unless a[:component_count].to_i == b[:component_count].to_i

              av = a[:volume].to_f
              bv = b[:volume].to_f
              (av - bv).abs <= [av.abs, bv.abs, 1.0].max * 1.0e-6
            end

            def path(record)
              return 'missing_record' unless record.is_a?(Hash)
              name = record['path'].to_s
              reason = record['fallback_reason'].to_s
              name == 'full_geometry_confirmation' && !reason.empty? ? "#{name}:#{reason}" : name
            end

            def comparison(full, canonical)
              full_median = median(full)
              canonical_median = median(canonical)
              speedup = canonical_median.positive? ? full_median / canonical_median : 0.0
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
              sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
            end

            def verdict(speedup)
              return 'canonical_faster' if speedup >= 1.05
              return 'full_faster' if speedup <= 0.95
              'similar'
            end

            def build_result(rows, iterations, warmup, keep_geometry)
              mismatch = rows.sum { |row| row['result_mismatch_count'].to_i }
              public_rows = rows.map { |row| row.reject { |key, _| key == '_samples' } }
              {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => 'synthetic_simple_cellspace_full_vs_canonical_microbenchmark',
                'production_decision_modified' => false,
                'validation_report_modified' => false,
                'iterations' => iterations,
                'warmup' => warmup,
                'face_counts' => SIDE_COUNTS.map { |sides| sides + 2 },
                'face_count_limit_exclusive' => 30,
                'relations' => RELATIONS.keys,
                'case_count' => rows.length,
                'tolerance_mm' => (Utils::Geometry::VALIDATION_TOLERANCE.to_f * 25.4).round(9),
                'result_mismatch_count' => mismatch,
                'result_equivalence' => mismatch.zero?,
                'fixture_kept' => keep_geometry == true,
                'cases' => public_rows,
                'relation_summary' => relation_summary(rows),
                'pass' => mismatch.zero?
              }
            end

            def relation_summary(rows)
              RELATIONS.keys.to_h do |relation|
                selected = rows.select { |row| row['relation'] == relation }
                full_cold = selected.flat_map { |row| row.dig('_samples', 'full_cold') }
                canon_cold = selected.flat_map { |row| row.dig('_samples', 'canonical_cold') }
                full_warm = selected.flat_map { |row| row.dig('_samples', 'full_warm') }
                canon_warm = selected.flat_map { |row| row.dig('_samples', 'canonical_warm') }
                paths = Hash.new(0)
                selected.each do |row|
                  row['canonical_path_counts'].each { |name, count| paths[name] += count.to_i }
                end
                [relation, {
                  'cold' => comparison(full_cold, canon_cold),
                  'warm' => comparison(full_warm, canon_warm),
                  'canonical_path_counts' => paths.sort.to_h
                }]
              end
            end

            def write_result(result)
              Dir.mkdir(OUTPUT_DIR) unless Dir.exist?(OUTPUT_DIR)
              @last_result_path = File.join(
                OUTPUT_DIR,
                "simple_cellspace_recheck_#{Time.now.strftime('%Y%m%d-%H%M%S')}.json"
              )
              File.write(@last_result_path, JSON.pretty_generate(result), encoding: 'UTF-8')
            end

            def erase_old_fixture(model)
              old = model.entities.grep(Sketchup::Group).select do |group|
                group.valid? && group.name.to_s == FIXTURE_NAME
              end
              return if old.empty?

              model.start_operation('Remove old simple recheck benchmark fixture', true)
              old.each { |group| group.erase! if group.valid? }
              model.commit_operation
            rescue StandardError
              model.abort_operation
              raise
            end

            def face_count(group)
              group.definition.entities.grep(Sketchup::Face).count(&:valid?)
            end
          end
        end
      end
    end
  end
end
