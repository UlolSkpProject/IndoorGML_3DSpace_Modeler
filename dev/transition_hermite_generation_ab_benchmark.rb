# frozen_string_literal: true

# Run from the SketchUp Ruby Console after the extension is loaded:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'transition_hermite_generation_ab_benchmark.rb')

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module TransitionHermiteGenerationABBenchmark
        ROUNDS = 15

        module_function

        def run
          spline = Utils::Math::HermiteSpline
          current = spline.method(:generate_segment)
          captured_calls = capture_live_calls(spline, current)
          raise 'No Hermite generate_segment calls captured' if captured_calls.empty?

          correctness = compare_outputs(current, captured_calls)
          samples = { optimized: [], legacy: [] }
          allocations = { optimized: [], legacy: [] }

          ROUNDS.times do |index|
            order = index.even? ? [:optimized, :legacy] : [:legacy, :optimized]
            order.each do |mode|
              elapsed_ms, alloc = measure_once do
                replay(mode, current, captured_calls)
              end
              samples[mode] << elapsed_ms
              allocations[mode] << alloc
            end
          end

          print_report(captured_calls, correctness, samples, allocations)
          true
        rescue StandardError => e
          warn "[benchmark] #{e.class}: #{e.message}"
          warn Array(e.backtrace).first(8).join("\n")
          false
        end

        def capture_live_calls(spline, current)
          indoor_model = IndoorModel.current
          overlay = DualGraphSpaceOverlay.new(indoor_model)
          builder = overlay.instance_variable_get(:@transition_curve_builder)
          captured = []

          spline.define_singleton_method(:generate_segment) do |*args, **kwargs|
            captured << [args, kwargs]
            kwargs.empty? ? current.call(*args) : current.call(*args, **kwargs)
          end

          builder.clear_cache
          builder.transition_line_points
          captured
        ensure
          spline.define_singleton_method(:generate_segment, current) if spline && current
        end

        def compare_outputs(current, captured_calls)
          point_count = 0
          captured_calls.each_with_index do |(args, kwargs), call_index|
            optimized = kwargs.empty? ? current.call(*args) : current.call(*args, **kwargs)
            legacy = legacy_generate_segment(*args, **kwargs)
            return { identical: false, call_index: call_index, point_count: point_count } unless optimized.length == legacy.length

            optimized.each_with_index do |point, point_index|
              expected = legacy[point_index]
              unless point.x == expected.x && point.y == expected.y && point.z == expected.z
                return {
                  identical: false,
                  call_index: call_index,
                  point_index: point_index,
                  point_count: point_count
                }
              end
              point_count += 1
            end
          end
          { identical: true, point_count: point_count }
        end

        def replay(mode, current, captured_calls)
          captured_calls.each do |args, kwargs|
            if mode == :optimized
              kwargs.empty? ? current.call(*args) : current.call(*args, **kwargs)
            else
              legacy_generate_segment(*args, **kwargs)
            end
          end
        end

        def legacy_generate_segment(p0, p1, tangent0, tangent1, segments = 8, include_start: true, refine: true)
          spline = Utils::Math::HermiteSpline
          base_ts = (0..segments).map { |i| i.to_f / segments }
          unless refine
            start_index = include_start ? 0 : 1
            return base_ts[start_index..-1].map { |t| spline.point(p0, p1, tangent0, tangent1, t) }
          end

          points = base_ts.map { |t| spline.point(p0, p1, tangent0, tangent1, t) }
          refined_ts = [base_ts.first]
          base_ts.each_cons(2).with_index do |(t_a, t_b), index|
            bend = index.zero? ? 0.0 : spline.bend_factor(points[index - 1], points[index], points[index + 1])
            extra = (bend * 3).round.clamp(0, 4)
            extra.times do |extra_index|
              refined_ts << t_a + ((t_b - t_a) * (extra_index + 1).to_f / (extra + 1))
            end
            refined_ts << t_b
          end

          start_index = include_start ? 0 : 1
          refined_ts.uniq.sort[start_index..-1].map do |t|
            spline.point(p0, p1, tangent0, tangent1, t)
          end
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

        def stats(values)
          sorted = values.sort
          {
            median: sorted[sorted.length / 2],
            min: sorted.first,
            max: sorted.last
          }
        end

        def print_report(captured_calls, correctness, samples, allocations)
          optimized = stats(samples[:optimized])
          legacy = stats(samples[:legacy])
          optimized_alloc = stats(allocations[:optimized])
          legacy_alloc = stats(allocations[:legacy])
          saved_ms = legacy[:median] - optimized[:median]
          saved_percent = legacy[:median].positive? ? (saved_ms / legacy[:median]) * 100.0 : 0.0
          saved_alloc = legacy_alloc[:median] - optimized_alloc[:median]

          puts '=' * 68
          puts ' IndoorGML Transition Hermite Generation A/B Benchmark'
          puts '=' * 68
          puts format('captured calls : %d', captured_calls.length)
          puts format('output points  : %d', correctness[:point_count])
          puts format('rounds         : %d paired samples', ROUNDS)
          puts format('ruby           : %s', RUBY_VERSION)
          puts '--- timing / allocation --------------------------------------------'
          puts format(
            '%-18s median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
            'optimized', optimized[:median], optimized[:min], optimized[:max], optimized_alloc[:median]
          )
          puts format(
            '%-18s median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
            'legacy', legacy[:median], legacy[:min], legacy[:max], legacy_alloc[:median]
          )
          puts '--- delta ----------------------------------------------------------'
          puts format('median saved          : %9.3f ms (%6.2f%%)', saved_ms, saved_percent)
          puts format('median allocation saved: %8d', saved_alloc)
          puts '--- correctness ----------------------------------------------------'
          puts format('outputs identical     : %s', correctness[:identical])
          unless correctness[:identical]
            puts format('first mismatch call   : %s', correctness[:call_index].inspect)
            puts format('first mismatch point  : %s', correctness[:point_index].inspect)
          end
          puts '=' * 68
          puts ' Benchmark complete'
          puts '=' * 68
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::TransitionHermiteGenerationABBenchmark.run
