# frozen_string_literal: true

# Run from the SketchUp Ruby Console after the extension is loaded:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'dual_overlay_optimization_benchmark.rb')

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module DualOverlayOptimizationBenchmark
        ROUNDS = 7

        TRACE_METHODS = [
          :overlay_state_point,
          :overlay_state_root_local_point,
          :overlay_render_point,
          :overlay_render_vector,
          :dual_overlay_state_visible?,
          :dual_overlay_transition_visible?,
          :entity_origin_in_root_local,
          :entity_transformation_in_root,
          :entity_world_transformation_under_root,
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
          overlay = DualGraphSpaceOverlay.new(indoor_model)
          state_renderer = overlay.instance_variable_get(:@state_renderer)
          transition_builder = overlay.instance_variable_get(:@transition_curve_builder)
          scale = DualOverlayPreferences.state_radius_scale

          unless indoor_model.respond_to?(:dual_overlay_visible?) && indoor_model.dual_overlay_visible?
            puts '[benchmark] Warning: dual overlay is currently hidden; getExtents may be empty.'
          end

          # Warm all caches before timing.
          state_renderer.send(:rebuild_state_points)
          state_renderer.overlay_state_extent_points(state_radius_scale: scale)
          transition_builder.transition_line_points

          results = {}
          results['getExtents warm cache hit'] = measure { overlay.getExtents }
          results['getExtents bounds rebuild'] = measure do
            state_renderer.send(:clear_extent_cache)
            overlay.getExtents
          end
          results['State full rebuild'] = measure do
            state_renderer.clear_cache
            state_renderer.send(:rebuild_state_points)
          end
          results['Transition render cache hit'] = measure do
            transition_builder.transition_line_points
          end
          results['Transition soft invalidate + rebuild'] = measure do
            transition_builder.invalidate
            transition_builder.transition_line_points
          end
          results['Transition hard clear + rebuild'] = measure do
            transition_builder.clear_cache
            transition_builder.transition_line_points
          end
          results['Full overlay soft invalidate + rebuild'] = measure do
            overlay.invalidate_transition_points
            transition_builder.transition_line_points
            state_renderer.send(:rebuild_state_points)
          end

          # Re-prime before diagnostics so each probe starts from the intended state.
          state_renderer.clear_cache
          state_renderer.send(:rebuild_state_points)
          state_renderer.overlay_state_extent_points(state_radius_scale: scale)
          transition_builder.clear_cache
          transition_builder.transition_line_points

          diagnostics = {}
          diagnostics['getExtents warm cache hit'] = trace_calls { overlay.getExtents }
          diagnostics['getExtents bounds rebuild'] = trace_calls do
            state_renderer.send(:clear_extent_cache)
            overlay.getExtents
          end
          diagnostics['State full rebuild'] = trace_calls do
            state_renderer.clear_cache
            state_renderer.send(:rebuild_state_points)
          end

          # Ensure per-transition render/curve caches exist for the soft probe.
          transition_builder.clear_cache
          transition_builder.transition_line_points
          diagnostics['Transition soft invalidate + rebuild'] = trace_calls do
            transition_builder.invalidate
            transition_builder.transition_line_points
          end
          diagnostics['Transition hard clear + rebuild'] = trace_calls do
            transition_builder.clear_cache
            transition_builder.transition_line_points
          end

          # Leave caches warm and extents present for final metrics.
          state_renderer.clear_cache
          state_renderer.send(:rebuild_state_points)
          state_renderer.overlay_state_extent_points(state_radius_scale: scale)
          transition_builder.transition_line_points

          print_report(indoor_model, state_renderer, transition_builder, results, diagnostics)
          true
        rescue StandardError => e
          warn "[benchmark] #{e.class}: #{e.message}"
          warn Array(e.backtrace).first(8).join("\n")
          false
        end

        def measure(rounds = ROUNDS)
          samples = []
          allocations = []

          rounds.times do
            GC.start
            before_alloc = GC.stat(:total_allocated_objects)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            yield
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            after_alloc = GC.stat(:total_allocated_objects)

            samples << (elapsed * 1000.0)
            allocations << (after_alloc - before_alloc)
          end

          sorted = samples.sort
          {
            median_ms: sorted[sorted.length / 2],
            min_ms: sorted.first,
            max_ms: sorted.last,
            alloc: allocations.sort[allocations.length / 2]
          }
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

        def print_report(indoor_model, state_renderer, transition_builder, results, diagnostics)
          states = Array(indoor_model.states)
          transitions = Array(indoor_model.transitions)
          cell_spaces = Array(indoor_model.cell_spaces)
          editing = indoor_model.respond_to?(:editing?) ? indoor_model.editing? : nil

          puts '=' * 60
          puts ' IndoorGML Dual Overlay Optimization Benchmark'
          puts '=' * 60
          puts format('states      : %d', states.length)
          puts format('transitions : %d', transitions.length)
          puts format('cell_spaces : %d', cell_spaces.length)
          puts format('editing     : %s', editing.inspect)
          puts format('rounds      : %d', ROUNDS)
          puts format('ruby        : %s', RUBY_VERSION)
          puts '--- timing / allocation ------------------------------------'

          results.each do |label, stat|
            puts format(
              '%-40s median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
              label,
              stat[:median_ms],
              stat[:min_ms],
              stat[:max_ms],
              stat[:alloc]
            )
          end

          puts '--- call-count diagnostics --------------------------------'
          diagnostics.each do |label, counts|
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

          state_points = Array(state_renderer.instance_variable_get(:@render_state_points))
          transition_points = Array(transition_builder.instance_variable_get(:@render_transition_line_points))
          curve_cache = transition_builder.instance_variable_get(:@transition_curve_cache) || {}
          extent_points = Array(state_renderer.instance_variable_get(:@render_state_extent_points))

          puts '--- cache / render data ------------------------------------'
          puts format('state render points:                %8d', state_points.length)
          puts format('transition GL line points:          %8d', transition_points.length)
          puts format('transition GL segments:             %8d', transition_points.length / 2)
          puts format('transition curve cache entries:     %8d', curve_cache.length)
          puts format('state extent cache:                 %8s', extent_points.empty? ? 'nil' : 'present')

          puts '--- derived metrics ----------------------------------------'
          segment_ratio = transitions.empty? ? 0.0 : (transition_points.length / 2.0) / transitions.length
          coverage = transitions.empty? ? 0.0 : (curve_cache.length.to_f / transitions.length) * 100.0
          puts format('GL segments / transition : %.3f', segment_ratio)
          puts format('curve-cache coverage      : %.2f%%', coverage)
          puts format('states                    : %d', states.length)
          puts '=' * 60
          puts ' Benchmark complete'
          puts '=' * 60
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::DualOverlayOptimizationBenchmark.run
