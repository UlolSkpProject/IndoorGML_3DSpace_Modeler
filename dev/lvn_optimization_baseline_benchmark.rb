# frozen_string_literal: true

# LocalVertexNormalizer optimization baseline benchmark.
#
# Select one or more Group / ComponentInstance solids, then run from the
# SketchUp Ruby Console:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'lvn_optimization_baseline_benchmark.rb')
#
# Every normalization runs with manage_operation:false inside an outer SketchUp
# operation that is aborted afterward. start_operation / abort_operation are NOT
# included in production timing or allocation measurements. After every rollback
# the selected entity is re-resolved by persistent_id and its local B-rep is
# compared with the original source signature.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnOptimizationBaselineBenchmark
        DEFAULT_ROUNDS = 3
        TOP_STAGE_COUNT = 15

        TRACE_METHODS = [
          :normalized?,
          :normalize_entity,
          :geometry_counts,
          :geometry_vertices,
          :solid_volume_mm3,
          :short_edge_sliver_collapse_plan,
          :triangle_snapshot,
          :normalized_triangle_snapshot,
          :conforming_triangle_snapshot,
          :discard_collapsed_triangle_records,
          :normalize_triangle_records_allowing_collisions,
          :validate_normalized_triangle_shapes!,
          :triangle_mesh_inventory,
          :validate_normalized_triangle_mesh!,
          :validate_triangle_intersections!,
          :collect_triangle_intersection_failures,
          :triangulate_exact_polygon_with_holes,
          :rebuild_triangles,
          :orient_and_merge_rebuilt_surface,
          :repair_rebuilt_entity_before_rollback,
          :normalized_surface_descriptor,
          :verify_normalized_surface_equivalence!,
          :max_grid_residual_mm,
          :manifold?
        ].freeze

        module_function

        def run(rounds: DEFAULT_ROUNDS)
          model = Sketchup.active_model
          selected = model.selection.to_a.select do |entity|
            entity.respond_to?(:definition) &&
              entity.respond_to?(:valid?) &&
              entity.valid?
          end
          if selected.empty?
            puts '[LVN BENCH] Select one or more Group / ComponentInstance solids first.'
            return false
          end

          rounds = [rounds.to_i, 1].max
          puts '=' * 78
          puts ' IndoorGML LVN Optimization Baseline Benchmark'
          puts '=' * 78
          puts format('selected solids : %d', selected.length)
          puts format('rounds / solid  : %d production samples', rounds)
          puts format('ruby            : %s', RUBY_VERSION)
          puts format('tolerance       : %.6f mm', LocalVertexNormalizer::DEFAULT_TOLERANCE_MM)
          puts 'measurement     : normalize only; outer operation/rollback excluded'
          puts 'source safety   : local B-rep signature checked after every rollback'

          results = selected.map do |entity|
            benchmark_entity(model, entity, rounds)
          rescue StandardError => error
            {
              status: :failed,
              label: entity_label(entity),
              error: "#{error.class}: #{error.message}",
              backtrace: Array(error.backtrace).first(6)
            }
          end

          print_summary(results)
          results.all? { |result| result[:status] == :success }
        rescue StandardError => error
          warn "[LVN BENCH] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(8).join("\n")
          false
        end

        def benchmark_entity(model, original, rounds)
          pid = persistent_id(original)
          source = resolve_entity(model, pid, original)
          raise "Could not resolve selected entity #{pid.inspect}" unless source

          signature = brep_signature(source)
          geometry = geometry_summary(source)

          with_rollback(model, source, 'LVN benchmark warmup') do |entity|
            LocalVertexNormalizer.normalize(
              entity,
              LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
              manage_operation: false
            )
          end
          assert_restored!(model, pid, source, signature)

          samples = []
          allocations = []
          strategies = []

          rounds.times do |index|
            entity = resolve_entity(model, pid, source)
            GC.start
            measured_ms = nil
            measured_alloc = nil

            result = with_rollback(model, entity, "LVN benchmark production #{index + 1}") do |current|
              before_alloc = GC.stat(:total_allocated_objects)
              started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              normalized = LocalVertexNormalizer.normalize(
                current,
                LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
                manage_operation: false
              )
              measured_ms =
                (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
              measured_alloc =
                GC.stat(:total_allocated_objects) - before_alloc
              normalized
            end

            samples << measured_ms
            allocations << measured_alloc
            strategies << normalization_strategy(result)
            assert_restored!(model, pid, source, signature)
          end

          trace_counts = trace_probe(model, pid, source)
          assert_restored!(model, pid, source, signature)

          profile_result = profile_probe(model, pid, source)
          assert_restored!(model, pid, source, signature)

          result = {
            status: :success,
            label: entity_label(source),
            geometry: geometry,
            timing: summarize(samples, allocations),
            strategies: strategies.uniq,
            trace_counts: trace_counts,
            profile:
              profile_result.is_a?(Hash) ? profile_result[:debug_profile] : nil
          }
          print_entity_result(result)
          result
        end

        def with_rollback(model, entity, label)
          started = model.start_operation(label, true)
          raise 'SketchUp start_operation returned false' if started == false

          result = nil
          begin
            result = yield(entity)
          ensure
            aborted = model.abort_operation
            raise 'SketchUp abort_operation returned false' if aborted == false
          end
          result
        end

        def trace_probe(model, pid, fallback)
          counts = Hash.new(0)
          tracer = TracePoint.new(:call, :c_call) do |tp|
            method_id = tp.method_id
            counts[method_id] += 1 if TRACE_METHODS.include?(method_id)
          end

          entity = resolve_entity(model, pid, fallback)
          with_rollback(model, entity, 'LVN benchmark trace') do |current|
            tracer.enable do
              LocalVertexNormalizer.normalize(
                current,
                LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
                manage_operation: false
              )
            end
          end
          counts
        ensure
          tracer&.disable
        end

        def profile_probe(model, pid, fallback)
          entity = resolve_entity(model, pid, fallback)
          with_rollback(model, entity, 'LVN benchmark profile') do |current|
            LocalVertexNormalizer.normalize(
              current,
              LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
              report: true,
              write_report: false,
              manage_operation: false
            )
          end
        end

        def summarize(samples, allocations)
          sorted = samples.sort
          alloc_sorted = allocations.sort
          {
            median_ms: sorted[sorted.length / 2],
            min_ms: sorted.first,
            max_ms: sorted.last,
            median_alloc: alloc_sorted[alloc_sorted.length / 2],
            min_alloc: alloc_sorted.first,
            max_alloc: alloc_sorted.last
          }
        end

        def normalization_strategy(result)
          return :unknown unless result.is_a?(Hash)

          result[:normalization_strategy] ||
            if result.dig(:normalization_fast_path, :applied)
              :already_normalized_fast_path_v2
            else
              :full_pipeline
            end
        rescue StandardError
          :unknown
        end

        def geometry_summary(entity)
          entities = entity.definition.entities
          faces = entities.grep(Sketchup::Face)
          edges = entities.grep(Sketchup::Edge)
          vertices = edges.flat_map(&:vertices).uniq
          {
            faces: faces.length,
            edges: edges.length,
            vertices: vertices.length,
            manifold: entity.respond_to?(:manifold?) ? entity.manifold? : nil
          }
        end

        def brep_signature(entity)
          entities = entity.definition.entities
          edges = entities.grep(Sketchup::Edge).map do |edge|
            a = point_key(edge.start.position)
            b = point_key(edge.end.position)
            (a <=> b) <= 0 ? [a, b] : [b, a]
          end.sort

          faces = entities.grep(Sketchup::Face).map do |face|
            face.loops.map do |loop|
              canonical_cycle(
                loop.vertices.map { |vertex| point_key(vertex.position) }
              )
            end.sort
          end.sort
          [edges, faces]
        end

        def point_key(point)
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end

        def canonical_cycle(points)
          return points if points.length < 2

          forward = minimum_rotation(points)
          reverse = minimum_rotation(points.reverse)
          (forward <=> reverse) <= 0 ? forward : reverse
        end

        def minimum_rotation(points)
          best = nil
          points.length.times do |index|
            candidate = points.rotate(index)
            best = candidate if best.nil? || (candidate <=> best) < 0
          end
          best
        end

        def assert_restored!(model, pid, fallback, expected)
          entity = resolve_entity(model, pid, fallback)
          raise "Entity #{pid.inspect} invalid after rollback" unless entity&.valid?
          return true if brep_signature(entity) == expected

          raise "Source B-rep changed after rollback for #{entity_label(entity)}"
        end

        def resolve_entity(model, pid, fallback = nil)
          if pid && model.respond_to?(:find_entity_by_persistent_id)
            found = model.find_entity_by_persistent_id(pid)
            return found if found&.valid?
          end
          return fallback if fallback&.valid?

          nil
        rescue StandardError
          fallback&.valid? ? fallback : nil
        end

        def persistent_id(entity)
          entity.persistent_id if entity.respond_to?(:persistent_id)
        rescue StandardError
          nil
        end

        def entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          label = name.empty? ? entity.class.to_s : name
          pid = persistent_id(entity)
          pid ? "#{label}[PID=#{pid}]" : label
        rescue StandardError
          entity.class.to_s
        end

        def top_stages(profile)
          return [] unless profile.is_a?(Hash) && profile[:stages].is_a?(Hash)

          profile[:stages]
            .sort_by { |_name, metrics| -metrics[:total_seconds].to_f }
            .first(TOP_STAGE_COUNT)
        end

        def print_entity_result(result)
          timing = result[:timing]
          geometry = result[:geometry]
          puts
          puts '-' * 78
          puts result[:label]
          puts format(
            'geometry        : faces=%d edges=%d vertices=%d manifold=%s',
            geometry[:faces],
            geometry[:edges],
            geometry[:vertices],
            geometry[:manifold].inspect
          )
          puts format(
            'production      : median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
            timing[:median_ms],
            timing[:min_ms],
            timing[:max_ms],
            timing[:median_alloc]
          )
          puts format('strategies      : %s', result[:strategies].join(', '))
          puts 'trace counts:'
          printed = false
          TRACE_METHODS.each do |method_id|
            count = result[:trace_counts][method_id]
            next if count.nil? || count.zero?

            puts format('  %-45s %8d', method_id, count)
            printed = true
          end
          puts '  (no traced calls)' unless printed

          profile = result[:profile]
          if profile
            puts format(
              'profile probe   : total=%9.3f ms status=%s',
              profile[:total_seconds].to_f * 1000.0,
              profile[:status]
            )
            puts 'top inclusive stages:'
            top_stages(profile).each do |name, metrics|
              puts format(
                '  %-45s %9.3f ms  calls=%4d  max=%9.3f',
                name,
                metrics[:total_seconds].to_f * 1000.0,
                metrics[:calls].to_i,
                metrics[:max_seconds].to_f * 1000.0
              )
            end
            if profile[:snapshot_reuse]
              puts format(
                'snapshot reuse  : %s',
                profile[:snapshot_reuse].inspect
              )
            end
          else
            puts 'profile probe   : unavailable'
          end
          puts 'source restored : true'
        end

        def print_summary(results)
          puts
          puts '=' * 78
          puts ' LVN Baseline Summary'
          puts '=' * 78
          successes = results.select { |result| result[:status] == :success }
          failures = results.reject { |result| result[:status] == :success }

          successes.each do |result|
            timing = result[:timing]
            geometry = result[:geometry]
            puts format(
              '%-34s faces=%5d  median=%9.3f ms  alloc=%9d  strategy=%s',
              result[:label][0, 34],
              geometry[:faces],
              timing[:median_ms],
              timing[:median_alloc],
              result[:strategies].join('/')
            )
          end

          unless successes.empty?
            total_median = successes.sum do |result|
              result[:timing][:median_ms]
            end
            total_alloc = successes.sum do |result|
              result[:timing][:median_alloc]
            end
            puts '--- aggregate ------------------------------------------------------------'
            puts format('sum of per-solid medians : %9.3f ms', total_median)
            puts format('sum median allocations   : %9d', total_alloc)
          end

          failures.each do |result|
            puts format(
              'FAILED %-34s %s',
              result[:label][0, 34],
              result[:error]
            )
            Array(result[:backtrace]).each { |line| puts "  #{line}" }
          end
          puts format(
            'result                  : %s',
            failures.empty? ? 'PASS' : 'FAIL'
          )
          puts '=' * 78
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::LvnOptimizationBaselineBenchmark.run
