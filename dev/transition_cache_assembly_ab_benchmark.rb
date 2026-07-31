# frozen_string_literal: true

# Compares the remaining Transition hard-path optimization candidates without
# modifying production behavior:
#
#   baseline       : current production implementation
#   no_curve_cache : skips the secondary Hermite point-group cache
#   flat_assembly  : stores one flat GL_LINES array per Transition instead of
#                    three temporary segment arrays + a segment-group Hash
#   combined       : no_curve_cache + flat_assembly
#
# Run from the SketchUp Ruby Console after the extension is loaded:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'transition_cache_assembly_ab_benchmark.rb')

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module TransitionCacheAssemblyABBenchmark
        ROUNDS = 9
        MODES = %i[baseline no_curve_cache flat_assembly combined].freeze

        module_function

        def run
          indoor_model = IndoorModel.current
          builders = MODES.to_h do |mode|
            overlay = DualGraphSpaceOverlay.new(indoor_model)
            builder = overlay.instance_variable_get(:@transition_curve_builder)
            configure_candidate(builder, mode)
            [mode, builder]
          end

          outputs = {}
          cache_stats = {}
          builders.each do |mode, builder|
            builder.clear_cache
            outputs[mode] = builder.transition_line_points.dup
            cache_stats[mode] = cache_sizes(builder)
          end

          correctness = compare_outputs(outputs)
          hard_samples = init_samples
          hard_allocations = init_samples
          soft_samples = init_samples
          soft_allocations = init_samples

          ROUNDS.times do |round|
            MODES.rotate(round % MODES.length).each do |mode|
              builder = builders.fetch(mode)

              elapsed_ms, alloc = measure_once do
                builder.clear_cache
                builder.transition_line_points
              end
              hard_samples[mode] << elapsed_ms
              hard_allocations[mode] << alloc

              elapsed_ms, alloc = measure_once do
                builder.invalidate
                builder.transition_line_points
              end
              soft_samples[mode] << elapsed_ms
              soft_allocations[mode] << alloc
            end
          end

          print_report(
            indoor_model,
            correctness,
            cache_stats,
            hard_samples,
            hard_allocations,
            soft_samples,
            soft_allocations
          )
          true
        rescue StandardError => e
          warn "[benchmark] #{e.class}: #{e.message}"
          warn Array(e.backtrace).first(10).join("\n")
          false
        end

        def configure_candidate(builder, mode)
          configure_no_curve_cache(builder) if %i[no_curve_cache combined].include?(mode)
          configure_flat_assembly(builder) if %i[flat_assembly combined].include?(mode)
        end

        def configure_no_curve_cache(builder)
          builder.define_singleton_method(:cached_transition_curve_point_groups) do |_transition, curve_input|
            control_points = curve_input[:points]
            return { default: control_points, first: [], second: [] } if control_points.length < 3

            if curve_input[:normal1] && curve_input[:normal2]
              hermite_transition_curve_point_groups(
                control_points,
                curve_input[:normal1],
                curve_input[:normal2]
              )
            else
              { default: control_points, first: [], second: [] }
            end
          end
        end

        def configure_flat_assembly(builder)
          builder.define_singleton_method(:flat_transition_curve_segments) do |transition, render_snapshot = nil|
            control_points = []
            curve_input = transition_curve_input(transition, render_snapshot)
            control_points = curve_input[:points]
            return [] if control_points.length < 2

            groups = cached_transition_curve_point_groups(transition, curve_input)
            segments = []
            append_group = lambda do |group|
              index = 0
              last_index = group.length - 1
              while index < last_index
                segments << group[index] << group[index + 1]
                index += 1
              end
            end
            append_group.call(groups[:default])
            append_group.call(groups[:first])
            append_group.call(groups[:second])
            segments
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Transition curve build failed: #{e.class}: #{e.message}"
            segments = []
            index = 0
            fallback = control_points || []
            last_index = fallback.length - 1
            while index < last_index
              segments << fallback[index] << fallback[index + 1]
              index += 1
            end
            segments
          end

          builder.define_singleton_method(:cached_transition_render_segments) do |transition, render_context_key, render_snapshot|
            fingerprint = transition_render_fingerprint(transition, render_context_key)
            cache_key = transition_render_cache_identity(transition)
            if fingerprint
              cached = @transition_render_segment_cache[cache_key]
              return cached[:segments] if cached && cached[:fingerprint] == fingerprint
            end

            segments = flat_transition_curve_segments(transition, render_snapshot)
            if fingerprint
              @transition_render_segment_cache.clear if @transition_render_segment_cache.length > transition_curve_cache_limit
              @transition_render_segment_cache[cache_key] = {
                fingerprint: fingerprint,
                segments: segments
              }
            end
            segments
          end

          builder.define_singleton_method(:build_render_transition_line_points) do
            points = []
            render_snapshot = transition_render_context_snapshot
            render_context_key = render_snapshot&.[](:cache_key) || transition_render_context_cache_key
            @indoor_model.transitions.each do |transition|
              next unless overlay_transition_visible?(transition)

              points.concat(
                cached_transition_render_segments(transition, render_context_key, render_snapshot)
              )
            end
            points
          end
        end

        def compare_outputs(outputs)
          baseline = outputs.fetch(:baseline)
          result = {}
          MODES.each do |mode|
            candidate = outputs.fetch(mode)
            mismatch = nil
            if baseline.length != candidate.length
              mismatch = { reason: :length, expected: baseline.length, actual: candidate.length }
            else
              baseline.each_index do |index|
                expected = baseline[index]
                actual = candidate[index]
                next if same_point?(expected, actual)

                mismatch = { reason: :point, index: index }
                break
              end
            end
            result[mode] = {
              identical: mismatch.nil?,
              mismatch: mismatch,
              points: candidate.length
            }
          end
          result
        end

        def same_point?(first, second)
          return first == second unless first.respond_to?(:x) && second.respond_to?(:x)

          first.x == second.x && first.y == second.y && first.z == second.z
        end

        def cache_sizes(builder)
          {
            render_segments: (builder.instance_variable_get(:@transition_render_segment_cache) || {}).length,
            curve_groups: (builder.instance_variable_get(:@transition_curve_cache) || {}).length
          }
        end

        def init_samples
          MODES.to_h { |mode| [mode, []] }
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

        def print_report(indoor_model, correctness, cache_stats, hard_samples, hard_allocations, soft_samples, soft_allocations)
          puts '=' * 76
          puts ' IndoorGML Transition Cache / GL Assembly A/B Benchmark'
          puts '=' * 76
          puts format('states      : %d', Array(indoor_model.states).length)
          puts format('transitions : %d', Array(indoor_model.transitions).length)
          puts format('rounds      : %d rotated samples / mode', ROUNDS)
          puts format('ruby        : %s', RUBY_VERSION)
          puts '--- hard clear + rebuild ----------------------------------------------'
          print_mode_stats(hard_samples, hard_allocations)
          puts '--- soft invalidate + rebuild -----------------------------------------'
          print_mode_stats(soft_samples, soft_allocations)
          puts '--- hard delta vs baseline --------------------------------------------'
          baseline = stats(hard_samples[:baseline])[:median]
          baseline_alloc = stats(hard_allocations[:baseline])[:median]
          MODES.drop(1).each do |mode|
            current = stats(hard_samples[mode])[:median]
            current_alloc = stats(hard_allocations[mode])[:median]
            saved = baseline - current
            percent = baseline.positive? ? (saved / baseline) * 100.0 : 0.0
            puts format(
              '%-16s saved=%9.3f ms (%7.2f%%)  alloc saved=%8d',
              mode,
              saved,
              percent,
              baseline_alloc - current_alloc
            )
          end
          puts '--- correctness / cache shape ----------------------------------------'
          MODES.each do |mode|
            check = correctness.fetch(mode)
            caches = cache_stats.fetch(mode)
            puts format(
              '%-16s identical=%-5s points=%7d  render-cache=%5d  curve-cache=%5d',
              mode,
              check[:identical],
              check[:points],
              caches[:render_segments],
              caches[:curve_groups]
            )
            puts "  mismatch: #{check[:mismatch].inspect}" unless check[:identical]
          end
          puts '=' * 76
          puts ' Benchmark complete'
          puts '=' * 76
        end

        def print_mode_stats(samples, allocations)
          MODES.each do |mode|
            stat = stats(samples.fetch(mode))
            alloc = stats(allocations.fetch(mode))
            puts format(
              '%-16s median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
              mode,
              stat[:median],
              stat[:min],
              stat[:max],
              alloc[:median]
            )
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::TransitionCacheAssemblyABBenchmark.run
