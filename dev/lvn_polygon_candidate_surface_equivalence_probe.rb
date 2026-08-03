# frozen_string_literal: true

require 'stringio'

# Load the Phase 3 single-solid probe without triggering its default auto-run.
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

# Phase 4 single-solid surface-equivalence probe.
#
# The expected surface is produced with the unchanged production pre-rebuild
# triangle pipeline, including target grid normalization and supported sliver
# handling. A temporary polygon candidate is then reconstructed and validated,
# and production verify_normalized_surface_equivalence! compares the two exact
# normalized triangle surfaces. The operation is always aborted.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateSurfaceEquivalenceProbe
        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          hole = LvnPolygonCandidateHoleReconstructionProbe
          exact = LvnPolygonCandidateExactHardGateProbe
          original_selection = model.selection.to_a

          source, _feasibility, snapshot, filter = exact.find_source(
            model,
            phase1,
            base
          )
          unless source
            puts '[LVN POLYGON SURFACE PHASE 4] No eligible selected source found.'
            exact.print_filter_summary(filter)
            return false
          end

          source_signature = base.brep_signature(source)
          source_counts = base.geometry_counts(source)
          source_volume_mm3 = base.solid_volume_mm3(source)
          order = base.connected_face_order(snapshot[:faces])
          inner_loop_count = snapshot[:faces].sum do |record|
            record[:inner_loops].length
          end

          normalizer = LocalVertexNormalizer.new(phase1::DEFAULT_TOLERANCE_MM)
          expected_started_at = monotonic_time
          expected = build_expected_target_surface(normalizer, source)
          expected_elapsed_ms = (monotonic_time - expected_started_at) * 1000.0

          puts '=' * 104
          puts ' LVN Polygon-Preserving Candidate — Phase 4 Production Surface Equivalence'
          puts '=' * 104
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
            inner_loop_count.positive? ?
              'validated inner-loop polygon path' :
              'validated no-hole polygon path'
          )
          puts 'expected surface      : unchanged production pre-rebuild target pipeline'
          puts 'candidate hard gate   : unchanged production exact mesh validation'
          puts 'surface equivalence   : production verify_normalized_surface_equivalence!'
          puts 'production normalize  : not called'
          puts 'candidate lifetime    : enclosing operation is aborted'
          puts 'source mutation       : none'
          exact.print_filter_summary(filter)
          puts '-' * 104

          result = nil
          operation_started = false
          begin
            operation_started = model.start_operation(
              'LVN polygon surface equivalence probe',
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

            candidate.name = "LVN_POLYGON_SURFACE_TEMP_#{phase1.persistent_id(source)}" if
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

            candidate_gate_started_at = monotonic_time
            candidate_surface = snapshot_and_validate_candidate(
              normalizer,
              candidate.definition.entities
            )
            candidate_gate_elapsed_ms =
              (monotonic_time - candidate_gate_started_at) * 1000.0

            equivalence_started_at = monotonic_time
            equivalence = normalizer.send(
              :verify_normalized_surface_equivalence!,
              expected[:triangles],
              candidate_surface[:triangles]
            )
            equivalence_elapsed_ms =
              (monotonic_time - equivalence_started_at) * 1000.0

            result = {
              status: :success,
              surface_equivalent: true,
              phase2: phase2,
              rebuild: rebuild,
              expected: expected,
              candidate_surface: candidate_surface,
              equivalence: equivalence,
              expected_elapsed_ms: expected_elapsed_ms,
              candidate_gate_elapsed_ms: candidate_gate_elapsed_ms,
              equivalence_elapsed_ms: equivalence_elapsed_ms,
              total_phase4_elapsed_ms:
                expected_elapsed_ms +
                candidate_gate_elapsed_ms +
                equivalence_elapsed_ms
            }
          rescue StandardError => error
            result = {
              status: :error,
              surface_equivalent: false,
              expected: expected,
              expected_elapsed_ms: expected_elapsed_ms,
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
          restore_selection(model, original_selection)
          selection_restored = selection_signature(model.selection.to_a) ==
            selection_signature(original_selection)

          print_result(result, source_restored, selection_restored)
          result[:status] == :success &&
            result[:surface_equivalent] &&
            source_restored &&
            selection_restored
        rescue StandardError => error
          warn "[LVN POLYGON SURFACE PHASE 4] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(14).join("\n")
          false
        ensure
          restore_selection(model, original_selection) if model && original_selection
        end

        def build_expected_target_surface(normalizer, source)
          entities = source.definition.entities
          source_duplicate_diagnostics = {}
          source_conforming_duplicate_diagnostics = {}
          grid_conforming_duplicate_diagnostics = {}

          source_triangles = normalizer.send(:triangle_snapshot, entities)
          source_triangles = normalizer.send(
            :conforming_triangle_snapshot,
            source_triangles,
            coordinate_space: :source,
            duplicate_diagnostics: source_conforming_duplicate_diagnostics
          )
          source_triangles, source_altitude_sliver = normalizer.send(
            :collapse_source_altitude_sliver_triangles,
            source_triangles
          )
          source_triangles = normalizer.send(
            :conforming_triangle_snapshot,
            source_triangles,
            coordinate_space: :source,
            duplicate_diagnostics: source_conforming_duplicate_diagnostics
          )
          source_triangles, source_cleanup = normalizer.send(
            :discard_collapsed_triangle_records,
            source_triangles,
            coordinate_space: :source
          )

          target_triangles, target_collision_cleanup = normalizer.send(
            :normalize_triangle_records_allowing_collisions,
            source_triangles,
            nil,
            duplicate_diagnostics: source_duplicate_diagnostics
          )
          target_triangles, target_cleanup = normalizer.send(
            :discard_collapsed_triangle_records,
            target_triangles
          )
          normalizer.send(:validate_normalized_triangle_shapes!, target_triangles)

          target_triangles = normalizer.send(
            :conforming_triangle_snapshot,
            target_triangles,
            duplicate_diagnostics: grid_conforming_duplicate_diagnostics
          )
          target_triangles, conforming_cleanup = normalizer.send(
            :discard_collapsed_triangle_records,
            target_triangles
          )
          raise 'Expected target surface contains no triangles' if target_triangles.empty?

          baseline_inventory = normalizer.send(
            :triangle_mesh_inventory,
            target_triangles
          )
          short_edge_plan = normalizer.send(
            :short_edge_sliver_collapse_plan,
            entities,
            nil
          )
          target_triangles, short_edge_repair = normalizer.send(
            :collapse_short_edge_sliver_triangles,
            target_triangles,
            short_edge_plan,
            baseline_inventory
          )
          post_sliver_cleanup = nil
          if short_edge_repair[:repairable]
            target_triangles, post_sliver_cleanup = normalizer.send(
              :discard_collapsed_triangle_records,
              target_triangles
            )
          end

          validation = normalizer.send(
            :validate_normalized_triangle_mesh!,
            target_triangles
          )
          normalizer.send(
            :validate_sliver_topology_when_comparable!,
            baseline_inventory,
            validation,
            short_edge_repair
          )

          {
            triangles: target_triangles,
            validation: validation,
            short_edge_plan: short_edge_plan,
            short_edge_repair: short_edge_repair,
            source_altitude_sliver: source_altitude_sliver,
            cleanup: {
              source: source_cleanup,
              target_collision: target_collision_cleanup,
              target: target_cleanup,
              conforming: conforming_cleanup,
              post_sliver: post_sliver_cleanup
            },
            duplicate_diagnostics: {
              source: source_duplicate_diagnostics,
              source_conforming: source_conforming_duplicate_diagnostics,
              grid_conforming: grid_conforming_duplicate_diagnostics
            }
          }
        end

        def snapshot_and_validate_candidate(normalizer, entities)
          duplicate_diagnostics = {}
          triangles = normalizer.send(
            :normalized_triangle_snapshot,
            entities,
            nil,
            duplicate_diagnostics: duplicate_diagnostics,
            snapshot_role: :polygon_candidate_phase4_surface_equivalence
          )
          snapshot_triangle_count = triangles.length
          triangles, cleanup = normalizer.send(
            :discard_collapsed_triangle_records,
            triangles
          )
          validation = normalizer.send(
            :validate_normalized_triangle_mesh!,
            triangles
          )
          {
            triangles: triangles,
            snapshot_triangle_count: snapshot_triangle_count,
            cleanup: cleanup,
            duplicate_diagnostics: duplicate_diagnostics,
            validation: validation
          }
        end

        def print_result(result, source_restored, selection_restored)
          if result[:status] == :error
            puts 'surface equivalent    : false'
            puts format('surface error         : %s', result[:error])
            Array(result[:backtrace]).each { |line| puts "  #{line}" }
            puts format('expected elapsed      : %.3f ms', result[:expected_elapsed_ms]) if
              result[:expected_elapsed_ms]
            puts format('source restored       : %s', source_restored)
            puts format('selection restored    : %s', selection_restored)
            puts 'result                : FAIL'
            puts '=' * 104
            return
          end

          expected = result[:expected]
          candidate = result[:candidate_surface]
          phase2 = result[:phase2]
          equivalence = result[:equivalence]

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
          puts format('expected triangles    : %d', expected[:triangles].length)
          puts format('candidate triangles   : %d', candidate[:triangles].length)
          puts format(
            'expected inventory    : V=%s E=%s T=%s components=%s',
            expected.dig(:validation, :vertex_count).inspect,
            expected.dig(:validation, :edge_count).inspect,
            expected.dig(:validation, :triangle_count).inspect,
            expected.dig(:validation, :component_count).inspect
          )
          puts format(
            'candidate inventory   : V=%s E=%s T=%s components=%s',
            candidate.dig(:validation, :vertex_count).inspect,
            candidate.dig(:validation, :edge_count).inspect,
            candidate.dig(:validation, :triangle_count).inspect,
            candidate.dig(:validation, :component_count).inspect
          )
          puts format(
            'expected sliver repair: repairable=%s repaired_faces=%d collapsed_vertices=%d',
            expected.dig(:short_edge_repair, :repairable).inspect,
            expected.dig(:short_edge_repair, :repaired_face_count).to_i,
            expected.dig(:short_edge_repair, :collapsed_vertex_count).to_i
          )
          puts format(
            'surface report        : %s',
            compact_inspect(equivalence)
          )
          puts format('expected elapsed      : %.3f ms', result[:expected_elapsed_ms])
          puts format('candidate gate elapsed: %.3f ms', result[:candidate_gate_elapsed_ms])
          puts format('equivalence elapsed   : %.3f ms', result[:equivalence_elapsed_ms])
          puts format('Phase 4 elapsed       : %.3f ms', result[:total_phase4_elapsed_ms])
          puts 'surface equivalent    : true'
          puts format('source restored       : %s', source_restored)
          puts format('selection restored    : %s', selection_restored)
          puts format(
            'result                : %s',
            source_restored && selection_restored ? 'PASS' : 'FAIL'
          )
          puts '=' * 104
        end

        def compact_inspect(value)
          text = value.inspect
          text.length > 1200 ? "#{text[0, 1200]}..." : text
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
  LvnPolygonCandidateSurfaceEquivalenceProbe.run
