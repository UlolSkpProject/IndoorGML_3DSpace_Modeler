# frozen_string_literal: true

require 'stringio'

# Load the single-solid Phase 2 probe without emitting the feasibility probe's
# development auto-run output when this is the first dev script loaded.
original_stdout = $stdout
original_stderr = $stderr
begin
  $stdout = StringIO.new
  $stderr = StringIO.new
  require_relative 'lvn_polygon_candidate_reconstruction_probe'
ensure
  $stdout = original_stdout
  $stderr = original_stderr
end

# Phase 2 representative-corpus reconstruction probe.
#
# The existing single-solid reconstruction probe remains the only implementation
# of candidate creation and inspection. This runner only selects a deterministic
# representative subset, invokes that probe one Solid at a time, captures its
# verbose output, and restores the original SketchUp selection.
#
# Safety boundaries:
# - Phase 1 candidates only
# - top-level instances only
# - no inner loops yet
# - no nested/non-geometry definition content
# - at most 250 source Faces
# - every candidate operation is aborted by the single-solid probe
# - production LocalVertexNormalizer is never called

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateReconstructionCorpusProbe
        SAMPLE_COUNT = 12
        MAX_FACE_COUNT = 250
        FAILURE_OUTPUT_LINES = 24

        module_function

        def run(sample_count: SAMPLE_COUNT, max_face_count: MAX_FACE_COUNT)
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          reconstruction = LvnPolygonCandidateReconstructionProbe
          original_selection = model.selection.to_a
          selected = phase1.selected_entities(model)

          if selected.empty?
            puts '[LVN POLYGON PHASE 2 CORPUS] Select Group / ComponentInstance solids first.'
            return false
          end

          puts '=' * 96
          puts ' LVN Polygon-Preserving Candidate Reconstruction — Phase 2 Representative Corpus'
          puts '=' * 96
          puts format('selected solids       : %d', selected.length)
          puts format('requested samples     : %d', sample_count.to_i)
          puts format('maximum source Faces  : %d', max_face_count.to_i)
          puts 'sampling              : deterministic eligible face-count quantiles'
          puts 'candidate lifetime    : each enclosing operation is aborted'
          puts 'source mutation       : none'
          puts 'production LVN calls  : none'

          filtering_started = monotonic_time
          eligible = []
          skipped = Hash.new(0)
          filter_errors = []

          selected.each do |entity|
            unless entity.respond_to?(:valid?) && entity.valid?
              skipped[:invalid_entity] += 1
              next
            end
            unless entity.parent == model
              skipped[:nested_instance] += 1
              next
            end

            face_count = valid_face_count(entity)
            if face_count > max_face_count.to_i
              skipped[:stress_over_face_limit] += 1
              next
            end

            feasibility = phase1.analyze_entity(entity)
            unless feasibility[:directly_preservable]
              skipped[:phase1_reject] += 1
              next
            end

            snapshot = reconstruction.snapshot_source(entity, phase1)
            if snapshot[:faces].any? { |record| !record[:inner_loops].empty? }
              skipped[:inner_loops] += 1
              next
            end
            unless snapshot[:non_geometry_entities].zero?
              skipped[:non_geometry_entities] += 1
              next
            end

            eligible << entity
          rescue StandardError => error
            skipped[:filter_error] += 1
            filter_errors << {
              label: safe_label(phase1, entity),
              error: "#{error.class}: #{error.message}"
            }
          end

          targets = phase1.quantile_sample(
            eligible,
            [sample_count.to_i, 1].max
          )

          puts '-' * 96
          puts format('eligible solids       : %d', eligible.length)
          puts format('sampled solids        : %d', targets.length)
          puts format('filter elapsed        : %.3f s', monotonic_time - filtering_started)
          print_skip_counts(skipped)

          if targets.empty?
            puts 'result                : FAIL (no eligible targets)'
            puts '=' * 96
            return false
          end

          results = []
          targets.each_with_index do |entity, index|
            model.selection.clear
            model.selection.add(entity)

            output = StringIO.new
            errors = StringIO.new
            previous_stdout = $stdout
            previous_stderr = $stderr
            started = monotonic_time
            passed = false

            begin
              $stdout = output
              $stderr = errors
              passed = reconstruction.run
            rescue StandardError => error
              errors.puts("#{error.class}: #{error.message}")
              Array(error.backtrace).first(8).each { |line| errors.puts(line) }
              passed = false
            ensure
              $stdout = previous_stdout
              $stderr = previous_stderr
            end

            elapsed_ms = (monotonic_time - started) * 1000.0
            captured = [output.string, errors.string].reject(&:empty?).join("\n")
            result = {
              label: safe_label(phase1, entity),
              faces: valid_face_count(entity),
              elapsed_ms: elapsed_ms,
              passed: passed == true,
              output: captured
            }
            results << result

            puts format(
              '[%02d/%02d] %-58s faces=%4d time=%9.3f ms result=%s',
              index + 1,
              targets.length,
              result[:label][0, 58],
              result[:faces],
              result[:elapsed_ms],
              result[:passed] ? 'PASS' : 'FAIL'
            )

            next if result[:passed]

            puts '  ---- captured probe tail ----'
            tail_lines(result[:output], FAILURE_OUTPUT_LINES).each do |line|
              puts "  #{line}"
            end
          end

          passed_results = results.select { |result| result[:passed] }
          failed_results = results.reject { |result| result[:passed] }
          total_ms = results.sum { |result| result[:elapsed_ms] }

          puts '=' * 96
          puts ' Phase 2 Representative Reconstruction Summary'
          puts '=' * 96
          puts format('tested solids         : %d', results.length)
          puts format('candidate PASS        : %d', passed_results.length)
          puts format('candidate FAIL        : %d', failed_results.length)
          puts format('total elapsed         : %.3f s', total_ms / 1000.0)
          puts format(
            'median elapsed        : %.3f ms',
            median(results.map { |result| result[:elapsed_ms] })
          )
          puts 'candidate operations  : all aborted by single-solid probe'
          puts 'production LVN calls  : 0'
          puts format('filter errors         : %d', filter_errors.length)

          unless filter_errors.empty?
            puts '-' * 96
            puts 'Filter error samples:'
            filter_errors.first(12).each do |entry|
              puts "  #{entry[:label]}: #{entry[:error]}"
            end
          end

          unless failed_results.empty?
            puts '-' * 96
            puts 'Failed reconstruction samples:'
            failed_results.each do |result|
              puts format(
                '  %-62s faces=%4d time=%9.3f ms',
                result[:label][0, 62],
                result[:faces],
                result[:elapsed_ms]
              )
            end
          end

          selection_restored = restore_selection(model, original_selection)
          puts format('selection restored    : %s', selection_restored)
          success = failed_results.empty? && filter_errors.empty? && selection_restored
          puts format('result                : %s', success ? 'PASS' : 'FAIL')
          puts '=' * 96
          success
        rescue StandardError => error
          warn "[LVN POLYGON PHASE 2 CORPUS] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(8).join("\n")
          restore_selection(model, original_selection) if defined?(model) && model
          false
        ensure
          restore_selection(model, original_selection) if
            defined?(model) && model && defined?(original_selection) && original_selection
        end

        def valid_face_count(entity)
          entity.definition.entities.grep(Sketchup::Face).count(&:valid?)
        end

        def print_skip_counts(skipped)
          if skipped.empty?
            puts 'skipped               : none'
            return
          end

          puts 'skipped:'
          skipped.sort_by { |reason, count| [-count, reason.to_s] }.each do |reason, count|
            puts format('  %-38s %6d', reason, count)
          end
        end

        def tail_lines(text, count)
          text.to_s.lines.map(&:chomp).last(count)
        end

        def safe_label(phase1, entity)
          phase1.entity_label(entity)
        rescue StandardError
          entity.to_s
        end

        def restore_selection(model, entities)
          model.selection.clear
          Array(entities).each do |entity|
            model.selection.add(entity) if entity.respond_to?(:valid?) && entity.valid?
          end
          expected = Array(entities).count do |entity|
            entity.respond_to?(:valid?) && entity.valid?
          end
          model.selection.length == expected
        rescue StandardError
          false
        end

        def median(values)
          sorted = Array(values).sort
          return 0.0 if sorted.empty?

          middle = sorted.length / 2
          if sorted.length.odd?
            sorted[middle]
          else
            (sorted[middle - 1] + sorted[middle]) / 2.0
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
  LvnPolygonCandidateReconstructionCorpusProbe.run
