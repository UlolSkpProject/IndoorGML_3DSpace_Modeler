# frozen_string_literal: true

# Phase 1 summary-only corpus probe for polygon-preserving LVN.
#
# Requires dev/lvn_polygon_preserving_feasibility_probe.rb to be loaded first.
# This script performs no SketchUp geometry mutation and never calls production LVN.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonPreservingCorpusSummaryProbe
        PROGRESS_INTERVAL = 50
        MAX_SAMPLE_COUNT = 12
        SLOWEST_SAMPLE_COUNT = 10

        module_function

        def run
          unless const_defined?(:LvnPolygonPreservingFeasibilityProbe, false)
            raise NameError,
                  'Load dev/lvn_polygon_preserving_feasibility_probe.rb first'
          end

          probe = LvnPolygonPreservingFeasibilityProbe
          model = Sketchup.active_model
          selected = probe.selected_entities(model)
          if selected.empty?
            puts '[LVN POLYGON CORPUS] Select Group / ComponentInstance solids first.'
            return false
          end

          puts '=' * 92
          puts ' LVN Polygon-Preserving Feasibility Probe — Phase 1 Full Corpus Summary'
          puts '=' * 92
          puts format('selected solids       : %d', selected.length)
          puts 'mode                  : all selected / summary only'
          puts format('grid tolerance        : %.6f mm', probe::DEFAULT_TOLERANCE_MM)
          puts format('planarity tolerance   : %.6f mm', probe::PLANARITY_TOLERANCE_MM)
          puts 'coordinate space      : definition local'
          puts 'geometry mutations    : none'
          puts 'production LVN calls  : none'
          puts format('progress interval     : %d solids', PROGRESS_INTERVAL)

          started_at = monotonic_time
          results = []
          errors = []
          slowest = []

          selected.each_with_index do |entity, index|
            entity_started_at = monotonic_time
            begin
              result = probe.analyze_entity(entity)
              results << result
              elapsed_ms = (monotonic_time - entity_started_at) * 1000.0
              slowest << [elapsed_ms, result[:label], result.dig(:source, :faces).to_i]
              slowest = slowest.max_by(SLOWEST_SAMPLE_COUNT) { |entry| entry[0] }
            rescue StandardError => error
              errors << {
                label: probe.entity_label(entity),
                error: "#{error.class}: #{error.message}"
              }
            end

            completed = index + 1
            if (completed % PROGRESS_INTERVAL).zero? || completed == selected.length
              candidates = results.count { |result| result[:directly_preservable] }
              fallbacks = results.length - candidates
              puts format(
                '[LVN POLYGON CORPUS] %4d/%4d candidates=%4d fallback=%4d errors=%3d elapsed=%8.3f s',
                completed,
                selected.length,
                candidates,
                fallbacks,
                errors.length,
                monotonic_time - started_at
              )
            end
          end

          print_summary(results, errors, slowest, monotonic_time - started_at)
          errors.empty?
        rescue StandardError => error
          warn "[LVN POLYGON CORPUS] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(8).join("\n")
          false
        end

        def print_summary(results, errors, slowest, elapsed_seconds)
          candidates = results.select { |result| result[:directly_preservable] }
          fallbacks = results.reject { |result| result[:directly_preservable] }

          face_reasons = Hash.new(0)
          global_reasons = Hash.new(0)
          collapse_solids = 0
          collapsed_source_vertices = 0
          maximum_displacement = 0.0
          total_faces = 0
          total_edges = 0
          total_vertices = 0

          results.each do |result|
            result.dig(:faces, :reason_counts).to_h.each do |reason, count|
              face_reasons[reason] += count.to_i
            end
            Array(result.dig(:global, :reasons)).each do |reason|
              global_reasons[reason] += 1
            end

            snap = result[:snap] || {}
            if snap[:collapse_class_count].to_i.positive?
              collapse_solids += 1
              collapsed_source_vertices += snap[:collapsed_source_vertex_count].to_i
            end
            maximum_displacement = [
              maximum_displacement,
              snap[:max_displacement_mm].to_f
            ].max

            source = result[:source] || {}
            total_faces += source[:faces].to_i
            total_edges += source[:edges].to_i
            total_vertices += source[:vertices].to_i
          end

          puts '=' * 92
          puts ' Phase 1 Full Corpus Feasibility Summary'
          puts '=' * 92
          puts format('analyzed solids       : %d', results.length)
          puts format('polygon candidates    : %d', candidates.length)
          puts format('existing LVN fallback : %d', fallbacks.length)
          puts format('probe errors          : %d', errors.length)
          rate = results.empty? ? 0.0 : candidates.length.to_f / results.length * 100.0
          puts format('candidate rate        : %.2f%%', rate)
          puts format('aggregate source      : F=%d E=%d V=%d', total_faces, total_edges, total_vertices)
          puts format('collapse solids       : %d', collapse_solids)
          puts format('collapsed source V    : %d', collapsed_source_vertices)
          puts format('max snap displacement : %.9f mm', maximum_displacement)
          puts format('elapsed               : %.3f s', elapsed_seconds)
          puts 'geometry mutations    : 0'

          puts '-' * 92
          puts 'Face unsafe reasons:'
          print_reason_counts(face_reasons)
          puts 'Global unsafe reasons:'
          print_reason_counts(global_reasons)

          unless fallbacks.empty?
            puts '-' * 92
            puts 'Fallback samples:'
            fallbacks.first(MAX_SAMPLE_COUNT).each do |result|
              reasons = result.dig(:faces, :reason_counts).to_h.keys +
                Array(result.dig(:global, :reasons))
              puts format(
                '  %-58s faces=%6d reasons=%s',
                result[:label].to_s[0, 58],
                result.dig(:source, :faces).to_i,
                reasons.uniq.join(', ')
              )
            end
          end

          unless errors.empty?
            puts '-' * 92
            puts 'Error samples:'
            errors.first(MAX_SAMPLE_COUNT).each do |entry|
              puts "  #{entry[:label]}: #{entry[:error]}"
            end
          end

          puts '-' * 92
          puts 'Slowest analyzed solids:'
          slowest.sort_by { |entry| -entry[0] }.each do |elapsed_ms, label, faces|
            puts format('  %9.3f ms  faces=%6d  %s', elapsed_ms, faces, label)
          end

          puts format('result                : %s', errors.empty? ? 'PASS' : 'FAIL')
          puts '=' * 92
        end

        def print_reason_counts(counts)
          if counts.empty?
            puts '  none'
            return
          end

          counts.sort_by { |reason, count| [-count, reason.to_s] }.each do |reason, count|
            puts format('  %-45s %8d', reason, count)
          end
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnPolygonPreservingCorpusSummaryProbe.run
