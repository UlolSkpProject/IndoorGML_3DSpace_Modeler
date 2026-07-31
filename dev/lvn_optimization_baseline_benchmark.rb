# frozen_string_literal: true

# LocalVertexNormalizer optimization baseline benchmark.
#
# Run from the SketchUp Ruby Console after the extension is loaded.
# Select one or more Group / ComponentInstance solids first, then:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'lvn_optimization_baseline_benchmark.rb')
#
# The benchmark never intentionally keeps normalized geometry. Every measured
# normalize call runs with manage_operation:false inside its own outer SketchUp
# operation, and that operation is aborted immediately afterward. The selected
# entity is then re-resolved by persistent_id and its exact local B-rep signature
# is compared with the original source signature.

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
          entities = benchmark_entities(model)
          if entities.empty?
            puts '[LVN BENCH] Select one or more Group / ComponentInstance solids first.'
            return false
          end

          rounds = [rounds.to_i, 1].max
          puts '=' * 78
          puts ' IndoorGML LVN Optimization Baseline Benchmark'
          puts '=' * 78
          puts format('selected solids : %d', entities.length)
          puts format('rounds / solid  : %d production samples', rounds)
          puts format('ruby            : %s', RUBY_VERSION)
          puts format('tolerance       : %.6f mm', LocalVertexNormalizer::DEFAULT_TOLERANCE_MM)
          puts 'measurement     : normalize only; outer rollback is excluded from timing'
          puts 'source safety   : exact local B-rep signature checked after every rollback'

          results = entities.map do |entity|
            benchmark_entity(model, entity, rounds)
          rescue StandardError => error
            {
              label: entity_label(entity),
              pid: persistent_id(entity),
              status: :failed,
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

        def benchmark_entities(model)
          model.selection.to_a.select do |entity|
            entity.respond_to?(:definition) &&
              entity.respond_to?(:valid?) &&
              entity.valid?
          end
        end

        def benchmark_entity(model, original_entity, rounds)
          pid = persistent_id(original_entity)
          source = resolve_entity(model, pid, original_entity)
          raise "Could not resolve selected entity #{pid.inspect}" unless source

          source_signature = brep_signature(source)
          before = geometry_summary(source)

          # Warm method lookup / caches without changing the source state.
          with_rollback_normalization(model, source, label: 'LVN benchmark warmup') do |entity|
            LocalVertexNormalizer.normalize(
              entity,
              LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
              manage_operation: false
            )
          end
          assert_source_restored!(model, pid, source_signature, source)

          samples = []
          allocations = []
          strategies = []
          rounds.times do |index|
            entity = resolve_entity(model, pid, source)
            GC.start
            before_alloc = GC.stat(:total_allocated_objects)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = with_rollback_normalization(
              model,
              entity,
              label: "LVN benchmark production #{index + 1}"
            ) do |current|
              LocalVertexNormalizer.normalize(
                current,
                LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
                manage_operation: false
              )
            end
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            after_alloc = GC.stat(:total_allocated_objects)

            samples << elapsed * 1000.0
            allocations << (after_alloc - before_alloc)
            strategies << normalization_strategy(result)
            assert_source_restored!(model, pid, source_signature, source)
          end

          trace_counts = production_trace_probe(model, pid, source)
          assert_source_restored!(model, pid, source_signature, source)

          profile_result = profile_probe(model, pid, source)
          assert_source_restored!(model, pid, source_signature, source)

          timing = summarize_samples(samples, allocations)
          profile = profile_result.is_a?(Hash) ? profile_result[:debug_profile] : nil

          result = {
            label: entity_label(source),
            pid: pid,
            status: :success,
            geometry: before,
            timing: timing,
            strategies: strategies.uniq,
            trace_counts: trace_counts,
            profile: profile,
            source_restored: true
          }
          print_entity_result(result)
          result
        end

        def with_rollback_normalization(model, entity, label:)
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

        def production_trace_probe(model, pid, fallback)
          counts = Hash.new(0)
          tracer = TracePoint.new(:call, :c_call) do |tp|
            method_id = tp.method_id
            counts[method_id] += 1 if TRACE_METHODS.include?(method_id)
          end

          entity = resolve_entity(model, pid, fallback)
          with_rollback_normalization(model, entity, label: 'LVN benchmark trace') do |current|
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
          with_rollback_normalization(model, entity, label: 'LVN benchmark profile') do |current|
            LocalVertexNormalizer.normalize(
              current,
              LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
              report: true,
              write_report: false,
              manage_operation: false
            )
          end
        end

        def summarize_samples(samples, allocations)
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
            (result.dig(:normalization_fast_path, :applied) ? :already_normalized_fast_path_v2 : :full_pipeline)
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
          edge_signatures = entities.grep(Sketchup::Edge).map do |edge|
            first = exact_point_key(edge.start.position)
            second = exact_point_key(edge.end.position)
            (first <=> second) <= 0 ? [first, second] : [second, first]
          end.sort

          face_signatures = entities.grep(Sketchup::Face).map do |face|
            loops = face.loops.map do |loop|
              canonical_cycle(loop.vertices.map { |vertex| exact_point_key(vertex.position) })
            end.sort
            loops
          end.sort

          [edge_signatures, face_signatures]
        end

        def exact_point_key(point)
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

        def assert_source_restored!(model, pid, expected_signature, fallback)
          entity = resolve_entity(model, pid, fallback)
          raise "Entity #{pid.inspect} is invalid after rollback" unless entity&.valid?

          actual = brep_signature(entity)
          return true if actual == expected_signature

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

        def top_profile_stages(profile)
          return [] unless profile.is_a?(Hash)

          stages = profile[:stages]
          return [] unless stages.is_a?(Hash)

          stages.sort_by { |_name, metrics| -metrics[:total_seconds].to_f }
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
            geometry[:faces], geometry[:edges], geometry[:vertices], geometry[:manifold].inspect
          )
          puts format(
            'production      : median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
            timing[:median_ms], timing[:min_ms], timing[:max_ms], timing[:median_alloc]
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
            top_profile_stages(profile).each do |name, metrics|
              puts format(
                '  %-45s %9.3f ms  calls=%4d  max=%9.3f',
                name,
                metrics[:total_seconds].to_f * 1000.0,
                metrics[:calls].to_i,
                metrics[:max_seconds].to_f * 1000.0
              )
            end
            snapshot_reuse = profile[:snapshot_reuse]
            puts format('snapshot reuse  : %s', snapshot_reuse.inspect) if snapshot_reuse
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
            total_median = successes.sum { |result| result[:timing][:median_ms] }
            total_alloc = successes.sum { |result| result[:timing][:median_alloc] }
            puts '--- aggregate ------------------------------------------------------------'
            puts format('sum of per-solid medians : %9.3f ms', total_median)
            puts format('sum median allocations   : %9d', total_alloc)
          end

          failures.each do |result|
            puts format('FAILED %-34s %s', result[:label][0, 34], result[:error])
            Array(result[:backtrace]).each { |line| puts "  #{line}" }
          end
          puts format('result                  : %s', failures.empty? ? 'PASS' : 'FAIL')
          puts '=' * 78
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::LvnOptimizationBaselineBenchmark.run
