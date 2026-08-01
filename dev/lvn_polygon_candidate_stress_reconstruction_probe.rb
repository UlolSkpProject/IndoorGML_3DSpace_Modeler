# frozen_string_literal: true

require 'stringio'
require_relative 'lvn_polygon_candidate_reconstruction_probe'

# Phase 2 large-solid stress reconstruction probe.
#
# Selects the largest Phase 1-safe, no-hole source from the current selection,
# runs the already validated single-solid polygon reconstruction path unchanged,
# suppresses the thousands of Face-order lines, and reports only final stress
# diagnostics. The candidate operation is aborted by the reused single probe.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateStressReconstructionProbe
        MINIMUM_SOURCE_FACES = 1_000
        FAILURE_LOG_TAIL_LINES = 40
        DIAGNOSTIC_PREFIXES = [
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
          original_selection = model.selection.to_a

          source, filter = find_largest_source(model, phase1, base)
          unless source
            puts '[LVN POLYGON STRESS PHASE 2] No eligible large source found in selection.'
            print_filter_summary(filter)
            return false
          end

          source_counts = base.geometry_counts(source)
          source_signature = base.brep_signature(source)

          puts '=' * 100
          puts ' LVN Polygon-Preserving Candidate Reconstruction — Phase 2 Large-Solid Stress'
          puts '=' * 100
          puts format('selected solids       : %d', original_selection.length)
          puts format('eligible large solids : %d', filter[:eligible])
          puts format('minimum source Faces  : %d', MINIMUM_SOURCE_FACES)
          puts format('source                : %s', phase1.entity_label(source))
          puts format(
            'source geometry       : F=%d E=%d V=%d manifold=%s',
            source_counts[:faces],
            source_counts[:edges],
            source_counts[:vertices],
            source_counts[:manifold].inspect
          )
          puts 'reconstruction path   : unchanged single-solid polygon probe'
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
            passed = capture_stdout(output) { base.run }
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
          filter = Hash.new(0)
          candidates = []

          phase1.selected_entities(model).each do |entity|
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
            if snapshot[:faces].any? { |record| !record[:inner_loops].empty? }
              filter[:inner_loops] += 1
              next
            end

            candidates << [entity, face_count]
          rescue StandardError
            filter[:filter_errors] += 1
          end

          filter[:eligible] = candidates.length
          source = candidates.max_by do |entity, face_count|
            [face_count, phase1.persistent_id(entity).to_i]
          end&.first
          [source, filter]
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
            inner_loops
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
