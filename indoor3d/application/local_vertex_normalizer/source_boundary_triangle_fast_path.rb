# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # A Face with exactly one three-vertex boundary loop already is the exact
      # polygon triangulation that the general source-boundary path would build.
      #
      # This shortcut is deliberately one-sided. It returns one record only when
      # the complete boundary is an exact non-degenerate triangle at source
      # precision and its orientation can be proven against the SketchUp Face
      # normal. Every other shape or uncertainty falls through to the established
      # loop classification, triangulation, and validation path.
      module LocalVertexNormalizerSourceBoundaryTriangleFastPath
        private

        def source_boundary_triangle_records(face, source_face_key)
          loops = face.loops
          return super unless loops.respond_to?(:length) && loops.length == 1

          loop = loops.first
          return super unless loop&.respond_to?(:vertices)

          vertices = loop.vertices
          return super unless vertices.respond_to?(:length) && vertices.length == 3

          points = vertices.map(&:position)
          return super unless points.length == 3

          triangle_keys = points.map { |point| source_precision_indices(point) }
          return super unless triangle_keys.uniq.length == 3
          return super if integer_zero_vector?(
            integer_triangle_normal(triangle_keys)
          )

          source_normal = vector_components(face.normal)
          return super unless source_normal.length == 3
          return super unless vector_length(source_normal).positive?

          actual_normal = vector_cross(
            vector_between(points[0], points[1]),
            vector_between(points[0], points[2])
          )
          return super unless vector_length(actual_normal).positive?

          orientation = vector_dot(actual_normal, source_normal)
          return super if orientation.zero?

          points = [points[0], points[2], points[1]] if orientation.negative?
          [
            {
              points: points,
              source_normal: source_normal,
              material: face.material,
              back_material: face.back_material,
              layer: face.layer,
              source_face_key: source_face_key,
              source_polygon_index: 0,
              source_boundary_snapshot: true
            }
          ]
        rescue StandardError
          # The fast path must never widen acceptance. Unexpected API objects or
          # malformed geometry are handled by the existing exact implementation.
          super
        end
      end

      class LocalVertexNormalizer
        prepend LocalVertexNormalizerSourceBoundaryTriangleFastPath unless
          ancestors.include?(
            LocalVertexNormalizerSourceBoundaryTriangleFastPath
          )
      end
    end
  end
end
