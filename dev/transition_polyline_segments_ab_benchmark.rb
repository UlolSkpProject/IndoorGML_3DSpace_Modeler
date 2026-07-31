# frozen_string_literal: true

# Run from the SketchUp Ruby Console after the extension is loaded:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'transition_polyline_segments_ab_benchmark.rb')

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module TransitionPolylineSegmentsAbBenchmark
        ROUNDS = 31

        module_function

        def run
          indoor_model = IndoorModel.current
          overlay = DualGraphSpaceOverlay.new(indoor_model)
          builder = overlay.instance_variable_get(:@transition_curve_builder)

          # Populate the real Hermite curve cache from the current model.
          builder.clear_cache
          builder.transition_line_points
          curve_cache = builder.instance_variable_get(:@transition_curve_cache) || {}
          point_groups = curve_cache.values.flat_map do |groups|
            [groups[:default], groups[:first], groups[:second]]
          end

          expected_refs = point_groups.sum do |points|
            length = Array(points).length
            length < 2 ? 0 : (length - 1) * 2
          end

          old_result = old_segments_for_groups(point_groups)
          new_result = manual_segments_for_groups(point_groups)
          unless old_result == new_result && old_result.length == expected_refs
            raise "Polyline implementation mismatch: old=#{old_result.length} new=#{new_result.length} expected=#{expected_refs}"
          end

          # Alternate execution order to reduce one-sided runtime drift.
          old_samples = []
          new_samples = []
          old_allocations = []
          new_allocations = []

          ROUNDS.times do |index|
            if index.even?
              stat = measure_once { old_segments_for_groups(point_groups) }
              old_samples << stat[:ms]
              old_allocations << stat[:alloc]

              stat = measure_once { manual_segments_for_groups(point_groups) }
              new_samples << stat[:ms]
              new_allocations << stat[:alloc]
            else
              stat = measure_once { manual_segments_for_groups(point_groups) }
              new_samples << stat[:ms]
              new_allocations << stat[:alloc]

              stat = measure_once { old_segments_for_groups(point_groups) }
              old_samples << stat[:ms]
              old_allocations << stat[:alloc]
            end
          end

          old_stat = summarize(old_samples, old_allocations)
          new_stat = summarize(new_samples, new_allocations)
          saved_ms = old_stat[:median_ms] - new_stat[:median_ms]
          saved_pct = old_stat[:median_ms].positive? ? (saved_ms / old_stat[:median_ms]) * 100.0 : 0.0

          puts '=' * 64
          puts ' IndoorGML Transition Polyline Segments A/B Benchmark'
          puts '=' * 64
          puts format('transitions       : %d', Array(indoor_model.transitions).length)
          puts format('curve cache       : %d', curve_cache.length)
          puts format('point groups      : %d', point_groups.length)
          puts format('segment point refs: %d', expected_refs)
          puts format('rounds            : %d paired samples', ROUNDS)
          puts format('ruby              : %s', RUBY_VERSION)
          puts '--- timing / allocation ----------------------------------------'
          print_stat('each_cons + flat_map', old_stat)
          print_stat('manual append', new_stat)
          puts '--- paired implementation delta -------------------------------'
          puts format('median saved by manual : %9.3f ms (%6.2f%%)', saved_ms, saved_pct)
          puts format('median alloc saved      : %9d', old_stat[:alloc] - new_stat[:alloc])
          puts '--- correctness -----------------------------------------------'
          puts format('outputs identical       : %s', (old_result == new_result).inspect)
          puts format('output refs              : %d', old_result.length)
          puts '=' * 64
          puts ' Benchmark complete'
          puts '=' * 64
          true
        rescue StandardError => e
          warn "[benchmark] #{e.class}: #{e.message}"
          warn Array(e.backtrace).first(8).join("\n")
          false
        end

        def old_segments_for_groups(point_groups)
          output = []
          point_groups.each do |points|
            output.concat(Array(points).each_cons(2).flat_map { |from, to| [from, to] })
          end
          output
        end

        def manual_segments_for_groups(point_groups)
          output = []
          point_groups.each do |points|
            source = Array(points)
            index = 0
            last_index = source.length - 1
            while index < last_index
              output << source[index]
              output << source[index + 1]
              index += 1
            end
          end
          output
        end

        def measure_once
          GC.start
          before_alloc = GC.stat(:total_allocated_objects)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          yield
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          after_alloc = GC.stat(:total_allocated_objects)
          { ms: elapsed * 1000.0, alloc: after_alloc - before_alloc }
        end

        def summarize(samples, allocations)
          sorted = samples.sort
          sorted_allocations = allocations.sort
          {
            median_ms: sorted[sorted.length / 2],
            min_ms: sorted.first,
            max_ms: sorted.last,
            alloc: sorted_allocations[sorted_allocations.length / 2]
          }
        end

        def print_stat(label, stat)
          puts format(
            '%-22s median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
            label,
            stat[:median_ms],
            stat[:min_ms],
            stat[:max_ms],
            stat[:alloc]
          )
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::TransitionPolylineSegmentsAbBenchmark.run
