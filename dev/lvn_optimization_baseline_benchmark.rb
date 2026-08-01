# frozen_string_literal: true

require 'digest'

# LocalVertexNormalizer optimization baseline benchmark.
#
# Default execution is intentionally light:
# - first selected solid only
# - one production normalize call
# - no warmup
# - no TracePoint
# - no debug profiler
#
# Run from the SketchUp Ruby Console after selecting a solid:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'lvn_optimization_baseline_benchmark.rb')
#
# Optional explicit runs:
#
#   ULOL::Indoor3DGmlModeler::IndoorCore::LvnOptimizationBaselineBenchmark.run(
#     rounds: 3,
#     all: true,
#     profile: true,
#     trace: false
#   )
#
# Every normalize call runs with manage_operation:false inside an outer
# SketchUp operation. The operation is aborted immediately afterward and the
# source B-rep signature is checked again. Normalized geometry is not retained.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnOptimizationBaselineBenchmark
        DEFAULT_ROUNDS = 1
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

        def run(rounds: DEFAULT_ROUNDS, all: false, profile: false, trace: false)
          model = Sketchup.active_model
          selected = benchmark_entities(model)
          if selected.empty?
            puts '[LVN BENCH] Select one or more Group / ComponentInstance solids first.'
            return false
          end

          entities = all ? selected : [selected.first]
          rounds = [rounds.to_i, 1].max

          puts '=' * 78
          puts ' IndoorGML LVN Optimization Baseline Benchmark'
          puts '=' * 78
          puts format('selected solids : %d', selected.length)
          puts format('tested solids   : %d%s', entities.length, all ? '' : ' (first selected only)')
          puts format('rounds / solid  : %d production sample(s)', rounds)
          puts format('profile probe   : %s', profile ? 'enabled' : 'disabled')
          puts format('TracePoint probe: %s', trace ? 'enabled' : 'disabled')
          puts format('ruby            : %s', RUBY_VERSION)
          puts format('tolerance       : %.6f mm', LocalVertexNormalizer::DEFAULT_TOLERANCE_MM)
          puts 'measurement     : normalize call only; operation start/rollback excluded'
          puts 'source safety   : exact local B-rep signature checked after every rollback'
          if !all && selected.length > 1
            puts '[LVN BENCH] Multiple solids selected; default run tests only the first one.'
          end

          results = entities.map.with_index do |entity, index|
            puts
            puts format('[LVN BENCH] Solid %d/%d: %s', index + 1, entities.length, entity_label(entity))
            benchmark_entity(
              model,
              entity,
              rounds,
              profile: profile,
              trace: trace
            )
          rescue StandardError => error
            warn "[LVN BENCH] FAILED #{entity_label(entity)}: #{error.class}: #{error.message}"
            warn Array(error.backtrace).first(8).join("\n")
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

        def benchmark_entity(model, original_entity, rounds, profile:, trace:)
          pid = persistent_id(original_entity)
          source = resolve_entity(model, pid, original_entity)
          raise "Could not resolve selected entity #{pid.inspect}" unless source

          puts '[LVN BENCH] Building source B-rep signature...'
          source_signature = brep_signature(source)
          geometry = geometry_summary(source)
          puts format(
            '[LVN BENCH] Source ready: faces=%d edges=%d vertices=%d manifold=%s',
            geometry[:faces],
            geometry[:edges],
            geometry[:vertices],
            geometry[:manifold].inspect
          )

          samples = []
          allocations = []
          strategies = []

          rounds.times do |index|
            entity = resolve_entity(model, pid, source)
            measurement = measure_with_rollback(
              model,
              entity,
              pid,
              source_signature,
              label: "LVN baseline production #{index + 1}/#{rounds}"
            ) do |current|
              LocalVertexNormalizer.normalize(
                current,
                LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
                manage_operation: false
              )
            end

            samples << measurement[:elapsed_ms]
            allocations << measurement[:allocations]
            strategies << normalization_strategy(measurement[:result])
          end

          trace_counts = trace ? trace_probe(model, pid, source, source_signature) : {}
          profile_result = profile ? profile_probe(model, pid, source, source_signature) : nil
          timing = summarize_samples(samples, allocations)
          debug_profile = profile_result.is_a?(Hash) ? profile_result[:debug_profile] : nil

          result = {
            label: entity_label(resolve_entity(model, pid, source) || source),
            pid: pid,
            status: :success,
            geometry: geometry,
            timing: timing,
            strategies: strategies.uniq,
            trace_counts: trace_counts,
            profile: debug_profile,
            source_restored: true
          }
          print_entity_result(result, trace: trace, profile: profile)
          result
        end

        def measure_with_rollback(model, entity, pid, expected_signature, label:)
          puts "[LVN BENCH] START #{label}"
          started_operation = model.start_operation(label, true)
          raise 'SketchUp start_operation returned false' if started_operation == false

          result = nil
          elapsed_ms = nil
          allocations = nil
          normalize_error = nil

          begin
            GC.start
            before_alloc = GC.stat(:total_allocated_objects)
            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            begin
              result = yield(entity)
            rescue StandardError => error
              normalize_error = error
            ensure
              finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              after_alloc = GC.stat(:total_allocated_objects)
              elapsed_ms = (finished_at - started_at) * 1000.0
              allocations = after_alloc - before_alloc
            end

            puts format(
              '[LVN BENCH] END   %s normalize=%9.3f ms alloc=%d status=%s',
              label,
              elapsed_ms,
              allocations,
              normalize_error ? 'failed' : 'success'
            )
          ensure
            puts "[LVN BENCH] ROLLBACK START #{label}"
            aborted = model.abort_operation
            raise 'SketchUp abort_operation returned false' if aborted == false
            puts "[LVN BENCH] ROLLBACK END   #{label}"
          end

          puts "[LVN BENCH] SOURCE CHECK START #{label}"
          assert_source_restored!(model, pid, expected_signature, entity)
          puts "[LVN BENCH] SOURCE CHECK PASS  #{label}"

          raise normalize_error if normalize_error

          {
            result: result,
            elapsed_ms: elapsed_ms,
            allocations: allocations
          }
        end

        def trace_probe(model, pid, fallback, source_signature)
          puts '[LVN BENCH] TracePoint probe explicitly enabled; this probe may be much slower.'
          counts = Hash.new(0)
          tracer = TracePoint.new(:call, :c_call) do |tp|
            method_id = tp.method_id
            counts[method_id] += 1 if TRACE_METHODS.include?(method_id)
          end

          entity = resolve_entity(model, pid, fallback)
          measurement = measure_with_rollback(
            model,
            entity,
            pid,
            source_signature,
            label: 'LVN baseline TracePoint probe'
          ) do |current|
            tracer.enable do
              LocalVertexNormalizer.normalize(
                current,
                LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
                manage_operation: false
              )
            end
          end
          puts format('[LVN BENCH] TracePoint probe normalize time: %.3f ms', measurement[:elapsed_ms])
          counts
        ensure
          tracer&.disable
        end

        def profile_probe(model, pid, fallback, source_signature)
          puts '[LVN BENCH] Debug profile probe explicitly enabled.'
          entity = resolve_entity(model, pid, fallback)
          measurement = measure_with_rollback(
            model,
            entity,
            pid,
            source_signature,
            label: 'LVN baseline debug profile probe'
          ) do |current|
            LocalVertexNormalizer.normalize(
              current,
              LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
              report: true,
              write_report: false,
              manage_operation: false
            )
          end
          measurement[:result]
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

        # Linearithmic signature construction. Face loops are represented by
        # sorted exact edge keys, avoiding rotation-based O(n^2) canonicalization.
        def brep_signature(entity)
          entities = entity.definition.entities
          edge_signatures = entities.grep(Sketchup::Edge).map do |edge|
            canonical_edge_key_exact(edge.start.position, edge.end.position)
          end.sort

          face_signatures = entities.grep(Sketchup::Face).map do |face|
            face.loops.map do |loop|
              vertices = loop.vertices
              vertices.each_index.map do |index|
                first = vertices[index].position
                second = vertices[(index + 1) % vertices.length].position
                canonical_edge_key_exact(first, second)
              end.sort
            end.sort
          end.sort

          Digest::SHA256.hexdigest(Marshal.dump([edge_signatures, face_signatures]))
        end

        def canonical_edge_key_exact(first, second)
          point_a = exact_point_key(first)
          point_b = exact_point_key(second)
          (point_a <=> point_b) <= 0 ? [point_a, point_b] : [point_b, point_a]
        end

        def exact_point_key(point)
          [point.x.to_f, point.y.to_f, point.z.to_f]
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

        def print_entity_result(result, trace:, profile:)
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

          if trace
            puts 'trace counts:'
            printed = false
            TRACE_METHODS.each do |method_id|
              count = result[:trace_counts][method_id]
              next if count.nil? || count.zero?

              puts format('  %-45s %8d', method_id, count)
              printed = true
            end
            puts '  (no traced calls)' unless printed
          else
            puts 'trace counts     : skipped'
          end

          debug_profile = result[:profile]
          if profile && debug_profile
            puts format(
              'profile probe   : total=%9.3f ms status=%s',
              debug_profile[:total_seconds].to_f * 1000.0,
              debug_profile[:status]
            )
            puts 'top inclusive stages:'
            top_profile_stages(debug_profile).each do |name, metrics|
              puts format(
                '  %-45s %9.3f ms  calls=%4d  max=%9.3f',
                name,
                metrics[:total_seconds].to_f * 1000.0,
                metrics[:calls].to_i,
                metrics[:max_seconds].to_f * 1000.0
              )
            end
            snapshot_reuse = debug_profile[:snapshot_reuse]
            puts format('snapshot reuse  : %s', snapshot_reuse.inspect) if snapshot_reuse
          else
            puts 'profile probe   : skipped'
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
