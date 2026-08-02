# frozen_string_literal: true

# Phase 5.5.2 follow-up:
# SketchUp's mesh for a complex Face can contain a zero-area triangle where one
# source-precision vertex lies on the opposite internal diagonal. Do not accept
# or delete that triangle. Flip the internal diagonal together with its unique
# non-degenerate neighbor, then run the unchanged exact source-boundary gate.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnComplexFaceTrianglePreservingProbe
        module SourcePrecisionDegenerateRepair
          private

          def source_boundary_triangle_records(face, source_face_key)
            complexity =
              LvnComplexFaceTrianglePreservingProbe.face_complexity(self, face)
            return super unless complexity[:complex]

            records = LvnComplexFaceTrianglePreservingProbe.mesh_triangle_records(
              self,
              face,
              source_face_key
            )
            loops = face.loops.map do |loop|
              compact_integer_loop(
                loop.vertices.map do |vertex|
                  source_precision_indices(vertex.position)
                end
              )
            end

            repaired_records, repair =
              LvnComplexFaceTrianglePreservingProbe
                .repair_source_precision_degenerate_mesh(self, records)

            begin
              validate_source_boundary_retriangulation!(repaired_records, loops)
            rescue LocalVertexNormalizer::Error, ArgumentError => error
              raise ComplexFaceMeshValidationError,
                    "Complex source Face mesh failed exact boundary validation: " \
                    "face=#{source_face_key.inspect} " \
                    "repair=#{repair.inspect} " \
                    "#{error.class}: #{error.message}"
            end

            @complex_face_triangle_preserving_records << complexity.merge(
              source_face_key: source_face_key,
              raw_mesh_triangle_count: records.length,
              mesh_triangle_count: repaired_records.length,
              source_precision_degenerate_repair: repair,
              exact_source_boundary_validated: true
            )
            repaired_records
          end
        end

        module Implementation
          Error = LocalVertexNormalizer::Error unless const_defined?(:Error, false)
          TopologyChangedError = LocalVertexNormalizer::TopologyChangedError unless
            const_defined?(:TopologyChangedError, false)
          MM_PER_INCH = LocalVertexNormalizer::MM_PER_INCH unless
            const_defined?(:MM_PER_INCH, false)

          prepend SourcePrecisionDegenerateRepair unless
            ancestors.include?(SourcePrecisionDegenerateRepair)
        end

        class << self
          def repair_source_precision_degenerate_mesh(normalizer, records)
            working = records.map(&:dup)
            before = source_precision_degenerate_diagnostics(normalizer, working)
            repaired_pairs = 0

            loop do
              degenerate_indices = working.each_index.select do |index|
                source_precision_degenerate_record?(normalizer, working[index])
              end
              break if degenerate_indices.empty?

              repair = nil
              degenerate_indices.each do |degenerate_index|
                degenerate = working[degenerate_index]
                split = source_precision_collinear_split(normalizer, degenerate)
                next unless split

                neighbor_indices = working.each_index.select do |candidate_index|
                  next false if candidate_index == degenerate_index

                  candidate = working[candidate_index]
                  next false unless
                    candidate[:source_face_key] == degenerate[:source_face_key]
                  next false if
                    source_precision_degenerate_record?(normalizer, candidate)

                  candidate_keys = source_precision_triangle_keys(
                    normalizer,
                    candidate
                  )
                  candidate_keys.include?(split[:endpoint_a_key]) &&
                    candidate_keys.include?(split[:endpoint_c_key])
                end

                if neighbor_indices.length > 1
                  raise ComplexFaceMeshValidationError,
                        "Complex mesh degenerate triangle has multiple exact " \
                        "neighbors: face=#{degenerate[:source_face_key].inspect} " \
                        "polygon=#{degenerate[:source_polygon_index].inspect} " \
                        "edge=#{[split[:endpoint_a_key], split[:endpoint_c_key]].inspect} " \
                        "neighbors=#{neighbor_indices.inspect}"
                end
                next if neighbor_indices.empty?

                repair = {
                  degenerate_index: degenerate_index,
                  neighbor_index: neighbor_indices.first,
                  split: split
                }
                break
              end

              unless repair
                after = source_precision_degenerate_diagnostics(
                  normalizer,
                  working
                )
                raise ComplexFaceMeshValidationError,
                      "Could not exactly retriangulate complex Face mesh " \
                      "degenerates: before=#{before.inspect} " \
                      "remaining=#{after.inspect}"
              end

              degenerate = working[repair[:degenerate_index]]
              neighbor = working[repair[:neighbor_index]]
              split = repair[:split]
              neighbor_points_by_key = neighbor[:points].each_with_object({}) do |point, result|
                result[normalizer.send(:source_precision_indices, point)] = point
              end
              opposite_entry = neighbor_points_by_key.find do |key, _point|
                key != split[:endpoint_a_key] &&
                  key != split[:endpoint_c_key]
              end
              unless opposite_entry
                raise ComplexFaceMeshValidationError,
                      "Exact degenerate neighbor has no opposite vertex: " \
                      "face=#{neighbor[:source_face_key].inspect} " \
                      "polygon=#{neighbor[:source_polygon_index].inspect}"
              end
              opposite_point = opposite_entry[1]

              replacements = [
                degenerate.merge(
                  points: [
                    split[:endpoint_a],
                    split[:middle],
                    opposite_point
                  ],
                  source_polygon_index: [
                    degenerate[:source_polygon_index],
                    :exact_diagonal_flip,
                    0
                  ],
                  source_mesh_degenerate_repair: true
                ),
                neighbor.merge(
                  points: [
                    split[:middle],
                    split[:endpoint_c],
                    opposite_point
                  ],
                  source_polygon_index: [
                    neighbor[:source_polygon_index],
                    :exact_diagonal_flip,
                    1
                  ],
                  source_mesh_degenerate_repair: true
                )
              ].map do |record|
                orient_source_mesh_record(normalizer, record)
              end

              replacements.each do |record|
                next unless
                  source_precision_degenerate_record?(normalizer, record)

                raise ComplexFaceMeshValidationError,
                      "Exact alternate diagonal still creates a degenerate " \
                      "triangle: face=#{record[:source_face_key].inspect} " \
                      "polygon=#{record[:source_polygon_index].inspect} " \
                      "keys=#{source_precision_triangle_keys(normalizer, record).inspect}"
              end

              [repair[:degenerate_index], repair[:neighbor_index]]
                .sort
                .reverse_each { |index| working.delete_at(index) }

              signatures = working.each_with_object({}) do |record, result|
                result[source_precision_triangle_signature(
                  normalizer,
                  record
                )] = true
              end
              replacements.each do |record|
                signature = source_precision_triangle_signature(
                  normalizer,
                  record
                )
                if signatures.key?(signature)
                  raise ComplexFaceMeshValidationError,
                        "Exact alternate diagonal creates a duplicate triangle: " \
                        "#{signature.inspect}"
                end

                signatures[signature] = true
                working << record
              end
              repaired_pairs += 1
            end

            after = source_precision_degenerate_diagnostics(normalizer, working)
            unless after[:total].zero?
              raise ComplexFaceMeshValidationError,
                    "Exact complex mesh repair left degenerate triangles: " \
                    "#{after.inspect}"
            end

            [
              working,
              {
                strategy: :source_precision_internal_diagonal_flip,
                raw_triangle_count: records.length,
                final_triangle_count: working.length,
                repaired_pairs: repaired_pairs,
                before: before,
                after: after
              }
            ]
          end

          def source_precision_degenerate_diagnostics(normalizer, records)
            samples = []
            coincident = 0
            collinear = 0

            records.each do |record|
              keys = source_precision_triangle_keys(normalizer, record)
              reason = if keys.uniq.length != 3
                         coincident += 1
                         :coincident_precision_vertices
                       elsif normalizer.send(
                         :integer_zero_vector?,
                         normalizer.send(:integer_triangle_normal, keys)
                       )
                         collinear += 1
                         :collinear
                       end
              next unless reason
              next if samples.length >= 8

              samples << {
                reason: reason,
                source_face_key: record[:source_face_key],
                source_polygon_index: record[:source_polygon_index],
                keys: keys
              }
            end

            {
              total: coincident + collinear,
              coincident_precision_vertices: coincident,
              collinear: collinear,
              samples: samples
            }
          end

          def source_precision_degenerate_record?(normalizer, record)
            keys = source_precision_triangle_keys(normalizer, record)
            return true if keys.uniq.length != 3

            normalizer.send(
              :integer_zero_vector?,
              normalizer.send(:integer_triangle_normal, keys)
            )
          end

          def source_precision_collinear_split(normalizer, record)
            points = record[:points]
            keys = source_precision_triangle_keys(normalizer, record)
            return nil unless keys.uniq.length == 3
            return nil unless normalizer.send(
              :integer_zero_vector?,
              normalizer.send(:integer_triangle_normal, keys)
            )

            keys.each_index do |middle_index|
              endpoint_indices = keys.each_index.reject do |index|
                index == middle_index
              end
              endpoint_a_index, endpoint_c_index = endpoint_indices
              middle_key = keys[middle_index]
              endpoint_a_key = keys[endpoint_a_index]
              endpoint_c_key = keys[endpoint_c_index]
              next unless normalizer.send(
                :integer_point_between?,
                middle_key,
                endpoint_a_key,
                endpoint_c_key
              )

              return {
                endpoint_a: points[endpoint_a_index],
                endpoint_a_key: endpoint_a_key,
                middle: points[middle_index],
                middle_key: middle_key,
                endpoint_c: points[endpoint_c_index],
                endpoint_c_key: endpoint_c_key
              }
            end

            nil
          end

          def source_precision_triangle_keys(normalizer, record)
            record[:points].map do |point|
              normalizer.send(:source_precision_indices, point)
            end
          end

          def source_precision_triangle_signature(normalizer, record)
            source_precision_triangle_keys(normalizer, record).sort
          end

          def orient_source_mesh_record(normalizer, record)
            points = record[:points]
            actual_normal = normalizer.send(
              :vector_cross,
              normalizer.send(:vector_between, points[0], points[1]),
              normalizer.send(:vector_between, points[0], points[2])
            )
            source_normal = Array(record[:source_normal])
            if normalizer.send(:vector_dot, actual_normal, source_normal).negative?
              record.merge(points: [points[0], points[2], points[1]])
            else
              record
            end
          end
        end
      end
    end
  end
end

load File.expand_path('lvn_complex_face_triangle_preserving_probe.rb', __dir__)

nil
