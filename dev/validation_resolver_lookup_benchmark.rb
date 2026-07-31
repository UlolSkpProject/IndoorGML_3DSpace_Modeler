# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ValidationResolverLookupBenchmark
        extend self

        ROUNDS = 101
        BATCH = 100

        def run(rounds: ROUNDS, batch: BATCH)
          indoor_model = IndoorModel.current
          cells = Array(indoor_model&.cell_spaces)
          raise 'IndoorModel.current not available' unless indoor_model
          raise 'No CellSpaces available' if cells.empty?

          resolver = IndoorGmlConverter::ValidationErrorGeometryResolver.new(
            indoor_model: indoor_model,
            model: indoor_model.respond_to?(:model) ? indoor_model.model : nil
          )

          samples = lookup_samples(cells)

          puts
          puts '============================================================'
          puts ' IndoorGML Validation Resolver Lookup Benchmark'
          puts '============================================================'
          puts "cell_spaces : #{cells.length}"
          puts "rounds      : #{rounds}"
          puts "batch       : #{batch} lookups/sample"
          puts "ruby        : #{RUBY_VERSION}"
          puts '--- timing / allocation ------------------------------------'

          results = {}
          samples.each do |label, value|
            results[label] = benchmark_case(label, rounds: rounds, batch: batch) do
              resolver.send(:cell_space_for, value)
            end
          end

          puts
          puts '--- correctness --------------------------------------------'
          samples.each do |label, value|
            result = resolver.send(:cell_space_for, value)
            expected = expected_cell(cells, value)
            puts format(
              '%-28s found=%-5s expected_match=%s',
              label,
              !result.nil?,
              result.equal?(expected)
            )
          end

          puts
          puts '--- derived ------------------------------------------------'
          if results['last exact'] && results['first exact']
            first = results['first exact'][:median_us]
            last = results['last exact'][:median_us]
            ratio = first.positive? ? last / first : 0.0
            puts format('last / first latency ratio : %.2fx', ratio)
          end
          if results['missing']
            puts format('missing lookup median       : %.3f us', results['missing'][:median_us])
          end

          puts '============================================================'
          puts ' Benchmark complete'
          puts '============================================================'
          true
        rescue StandardError => e
          puts "[ValidationResolverLookupBenchmark] ERROR: #{e.class}: #{e.message}"
          Array(e.backtrace).first(12).each { |line| puts "  #{line}" }
          false
        end

        private

        def lookup_samples(cells)
          first = cells.first
          middle = cells[cells.length / 2]
          last = cells.last

          first_id = first&.id.to_s
          middle_id = middle&.id.to_s
          last_id = last&.id.to_s

          {
            'first exact' => first_id,
            'middle exact' => middle_id,
            'last exact' => last_id,
            'last cell_ prefix' => "cell_#{normalize_cell_id(last_id)}",
            'last solid_ prefix' => "solid_#{normalize_cell_id(last_id)}",
            'missing' => '__validation_lookup_missing__'
          }
        end

        def benchmark_case(label, rounds:, batch:)
          timings = []
          allocations = []

          3.times { batch.times { yield } }

          rounds.times do
            GC.start
            before_alloc = GC.stat(:total_allocated_objects)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            batch.times { yield }

            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            after_alloc = GC.stat(:total_allocated_objects)

            timings << (elapsed * 1_000_000.0 / batch)
            allocations << ((after_alloc - before_alloc).to_f / batch)
          end

          sorted = timings.sort
          sorted_alloc = allocations.sort
          median_us = sorted[sorted.length / 2]
          median_alloc = sorted_alloc[sorted_alloc.length / 2]

          puts format(
            '%-28s median=%9.3f us  min=%9.3f  max=%9.3f  alloc=%8.2f',
            label,
            median_us,
            sorted.first,
            sorted.last,
            median_alloc
          )

          {
            median_us: median_us,
            median_alloc: median_alloc
          }
        end

        def expected_cell(cells, value)
          target = normalize_cell_id(value)
          cells.find do |cell_space|
            normalize_cell_id(cell_space&.id) == target
          end
        end

        def normalize_cell_id(value)
          value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
               .sub(/\Asolid_/, '')
               .sub(/\Acell_/, '')
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::ValidationResolverLookupBenchmark.run
