# frozen_string_literal: true

require 'stringio'

# Load the single-solid Phase 3 probe without triggering its default auto-run.
dependency_model = Sketchup.active_model
dependency_selection = dependency_model.selection.to_a
dependency_stdout = $stdout
dependency_stderr = $stderr
begin
  dependency_model.selection.clear
  $stdout = StringIO.new
  $stderr = StringIO.new
  require_relative 'lvn_polygon_candidate_exact_hard_gate_probe'
ensure
  $stdout = dependency_stdout
  $stderr = dependency_stderr
  dependency_model.selection.clear
  dependency_selection.each do |entity|
    dependency_model.selection.add(entity) if entity.respond_to?(:valid?) && entity.valid?
  end
end

# Phase 3 representative-corpus exact hard-gate probe.
#
# Reuses the single-solid Phase 3 implementation unchanged. The runner selects
# deterministic no-hole face-count quantiles plus every eligible inner-loop
# source, invokes the exact gate one source at a time, captures verbose output,
# and restores the original selection.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateExactHardGateCorpusProbe
        NO_HOLE_SAMPLE_COUNT = 12
        MAX_FACE_COUNT = 250
        FAILURE_OUTPUT_LINES = 32

        module_function

        def run(
          no_hole_sample_count: NO_HOLE_SAMPLE_COUNT,
          max_face_count: MAX_FACE_COUNT
        )
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          exact = LvnPolygonCandidateExactHardGateProbe
          original_selection = model.selection.to_a
          selected = phase1.selected_entities(model)

          if selected.empty?
            puts '[LVN POLYGON EXACT GATE PHASE 3 CORPUS] Select solids first.'
            return false
          end

          puts '=' * 104
          puts ' LVN Polygon-Preserving Candidate — Phase 3 Representative Exact Hard-Gate Corpus'
          puts '=' * 104
          puts format('selected solids       : %d', selected.length)
          puts format('no-hole samples       : %d', no_hole_sample_count.to_i)
          puts 'inner-loop samples    : all eligible'
          puts format('maximum source Faces  : %d', max_face_count.to_i)
          puts 'hard gate             : unchanged production private validation methods'
          puts 'surface equivalence   : not run (Phase 4)'
          puts 'candidate lifetime    : each enclosing operation is aborted'
          puts 'source mutation       : none'
          puts 'production normalize  : not called'

          filtering_started = monotonic_time
          no_hole_records = []
          hole_records = []
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
              skipped[:above_face_limit] += 1
              next
            end

            feasibility = phase1.analyze_entity(entity)
            unless feasibility[:directly_preservable]
              skipped[:phase1_reject] += 1
              next
            end

            snapshot = base.snapshot_source(entity, phase1)
            unless snapshot[:non_geometry_entities].zero?
              skipped[:non_geometry_entities] += 1
              next
            end

            inner_loop_count = snapshot[:faces].sum do |record|
              record[:inner_loops].length
            end
            target = {
              entity: entity,
              faces: face_count,
              inner_loops: inner_loop_count,
              label: safe_label(phase1, entity)
            }
            if inner_loop_count.positive?
              hole_records << target
            else
              no_hole_records << target
            end
          rescue StandardError => error
            skipped[:filter_error] += 1
            filter_errors << {
              label: safe_label(phase1, entity),
              error: "#{error.class}: #{error.message}"
            }
          end

          no_hole_entities = no_hole_records.map { |record| record[:entity] }
          sampled_no_hole_entities = phase1.quantile_sample(
            no_hole_entities,
            [no_hole_sample_count.to_i, 1].max
          )
          no_hole_by_id = no_hole_records.to_h do |record|
            [entity_identity(record[:entity]), record]
          end
          sampled_no_holes = sampled_no_hole_entities.filter_map do |entity|
            no_hole_by_id[entity_identity(entity)]
          end
          sorted_holes = hole_records.sort_by do |record|
            [record[:faces], record[:inner_loops], entity_identity(record[:entity])]
          end
          targets = sampled_no_holes + sorted_holes

          puts '-' * 104
          puts format('eligible no-hole      : %d', no_hole_records.length)
          puts format('eligible inner-loop   : %d', hole_records.length)
          puts format('sampled no-hole       : %d', sampled_no_holes.length)
          puts format('sampled inner-loop    : %d', sorted_holes.length)
          puts format('total targets         : %d', targets.length)
          puts format('filter elapsed        : %.3f s', monotonic_time - filtering_started)
          print_skip_counts(skipped)

          if targets.empty?
            puts 'result                : FAIL (no eligible targets)'
            puts '=' * 104
            return false
          end

          results = []
          targets.each_with_index do |target, index|
            entity = target[:entity]
            model.selection.clear
            model.selection.add(entity)

            output = StringIO.new
            errors = StringIO.new
            previous_stdout = $stdout
            previous_stderr = $stderr
            started_at = monotonic_time
            passed = false

            begin
              $stdout = output
              $stderr = errors
              passed = exact.run
            rescue StandardError => error
              errors.puts("#{error.class}: #{error.message}")
              Array(error.backtrace).first(10).each { |line| errors.puts(line) }
              passed = false
            ensure
              $stdout = previous_stdout
              $stderr = previous_stderr
            end

            elapsed_ms = (monotonic_time - started_at) * 1000.0
            captured = [output.string, errors.string].reject(&:empty?).join("\n")
            result = target.merge(
              elapsed_ms: elapsed_ms,
              hard_gate_elapsed_ms: extract_metric_ms(captured, 'hard gate elapsed'),
              passed: passed == true,
              output: captured
            )
            results << result

            category = result[:inner_loops].positive? ? 'hole' : 'plain'
            gate_text = if result[:hard_gate_elapsed_ms]
                          format('%9.3f', result[:hard_gate_elapsed_ms])
                        else
                          '      n/a'
                        end
            puts format(
              '[%02d/%02d] %-54s type=%-5s F=%4d inner=%3d gate=%s ms total=%9.3f ms %s',
              index + 1,
              targets.length,
              result[:label][0, 54],
              category,
              result[:faces],
              result[:inner_loops],
              gate_text,
              result[:elapsed_ms],
              result[:passed] ? 'PASS' : 'FAIL'
            )

            next if result[:passed]

            puts '  ---- captured exact-gate tail ----'
            tail_lines(result[:output], FAILURE_OUTPUT_LINES).each do |line|
              puts "  #{line}"
            end
          end

          passed_results = results.select { |result| result[:passed] }
          failed_results = results.reject { |result| result[:passed] }
          gate_times = results.filter_map { |result| result[:hard_gate_elapsed_ms] }
          total_ms = results.sum { |result| result[:elapsed_ms] }

          selection_restored = restore_selection(model, original_selection)

          puts '=' * 104
          puts ' Phase 3 Representative Exact Hard-Gate Summary'
          puts '=' * 104
          puts format('tested solids         : %d', results.length)
          puts format('no-hole tested        : %d', results.count { |r| r[:inner_loops].zero? })
          puts format('inner-loop tested     : %d', results.count { |r| r[:inner_loops].positive? })
          puts format('hard gate PASS        : %d', passed_results.length)
          puts format('hard gate FAIL        : %d', failed_results.length)
          puts format('total elapsed         : %.3f s', total_ms / 1000.0)
          puts format('median total elapsed  : %.3f ms', median(results.map { |r| r[:elapsed_ms] }))
          unless gate_times.empty?
            puts format('median gate elapsed   : %.3f ms', median(gate_times))
            puts format('maximum gate elapsed  : %.3f ms', gate_times.max)
          end
          puts 'candidate operations  : all aborted by single-solid probe'
          puts 'production normalize  : 0 calls'
          puts format('filter errors         : %d', filter_errors.length)
          puts format('selection restored    : %s', selection_restored)

          unless filter_errors.empty?
            puts '-' * 104
            puts 'Filter error samples:'
            filter_errors.first(12).each do |entry|
              puts "  #{entry[:label]}: #{entry[:error]}"
            end
          end

          unless failed_results.empty?
            puts '-' * 104
            puts 'Failed exact-gate samples:'
            failed_results.each do |result|
              puts format(
                '  %-62s F=%4d inner=%3d total=%9.3f ms',
                result[:label][0, 62],
                result[:faces],
                result[:inner_loops],
                result[:elapsed_ms]
              )
            end
          end

          success = failed_results.empty? && filter_errors.empty? && selection_restored
          puts format('result                : %s', success ? 'PASS' : 'FAIL')
          puts '=' * 104
          success
        rescue StandardError => error
          warn "[LVN POLYGON EXACT GATE PHASE 3 CORPUS] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(10).join("\n")
          restore_selection(model, original_selection) if defined?(model) && model
          false
        ensure
          restore_selection(model, original_selection) if
            defined?(model) && model && defined?(original_selection) && original_selection
        end

        def valid_face_count(entity)
          entity.definition.entities.grep(Sketchup::Face).count(&:valid?)
        end

        def entity_identity(entity)
          if entity.respond_to?(:persistent_id)
            entity.persistent_id.to_i
          else
            entity.object_id
          end
        end

        def extract_metric_ms(text, label)
          match = text.to_s.match(/^\s*#{Regexp.escape(label)}\s*:\s*([0-9.]+)\s+ms\s*$/)
          match && match[1].to_f
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
          expected_ids = []
          Array(entities).each do |entity|
            next unless entity.respond_to?(:valid?) && entity.valid?

            model.selection.add(entity)
            expected_ids << entity_identity(entity)
          end
          actual_ids = model.selection.to_a.map { |entity| entity_identity(entity) }.sort
          actual_ids == expected_ids.sort
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
  LvnPolygonCandidateExactHardGateCorpusProbe.run
