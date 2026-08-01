# frozen_string_literal: true

require 'stringio'
require_relative 'lvn_polygon_candidate_reconstruction_probe'

# Load the validated inner-loop reconstruction helper without triggering its
# default selected-source run. Only selection and stdout are temporarily changed.
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

# Phase 3 single-solid exact hard-gate probe.
#
# Reconstructs one Phase 1-safe polygon candidate on a temporary unique copy,
# then invokes the unchanged production LocalVertexNormalizer triangle snapshot,
# collapsed-triangle cleanup, and exact normalized-mesh validation methods.
# It does not run surface equivalence (Phase 4) or production normalize/fallback.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateExactHardGateProbe
        MAXIMUM_INITIAL_SOURCE_FACES = 250

        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          hole = LvnPolygonCandidateHoleReconstructionProbe
          original_selection = model.selection.to_a

          source, feasibility, snapshot, filter = find_source(
            model,
            phase1,
            base
          )
          unless source
            puts '[LVN POLYGON EXACT GATE PHASE 3] No eligible selected source found.'
            print_filter_summary(filter)
            return false
          end

          source_signature = base.brep_signature(source)
          source_counts = base.geometry_counts(source)
          source_volume_mm3 = base.solid_volume_mm3(source)
          order = base.connected_face_order(snapshot[:faces])
          inner_loop_count = snapshot[:faces].sum do |record|
            record[:inner_loops].length
          end

          puts '=' * 100
          puts ' LVN Polygon-Preserving Candidate — Phase 3 Existing Exact Hard Gate'
          puts '=' * 100
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
            'source Face loops     : %d outer / %d inner',
            snapshot[:faces].length,
            inner_loop_count
          )
          puts format('grid tolerance        : %.6f mm', phase1::DEFAULT_TOLERANCE_MM)
          puts format(
            'reconstruction path   : %s',
            inner_loop_count.positive? ? 'validated inner-loop polygon path' : 'validated no-hole polygon path'
          )
          puts 'hard gate snapshot    : production normalized_triangle_snapshot'
          puts 'hard gate cleanup     : production discard_collapsed_triangle_records'
          puts 'hard gate validation  : production validate_normalized_triangle_mesh!'
          puts 'surface equivalence   : not run (Phase 4)'
          puts 'production normalize  : not called'
          puts 'candidate lifetime    : enclosing operation is aborted'
          puts 'source mutation       : none'
          print_filter_summary(filter)
          puts '-' * 100

          result = nil
          operation_started = false
          begin
            operation_started = model.start_operation(
              'LVN polygon exact hard gate probe',
              true
            )
            raise 'SketchUp start_operation returned false' if operation_started == false

            candidate = EntityCopyHelper.copy_instance(
              source: source,
              target_entities: model.entities,
              transformation: source.transformation,
              convert_to_group: :source_group,
              make_unique: true,
              copy_attributes: %i[name material layer visible]
            )
            raise 'Candidate copy is invalid' unless candidate&.valid?
            if candidate.definition == source.definition
              raise 'Candidate copy did not receive a unique definition'
            end

            candidate.name = "LVN_POLYGON_EXACT_GATE_TEMP_#{phase1.persistent_id(source)}" if
              candidate.respond_to?(:name=)

            candidate_entities = candidate.definition.entities
            base.erase_geometry(candidate_entities)
            rebuild = if inner_loop_count.positive?
                        hole.rebuild_polygon_faces_with_holes(
                          candidate_entities,
                          order,
                          phase1,
                          base
                        )
                      else
                        base.rebuild_polygon_faces(candidate_entities, order)
                      end

            phase2 = base.inspect_candidate(
              candidate,
              source_counts,
              source_volume_mm3,
              snapshot,
              rebuild,
              phase1
            )
            unless phase2[:candidate_acceptable]
              raise "Phase 2 candidate rejected: #{phase2[:reasons].inspect}"
            end

            result = run_existing_exact_hard_gate(
              candidate,
              phase2,
              rebuild,
              phase1
            )
          rescue StandardError => error
            result = {
              status: :error,
              hard_gate_passed: false,
              error: "#{error.class}: #{error.message}",
              backtrace: Array(error.backtrace).first(12)
            }
          ensure
            if operation_started
              aborted = model.abort_operation
              raise 'SketchUp abort_operation returned false' if aborted == false
            end
          end

          source_restored = base.brep_signature(source) == source_signature
          restore_selection(model, original_selection)
          selection_restored = selection_signature(model.selection.to_a) ==
            selection_signature(original_selection)

          print_result(result, source_restored, selection_restored)
          result[:status] == :success &&
            result[:hard_gate_passed] &&
            source_restored &&
            selection_restored
        rescue StandardError => error
          warn "[LVN POLYGON EXACT GATE PHASE 3] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(12).join("\n")
          false
        ensure
          restore_selection(model, original_selection) if model && original_selection
        end

        def run_existing_exact_hard_gate(candidate, phase2, rebuild, phase1)
          normalizer = LocalVertexNormalizer.new(phase1::DEFAULT_TOLERANCE_MM)
          duplicate_diagnostics = {}

          started_at = monotonic_time
          triangle_records = normalizer.send(
            :normalized_triangle_snapshot,
            candidate.definition.entities,
            nil,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :polygon_candidate_phase3_exact_gate
          )
          snapshot_elapsed_ms = (monotonic_time - started_at) * 1000.0
          snapshot_triangle_count = triangle_records.length

          cleanup_started_at = monotonic_time
          triangle_records, cleanup = normalizer.send(
            :discard_collapsed_triangle_records,
            triangle_records
          )
          cleanup_elapsed_ms = (monotonic_time - cleanup_started_at) * 1000.0

          validation_started_at = monotonic_time
          validation = normalizer.send(
            :validate_normalized_triangle_mesh!,
            triangle_records
          )
          validation_elapsed_ms = (monotonic_time - validation_started_at) * 1000.0

          {
            status: :success,
            hard_gate_passed: true,
            phase2: phase2,
            rebuild: rebuild,
            snapshot_triangle_count: snapshot_triangle_count,
            validated_triangle_count: triangle_records.length,
            cleanup: cleanup,
            duplicate_diagnostics: duplicate_diagnostics,
            validation: validation,
            snapshot_elapsed_ms: snapshot_elapsed_ms,
            cleanup_elapsed_ms: cleanup_elapsed_ms,
            validation_elapsed_ms: validation_elapsed_ms,
            total_hard_gate_elapsed_ms:
              snapshot_elapsed_ms + cleanup_elapsed_ms + validation_elapsed_ms
          }
        end

        def find_source(model, phase1, base)
          filter = Hash.new(0)
          candidates = []

          phase1.selected_entities(model).each do |entity|
            unless entity.parent == model
              filter[:not_top_level] += 1
              next
            end

            face_count = entity.definition.entities.grep(Sketchup::Face).count(&:valid?)
            if face_count > MAXIMUM_INITIAL_SOURCE_FACES
              filter[:above_initial_face_limit] += 1
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

            candidates << [entity, feasibility, snapshot, face_count]
          rescue StandardError
            filter[:filter_errors] += 1
          end

          filter[:eligible] = candidates.length
          selected = candidates.min_by do |entity, _feasibility, snapshot, face_count|
            [
              face_count,
              snapshot[:faces].sum { |record| record[:inner_loops].length },
              phase1.persistent_id(entity).to_i
            ]
          end
          return [nil, nil, nil, filter] unless selected

          [selected[0], selected[1], selected[2], filter]
        end

        def print_result(result, source_restored, selection_restored)
          if result[:status] == :error
            puts format('hard gate passed      : false')
            puts format('hard gate error       : %s', result[:error])
            Array(result[:backtrace]).each { |line| puts "  #{line}" }
            puts format('source restored       : %s', source_restored)
            puts format('selection restored    : %s', selection_restored)
            puts 'result                : FAIL'
            puts '=' * 100
            return
          end

          phase2 = result[:phase2]
          validation = result[:validation]
          cleanup = result[:cleanup]

          puts format(
            'candidate geometry    : F=%d E=%d V=%d manifold=%s',
            phase2.dig(:candidate_counts, :faces),
            phase2.dig(:candidate_counts, :edges),
            phase2.dig(:candidate_counts, :vertices),
            phase2.dig(:candidate_counts, :manifold).inspect
          )
          puts format(
            'requested/created Face: %d/%d',
            result.dig(:rebuild, :requested_faces),
            result.dig(:rebuild, :created_faces)
          )
          puts format('Phase 2 acceptable    : %s', phase2[:candidate_acceptable])
          puts format('snapshot triangles    : %d', result[:snapshot_triangle_count])
          puts format('validated triangles   : %d', result[:validated_triangle_count])
          puts format(
            'collapsed cleanup     : coincident=%d collinear=%d duplicate=%d',
            cleanup[:removed_coincident_triangle_count].to_i,
            cleanup[:removed_collinear_triangle_count].to_i,
            cleanup[:removed_duplicate_triangle_count].to_i
          )
          puts format(
            'exact mesh inventory  : V=%s E=%s T=%s components=%s',
            validation[:vertex_count].inspect,
            validation[:edge_count].inspect,
            validation[:triangle_count].inspect,
            validation[:component_count].inspect
          )
          puts format(
            'intersection pairs    : %s',
            validation[:tested_triangle_pairs].inspect
          )
          puts format(
            'duplicate triangles   : %d',
            result[:duplicate_diagnostics][:duplicate_count].to_i
          )
          puts format('snapshot elapsed      : %.3f ms', result[:snapshot_elapsed_ms])
          puts format('cleanup elapsed       : %.3f ms', result[:cleanup_elapsed_ms])
          puts format('validation elapsed    : %.3f ms', result[:validation_elapsed_ms])
          puts format('hard gate elapsed     : %.3f ms', result[:total_hard_gate_elapsed_ms])
          puts 'hard gate passed      : true'
          puts format('source restored       : %s', source_restored)
          puts format('selection restored    : %s', selection_restored)
          puts format(
            'result                : %s',
            source_restored && selection_restored ? 'PASS' : 'FAIL'
          )
          puts '=' * 100
        end

        def print_filter_summary(filter)
          puts 'filter summary:'
          keys = %i[
            above_initial_face_limit
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
          puts format('eligible              : %d', filter[:eligible].to_i)
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
  LvnPolygonCandidateExactHardGateProbe.run
