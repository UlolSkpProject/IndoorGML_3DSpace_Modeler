# frozen_string_literal: true

# Phase 5.5.2 follow-up.
# Keep the complex Face on SketchUp's triangle mesh path, but do not bypass the
# established source-boundary normalization pipeline. Reuse its projection,
# degenerate-pair repair and topology-point subdivision before the unchanged
# exact Face-loop validation gate.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnComplexFaceTrianglePreservingProbe
        module ExistingSourceBoundaryMeshPath
          private

          def source_boundary_triangle_records(face, source_face_key)
            complexity =
              LvnComplexFaceTrianglePreservingProbe.face_complexity(self, face)
            return super unless complexity[:complex]

            raw_records =
              LvnComplexFaceTrianglePreservingProbe.mesh_triangle_records(
                self,
                face,
                source_face_key
              )
            plan = @source_boundary_normalization_plan
            loop_entries = complex_face_loop_entries_v4(face, plan)
            topology_points = loop_entries.flatten.map { |entry| entry[:point] }
            topology_loops = loop_entries.map do |entries|
              compact_integer_loop(
                entries.map { |entry| source_precision_indices(entry[:point]) }
              )
            end

            target_by_source_key = complex_face_target_map_v4(face, plan)
            normalized_records = raw_records.map do |record|
              points = record[:points].map do |point|
                target_by_source_key.fetch(
                  source_precision_indices(point),
                  point
                )
              end
              record.merge(
                points: points,
                source_mesh_boundary_normalized: true
              )
            end

            repaired_records, degenerate_repair =
              repair_degenerate_source_triangles(
                normalized_records,
                coordinate_space: :source
              )
            subdivided_records = subdivide_source_boundary_records(
              repaired_records,
              topology_points
            )

            begin
              validate_source_boundary_retriangulation!(
                subdivided_records,
                topology_loops
              )
            rescue LocalVertexNormalizer::Error, ArgumentError => error
              raise ComplexFaceMeshValidationError,
                    "Complex source Face mesh failed normalized exact boundary " \
                    "validation: face=#{source_face_key.inspect} " \
                    "raw=#{raw_records.length} " \
                    "normalized=#{normalized_records.length} " \
                    "repaired=#{repaired_records.length} " \
                    "subdivided=#{subdivided_records.length} " \
                    "repair=#{degenerate_repair.inspect} " \
                    "#{error.class}: #{error.message}"
            end

            @complex_face_triangle_preserving_records << complexity.merge(
              source_face_key: source_face_key,
              raw_mesh_triangle_count: raw_records.length,
              normalized_mesh_triangle_count: normalized_records.length,
              repaired_mesh_triangle_count: repaired_records.length,
              mesh_triangle_count: subdivided_records.length,
              source_boundary_plan_present: !plan.nil?,
              source_boundary_target_count:
                plan ? plan.fetch(:targets, {}).length : 0,
              source_degenerate_repair: degenerate_repair,
              source_boundary_topology_subdivided: true,
              exact_source_boundary_validated: true
            )
            subdivided_records
          end

          def complex_face_loop_entries_v4(face, plan)
            return source_boundary_normalized_loop_entries(face, plan) if plan

            face.loops.map do |loop|
              compact_source_boundary_entries(
                loop.vertices.map do |vertex|
                  {
                    vertex_id: stable_entity_id(vertex),
                    point: vertex.position,
                    targeted: false,
                    redundant: false
                  }
                end
              )
            end
          end

          def complex_face_target_map_v4(face, plan)
            targets = plan ? plan.fetch(:targets, {}) : {}
            face.loops.each_with_object({}) do |loop, result|
              loop.vertices.each do |vertex|
                original = vertex.position
                target = targets[stable_entity_id(vertex)] || original
                result[source_precision_indices(original)] = target
              end
            end
          end
        end

        module Implementation
          Error = LocalVertexNormalizer::Error unless const_defined?(:Error, false)
          TopologyChangedError = LocalVertexNormalizer::TopologyChangedError unless
            const_defined?(:TopologyChangedError, false)
          MM_PER_INCH = LocalVertexNormalizer::MM_PER_INCH unless
            const_defined?(:MM_PER_INCH, false)

          prepend ExistingSourceBoundaryMeshPath unless
            ancestors.include?(ExistingSourceBoundaryMeshPath)
        end
      end
    end
  end
end

load File.expand_path('lvn_complex_face_triangle_preserving_probe.rb', __dir__)

nil
