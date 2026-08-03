# frozen_string_literal: true

require 'stringio'
require_relative 'lvn_polygon_candidate_reconstruction_probe'

# Load the validated inner-loop probe without triggering its default selected-
# source execution. This wrapper temporarily clears and restores selection only
# while the dependency file is evaluated; no model geometry is modified.
dependency_model = Sketchup.active_model
dependency_selection = dependency_model.selection.to_a
dependency_stdout = $stdout
begin
  dependency_model.selection.clear
  $stdout = StringIO.new
  require_relative 'lvn_polygon_candidate_hole_reconstruction_probe'
ensure
  $stdout = dependency_stdout
  dependency_model.selection.clear
  dependency_selection.each do |entity|
    dependency_model.selection.add(entity) if entity.respond_to?(:valid?) && entity.valid?
  end
end

# Phase 2 large-solid stress reconstruction probe.
#
# Searches the current selection first. If no eligible large source is found,
# it falls back to all top-level Group / ComponentInstance entities in the model.
# The source loop topology selects the already validated no-hole or inner-loop
# reconstruction path. Thousands of Face-order lines are suppressed and only
# final stress diagnostics are reported. The reused probe aborts its candidate
# operation, preserving the original source geometry.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateStressReconstructionProbe
        MINIMUM_SOURCE_FACES = 1_000
        FAILURE_LOG_TAIL_LINES = 40
        DIAGNOSTIC_PREFIXES = [
          'inner loops carved',
          'inner add deltas',
          'candidate geometry',
          'requested/created Face',
          'boundary edges',
          'overused edges',
          'Face loop exact',
          'Phase 1 recheck',
          'volume delta',
          'candidate reasons',
          'candidate acceptable',
          'source restored',
          'result'
        ].freeze

        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          hole = LvnPolygonCandidateHoleReconstructionProbe
          original_selection = model.selection.to_a

          candidate, filter, search_scope = find_largest_source(model, phase1, base)
          unless candidate
            puts '[LVN POLYGON STRESS PHASE 2] No eligible large source found.'
            puts format('source search scope   : %s', search_scope_label(search_scope))
            puts format('searched source pool  : %d', filter[:pool_entities].to_i)
            print_filter_summary(filter)
            return false
          end

          source = candidate[:entity]
          source_counts = base.geometry_counts(source)
          source_signature = base.brep_signature(source)
          inner_loop_count = candidate[:inner_loop_count]
          reconstruction_probe = inner_loop_count.positive? ? hole : base
          reconstruction_path = if inner_loop_count.positive?
                                  'validated inner-loop polygon probe'
                                else
                                  'validated no-hole polygon probe'
                                end

          puts '=' * 100
          puts ' LVN Polygon-Preserving Candidate Reconstruction — Phase 2 Large-Solid Stress'
          puts '=' * 100
          puts format('selected solids       : %d', original_selection.length)
          puts format('source search scope   : %s', search_scope_label(search_scope))
          puts format('searched source pool  : %d', filter[:pool_entities].to_i)
          puts format('eligible large solids : %d', filter[:eligible])
          puts format('eligible no-hole      : %d', filter[:eligible_no_holes])
          puts format('eligible inner-loop   : %d', filter[:eligible_with_inner_loops])
          puts format('minimum source Faces  : %d', MINIMUM_SOURCE_FACES)
          puts format('source                : %s', phase1.entity_label(source))
          puts format(
            'source geometry       : F=%d E=%d V=%d manifold=%s',
            source_counts[:faces],
            source_counts[:edges],
            source_counts[:vertices],
            source_counts[:manifold].inspect
          )
          puts format(
            'source Face loops     : %d outer / %d inner',
            candidate[:snapshot][:faces].length,
            inner_loop_count
          )
          puts format('reconstruction path   : %s', reconstruction_path)
          puts 'Face-order output     : suppressed'
          puts 'candidate lifetime    : enclosing operation is aborted'
          puts 'source mutation       : none'
          puts 'production LVN calls  : none'
          print_filter_summary(filter)
          puts '-' * 100

          output = StringIO.new
          passed = false
          elapsed_ms = nil
          begin
            model.selection.clear
            model.selection.add(source)
            started_at = monotonic_time
            passed = capture_stdout(output) { reconstruction_probe.run }
            elapsed_ms = (monotonic_time - started_at) * 1000.0
          ensure
            restore_selection(model, original_selection)
          end

          source_restored = base.brep_signature(source) == source_signature
          selection_restored = selection_signature(model.selection.to_a) ==
            selection_signature(original_selection)

          print_diagnostics(output.string, passed)
          puts format('stress elapsed        : %.3f ms', elapsed_ms) if elapsed_ms
          puts format('source restored       : %s', source_restored)
          puts format('selection restored    : %s', selection_restored)
          puts format(
            'result                : %s',
            passed && source_restored && selection_restored ? 'PASS' : 'FAIL'
          )
          puts '=' * 100

          passed && source_restored && selection_restored
        rescue StandardError => error
          warn "[LVN POLYGON STRESS PHASE 2] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(10).join("\n")
          false
        ensure
          restore_selection(model, original_selection) if model && original_selection
        end

        def find_largest_source(model, phase1, base)
          selected = phase1.selected_entities(model)
          selected_candidates, selected_filter = evaluate_pool(
            selected,
            model,
            phase1,
            base
          )

          unless selected_candidates.empty?
            selected_filter[:pool_entities] = selected.length
            return [
              largest_candidate(selected_candidates, phase1),
              selected_filter,
              :selection
            ]
          end

          root_pool = top_level_instances(model)
          root_candidates, root_filter = evaluate_pool(
            root_pool,
            model,
            phase1,
            base
          )
          root_filter[:pool_entities] = root_pool.length
          root_filter[:selection_entities] = selected.length
          root_filter[:selection_had_no_eligible] = 1

          [
            largest_candidate(root_candidates, phase1),
            root_filter,
            :model_root_fallback
          ]
        end

        def evaluate_pool(pool, model, phase1, base)
          filter = Hash.new(0)
          candidates = []

          Array(pool).each do |entity|
            unless entity.parent == model
              filter[:not_top_level] += 1
              next
            end

            face_count = entity.definition.entities.grep(Sketchup::Face).count(&:valid?)
            if face_count < MINIMUM_SOURCE_FACES
              filter[:below_face_limit] += 1
              next
            end

            feasibility = phase1.analyze_entity(entity)
            unless feasibility[:directly_preservable]
              filter[:phase1_reject] += 1
              next
            end

            snapshot = base.snapshot_source(entity, phase1)
            if snapshot[:non_geometry_entities].positive?
              filter[:non_geometry_entities] += 1
              next
            end

            inner_loop_count = snapshot[:faces].sum do |record|
              record[:inner_loops].length
            end
            if inner_loop_count.positive?
              filter[:eligible_with_inner_loops] += 1
            else
              filter[:eligible_no_holes] += 1
            end

            candidates << {
              entity: entity,
              face_count: face_count,
              snapshot: snapshot,
              inner_loop_count: inner_loop_count
            }
          rescue StandardError
            filter[:filter_errors] += 1
          end

          filter[:eligible] = candidates.length
          [candidates, filter]
        end

        def largest_candidate(candidates, phase1)
          candidates.max_by do |candidate|
            [
              candidate[:face_count],
              phase1.persistent_id(candidate[:entity]).to_i
            ]
          end
        end

        def top_level_instances(model)
          model.entities.to_a.select do |entity|
            entity.respond_to?(:definition) &&
              entity.respond_to?(:valid?) &&
              entity.valid?
          end
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

        def capture_stdout(target)
          previous = $stdout
          $stdout = target
          yield
        ensure
          $stdout = previous
        end

        def print_diagnostics(output, passed)
          lines = output.lines.map(&:rstrip)
          diagnostics = lines.select do |line|
            stripped = line.strip
            DIAGNOSTIC_PREFIXES.any? { |prefix| stripped.start_with?(prefix) }
          end

          if passed
            diagnostics.each { |line| puts line }
            return
          end

          puts 'single-probe diagnostic tail:'
          lines.last(FAILURE_LOG_TAIL_LINES).each { |line| puts "  #{line}" }
        end

        def print_filter_summary(filter)
          puts 'filter summary:'
          keys = %i[
            below_face_limit
            phase1_reject
            non_geometry_entities
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

        def restore_selection(model, entities)
          return unless model

          model.selection.clear
          Array(entities).each do |entity|
            model.selection.add(entity) if entity.respond_to?(:valid?) && entity.valid?
          end
        rescue StandardError
          nil
        end

        def selection_signature(entities)
          Array(entities).filter_map do |entity|
            next unless entity.respond_to?(:valid?) && entity.valid?

            entity.respond_to?(:persistent_id) ? entity.persistent_id : entity.object_id
          end.sort
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnPolygonCandidateStressReconstructionProbe.run
