# frozen_string_literal: true

# Run from the SketchUp Ruby Console after the extension is loaded:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'transition_hard_rebuild_snapshot_ab_benchmark.rb')

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module TransitionHardRebuildSnapshotABBenchmark
        ROUNDS = 15
        TRACE_METHODS = [
          :overlay_render_context_snapshot,
          :overlay_render_context_cache_key,
          :overlay_render_point,
          :overlay_render_point_from_snapshot,
          :overlay_render_vector,
          :overlay_render_vector_from_snapshot,
          :root_transformation_in_model,
          :root_local_point_to_model,
          :root_local_vector_to_model,
          :transition_curve_input,
          :transition_curve_segments,
          :cached_transition_curve_point_groups,
          :hermite_transition_curve_point_groups,
          :generate_segment,
          :polyline_segments
        ].freeze

        module_function

        def run
          indoor_model = IndoorModel.current
          snapshot_overlay = DualGraphSpaceOverlay.new(indoor_model)
          legacy_overlay = DualGraphSpaceOverlay.new(indoor_model)

          # Force only the legacy comparison instance to skip the new per-rebuild
          # render snapshot. All other builder/cache/curve code remains identical.
          legacy_overlay.define_singleton_method(:overlay_render_context_snapshot) { nil }

          snapshot_builder = snapshot_overlay.instance_variable_get(:@transition_curve_builder)
          legacy_builder = legacy_overlay.instance_variable_get(:@transition_curve_builder)

          # Prime method dispatch and SketchUp-side objects, then hard-clear so every
          # timed sample performs a full cold transition rebuild.
          snapshot_builder.transition_line_points
          legacy_builder.transition_line_points
          snapshot_builder.clear_cache
          legacy_builder.clear_cache

          samples = { snapshot: [], legacy: [] }
          allocations = { snapshot: [], legacy: [] }

          ROUNDS.times do |index|
            order = index.even? ? [:snapshot, :legacy] : [:legacy, :snapshot]
            order.each do |mode|
              builder = mode == :snapshot ? snapshot_builder : legacy_builder
              elapsed_ms, alloc = measure_once do
                builder.clear_cache
                builder.transition_line_points
              end
              samples[mode] << elapsed_ms
              allocations[mode] << alloc
            end
          end

          snapshot_trace = trace_calls do
            snapshot_builder.clear_cache
            snapshot_builder.transition_line_points
          end
          legacy_trace = trace_calls do
            legacy_builder.clear_cache
            legacy_builder.transition_line_points
          end

          print_report(indoor_model, samples, allocations, snapshot_trace, legacy_trace)
          true
        rescue StandardError => e
          warn "[benchmark] #{e.class}: #{e.message}"
          warn Array(e.backtrace).first(8).join("\n")
          false
        end

        def measure_once
          GC.start
          before_alloc = GC.stat(:total_allocated_objects)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          yield
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          after_alloc = GC.stat(:total_allocated_objects)
          [elapsed * 1000.0, after_alloc - before_alloc]
        end

        def trace_calls
          counts = Hash.new(0)
          tracer = TracePoint.new(:call, :c_call) do |tp|
            method_id = tp.method_id
            counts[method_id] += 1 if TRACE_METHODS.include?(method_id)
          end
          tracer.enable { yield }
          counts
        end

        def stats(values)
          sorted = values.sort
          {
            median: sorted[sorted.length / 2],
            min: sorted.first,
            max: sorted.last
          }
        end

        def print_report(indoor_model, samples, allocations, snapshot_trace, legacy_trace)
          snapshot = stats(samples[:snapshot])
          legacy = stats(samples[:legacy])
          snapshot_alloc = stats(allocations[:snapshot])
          legacy_alloc = stats(allocations[:legacy])

          puts '=' * 64
          puts ' IndoorGML Transition Hard Rebuild Snapshot A/B Benchmark'
          puts '=' * 64
          puts format('transitions : %d', Array(indoor_model.transitions).length)
          puts format('rounds      : %d paired samples', ROUNDS)
          puts format('ruby        : %s', RUBY_VERSION)
          puts '--- timing / allocation ----------------------------------------'
          puts format(
            '%-18s median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
            'snapshot ON', snapshot[:median], snapshot[:min], snapshot[:max], snapshot_alloc[:median]
          )
          puts format(
            '%-18s median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
            'snapshot OFF', legacy[:median], legacy[:min], legacy[:max], legacy_alloc[:median]
          )

          delta = legacy[:median] - snapshot[:median]
          percent = legacy[:median].positive? ? (delta / legacy[:median]) * 100.0 : 0.0
          puts '--- paired implementation delta -------------------------------'
          puts format('median saved by snapshot : %9.3f ms (%6.2f%%)', delta, percent)

          puts '--- call-count diagnostics ------------------------------------'
          print_trace('snapshot ON', snapshot_trace)
          print_trace('snapshot OFF', legacy_trace)
          puts '=' * 64
          puts ' Benchmark complete'
          puts '=' * 64
        end

        def print_trace(label, counts)
          puts "[#{label}]"
          printed = false
          TRACE_METHODS.each do |method_id|
            count = counts[method_id]
            next if count.nil? || count.zero?

            puts format('  %-45s %8d', method_id, count)
            printed = true
          end
          puts '  (no traced calls)' unless printed
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::TransitionHardRebuildSnapshotABBenchmark.run
