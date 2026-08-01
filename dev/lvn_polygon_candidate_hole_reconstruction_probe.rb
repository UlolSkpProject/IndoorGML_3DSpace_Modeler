# frozen_string_literal: true

require_relative 'lvn_polygon_candidate_reconstruction_probe'

# Phase 2 single-solid inner-loop reconstruction probe.
#
# This probe leaves the already validated no-hole path unchanged. It selects the
# first Phase 1-safe source with one or more inner loops, creates a temporary
# unique copy, rebuilds each source polygon explicitly, carves every inner loop
# by adding and then erasing only its temporary fill Face, validates the exact
# polygon loop signature, and aborts the enclosing operation.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateHoleReconstructionProbe
        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          source, feasibility, snapshot = find_source(model, phase1, base)

          unless source
            puts '[LVN POLYGON HOLE PHASE 2] No selected Phase 1-safe source with inner loops.'
            return false
          end

          source_signature = base.brep_signature(source)
          source_counts = base.geometry_counts(source)
          source_volume_mm3 = base.solid_volume_mm3(source)
          order = base.connected_face_order(snapshot[:faces])
          inner_loop_count = snapshot[:faces].sum { |record| record[:inner_loops].length }

          print_header(
            source,
            source_counts,
            snapshot,
            inner_loop_count,
            order,
            phase1,
            base
          )

          result = nil
          operation_started = false
          begin
            operation_started = model.start_operation(
              'LVN polygon hole candidate reconstruction probe',
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

            candidate.name = "LVN_POLYGON_HOLE_CANDIDATE_TEMP_#{phase1.persistent_id(source)}" if
              candidate.respond_to?(:name=)

            candidate_entities = candidate.definition.entities
            base.erase_geometry(candidate_entities)
            rebuild = rebuild_polygon_faces_with_holes(
              candidate_entities,
              order,
              phase1,
              base
            )
            result = base.inspect_candidate(
              candidate,
              source_counts,
              source_volume_mm3,
              snapshot,
              rebuild,
              phase1
            )
            result[:hole_rebuild] = rebuild
          rescue StandardError => error
            result = {
              status: :error,
              error: "#{error.class}: #{error.message}",
              backtrace: Array(error.backtrace).first(10)
            }
          ensure
            if operation_started
              aborted = model.abort_operation
              raise 'SketchUp abort_operation returned false' if aborted == false
            end
          end

          source_restored = base.brep_signature(source) == source_signature
          print_result(result, source_restored, base)
          result[:status] == :success &&
            result[:candidate_acceptable] &&
            source_restored
        rescue StandardError => error
          warn "[LVN POLYGON HOLE PHASE 2] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(10).join("\n")
          false
        end

        def find_source(model, phase1, base)
          selected = phase1.selected_entities(model)
          selected.each do |entity|
            next unless entity.parent == model

            snapshot = base.snapshot_source(entity, phase1)
            next if snapshot[:non_geometry_entities].positive?
            next unless snapshot[:faces].any? { |record| !record[:inner_loops].empty? }

            feasibility = phase1.analyze_entity(entity)
            next unless feasibility[:directly_preservable]

            return [entity, feasibility, snapshot]
          rescue StandardError
            next
          end
          [nil, nil, nil]
        end

        def rebuild_polygon_faces_with_holes(entities, ordered_records, phase1, base)
          created = []
          face_deltas = []
          hole_operations = []

          ordered_records.each do |record|
            before_faces = valid_face_count(entities)
            outer_points = record[:outer_loop].map { |key| base.point_from_grid_key(key) }
            outer_face = entities.add_face(outer_points)
            unless outer_face&.valid?
              raise "outer add_face failed for source Face #{record[:index]}"
            end

            record[:inner_loops].each_with_index do |inner_loop, inner_index|
              before_inner_faces = valid_face_count(entities)
              inner_points = inner_loop.map { |key| base.point_from_grid_key(key) }
              fill_face = entities.add_face(inner_points)
              unless fill_face&.valid?
                raise(
                  "inner add_face failed for source Face #{record[:index]} " \
                  "inner loop #{inner_index}"
                )
              end

              after_add_faces = valid_face_count(entities)
              entities.erase_entities(fill_face)
              after_erase_faces = valid_face_count(entities)

              unless after_erase_faces == before_inner_faces
                raise(
                  "inner carve net Face delta #{after_erase_faces - before_inner_faces} " \
                  "for source Face #{record[:index]} inner loop #{inner_index}"
                )
              end

              hole_operations << {
                source_face_index: record[:index],
                inner_loop_index: inner_index,
                add_face_delta: after_add_faces - before_inner_faces,
                net_face_delta: after_erase_faces - before_inner_faces
              }
            end

            final_face = find_rebuilt_face(entities, record, phase1, base)
            unless final_face&.valid?
              raise "rebuilt Face signature not found for source Face #{record[:index]}"
            end

            current_normal = [
              final_face.normal.x.to_f,
              final_face.normal.y.to_f,
              final_face.normal.z.to_f
            ]
            final_face.reverse! if
              base.vector_dot(current_normal, record[:source_normal]).negative?
            final_face.material = record[:material] if final_face.respond_to?(:material=)
            final_face.back_material = record[:back_material] if
              final_face.respond_to?(:back_material=)
            final_face.layer = record[:layer] if
              record[:layer] && final_face.respond_to?(:layer=)

            after_faces = valid_face_count(entities)
            delta = after_faces - before_faces
            face_deltas << {
              source_face_index: record[:index],
              face_delta: delta,
              inner_loop_count: record[:inner_loops].length
            }
            unless delta == 1
              raise "Unexpected net Face delta #{delta} for source Face #{record[:index]}"
            end

            created << final_face
          end

          {
            requested_faces: ordered_records.length,
            created_faces: created.length,
            requested_inner_loops:
              ordered_records.sum { |record| record[:inner_loops].length },
            carved_inner_loops: hole_operations.length,
            face_deltas: face_deltas,
            hole_operations: hole_operations
          }
        end

        def find_rebuilt_face(entities, record, phase1, base)
          expected = [
            base.loop_signature(record[:outer_loop]),
            record[:inner_loops].map { |loop| base.loop_signature(loop) }.sort
          ]

          entities.grep(Sketchup::Face).find do |face|
            next false unless face.valid?

            loops = phase1.ordered_face_loops(face).map do |loop|
              keys = loop.vertices.map { |vertex| phase1.grid_key(vertex.position) }
              base.loop_signature(keys)
            end
            [loops.first, loops.drop(1).sort] == expected
          end
        end

        def valid_face_count(entities)
          entities.grep(Sketchup::Face).count(&:valid?)
        end

        def print_header(source, source_counts, snapshot, inner_loop_count, order, phase1, base)
          puts '=' * 96
          puts ' LVN Polygon-Preserving Hole Reconstruction — Phase 2 (Temporary Copy)'
          puts '=' * 96
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
          puts 'hole strategy         : add inner fill Face, erase only that Face'
          puts 'ordering heuristic    : shared-edge frontier, then local-Z bucket'
          puts format('angle tolerance       : %.6f deg', base::ANGLE_TOLERANCE_DEG)
          puts 'source mutation       : none'
          puts 'production LVN calls  : none'
          puts 'candidate lifetime    : enclosing operation is aborted'
          puts '-' * 96
          puts 'Face order:'
          order.each_with_index do |record, index|
            puts format(
              '  %3d. source_face=%4d axis=%-10s vertices=%4d inner=%d',
              index + 1,
              record[:index],
              base.axis_bucket_label(record[:axis_bucket]),
              record[:outer_loop].length,
              record[:inner_loops].length
            )
          end
        end

        def print_result(result, source_restored, base)
          puts '-' * 96
          if result[:status] == :error
            puts "candidate status      : ERROR #{result[:error]}"
            Array(result[:backtrace]).each { |line| puts "  #{line}" }
            puts format('source restored       : %s', source_restored)
            puts 'result                : FAIL'
            puts '=' * 96
            return
          end

          rebuild = result[:hole_rebuild]
          puts format(
            'inner loops carved    : %d/%d',
            rebuild[:carved_inner_loops],
            rebuild[:requested_inner_loops]
          )
          unusual_add_deltas = rebuild[:hole_operations].reject do |operation|
            operation[:add_face_delta] == 1
          end
          puts format(
            'inner add deltas      : %s',
            unusual_add_deltas.empty? ? 'all +1' : unusual_add_deltas.inspect
          )
          base.print_result(result, source_restored)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnPolygonCandidateHoleReconstructionProbe.run
