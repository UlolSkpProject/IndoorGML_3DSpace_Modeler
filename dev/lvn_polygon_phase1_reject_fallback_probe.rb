# frozen_string_literal: true

require 'stringio'

# Load the Phase 5 forced-failure helper without triggering its default auto-run.
dependency_model = Sketchup.active_model
dependency_selection = dependency_model.selection.to_a
dependency_stdout = $stdout
dependency_stderr = $stderr
begin
  dependency_model.selection.clear
  $stdout = StringIO.new
  $stderr = StringIO.new
  require_relative 'lvn_polygon_whole_solid_fallback_probe'
ensure
  $stdout = dependency_stdout
  $stderr = dependency_stderr
  dependency_model.selection.clear
  dependency_selection.each do |entity|
    dependency_model.selection.add(entity) if entity.respond_to?(:valid?) && entity.valid?
  end
end

# Phase 5 single-solid real-dispatch fallback probe.
#
# Selects the smallest top-level source that the unchanged Phase 1 feasibility
# analysis rejects. The polygon path must not be attempted. A fresh unique copy
# is created from the untouched source and normalized through the unchanged
# production LocalVertexNormalizer. The enclosing operation is always aborted.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonPhase1RejectFallbackProbe
        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          fallback = LvnPolygonWholeSolidFallbackProbe
          original_selection = model.selection.to_a
          root_before = fallback.model_root_signature(model)

          source, feasibility, filter = find_source(model, phase1)
          unless source
            puts '[LVN POLYGON FALLBACK PHASE 5] No selected Phase 1-rejected source found.'
            print_filter_summary(filter)
            return false
          end

          source_signature = base.brep_signature(source)
          source_counts = base.geometry_counts(source)
          face_reasons = feasibility.dig(:faces, :reason_counts) || {}
          global_reasons = Array(feasibility.dig(:global, :reasons))

          puts '=' * 108
          puts ' LVN Polygon-Preserving Candidate — Phase 5 Real Phase-1-Reject Fallback'
          puts '=' * 108
          puts format('selected solids       : %d', original_selection.length)
          puts format('source                : %s', phase1.entity_label(source))
          puts format(
            'source geometry       : F=%d E=%d V=%d manifold=%s',
            source_counts[:faces],
            source_counts[:edges],
            source_counts[:vertices],
            source_counts[:manifold].inspect
          )
          puts format(
            'source max snap move  : %.9f mm',
            feasibility.dig(:snap, :max_displacement_mm).to_f
          )
          puts format('Phase 1 candidate     : %s', feasibility[:directly_preservable])
          puts format('Face reject reasons   : %s', compact_inspect(face_reasons))
          puts format('global reject reasons : %s', compact_inspect(global_reasons))
          puts 'dispatch reason       : phase1_reject'
          puts 'polygon attempted     : false'
          puts 'fallback source       : fresh unique copy from untouched source'
          puts 'fallback engine       : production LocalVertexNormalizer.normalize'
          puts 'candidate lifetime    : enclosing operation is aborted'
          puts 'source mutation       : none'
          print_filter_summary(filter)
          puts '-' * 108

          result = nil
          operation_started = false
          begin
            operation_started = model.start_operation(
              'LVN Phase 1 reject fallback probe',
              true
            )
            raise 'SketchUp start_operation returned false' if operation_started == false

            fallback_candidate = fallback.copy_source_instance(
              source,
              model,
              phase1,
              'LVN_PHASE1_REJECT_FALLBACK_TEMP'
            )
            fallback_fresh = base.brep_signature(fallback_candidate) == source_signature
            definition_isolated = fallback_candidate.definition != source.definition

            fallback_started_at = monotonic_time
            fallback_report = LocalVertexNormalizer.normalize(
              fallback_candidate,
              phase1::DEFAULT_TOLERANCE_MM,
              manage_operation: false
            )
            fallback_elapsed_ms = (monotonic_time - fallback_started_at) * 1000.0

            fallback_manifold =
              fallback_candidate.valid? &&
              fallback_candidate.respond_to?(:manifold?) &&
              fallback_candidate.manifold? == true
            fallback_normalized = LocalVertexNormalizer.normalized?(
              fallback_candidate,
              phase1::DEFAULT_TOLERANCE_MM
            )
            fallback_report_complete =
              fallback_report.is_a?(Hash) &&
              fallback_report[:normalization_complete] == true &&
              fallback_report[:manifold] == true

            result = {
              status: :success,
              polygon_attempted: false,
              dispatch_reason: :phase1_reject,
              fallback_fresh: fallback_fresh,
              definition_isolated: definition_isolated,
              fallback_report: fallback_report,
              fallback_report_complete: fallback_report_complete,
              fallback_manifold: fallback_manifold,
              fallback_normalized: fallback_normalized,
              fallback_elapsed_ms: fallback_elapsed_ms
            }
          rescue StandardError => error
            result = {
              status: :error,
              polygon_attempted: false,
              dispatch_reason: :phase1_reject,
              error: "#{error.class}: #{error.message}",
              backtrace: Array(error.backtrace).first(14)
            }
          ensure
            if operation_started
              aborted = model.abort_operation
              raise 'SketchUp abort_operation returned false' if aborted == false
            end
          end

          source_restored = base.brep_signature(source) == source_signature
          root_restored = fallback.model_root_signature(model) == root_before
          selection_restored = fallback.restore_selection(model, original_selection)

          print_result(
            result,
            source_restored,
            root_restored,
            selection_restored
          )

          success?(
            result,
            source_restored,
            root_restored,
            selection_restored
          )
        rescue StandardError => error
          warn "[LVN PHASE1 REJECT FALLBACK PHASE 5] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(14).join("\n")
          false
        ensure
          fallback.restore_selection(model, original_selection) if
            defined?(fallback) && fallback && defined?(model) && model &&
            defined?(original_selection) && original_selection
        end

        def find_source(model, phase1)
          filter = Hash.new(0)
          candidates = []

          phase1.selected_entities(model).each do |entity|
            unless entity.parent == model
              filter[:not_top_level] += 1
              next
            end

            feasibility = phase1.analyze_entity(entity)
            if feasibility[:directly_preservable]
              filter[:phase1_accept] += 1
              next
            end

            candidates << [
              entity,
              feasibility,
              entity.definition.entities.grep(Sketchup::Face).count(&:valid?)
            ]
          rescue StandardError
            filter[:filter_errors] += 1
          end

          filter[:eligible] = candidates.length
          selected = candidates.min_by do |entity, feasibility, face_count|
            [
              face_count,
              feasibility.dig(:faces, :unsafe).to_i,
              Array(feasibility.dig(:global, :reasons)).length,
              phase1.persistent_id(entity).to_i
            ]
          end
          return [nil, nil, filter] unless selected

          [selected[0], selected[1], filter]
        end

        def success?(result, source_restored, root_restored, selection_restored)
          result[:status] == :success &&
            result[:polygon_attempted] == false &&
            result[:dispatch_reason] == :phase1_reject &&
            result[:fallback_fresh] &&
            result[:definition_isolated] &&
            result[:fallback_report_complete] &&
            result[:fallback_manifold] &&
            result[:fallback_normalized] &&
            source_restored &&
            root_restored &&
            selection_restored
        end

        def print_result(result, source_restored, root_restored, selection_restored)
          if result[:status] == :error
            puts 'fallback status       : ERROR'
            puts format('fallback error        : %s', result[:error])
            Array(result[:backtrace]).each { |line| puts "  #{line}" }
            puts format('polygon attempted     : %s', result[:polygon_attempted])
            puts format('dispatch reason       : %s', result[:dispatch_reason].inspect)
            puts format('source restored       : %s', source_restored)
            puts format('model root restored   : %s', root_restored)
            puts format('selection restored    : %s', selection_restored)
            puts 'result                : FAIL'
            puts '=' * 108
            return
          end

          report = result[:fallback_report]
          puts format('polygon attempted     : %s', result[:polygon_attempted])
          puts format('dispatch reason       : %s', result[:dispatch_reason].inspect)
          puts format('fallback copy fresh   : %s', result[:fallback_fresh])
          puts format('definition isolated   : %s', result[:definition_isolated])
          puts format('fallback report complete: %s', result[:fallback_report_complete])
          puts format('fallback manifold     : %s', result[:fallback_manifold])
          puts format('fallback normalized   : %s', result[:fallback_normalized])
          puts format(
            'fallback strategy     : %s',
            report.is_a?(Hash) ? report[:normalization_strategy].inspect : 'n/a'
          )
          puts format(
            'fallback grid residual: %s mm',
            report.is_a?(Hash) ? report[:max_grid_residual_mm].inspect : 'n/a'
          )
          puts format('fallback elapsed      : %.3f ms', result[:fallback_elapsed_ms])
          puts format('source restored       : %s', source_restored)
          puts format('model root restored   : %s', root_restored)
          puts format('selection restored    : %s', selection_restored)
          puts format(
            'result                : %s',
            success?(result, source_restored, root_restored, selection_restored) ?
              'PASS' : 'FAIL'
          )
          puts '=' * 108
        end

        def print_filter_summary(filter)
          puts 'filter summary:'
          keys = %i[
            phase1_accept
            not_top_level
            filter_errors
          ]
          shown = false
          keys.each do |key|
            count = filter[key].to_i
            next unless count.positive?

            puts format('  %-38s %6d', key, count)
            shown = true
          end
          puts '  none' unless shown
          puts format('eligible              : %d', filter[:eligible].to_i)
        end

        def compact_inspect(value)
          text = value.inspect
          text.length > 1200 ? "#{text[0, 1200]}..." : text
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnPolygonPhase1RejectFallbackProbe.run
