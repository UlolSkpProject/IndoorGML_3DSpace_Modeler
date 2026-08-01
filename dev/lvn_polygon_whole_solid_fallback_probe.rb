# frozen_string_literal: true

require 'stringio'

# Load the Phase 4 single-solid helper without triggering its default auto-run.
dependency_model = Sketchup.active_model
dependency_selection = dependency_model.selection.to_a
dependency_stdout = $stdout
dependency_stderr = $stderr
begin
  dependency_model.selection.clear
  $stdout = StringIO.new
  $stderr = StringIO.new
  require_relative 'lvn_polygon_candidate_surface_equivalence_probe'
ensure
  $stdout = dependency_stdout
  $stderr = dependency_stderr
  dependency_model.selection.clear
  dependency_selection.each do |entity|
    dependency_model.selection.add(entity) if entity.respond_to?(:valid?) && entity.valid?
  end
end

# Phase 5 forced-failure whole-solid fallback probe.
#
# A Phase 1-safe source with a real grid displacement is copied and reconstructed
# through Phase 4. Immediately after surface equivalence passes, a controlled
# polygon-path failure is injected. The failed polygon candidate is never reused.
# A second, fresh unique copy is created from the untouched source and normalized
# through the unchanged production LocalVertexNormalizer. The enclosing operation
# is aborted, so source geometry and model-root inventory must be restored exactly.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonWholeSolidFallbackProbe
        MAXIMUM_SOURCE_FACES = 250

        class InjectedPolygonFailure < StandardError; end

        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          hole = LvnPolygonCandidateHoleReconstructionProbe
          surface = LvnPolygonCandidateSurfaceEquivalenceProbe
          original_selection = model.selection.to_a
          root_before = model_root_signature(model)

          source, feasibility, snapshot, filter = find_source(
            model,
            phase1,
            base
          )
          unless source
            puts '[LVN POLYGON FALLBACK PHASE 5] No eligible moving source found.'
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
          normalizer = LocalVertexNormalizer.new(phase1::DEFAULT_TOLERANCE_MM)
          expected = surface.build_expected_target_surface(normalizer, source)

          puts '=' * 108
          puts ' LVN Polygon-Preserving Candidate — Phase 5 Forced-Failure Whole-Solid Fallback'
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
            'source Face loops     : %d outer / %d inner',
            snapshot[:faces].length,
            inner_loop_count
          )
          puts format(
            'source max snap move  : %.9f mm',
            feasibility.dig(:snap, :max_displacement_mm).to_f
          )
          puts format('grid tolerance        : %.6f mm', phase1::DEFAULT_TOLERANCE_MM)
          puts 'polygon path          : reconstruct + exact gate + surface equivalence'
          puts 'forced failure point  : immediately after Phase 4 equivalence passes'
          puts 'fallback source       : fresh unique copy from untouched source'
          puts 'fallback engine       : production LocalVertexNormalizer.normalize'
          puts 'fallback reuse        : failed polygon candidate is never reused'
          puts 'candidate lifetime    : enclosing operation is aborted'
          puts 'source mutation       : none'
          print_filter_summary(filter)
          puts '-' * 108

          result = nil
          operation_started = false
          begin
            operation_started = model.start_operation(
              'LVN polygon whole-solid fallback probe',
              true
            )
            raise 'SketchUp start_operation returned false' if operation_started == false

            polygon_candidate = nil
            polygon_phase4_passed = false
            polygon_error = nil
            polygon_definition_id = nil

            begin
              polygon_candidate = copy_source_instance(
                source,
                model,
                phase1,
                'LVN_POLYGON_FAILED_TEMP'
              )
              polygon_definition_id = polygon_candidate.definition.object_id
              polygon_entities = polygon_candidate.definition.entities
              base.erase_geometry(polygon_entities)

              rebuild = if inner_loop_count.positive?
                          hole.rebuild_polygon_faces_with_holes(
                            polygon_entities,
                            order,
                            phase1,
                            base
                          )
                        else
                          base.rebuild_polygon_faces(polygon_entities, order)
                        end

              phase2 = base.inspect_candidate(
                polygon_candidate,
                source_counts,
                source_volume_mm3,
                snapshot,
                rebuild,
                phase1
              )
              unless phase2[:candidate_acceptable]
                raise "Phase 2 candidate rejected: #{phase2[:reasons].inspect}"
              end

              candidate_surface = surface.snapshot_and_validate_candidate(
                normalizer,
                polygon_entities
              )
              equivalence = normalizer.send(
                :verify_normalized_surface_equivalence!,
                expected[:triangles],
                candidate_surface[:triangles]
              )
              unless equivalence.is_a?(Hash) && equivalence[:equivalent] == true
                raise "Unexpected surface equivalence result: #{equivalence.inspect}"
              end

              polygon_phase4_passed = true
              raise InjectedPolygonFailure,
                    'forced failure after exact surface equivalence pass'
            rescue StandardError => error
              polygon_error = error
            end

            unless polygon_phase4_passed && polygon_error.is_a?(InjectedPolygonFailure)
              raise(
                "Polygon path did not reach the intended forced-failure point: " \
                "#{polygon_error.class}: #{polygon_error.message}"
              )
            end

            fallback_candidate = copy_source_instance(
              source,
              model,
              phase1,
              'LVN_EXISTING_FALLBACK_TEMP'
            )
            fallback_definition_id = fallback_candidate.definition.object_id
            fallback_fresh = base.brep_signature(fallback_candidate) == source_signature
            definition_isolated =
              fallback_candidate.definition != source.definition &&
              fallback_definition_id != polygon_definition_id

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
              polygon_phase4_passed: polygon_phase4_passed,
              polygon_error_class: polygon_error.class.name,
              polygon_error_message: polygon_error.message,
              polygon_candidate_reused: fallback_definition_id == polygon_definition_id,
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
          root_restored = model_root_signature(model) == root_before
          selection_restored = restore_selection(model, original_selection)

          print_result(
            result,
            source_restored,
            root_restored,
            selection_restored
          )

          result[:status] == :success &&
            result[:polygon_phase4_passed] &&
            result[:polygon_error_class] == InjectedPolygonFailure.name &&
            !result[:polygon_candidate_reused] &&
            result[:fallback_fresh] &&
            result[:definition_isolated] &&
            result[:fallback_report_complete] &&
            result[:fallback_manifold] &&
            result[:fallback_normalized] &&
            source_restored &&
            root_restored &&
            selection_restored
        rescue StandardError => error
          warn "[LVN POLYGON FALLBACK PHASE 5] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(14).join("\n")
          false
        ensure
          restore_selection(model, original_selection) if model && original_selection
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
            if face_count > MAXIMUM_SOURCE_FACES
              filter[:above_face_limit] += 1
              next
            end

            feasibility = phase1.analyze_entity(entity)
            unless feasibility[:directly_preservable]
              filter[:phase1_reject] += 1
              next
            end

            if feasibility.dig(:snap, :max_displacement_mm).to_f <=
               LocalVertexNormalizer::GRID_EPSILON_MM
              filter[:already_on_grid] += 1
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
          selected = candidates.min_by do |entity, feasibility, snapshot, face_count|
            [
              face_count,
              snapshot[:faces].sum { |record| record[:inner_loops].length },
              feasibility.dig(:snap, :max_displacement_mm).to_f,
              phase1.persistent_id(entity).to_i
            ]
          end
          return [nil, nil, nil, filter] unless selected

          [selected[0], selected[1], selected[2], filter]
        end

        def copy_source_instance(source, model, phase1, prefix)
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

          candidate.name = "#{prefix}_#{phase1.persistent_id(source)}" if
            candidate.respond_to?(:name=)
          candidate
        end

        def model_root_signature(model)
          model.entities.to_a.filter_map do |entity|
            next unless entity.respond_to?(:valid?) && entity.valid?

            identity = if entity.respond_to?(:persistent_id)
                         entity.persistent_id.to_i
                       else
                         entity.object_id
                       end
            [entity.class.name, identity]
          end.sort_by { |entry| [entry[0], entry[1]] }
        end

        def print_result(result, source_restored, root_restored, selection_restored)
          if result[:status] == :error
            puts 'fallback status       : ERROR'
            puts format('fallback error        : %s', result[:error])
            Array(result[:backtrace]).each { |line| puts "  #{line}" }
            puts format('source restored       : %s', source_restored)
            puts format('model root restored   : %s', root_restored)
            puts format('selection restored    : %s', selection_restored)
            puts 'result                : FAIL'
            puts '=' * 108
            return
          end

          report = result[:fallback_report]
          puts format('polygon reached P4    : %s', result[:polygon_phase4_passed])
          puts format('polygon failure class : %s', result[:polygon_error_class])
          puts format('polygon failure       : %s', result[:polygon_error_message])
          puts format('polygon candidate reused: %s', result[:polygon_candidate_reused])
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

          success =
            result[:polygon_phase4_passed] &&
            result[:polygon_error_class] == InjectedPolygonFailure.name &&
            !result[:polygon_candidate_reused] &&
            result[:fallback_fresh] &&
            result[:definition_isolated] &&
            result[:fallback_report_complete] &&
            result[:fallback_manifold] &&
            result[:fallback_normalized] &&
            source_restored &&
            root_restored &&
            selection_restored
          puts format('result                : %s', success ? 'PASS' : 'FAIL')
          puts '=' * 108
        end

        def print_filter_summary(filter)
          puts 'filter summary:'
          keys = %i[
            phase1_reject
            already_on_grid
            above_face_limit
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
  LvnPolygonWholeSolidFallbackProbe.run
