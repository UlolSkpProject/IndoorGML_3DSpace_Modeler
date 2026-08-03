# frozen_string_literal: true

require 'stringio'
require_relative 'lvn_polygon_candidate_reconstruction_probe'

# Load the validated single-solid hole probe while suppressing its file-level
# automatic run. The module itself is reused unchanged for every corpus item.
indoor_core = ULOL::Indoor3DGmlModeler::IndoorCore
unless indoor_core.const_defined?(:LvnPolygonCandidateHoleReconstructionProbe, false)
  captured = StringIO.new
  original_stdout = $stdout
  original_stderr = $stderr
  begin
    $stdout = captured
    $stderr = captured
    require_relative 'lvn_polygon_candidate_hole_reconstruction_probe'
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end
end

# Phase 2 all-selected inner-loop reconstruction corpus probe.
#
# - Reuses the exact single-solid hole reconstruction implementation.
# - Tests every selected top-level Phase 1-safe source with inner loops.
# - Runs one temporary-copy operation per source and relies on the single-solid
#   probe to abort it and verify exact source restoration.
# - Restores the original selection after the corpus completes.
# - Never calls production LocalVertexNormalizer.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateHoleReconstructionCorpusProbe
        FAILURE_OUTPUT_LINES = 30

        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          hole = LvnPolygonCandidateHoleReconstructionProbe

          original_selection = model.selection.to_a.select do |entity|
            entity.respond_to?(:valid?) && entity.valid?
          end
          if original_selection.empty?
            puts '[LVN POLYGON HOLE CORPUS] Select Group / ComponentInstance solids first.'
            return false
          end

          original_selection_signature = selection_signature(original_selection, phase1)
          candidates = []
          filter_errors = []
          skipped = Hash.new(0)
          filter_started_at = monotonic_time

          original_selection.each do |entity|
            unless entity.respond_to?(:definition) && entity.parent == model
              skipped[:not_top_level_instance] += 1
              next
            end

            begin
              snapshot = base.snapshot_source(entity, phase1)
              if snapshot[:non_geometry_entities].positive?
                skipped[:non_geometry_entities] += 1
                next
              end

              inner_loop_count = snapshot[:faces].sum do |record|
                record[:inner_loops].length
              end
              if inner_loop_count.zero?
                skipped[:no_inner_loops] += 1
                next
              end

              feasibility = phase1.analyze_entity(entity)
              unless feasibility[:directly_preservable]
                skipped[:phase1_reject] += 1
                next
              end

              counts = base.geometry_counts(entity)
              candidates << {
                entity: entity,
                label: phase1.entity_label(entity),
                pid: phase1.persistent_id(entity),
                faces: counts[:faces],
                edges: counts[:edges],
                vertices: counts[:vertices],
                inner_loops: inner_loop_count,
                hole_faces: snapshot[:faces].count do |record|
                  !record[:inner_loops].empty?
                end
              }
            rescue StandardError => error
              filter_errors << {
                label: phase1.entity_label(entity),
                error: "#{error.class}: #{error.message}"
              }
            end
          end

          candidates.sort_by! do |entry|
            [entry[:faces], entry[:inner_loops], entry[:pid].to_i, entry[:label]]
          end

          print_header(
            original_selection.length,
            candidates,
            skipped,
            filter_errors,
            monotonic_time - filter_started_at
          )

          if candidates.empty?
            restore_selection(model, original_selection)
            puts 'result                : FAIL (no eligible inner-loop sources)'
            puts '=' * 100
            return false
          end

          results = []
          corpus_started_at = monotonic_time

          candidates.each_with_index do |entry, index|
            elapsed_ms = nil
            output = ''
            passed = false
            error_text = nil

            begin
              model.selection.clear
              model.selection.add(entry[:entity])

              started_at = monotonic_time
              passed, output = capture_output { hole.run }
              elapsed_ms = (monotonic_time - started_at) * 1000.0
            rescue StandardError => error
              elapsed_ms ||= 0.0
              error_text = "#{error.class}: #{error.message}"
              output = Array(error.backtrace).first(8).join("\n")
            end

            result = entry.merge(
              passed: passed == true,
              elapsed_ms: elapsed_ms,
              output: output,
              error: error_text
            )
            results << result

            puts format(
              '[%02d/%02d] %-62s faces=%4d inner=%3d time=%9.3f ms result=%s',
              index + 1,
              candidates.length,
              entry[:label].to_s[0, 62],
              entry[:faces],
              entry[:inner_loops],
              elapsed_ms,
              result[:passed] ? 'PASS' : 'FAIL'
            )

            next if result[:passed]

            puts '  --- single-solid probe output tail ---'
            output.to_s.lines.last(FAILURE_OUTPUT_LINES).each do |line|
              puts "  #{line.rstrip}"
            end
            puts "  ERROR: #{error_text}" if error_text
          end

          total_elapsed = monotonic_time - corpus_started_at
          restore_selection(model, original_selection)
          restored_signature = selection_signature(model.selection.to_a, phase1)
          selection_restored = restored_signature == original_selection_signature

          print_summary(
            results,
            filter_errors,
            total_elapsed,
            selection_restored
          )

          results.all? { |result| result[:passed] } &&
            filter_errors.empty? &&
            selection_restored
        rescue StandardError => error
          restore_selection(model, original_selection) if
            defined?(model) && defined?(original_selection)
          warn "[LVN POLYGON HOLE CORPUS] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(10).join("\n")
          false
        end

        def print_header(selected_count, candidates, skipped, filter_errors, elapsed_seconds)
          puts '=' * 100
          puts ' LVN Polygon-Preserving Hole Reconstruction — Phase 2 Full Inner-Loop Corpus'
          puts '=' * 100
          puts format('selected solids       : %d', selected_count)
          puts format('eligible inner-loop   : %d', candidates.length)
          puts 'sampling              : all eligible selected solids'
          puts 'hole strategy         : add inner fill Face, erase only that Face'
          puts 'candidate lifetime    : each enclosing operation is aborted'
          puts 'source mutation       : none'
          puts 'production LVN calls  : none'
          puts format('filter elapsed        : %.3f s', elapsed_seconds)
          puts 'skipped:'
          if skipped.empty?
            puts '  none'
          else
            skipped.sort_by { |reason, _count| reason.to_s }.each do |reason, count|
              puts format('  %-42s %6d', reason, count)
            end
          end
          puts format('filter errors         : %d', filter_errors.length)
          unless filter_errors.empty?
            filter_errors.first(10).each do |entry|
              puts "  #{entry[:label]}: #{entry[:error]}"
            end
          end
          puts '-' * 100
        end

        def print_summary(results, filter_errors, total_elapsed, selection_restored)
          passed = results.count { |result| result[:passed] }
          failed = results.length - passed
          elapsed_values = results.map { |result| result[:elapsed_ms] }.sort
          median_elapsed = median(elapsed_values)
          total_inner_loops = results.sum { |result| result[:inner_loops] }
          total_hole_faces = results.sum { |result| result[:hole_faces] }

          puts '=' * 100
          puts ' Phase 2 Full Inner-Loop Reconstruction Summary'
          puts '=' * 100
          puts format('tested solids         : %d', results.length)
          puts format('candidate PASS        : %d', passed)
          puts format('candidate FAIL        : %d', failed)
          puts format('hole-bearing Faces    : %d', total_hole_faces)
          puts format('inner loops tested    : %d', total_inner_loops)
          puts format('total elapsed         : %.3f s', total_elapsed)
          puts format('median elapsed        : %.3f ms', median_elapsed)
          puts format(
            'maximum elapsed       : %.3f ms',
            elapsed_values.max || 0.0
          )
          puts 'candidate operations  : all aborted by single-solid probe'
          puts 'production LVN calls  : 0'
          puts format('filter errors         : %d', filter_errors.length)
          puts format('selection restored    : %s', selection_restored)
          puts format(
            'result                : %s',
            failed.zero? && filter_errors.empty? && selection_restored ? 'PASS' : 'FAIL'
          )
          puts '=' * 100
        end

        def capture_output
          buffer = StringIO.new
          original_stdout = $stdout
          original_stderr = $stderr
          result = nil
          begin
            $stdout = buffer
            $stderr = buffer
            result = yield
          ensure
            $stdout = original_stdout
            $stderr = original_stderr
          end
          [result, buffer.string]
        end

        def restore_selection(model, entities)
          model.selection.clear
          entities.each do |entity|
            model.selection.add(entity) if
              entity.respond_to?(:valid?) && entity.valid?
          end
        end

        def selection_signature(entities, phase1)
          entities.select do |entity|
            entity.respond_to?(:valid?) && entity.valid?
          end.map do |entity|
            [entity.class.name, phase1.persistent_id(entity).to_i, entity.object_id]
          end.sort
        end

        def median(values)
          return 0.0 if values.empty?

          middle = values.length / 2
          return values[middle] if values.length.odd?

          (values[middle - 1] + values[middle]) / 2.0
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnPolygonCandidateHoleReconstructionCorpusProbe.run
