# frozen_string_literal: true

require 'stringio'

# Load the single-solid real Phase-1-reject fallback probe without triggering
# its default selected-source execution. Only selection and console streams are
# temporarily changed while the dependency is evaluated.
dependency_model = Sketchup.active_model
dependency_selection = dependency_model.selection.to_a
dependency_stdout = $stdout
dependency_stderr = $stderr
begin
  dependency_model.selection.clear
  $stdout = StringIO.new
  $stderr = StringIO.new
  require_relative 'lvn_polygon_phase1_reject_fallback_probe'
ensure
  $stdout = dependency_stdout
  $stderr = dependency_stderr
  dependency_model.selection.clear
  dependency_selection.each do |entity|
    dependency_model.selection.add(entity) if entity.respond_to?(:valid?) && entity.valid?
  end
end

# Phase 5 full Phase-1-reject fallback corpus probe.
#
# Every selected top-level source rejected by the unchanged Phase 1 feasibility
# analysis is routed directly to the existing production LocalVertexNormalizer
# through the already validated single-solid fallback probe. The polygon path is
# never attempted. Each fallback runs on a fresh unique copy and its enclosing
# operation is aborted before the next source is tested.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonPhase1RejectFallbackCorpusProbe
        FAILURE_OUTPUT_LINES = 36

        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          fallback = LvnPolygonWholeSolidFallbackProbe
          single = LvnPolygonPhase1RejectFallbackProbe
          original_selection = model.selection.to_a
          root_before = fallback.model_root_signature(model)
          selected = phase1.selected_entities(model)

          if selected.empty?
            puts '[LVN PHASE1 REJECT FALLBACK CORPUS] Select solids first.'
            return false
          end

          puts '=' * 112
          puts ' LVN Polygon-Preserving Candidate — Phase 5 Full Phase-1-Reject Fallback Corpus'
          puts '=' * 112
          puts format('selected solids       : %d', selected.length)
          puts 'dispatch condition    : unchanged Phase 1 directly_preservable == false'
          puts 'polygon attempted     : false for every target'
          puts 'fallback source       : fresh unique copy from untouched source'
          puts 'fallback engine       : production LocalVertexNormalizer.normalize'
          puts 'candidate lifetime    : every enclosing operation is aborted'
          puts 'source mutation       : none'

          filtering_started_at = monotonic_time
          targets = []
          skipped = Hash.new(0)
          filter_errors = []

          selected.each do |entity|
            unless entity.respond_to?(:valid?) && entity.valid?
              skipped[:invalid_entity] += 1
              next
            end
            unless entity.parent == model
              skipped[:not_top_level] += 1
              next
            end

            feasibility = phase1.analyze_entity(entity)
            if feasibility[:directly_preservable]
              skipped[:phase1_accept] += 1
              next
            end

            targets << {
              entity: entity,
              label: safe_label(phase1, entity),
              faces: valid_face_count(entity),
              unsafe_faces: feasibility.dig(:faces, :unsafe).to_i,
              max_snap_move_mm: feasibility.dig(:snap, :max_displacement_mm).to_f,
              face_reasons: feasibility.dig(:faces, :reason_counts) || {},
              global_reasons: Array(feasibility.dig(:global, :reasons))
            }
          rescue StandardError => error
            skipped[:filter_error] += 1
            filter_errors << {
              label: safe_label(phase1, entity),
              error: "#{error.class}: #{error.message}"
            }
          end

          targets.sort_by! do |target|
            [
              target[:faces],
              target[:unsafe_faces],
              target[:global_reasons].length,
              entity_identity(target[:entity])
            ]
          end

          puts '-' * 112
          puts format('eligible rejects      : %d', targets.length)
          puts format('filter elapsed        : %.3f s', monotonic_time - filtering_started_at)
          print_skip_counts(skipped)

          if targets.empty?
            selection_restored = fallback.restore_selection(model, original_selection)
            root_restored = fallback.model_root_signature(model) == root_before
            puts format('model root restored   : %s', root_restored)
            puts format('selection restored    : %s', selection_restored)
            puts 'result                : FAIL (no Phase 1 rejects)'
            puts '=' * 112
            return false
          end

          results = []
          targets.each_with_index do |target, index|
            entity = target[:entity]
            source_signature = base.brep_signature(entity)
            iteration_root_before = fallback.model_root_signature(model)

            model.selection.clear
            model.selection.add(entity)

            output = StringIO.new
            errors = StringIO.new
            previous_stdout = $stdout
            previous_stderr = $stderr
            started_at = monotonic_time
            single_passed = false

            begin
              $stdout = output
              $stderr = errors
              single_passed = single.run
            rescue StandardError => error
              errors.puts("#{error.class}: #{error.message}")
              Array(error.backtrace).first(12).each { |line| errors.puts(line) }
              single_passed = false
            ensure
              $stdout = previous_stdout
              $stderr = previous_stderr
            end

            elapsed_ms = (monotonic_time - started_at) * 1000.0
            captured = [output.string, errors.string].reject(&:empty?).join("\n")
            source_restored = base.brep_signature(entity) == source_signature
            root_restored = fallback.model_root_signature(model) == iteration_root_before
            single_selection_restored = selection_signature(model.selection.to_a) ==
              [entity_identity(entity)]
            polygon_not_attempted = captured.match?(/^\s*polygon attempted\s*:\s*false\s*$/)
            dispatch_reject = captured.match?(
              /^\s*dispatch reason\s*:\s*:phase1_reject\s*$/
            )
            passed =
              single_passed == true &&
              polygon_not_attempted &&
              dispatch_reject &&
              source_restored &&
              root_restored &&
              single_selection_restored

            result = target.merge(
              elapsed_ms: elapsed_ms,
              fallback_elapsed_ms: extract_metric_ms(captured, 'fallback elapsed'),
              fallback_strategy: extract_value(captured, 'fallback strategy'),
              single_passed: single_passed == true,
              polygon_not_attempted: polygon_not_attempted,
              dispatch_reject: dispatch_reject,
              source_restored: source_restored,
              root_restored: root_restored,
              single_selection_restored: single_selection_restored,
              passed: passed,
              output: captured
            )
            results << result

            fallback_text = if result[:fallback_elapsed_ms]
                              format('%9.3f', result[:fallback_elapsed_ms])
                            else
                              '      n/a'
                            end
            reasons = compact_reasons(result[:face_reasons], result[:global_reasons])
            puts format(
              '[%02d/%02d] %-55s F=%4d unsafe=%3d move=%0.9f fallback=%s ms total=%9.3f ms %s',
              index + 1,
              targets.length,
              result[:label][0, 55],
              result[:faces],
              result[:unsafe_faces],
              result[:max_snap_move_mm],
              fallback_text,
              result[:elapsed_ms],
              result[:passed] ? 'PASS' : 'FAIL'
            )
            puts "           reasons=#{reasons}"

            next if result[:passed]

            puts '  ---- captured fallback tail ----'
            tail_lines(result[:output], FAILURE_OUTPUT_LINES).each do |line|
              puts "  #{line}"
            end
          end

          passed_results = results.select { |result| result[:passed] }
          failed_results = results.reject { |result| result[:passed] }
          fallback_times = results.filter_map { |result| result[:fallback_elapsed_ms] }
          total_ms = results.sum { |result| result[:elapsed_ms] }

          root_restored = fallback.model_root_signature(model) == root_before
          selection_restored = fallback.restore_selection(model, original_selection)

          puts '=' * 112
          puts ' Phase 5 Full Phase-1-Reject Fallback Summary'
          puts '=' * 112
          puts format('tested rejects        : %d', results.length)
          puts format('fallback PASS         : %d', passed_results.length)
          puts format('fallback FAIL         : %d', failed_results.length)
          puts format(
            'polygon attempted     : %d',
            results.count { |result| !result[:polygon_not_attempted] }
          )
          puts format(
            'dispatch mismatches   : %d',
            results.count { |result| !result[:dispatch_reject] }
          )
          puts format(
            'source restore fails  : %d',
            results.count { |result| !result[:source_restored] }
          )
          puts format(
            'root restore fails    : %d',
            results.count { |result| !result[:root_restored] }
          )
          puts format('total elapsed         : %.3f s', total_ms / 1000.0)
          puts format(
            'median total elapsed  : %.3f ms',
            median(results.map { |result| result[:elapsed_ms] })
          )
          unless fallback_times.empty?
            puts format('median fallback       : %.3f ms', median(fallback_times))
            puts format('maximum fallback      : %.3f ms', fallback_times.max)
          end
          puts 'candidate operations  : all aborted by single-solid probe'
          puts format('filter errors         : %d', filter_errors.length)
          puts format('model root restored   : %s', root_restored)
          puts format('selection restored    : %s', selection_restored)

          unless filter_errors.empty?
            puts '-' * 112
            puts 'Filter error samples:'
            filter_errors.first(12).each do |entry|
              puts "  #{entry[:label]}: #{entry[:error]}"
            end
          end

          unless failed_results.empty?
            puts '-' * 112
            puts 'Failed fallback targets:'
            failed_results.each do |result|
              puts format(
                '  %-64s F=%4d unsafe=%3d total=%9.3f ms',
                result[:label][0, 64],
                result[:faces],
                result[:unsafe_faces],
                result[:elapsed_ms]
              )
            end
          end

          success =
            failed_results.empty? &&
            filter_errors.empty? &&
            root_restored &&
            selection_restored
          puts format('result                : %s', success ? 'PASS' : 'FAIL')
          puts '=' * 112
          success
        rescue StandardError => error
          warn "[LVN PHASE1 REJECT FALLBACK CORPUS] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(12).join("\n")
          false
        ensure
          fallback.restore_selection(model, original_selection) if
            defined?(fallback) && fallback && defined?(model) && model &&
            defined?(original_selection) && original_selection
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

        def selection_signature(entities)
          Array(entities).filter_map do |entity|
            next unless entity.respond_to?(:valid?) && entity.valid?

            entity_identity(entity)
          end.sort
        end

        def extract_metric_ms(text, label)
          match = text.to_s.match(
            /^\s*#{Regexp.escape(label)}\s*:\s*([0-9.eE+-]+)\s+ms\s*$/
          )
          match && match[1].to_f
        end

        def extract_value(text, label)
          match = text.to_s.match(/^\s*#{Regexp.escape(label)}\s*:\s*(.+?)\s*$/)
          match && match[1]
        end

        def compact_reasons(face_reasons, global_reasons)
          face_text = face_reasons.empty? ? 'none' : face_reasons.inspect
          global_text = global_reasons.empty? ? 'none' : global_reasons.inspect
          text = "face=#{face_text} global=#{global_text}"
          text.length > 180 ? "#{text[0, 180]}..." : text
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
  LvnPolygonPhase1RejectFallbackCorpusProbe.run
