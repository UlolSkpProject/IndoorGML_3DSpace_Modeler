# frozen_string_literal: true

require 'digest'
require_relative 'lvn_polygon_preserving_feasibility_probe'
require_relative '../indoor3d/infrastructure/scene/entity_copy_helper'

# Phase 2 single-solid candidate reconstruction probe.
#
# - Uses definition-local source polygon loops.
# - Applies only the 0.001 mm integer-grid snap already analyzed in Phase 1.
# - Rebuilds one temporary copy with polygon Faces, not triangle Faces.
# - Aborts the enclosing SketchUp operation after collecting diagnostics.
# - Never calls production LocalVertexNormalizer.
#
# This first Phase 2 probe intentionally rejects nested source instances and
# Faces with inner loops. Those cases remain future Phase 2 work, not failures
# of the production LVN.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnPolygonCandidateReconstructionProbe
        ANGLE_TOLERANCE_DEG =
          LocalVertexNormalizer::COPLANAR_ANGLE_TOLERANCE_DEG
        MM_PER_INCH = LocalVertexNormalizer::MM_PER_INCH

        module_function

        def run
          model = Sketchup.active_model
          source = model.selection.to_a.find do |entity|
            entity.respond_to?(:definition) &&
              entity.respond_to?(:valid?) &&
              entity.valid?
          end
          unless source
            puts '[LVN POLYGON PHASE 2] Select one top-level Group / ComponentInstance first.'
            return false
          end

          unless source.parent == model
            puts '[LVN POLYGON PHASE 2] REJECT: initial probe supports top-level instances only.'
            return false
          end

          phase1 = LvnPolygonPreservingFeasibilityProbe
          feasibility = phase1.analyze_entity(source)
          unless feasibility[:directly_preservable]
            reasons = feasibility.dig(:faces, :reason_counts).to_h.keys +
              Array(feasibility.dig(:global, :reasons))
            puts "[LVN POLYGON PHASE 2] REJECT: Phase 1 unsafe (#{reasons.uniq.join(', ')})"
            return false
          end

          snapshot = snapshot_source(source, phase1)
          if snapshot[:faces].any? { |record| !record[:inner_loops].empty? }
            puts '[LVN POLYGON PHASE 2] REJECT: initial probe does not reconstruct inner loops yet.'
            return false
          end
          unless snapshot[:non_geometry_entities].zero?
            puts format(
              '[LVN POLYGON PHASE 2] REJECT: definition contains %d non-edge/face entities.',
              snapshot[:non_geometry_entities]
            )
            return false
          end

          source_signature = brep_signature(source)
          source_counts = geometry_counts(source)
          source_volume_mm3 = solid_volume_mm3(source)
          order = connected_face_order(snapshot[:faces])

          puts '=' * 92
          puts ' LVN Polygon-Preserving Candidate Reconstruction — Phase 2 (Temporary Copy)'
          puts '=' * 92
          puts format('source                : %s', phase1.entity_label(source))
          puts format(
            'source geometry       : F=%d E=%d V=%d manifold=%s',
            source_counts[:faces],
            source_counts[:edges],
            source_counts[:vertices],
            source_counts[:manifold].inspect
          )
          puts format('source Face loops     : %d outer / 0 inner', snapshot[:faces].length)
          puts format('grid tolerance        : %.6f mm', phase1::DEFAULT_TOLERANCE_MM)
          puts 'ordering heuristic    : shared-edge frontier, then local-Z bucket'
          puts format('angle tolerance       : %.6f deg', ANGLE_TOLERANCE_DEG)
          puts 'source mutation       : none'
          puts 'production LVN calls  : none'
          puts 'candidate lifetime    : enclosing operation is aborted'
          puts '-' * 92
          puts 'Face order:'
          order.each_with_index do |record, index|
            puts format(
              '  %3d. source_face=%4d shared-priority=%s axis=%s vertices=%d',
              index + 1,
              record[:index],
              index.zero? ? 'seed' : 'frontier',
              axis_bucket_label(record[:axis_bucket]),
              record[:outer_loop].length
            )
          end

          result = nil
          operation_started = false
          begin
            operation_started = model.start_operation(
              'LVN polygon candidate reconstruction probe',
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

            candidate.name = "LVN_POLYGON_CANDIDATE_TEMP_#{phase1.persistent_id(source)}" if
              candidate.respond_to?(:name=)

            candidate_entities = candidate.definition.entities
            erase_geometry(candidate_entities)
            rebuild = rebuild_polygon_faces(candidate_entities, order)
            result = inspect_candidate(
              candidate,
              source_counts,
              source_volume_mm3,
              snapshot,
              rebuild,
              phase1
            )
          rescue StandardError => error
            result = {
              status: :error,
              error: "#{error.class}: #{error.message}",
              backtrace: Array(error.backtrace).first(8)
            }
          ensure
            if operation_started
              aborted = model.abort_operation
              raise 'SketchUp abort_operation returned false' if aborted == false
            end
          end

          source_restored = brep_signature(source) == source_signature
          print_result(result, source_restored)
          result[:status] == :success && result[:candidate_acceptable] && source_restored
        rescue StandardError => error
          warn "[LVN POLYGON PHASE 2] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(8).join("\n")
          false
        end

        def snapshot_source(source, phase1)
          entities = source.definition.entities
          faces = entities.grep(Sketchup::Face).select(&:valid?)
          geometry_classes = [Sketchup::Face, Sketchup::Edge]
          non_geometry_count = entities.to_a.count do |entity|
            geometry_classes.none? { |klass| entity.is_a?(klass) }
          end

          records = faces.map.with_index do |face, index|
            loops = phase1.ordered_face_loops(face).map do |loop|
              loop.vertices.map { |vertex| phase1.grid_key(vertex.position) }
            end
            outer_loop = loops.first
            inner_loops = loops.drop(1)
            normal = [face.normal.x.to_f, face.normal.y.to_f, face.normal.z.to_f]
            {
              index: index,
              face_pid: phase1.persistent_id(face),
              outer_loop: outer_loop,
              inner_loops: inner_loops,
              edge_keys: loop_edge_keys(outer_loop),
              source_normal: normal,
              axis_bucket: axis_bucket(normal),
              material: face.material,
              back_material: face.back_material,
              layer: face.layer
            }
          end

          {
            faces: records,
            non_geometry_entities: non_geometry_count
          }
        end

        def connected_face_order(records)
          remaining = records.dup
          ordered = []
          built_edges = {}

          until remaining.empty?
            record = remaining.min_by do |candidate|
              shared = candidate[:edge_keys].count { |edge| built_edges.key?(edge) }
              [
                -shared,
                candidate[:axis_bucket],
                candidate[:inner_loops].length,
                candidate[:outer_loop].length,
                candidate[:index]
              ]
            end
            remaining.delete(record)
            ordered << record
            record[:edge_keys].each { |edge| built_edges[edge] = true }
          end

          ordered
        end

        def rebuild_polygon_faces(entities, ordered_records)
          created = []
          auto_face_deltas = []

          ordered_records.each do |record|
            before_faces = entities.grep(Sketchup::Face).count(&:valid?)
            points = record[:outer_loop].map { |key| point_from_grid_key(key) }
            face = entities.add_face(points)
            unless face&.valid?
              raise "add_face failed for source Face #{record[:index]}"
            end

            after_faces = entities.grep(Sketchup::Face).count(&:valid?)
            delta = after_faces - before_faces
            auto_face_deltas << {
              source_face_index: record[:index],
              face_delta: delta
            }
            unless delta == 1
              raise "Unexpected SketchUp Face delta #{delta} for source Face #{record[:index]}"
            end

            current_normal = [face.normal.x.to_f, face.normal.y.to_f, face.normal.z.to_f]
            face.reverse! if vector_dot(current_normal, record[:source_normal]).negative?
            face.material = record[:material] if face.respond_to?(:material=)
            face.back_material = record[:back_material] if face.respond_to?(:back_material=)
            face.layer = record[:layer] if record[:layer] && face.respond_to?(:layer=)
            created << face
          end

          {
            requested_faces: ordered_records.length,
            created_faces: created.length,
            face_deltas: auto_face_deltas
          }
        end

        def inspect_candidate(candidate, source_counts, source_volume_mm3, snapshot, rebuild, phase1)
          counts = geometry_counts(candidate)
          candidate_volume_mm3 = solid_volume_mm3(candidate)
          volume_delta_mm3 = if source_volume_mm3 && candidate_volume_mm3
                               (candidate_volume_mm3 - source_volume_mm3).abs
                             end
          boundary = candidate.definition.entities.grep(Sketchup::Edge).count do |edge|
            edge.valid? && edge.faces.length == 1
          end
          overused = candidate.definition.entities.grep(Sketchup::Edge).count do |edge|
            edge.valid? && edge.faces.length > 2
          end
          expected_signature = snapshot_face_signature(snapshot[:faces])
          actual_signature = entity_face_signature(candidate, phase1)
          phase1_result = phase1.analyze_entity(candidate)

          reasons = []
          reasons << :face_count_changed if counts[:faces] != source_counts[:faces]
          reasons << :edge_count_changed if counts[:edges] != source_counts[:edges]
          reasons << :vertex_count_changed if counts[:vertices] != source_counts[:vertices]
          reasons << :candidate_not_manifold unless counts[:manifold] == true
          reasons << :boundary_edges if boundary.positive?
          reasons << :overused_edges if overused.positive?
          reasons << :face_loop_signature_changed unless actual_signature == expected_signature
          reasons << :phase1_candidate_rejected unless phase1_result[:directly_preservable]

          {
            status: :success,
            candidate_acceptable: reasons.empty?,
            reasons: reasons,
            source_counts: source_counts,
            candidate_counts: counts,
            boundary_edges: boundary,
            overused_edges: overused,
            source_volume_mm3: source_volume_mm3,
            candidate_volume_mm3: candidate_volume_mm3,
            volume_delta_mm3: volume_delta_mm3,
            face_loop_signature_equal: actual_signature == expected_signature,
            phase1_recheck: phase1_result[:directly_preservable],
            rebuild: rebuild
          }
        end

        def print_result(result, source_restored)
          puts '-' * 92
          if result[:status] == :error
            puts "candidate status      : ERROR #{result[:error]}"
            Array(result[:backtrace]).each { |line| puts "  #{line}" }
            puts format('source restored       : %s', source_restored)
            puts 'result                : FAIL'
            puts '=' * 92
            return
          end

          counts = result[:candidate_counts]
          puts format(
            'candidate geometry    : F=%d E=%d V=%d manifold=%s',
            counts[:faces], counts[:edges], counts[:vertices], counts[:manifold].inspect
          )
          puts format('requested/created Face: %d/%d', result.dig(:rebuild, :requested_faces), result.dig(:rebuild, :created_faces))
          puts format('boundary edges        : %d', result[:boundary_edges])
          puts format('overused edges        : %d', result[:overused_edges])
          puts format('Face loop exact       : %s', result[:face_loop_signature_equal])
          puts format('Phase 1 recheck       : %s', result[:phase1_recheck])
          if result[:volume_delta_mm3]
            puts format('volume delta          : %.9f mm3', result[:volume_delta_mm3])
          else
            puts 'volume delta          : unavailable'
          end
          puts format('candidate reasons     : %s', result[:reasons].empty? ? 'none' : result[:reasons].join(', '))
          puts format('candidate acceptable  : %s', result[:candidate_acceptable])
          puts format('source restored       : %s', source_restored)
          puts format(
            'result                : %s',
            result[:candidate_acceptable] && source_restored ? 'PASS' : 'FAIL'
          )
          puts '=' * 92
        end

        def geometry_counts(entity)
          entities = entity.definition.entities
          faces = entities.grep(Sketchup::Face).select(&:valid?)
          edges = entities.grep(Sketchup::Edge).select(&:valid?)
          {
            faces: faces.length,
            edges: edges.length,
            vertices: edges.flat_map(&:vertices).uniq.length,
            manifold: entity.respond_to?(:manifold?) ? entity.manifold? : nil
          }
        end

        def erase_geometry(entities)
          geometry = entities.to_a.select do |entity|
            entity.is_a?(Sketchup::Face) || entity.is_a?(Sketchup::Edge)
          end
          entities.erase_entities(geometry) unless geometry.empty?
        end

        def snapshot_face_signature(records)
          records.map do |record|
            [
              loop_signature(record[:outer_loop]),
              record[:inner_loops].map { |loop| loop_signature(loop) }.sort
            ]
          end.sort
        end

        def entity_face_signature(entity, phase1)
          entity.definition.entities.grep(Sketchup::Face).select(&:valid?).map do |face|
            loops = phase1.ordered_face_loops(face).map do |loop|
              keys = loop.vertices.map { |vertex| phase1.grid_key(vertex.position) }
              loop_signature(keys)
            end
            [loops.first, loops.drop(1).sort]
          end.sort
        end

        def loop_signature(keys)
          loop_edge_keys(keys).sort
        end

        def loop_edge_keys(keys)
          keys.each_index.map do |index|
            canonical_edge(keys[index], keys[(index + 1) % keys.length])
          end
        end

        def canonical_edge(first, second)
          (first <=> second) <= 0 ? [first, second] : [second, first]
        end

        def point_from_grid_key(key)
          values = key.map do |index|
            index * LvnPolygonPreservingFeasibilityProbe::DEFAULT_TOLERANCE_MM /
              MM_PER_INCH
          end
          Geom::Point3d.new(values[0], values[1], values[2])
        end

        def axis_bucket(normal)
          length = Math.sqrt(vector_dot(normal, normal))
          return 2 unless length.positive?

          z_abs = normal[2].abs / length
          radians = ANGLE_TOLERANCE_DEG * Math::PI / 180.0
          return 0 if z_abs >= Math.cos(radians)
          return 1 if z_abs <= Math.sin(radians)

          2
        end

        def axis_bucket_label(bucket)
          { 0 => 'horizontal', 1 => 'vertical', 2 => 'oblique' }.fetch(bucket, 'unknown')
        end

        def vector_dot(first, second)
          (first[0] * second[0]) +
            (first[1] * second[1]) +
            (first[2] * second[2])
        end

        def solid_volume_mm3(entity)
          entity.volume.to_f * (MM_PER_INCH**3)
        rescue StandardError
          nil
        end

        def brep_signature(entity)
          edges = entity.definition.entities.grep(Sketchup::Edge).select(&:valid?).map do |edge|
            canonical_edge(exact_point_key(edge.start.position), exact_point_key(edge.end.position))
          end.sort
          faces = entity.definition.entities.grep(Sketchup::Face).select(&:valid?).map do |face|
            face.loops.map do |loop|
              vertices = loop.vertices
              vertices.each_index.map do |index|
                canonical_edge(
                  exact_point_key(vertices[index].position),
                  exact_point_key(vertices[(index + 1) % vertices.length].position)
                )
              end.sort
            end.sort
          end.sort
          Digest::SHA256.hexdigest(Marshal.dump([edges, faces]))
        end

        def exact_point_key(point)
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end
      end
    end
  end
end
