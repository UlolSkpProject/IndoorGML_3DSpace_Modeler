# frozen_string_literal: true

# Representative-corpus A/B for the per-normalize clean intersection cache.
# Requires dev/lvn_optimization_baseline_benchmark.rb to be loaded first.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnCleanCacheThresholdCorpusAB
        module_function

        CONST_NAME = :TRIANGLE_INTERSECTION_CLEAN_CACHE_MIN_TRIANGLES
        THRESHOLDS = [64, 8].freeze
        DEFAULT_SAMPLE_COUNT = 12

        def run(sample_count: DEFAULT_SAMPLE_COUNT)
          model = Sketchup.active_model
          bench = LvnOptimizationBaselineBenchmark
          selected = model.selection.to_a.select do |entity|
            entity.respond_to?(:definition) && entity.respond_to?(:valid?) && entity.valid?
          end
          raise 'Select one or more solids first' if selected.empty?

          corpus = representative_corpus(selected, sample_count)
          cache = LocalVertexNormalizerTriangleIntersectionCleanCacheV2
          original = cache.const_get(CONST_NAME, false)
          totals = THRESHOLDS.to_h do |threshold|
            [threshold, { milliseconds: 0.0, allocations: 0, wins: 0 }]
          end
          results = []

          puts '=' * 88
          puts ' LVN Clean Cache Threshold Representative Corpus A/B'
          puts '=' * 88
          puts format('selected solids : %d', selected.length)
          puts format('sampled solids  : %d', corpus.length)
          puts format('thresholds      : %s', THRESHOLDS.join(', '))
          puts 'sampling        : deterministic face-count quantiles'

          corpus.each_with_index do |entity, corpus_index|
            pid = bench.persistent_id(entity)
            source = bench.resolve_entity(model, pid, entity)
            source_signature = bench.brep_signature(source)
            geometry = bench.geometry_summary(source)
            measurements = {}

            puts '-' * 88
            puts format(
              '[%02d/%02d] %s faces=%d edges=%d vertices=%d',
              corpus_index + 1,
              corpus.length,
              bench.entity_label(source),
              geometry[:faces],
              geometry[:edges],
              geometry[:vertices]
            )

            THRESHOLDS.rotate(corpus_index % THRESHOLDS.length).each do |threshold|
              set_threshold(cache, threshold)
              current = bench.resolve_entity(model, pid, source)
              measurement = measure_one(
                model,
                bench,
                current,
                pid,
                source_signature,
                threshold
              )
              measurements[threshold] = measurement
              totals[threshold][:milliseconds] += measurement[:milliseconds]
              totals[threshold][:allocations] += measurement[:allocations]
              puts format(
                '  threshold=%-3d time=%9.3f ms alloc=%8d outcome=%s',
                threshold,
                measurement[:milliseconds],
                measurement[:allocations],
                outcome_label(measurement[:outcome])
              )
            end

            base = measurements.fetch(THRESHOLDS.first)
            candidate = measurements.fetch(THRESHOLDS.last)
            exact = base[:outcome] == candidate[:outcome]
            raise "Threshold outcomes differ for #{bench.entity_label(source)}" unless exact

            if candidate[:milliseconds] < base[:milliseconds]
              totals[THRESHOLDS.last][:wins] += 1
            elsif base[:milliseconds] < candidate[:milliseconds]
              totals[THRESHOLDS.first][:wins] += 1
            end

            results << {
              label: bench.entity_label(source),
              geometry: geometry,
              measurements: measurements,
              exact: true
            }
            puts '  exact outcome=true source restored=true'
          end

          print_summary(results, totals)
          true
        ensure
          set_threshold(cache, original) if defined?(cache) && cache && defined?(original) && original
          if defined?(original) && original
            puts "[LVN CACHE CORPUS A/B] production threshold restored=#{original}"
          end
        end

        def representative_corpus(selected, sample_count)
          sorted = selected.sort_by do |entity|
            faces = entity.definition.entities.grep(Sketchup::Face).length
            [faces, persistent_sort_key(entity)]
          end
          count = [[sample_count.to_i, 1].max, sorted.length].min
          return sorted if count == sorted.length
          return [sorted.first] if count == 1

          indices = count.times.map do |index|
            ((index * (sorted.length - 1)).to_f / (count - 1)).round
          end.uniq
          indices.map { |index| sorted.fetch(index) }
        end

        def persistent_sort_key(entity)
          return entity.persistent_id.to_i if entity.respond_to?(:persistent_id)

          entity.object_id
        rescue StandardError
          entity.object_id
        end

        def measure_one(model, bench, entity, pid, source_signature, threshold)
          label = "LVN clean cache corpus threshold=#{threshold}"
          started_operation = model.start_operation(label, true)
          raise 'start_operation failed' if started_operation == false

          milliseconds = nil
          allocations = nil
          outcome = nil
          begin
            GC.start
            before_alloc = GC.stat(:total_allocated_objects)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            begin
              result = LocalVertexNormalizer.normalize(
                entity,
                LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
                manage_operation: false
              )
              outcome = [
                :success,
                bench.brep_signature(entity),
                bench.normalization_strategy(result)
              ]
            rescue StandardError => error
              outcome = [:error, error.class.name, error.message]
            ensure
              milliseconds =
                (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
              allocations = GC.stat(:total_allocated_objects) - before_alloc
            end
          ensure
            aborted = model.abort_operation
            raise 'abort_operation failed' if aborted == false
          end

          bench.assert_source_restored!(model, pid, source_signature, entity)
          {
            milliseconds: milliseconds,
            allocations: allocations,
            outcome: outcome
          }
        end

        def outcome_label(outcome)
          return "success/#{outcome[2]}" if outcome[0] == :success

          "error/#{outcome[1]}"
        end

        def print_summary(results, totals)
          base_threshold = THRESHOLDS.first
          candidate_threshold = THRESHOLDS.last
          base = totals.fetch(base_threshold)
          candidate = totals.fetch(candidate_threshold)
          saved = base[:milliseconds] - candidate[:milliseconds]
          percent = base[:milliseconds].positive? ? saved / base[:milliseconds] * 100.0 : 0.0

          puts '=' * 88
          puts ' Representative Corpus Summary'
          puts '=' * 88
          puts format(
            'threshold=%-3d total=%10.3f ms alloc=%10d wins=%d',
            base_threshold,
            base[:milliseconds],
            base[:allocations],
            base[:wins]
          )
          puts format(
            'threshold=%-3d total=%10.3f ms alloc=%10d wins=%d',
            candidate_threshold,
            candidate[:milliseconds],
            candidate[:allocations],
            candidate[:wins]
          )
          puts format('time saved       : %10.3f ms (%7.2f%%)', saved, percent)
          puts format('allocation saved : %10d', base[:allocations] - candidate[:allocations])
          puts format('exact outcomes   : %d/%d', results.count { |result| result[:exact] }, results.length)
          puts 'source restored   : true'
          puts 'result            : PASS'
          puts '=' * 88
        end

        def set_threshold(cache, value)
          cache.send(:remove_const, CONST_NAME) if cache.const_defined?(CONST_NAME, false)
          cache.const_set(CONST_NAME, value)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::LvnCleanCacheThresholdCorpusAB.run
