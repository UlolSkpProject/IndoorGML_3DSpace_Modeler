# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ValidationOverlayBaselineBenchmark
        extend self

        DEFAULT_ROUNDS = 7
        DEFAULT_SYNTHETIC_TRIANGLES = 5_000
        DEFAULT_SYNTHETIC_EDGE_SEGMENTS = 5_000

        TRACE_METHODS = [
          :flatten,
          :geometry_points,
          :normalized_geometry,
          :draw_triangles,
          :draw_lines
        ].freeze

        def run(
          rounds: DEFAULT_ROUNDS,
          synthetic_triangles: DEFAULT_SYNTHETIC_TRIANGLES,
          synthetic_edge_segments: DEFAULT_SYNTHETIC_EDGE_SEGMENTS
        )
          indoor_model = IndoorModel.current
          raise 'Current IndoorModel not found' unless indoor_model

          source_geometry, source_label = benchmark_geometry(
            synthetic_triangles: synthetic_triangles,
            synthetic_edge_segments: synthetic_edge_segments
          )

          overlay = ValidationErrorGeometryOverlay.new(indoor_model)
          force_geometry_rendering(overlay)
          overlay.set_geometry(source_geometry)
          view = NoopView.new

          print_header(
            source_geometry,
            source_label: source_label,
            rounds: rounds
          )

          warm_up(overlay, source_geometry, view)

          puts '--- timing / allocation ------------------------------------'

          benchmark_case('set_geometry', rounds: rounds) do
            overlay.set_geometry(source_geometry)
          end

          overlay.set_geometry(source_geometry)
          benchmark_case('geometry_points', rounds: rounds) do
            overlay.send(:geometry_points)
          end

          overlay.set_geometry(source_geometry)
          benchmark_case('getExtents', rounds: rounds) do
            overlay.getExtents
          end

          overlay.set_geometry(source_geometry)
          benchmark_case('draw preprocessing (noop view)', rounds: rounds) do
            overlay.draw(view)
          end

          benchmark_case('set_geometry + geometry_points', rounds: rounds) do
            overlay.set_geometry(source_geometry)
            overlay.send(:geometry_points)
          end

          benchmark_case('set_geometry + getExtents', rounds: rounds) do
            overlay.set_geometry(source_geometry)
            overlay.getExtents
          end

          puts
          puts '--- call-count diagnostics --------------------------------'

          overlay.set_geometry(source_geometry)
          trace_case('geometry_points') do
            overlay.send(:geometry_points)
          end

          overlay.set_geometry(source_geometry)
          trace_case('getExtents') do
            overlay.getExtents
          end

          overlay.set_geometry(source_geometry)
          trace_case('draw preprocessing') do
            overlay.draw(view)
          end

          puts
          puts '--- geometry / allocation shape ---------------------------'

          normalized = overlay.instance_variable_get(:@geometry) || {}
          face_triangles = Array(normalized[:face_triangles])
          face_edges = Array(normalized[:face_edges])
          overlap_triangles = Array(normalized[:overlap_triangles])
          overlap_edges = Array(normalized[:overlap_edges])

          points1 = overlay.send(:geometry_points)
          points2 = overlay.send(:geometry_points)

          puts format('%-34s %10d', 'face triangles:', face_triangles.length)
          puts format('%-34s %10d', 'face edge points:', face_edges.length)
          puts format('%-34s %10d', 'overlap triangles:', overlap_triangles.length)
          puts format('%-34s %10d', 'overlap edge points:', overlap_edges.length)
          puts format('%-34s %10d', 'geometry_points refs:', points1.length)
          puts format('%-34s %10s', 'geometry_points same object:', points1.equal?(points2).to_s)
          puts format('%-34s %10d', 'noop draw calls:', view.draw_calls)

          puts
          puts '============================================================'
          puts ' Benchmark complete'
          puts '============================================================'

          true
        rescue StandardError => e
          puts
          puts "[ValidationOverlayBenchmark] ERROR: #{e.class}: #{e.message}"
          Array(e.backtrace).first(15).each { |line| puts "  #{line}" }
          false
        end

        def benchmark_case(label, rounds:)
          samples = []
          allocations = []

          rounds.times do
            GC.start
            allocation_before = GC.stat(:total_allocated_objects)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            yield

            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            allocation_after = GC.stat(:total_allocated_objects)

            samples << elapsed * 1000.0
            allocations << (allocation_after - allocation_before)
          end

          sorted = samples.sort
          sorted_allocations = allocations.sort
          median = sorted[sorted.length / 2]
          allocation_median = sorted_allocations[sorted_allocations.length / 2]

          puts format(
            '%-40s median=%9.3f ms  min=%9.3f  max=%9.3f  alloc=%9d',
            label,
            median,
            sorted.first,
            sorted.last,
            allocation_median
          )

          {
            median_ms: median,
            min_ms: sorted.first,
            max_ms: sorted.last,
            allocation_median: allocation_median
          }
        end

        def trace_case(label)
          counts = Hash.new(0)
          tracer = TracePoint.new(:call, :c_call) do |tp|
            counts[tp.method_id] += 1 if TRACE_METHODS.include?(tp.method_id)
          end

          tracer.enable
          yield
        ensure
          tracer&.disable

          puts "[#{label}]"
          printed = false
          TRACE_METHODS.each do |method_id|
            count = counts[method_id]
            next unless count.positive?

            printed = true
            puts format('  %-34s %8d', method_id, count)
          end
          puts '  (no traced calls)' unless printed
        end

        def benchmark_geometry(synthetic_triangles:, synthetic_edge_segments:)
          live_geometry = live_validation_geometry
          return [live_geometry, 'live validation overlay'] if geometry_present?(live_geometry)

          [
            synthetic_geometry(
              triangle_count: synthetic_triangles,
              edge_segment_count: synthetic_edge_segments
            ),
            'synthetic fallback'
          ]
        end

        def live_validation_geometry
          model = Sketchup.active_model
          return nil unless model&.respond_to?(:overlays)

          overlay = model.overlays.find do |candidate|
            candidate.respond_to?(:overlay_id) &&
              candidate.overlay_id == ValidationErrorGeometryOverlay::OVERLAY_ID
          end
          return nil unless overlay

          geometry = overlay.instance_variable_get(:@geometry)
          geometry.is_a?(Hash) ? geometry : nil
        rescue StandardError
          nil
        end

        def geometry_present?(geometry)
          return false unless geometry.is_a?(Hash)

          Array(geometry[:face_triangles]).any? ||
            Array(geometry[:face_edges]).any? ||
            Array(geometry[:overlap_triangles]).any? ||
            Array(geometry[:overlap_edges]).any?
        end

        def synthetic_geometry(triangle_count:, edge_segment_count:)
          face_triangle_count = triangle_count / 2
          overlap_triangle_count = triangle_count - face_triangle_count
          face_edge_count = edge_segment_count / 2
          overlap_edge_count = edge_segment_count - face_edge_count

          {
            face_triangles: build_triangles(face_triangle_count, 0.0),
            face_edges: build_edge_points(face_edge_count, 10_000.0),
            overlap_triangles: build_triangles(overlap_triangle_count, 20_000.0),
            overlap_edges: build_edge_points(overlap_edge_count, 30_000.0)
          }
        end

        def build_triangles(count, offset)
          Array.new(count) do |index|
            x = offset + index.to_f
            [
              Geom::Point3d.new(x, 0.0, 0.0),
              Geom::Point3d.new(x + 1.0, 0.0, 0.0),
              Geom::Point3d.new(x, 1.0, 0.0)
            ]
          end
        end

        def build_edge_points(segment_count, offset)
          points = []
          segment_count.times do |index|
            x = offset + index.to_f
            points << Geom::Point3d.new(x, 0.0, 0.0)
            points << Geom::Point3d.new(x + 1.0, 1.0, 0.0)
          end
          points
        end

        def force_geometry_rendering(overlay)
          overlay.define_singleton_method(:draw_validation_geometry?) { true }
        end

        def warm_up(overlay, source_geometry, view)
          overlay.set_geometry(source_geometry)
          overlay.send(:geometry_points)
          overlay.getExtents
          overlay.draw(view)
          GC.start
        end

        def print_header(geometry, source_label:, rounds:)
          face_triangles = Array(geometry[:face_triangles])
          face_edges = Array(geometry[:face_edges])
          overlap_triangles = Array(geometry[:overlap_triangles])
          overlap_edges = Array(geometry[:overlap_edges])
          total_refs =
            (face_triangles.length * 3) +
            face_edges.length +
            (overlap_triangles.length * 3) +
            overlap_edges.length

          puts
          puts '============================================================'
          puts ' IndoorGML Validation Overlay Baseline Benchmark'
          puts '============================================================'
          puts "source                 : #{source_label}"
          puts "rounds                 : #{rounds}"
          puts "face triangles         : #{face_triangles.length}"
          puts "face edge points       : #{face_edges.length}"
          puts "overlap triangles      : #{overlap_triangles.length}"
          puts "overlap edge points    : #{overlap_edges.length}"
          puts "estimated point refs   : #{total_refs}"
          puts "ruby                   : #{RUBY_VERSION}" if defined?(RUBY_VERSION)
        end

        class NoopView
          attr_reader :draw_calls
          attr_accessor :drawing_color, :line_width, :line_stipple

          def initialize
            @draw_calls = 0
          end

          def draw(_primitive, _points)
            @draw_calls += 1
            true
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::ValidationOverlayBaselineBenchmark.run
