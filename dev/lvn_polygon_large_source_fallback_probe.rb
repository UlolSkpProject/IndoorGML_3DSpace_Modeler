# frozen_string_literal: true

require 'stringio'

# Load the validated whole-solid fallback helper without triggering its default
# selected-source execution. Selection and console streams are restored exactly.
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

# Phase 5 large-source whole-solid fallback probe.
#
# The source-size guard is intentionally evaluated before Phase 1 feasibility.
# A top-level source with at least MINIMUM_LARGE_SOURCE_FACES is routed directly
# to the unchanged production LocalVertexNormalizer on a fresh unique copy. The
# polygon path and Phase 1 analysis are never attempted for the chosen source.
# The enclosing operation is aborted, preserving source geometry and model root.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonLargeSourceFallbackProbe
        MINIMUM_LARGE_SOURCE_FACES = 1_000

        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          fallback = LvnPolygonWholeSolidFallbackProbe
          original_selection = model.selection.to_a
          root_before = fallback.model_root_signature(model)

          source, filter, search_scope = find_largest_source(model, phase1)
          unless source
            puts '[LVN LARGE SOURCE FALLBACK PHASE 5] No source reached the size guard.'
            puts format('source search scope   : %s', search_scope_label(search_scope))
            puts format('searched source pool  : %d', filter[:pool_entities].to_i)
            print_filter_summary(filter)
            return false
          end

          source_signature = base.brep_signature(source)
          source_counts = base.geometry_counts(source)

          puts '=' * 108
          puts ' LVN Polygon-Preserving Candidate — Phase 5 Large-Source Whole-Solid Fallback'
          puts '=' * 108
          puts format('selected solids       : %d', original_selection.length)
          puts format('source search scope   : %s', search_scope_label(search_scope))
          puts format('searched source pool  : %d', filter[:pool_entities].to_i)
          puts format('eligible large solids : %d', filter[:eligible].to_i)
          puts format('size guard Faces      : >= %d', MINIMUM_LARGE_SOURCE_FACES)
          puts format('source                : %s', phase1.entity_label(source))
          puts format(
            'source geometry       : F=%d E=%d V=%d manifold=%s',
            source_counts[:faces],
            source_counts[:edges],
            source_counts[:vertices],
            source_counts[:manifold].inspect
          )
          puts 'dispatch order        : source Face count before Phase 1 feasibility'
          puts 'dispatch reason       : source_face_limit'
          puts 'Phase 1 attempted     : false'
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
              'LVN large-source whole-solid fallback probe',
              true
            )
            raise 'SketchUp start_operation returned false' if operation_started == false

            fallback_candidate = fallback.copy_source_instance(
              source,
              model,
              phase1,
              'LVN_LARGE_SOURCE_FALLBACK_TEMP'
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
              dispatch_reason: :source_face_limit,
              phase1_attempted: false,
              polygon_attempted: false,
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
              dispatch_reason: :source_face_limit,
              phase1_attempted: false,
              polygon_attempted: false,
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

          print_result(result, source_restored, root_restored, selection_restored)
          success?(result, source_restored, root_restored, selection_restored)
        rescue StandardError => error
          warn "[LVN LARGE SOURCE FALLBACK PHASE 5] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(14).join("\n")
          false
        ensure
          fallback.restore_selection(model, original_selection) if
            defined?(fallback) && fallback && defined?(model) && model &&
            defined?(original_selection) && original_selection
        end

        def find_largest_source(model, phase1)
          selected = phase1.selected_entities(model)
          selected_candidates, selected_filter = evaluate_pool(selected, model)
          unless selected_candidates.empty?
            selected_filter[:pool_entities] = selected.length
            return [largest_candidate(selected_candidates), selected_filter, :selection]
          end

          root_pool = top_level_instances(model)
          root_candidates, root_filter = evaluate_pool(root_pool, model)
          root_filter[:pool_entities] = root_pool.length
          root_filter[:selection_entities] = selected.length
          root_filter[:selection_had_no_eligible] = 1
          [largest_candidate(root_candidates), root_filter, :model_root_fallback]
        end

        def evaluate_pool(pool, model)
          filter = Hash.new(0)
          candidates = []

          Array(pool).each do |entity|
            unless entity.respond_to?(:valid?) && entity.valid?
              filter[:invalid_entity] += 1
              next
            end
            unless entity.parent == model
              filter[:not_top_level] += 1
              next
            end

            face_count = entity.definition.entities.grep(Sketchup::Face).count(&:valid?)
            if face_count < MINIMUM_LARGE_SOURCE_FACES
              filter[:below_face_limit] += 1
              next
            end

            candidates << { entity: entity, face_count: face_count }
          rescue StandardError
            filter[:filter_errors] += 1
          end

          filter[:eligible] = candidates.length
          [candidates, filter]
        end

        def largest_candidate(candidates)
          selected = Array(candidates).max_by do |candidate|
            [candidate[:face_count], entity_identity(candidate[:entity])]
          end
          selected && selected[:entity]
        end

        def top_level_instances(model)
          model.entities.to_a.select do |entity|
            entity.respond_to?(:definition) &&
              entity.respond_to?(:valid?) &&
              entity.valid?
          end
        end

        def success?(result, source_restored, root_restored, selection_restored)
          result[:status] == :success &&
            result[:dispatch_reason] == :source_face_limit &&
            result[:phase1_attempted] == false &&
            result[:polygon_attempted] == false &&
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
          else
            report = result[:fallback_report]
            puts format('Phase 1 attempted     : %s', result[:phase1_attempted])
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
          end

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
            below_face_limit
            invalid_entity
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
        end

        def search_scope_label(scope)
          case scope
          when :selection
            'current selection'
          when :model_root_fallback
            'model root fallback'
          else
            scope.to_s
          end
        end

        def entity_identity(entity)
          if entity.respond_to?(:persistent_id)
            entity.persistent_id.to_i
          else
            entity.object_id
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
  LvnPolygonLargeSourceFallbackProbe.run
