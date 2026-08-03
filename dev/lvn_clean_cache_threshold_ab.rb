# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnCleanCacheThresholdAB
        module_function

        CONST_NAME = :TRIANGLE_INTERSECTION_CLEAN_CACHE_MIN_TRIANGLES
        THRESHOLDS = [64, 8].freeze
        ROUNDS = 5

        def run
          model = Sketchup.active_model
          entity = model.selection.to_a.find { |e| e.respond_to?(:definition) && e.valid? }
          raise 'Select a solid first' unless entity

          bench = LvnOptimizationBaselineBenchmark
          cache = LocalVertexNormalizerTriangleIntersectionCleanCacheV2
          original = cache.const_get(CONST_NAME, false)
          pid = bench.persistent_id(entity)
          source_signature = bench.brep_signature(entity)
          samples = THRESHOLDS.to_h { |value| [value, []] }
          output_signature = nil

          puts '=' * 72
          puts ' LVN Clean Cache Threshold A/B'
          puts '=' * 72
          puts "solid      : #{bench.entity_label(entity)}"
          puts "thresholds : #{THRESHOLDS.join(', ')}"
          puts "rounds     : #{ROUNDS} rotated samples"

          ROUNDS.times do |round|
            THRESHOLDS.rotate(round % THRESHOLDS.length).each do |threshold|
              set_threshold(cache, threshold)
              current = bench.resolve_entity(model, pid, entity)
              label = "threshold=#{threshold} sample=#{samples[threshold].length + 1}/#{ROUNDS}"
              puts "[LVN CACHE A/B] START #{label}"
              started_op = model.start_operation("LVN cache A/B #{label}", true)
              raise 'start_operation failed' if started_op == false

              begin
                GC.start
                before_alloc = GC.stat(:total_allocated_objects)
                started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                result = LocalVertexNormalizer.normalize(
                  current,
                  LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
                  manage_operation: false
                )
                elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
                allocations = GC.stat(:total_allocated_objects) - before_alloc
                signature = bench.brep_signature(current)
                output_signature ||= signature
                raise "Output mismatch at threshold=#{threshold}" unless signature == output_signature
                strategy = bench.normalization_strategy(result)
              ensure
                aborted = model.abort_operation
                raise 'abort_operation failed' if aborted == false
              end

              bench.assert_source_restored!(model, pid, source_signature, entity)
              samples[threshold] << [elapsed, allocations]
              puts format(
                '[LVN CACHE A/B] END   %s time=%9.3f ms alloc=%d strategy=%s exact=true',
                label, elapsed, allocations, strategy
              )
            end
          end

          stats = samples.transform_values do |entries|
            times = entries.map(&:first).sort
            allocs = entries.map(&:last).sort
            [times[times.length / 2], times.first, times.last, allocs[allocs.length / 2]]
          end
          puts '-' * 72
          THRESHOLDS.each do |threshold|
            median, min, max, alloc = stats.fetch(threshold)
            puts format('threshold=%-3d median=%9.3f min=%9.3f max=%9.3f alloc=%d', threshold, median, min, max, alloc)
          end
          base = stats.fetch(THRESHOLDS.first)
          candidate = stats.fetch(THRESHOLDS.last)
          saved = base[0] - candidate[0]
          percent = saved / base[0] * 100.0
          puts format('saved      : %9.3f ms (%7.2f%%)', saved, percent)
          puts format('alloc saved: %d', base[3] - candidate[3])
          puts 'outputs identical: true'
          puts 'source restored  : true'
          true
        ensure
          set_threshold(cache, original) if defined?(cache) && cache && defined?(original) && original
          puts "[LVN CACHE A/B] production threshold restored=#{original}" if defined?(original) && original
        end

        def set_threshold(cache, value)
          cache.send(:remove_const, CONST_NAME) if cache.const_defined?(CONST_NAME, false)
          cache.const_set(CONST_NAME, value)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::LvnCleanCacheThresholdAB.run
