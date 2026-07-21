# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Edge; end unless const_defined?(:Edge, false)
  class Face; end unless const_defined?(:Face, false)
end

require_relative '../../indoor3d/application/local_vertex_normalizer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerTest < Minitest::Test
        Point = Struct.new(:x, :y, :z)

        class FakeMesh
          attr_reader :polygons

          def initialize(points, polygons = nil)
            @points = points
            @polygons = polygons || [(1..points.length).to_a]
          end

          def point_at(index)
            @points[index - 1]
          end
        end

        class FakeFace
          attr_reader :reverse_count

          def initialize(points)
            @points = points
            @reverse_count = 0
          end

          def valid?
            true
          end

          def mesh(_flags)
            FakeMesh.new(@points)
          end

          def reverse!
            @points = @points.reverse
            @reverse_count += 1
            self
          end
        end

        class SnapshotFace
          attr_reader :normal, :persistent_id

          def initialize(points, polygons, persistent_id)
            @points = points
            @polygons = polygons
            @persistent_id = persistent_id
            @normal = Point.new(0.0, 0.0, 1.0)
          end

          def valid?
            true
          end

          def mesh(_flags)
            FakeMesh.new(@points, @polygons)
          end

          def material
            nil
          end

          def back_material
            nil
          end

          def layer
            nil
          end
        end

        class SnapshotEntities
          def initialize(faces)
            @faces = faces
          end

          def grep(klass)
            klass == SnapshotFace ? @faces : []
          end
        end

        class AxisVertex
          attr_reader :position, :persistent_id

          def initialize(position, persistent_id)
            @position = position
            @persistent_id = persistent_id
          end
        end

        class AxisEdge
          attr_reader :persistent_id
          attr_accessor :faces

          def initialize(persistent_id, faces = [])
            @persistent_id = persistent_id
            @faces = faces
          end

          def valid?
            true
          end
        end

        class AxisFace
          attr_reader :vertices, :normal, :edges

          def initialize(vertices, normal, edges = [])
            @vertices = vertices
            @normal = normal
            @edges = edges
          end

          def valid?
            true
          end

          def mesh(_flags)
            FakeMesh.new(@vertices.map(&:position))
          end
        end

        class AxisEntities
          def initialize(faces)
            @faces = faces
          end

          def grep(klass)
            klass == AxisFace ? @faces : []
          end
        end

        SliverVertex = Struct.new(:position)

        class SliverEdge
          attr_reader :vertices
          attr_accessor :faces

          def initialize(vertex_a, vertex_b)
            @vertices = [vertex_a, vertex_b]
            @faces = []
          end

          def valid?
            true
          end
        end

        SliverLoop = Struct.new(:vertices, :edges)
        SupportFace = Struct.new(:persistent_id)

        class SliverFace
          attr_reader :outer_loop, :persistent_id, :normal

          def initialize(outer_loop, persistent_id)
            @outer_loop = outer_loop
            @persistent_id = persistent_id
            @normal = Point.new(0.0, 1.0, 0.0)
          end

          def valid?
            true
          end

          def loops
            [@outer_loop]
          end

          def material
            nil
          end

          def back_material
            nil
          end

          def layer
            nil
          end
        end

        class SliverEntities
          def initialize(faces, edges)
            @faces = faces
            @edges = edges
          end

          def grep(klass)
            return @faces if klass == SliverFace
            return @edges if klass == SliverEdge

            []
          end
        end

        class FakeModel
          attr_reader :calls
          attr_accessor :start_result, :commit_result, :abort_result

          def initialize
            @calls = []
            @start_result = true
            @commit_result = true
            @abort_result = true
          end

          def start_operation(name, transparent)
            @calls << [:start_operation, name, transparent]
            @start_result
          end

          def commit_operation
            @calls << [:commit_operation]
            @commit_result
          end

          def abort_operation
            @calls << [:abort_operation]
            @abort_result
          end
        end

        def normalizer(model: nil, face_class: FakeFace, edge_class: Sketchup::Edge)
          LocalVertexNormalizer.new(
            0.001,
            point_factory: ->(x, y, z) { Point.new(x, y, z) },
            vector_factory: ->(x, y, z) { [x, y, z] },
            edge_class: edge_class,
            face_class: face_class,
            model: model
          )
        end

        def tetrahedron_faces
          origin = point(0, 0, 0)
          x = point(1, 0, 0)
          y = point(0, 1, 0)
          z = point(0, 0, 1)
          [
            [origin, y, x],
            [origin, x, z],
            [origin, z, y],
            [x, y, z]
          ]
        end

        def point(x, y, z)
          Point.new(x.to_f, y.to_f, z.to_f)
        end

        def mm_point(x, y, z)
          point(x.to_f / 25.4, y.to_f / 25.4, z.to_f / 25.4)
        end

        def sliver_prism_triangle_records
          bottom = [
            mm_point(0, 0, 0),
            mm_point(0.2, 0, 0),
            mm_point(10, 0, 0),
            mm_point(10, 10, 0),
            mm_point(0, 10, 0)
          ]
          top = bottom.map { |point| mm_point(point.x * 25.4, point.y * 25.4, 10) }
          triangles = []
          add_triangle_record(triangles, bottom[3], bottom[4], bottom[0], :bottom)
          add_triangle_record(triangles, bottom[3], bottom[0], bottom[1], :bottom)
          add_triangle_record(triangles, bottom[3], bottom[1], bottom[2], :bottom)
          add_triangle_record(triangles, top[3], top[0], top[4], :top)
          add_triangle_record(triangles, top[3], top[1], top[0], :top)
          add_triangle_record(triangles, top[3], top[2], top[1], :top)

          5.times do |index|
            following = (index + 1) % 5
            add_triangle_record(
              triangles,
              bottom[index],
              bottom[following],
              top[following],
              "side_#{index}".to_sym
            )
            add_triangle_record(
              triangles,
              bottom[index],
              top[following],
              top[index],
              "side_#{index}".to_sym
            )
          end

          [
            triangles,
            {
              bottom_a: bottom[0],
              bottom_b: bottom[1],
              top_a: top[0],
              top_b: top[1]
            }
          ]
        end

        def add_triangle_record(records, point_a, point_b, point_c, source_face_key)
          records << {
            points: [point_a, point_b, point_c],
            source_normal: [0.0, 0.0, 1.0],
            material: nil,
            back_material: nil,
            layer: nil,
            source_face_key: source_face_key,
            source_polygon_index: records.length
          }
        end

        def boundary_edges_for(instance, records)
          incidence = Hash.new(0)
          records.each do |record|
            keys = record[:points].map do |point|
              instance.send(:grid_indices, point)
            end
            3.times do |index|
              edge = instance.send(
                :canonical_edge_key,
                keys[index],
                keys[(index + 1) % 3]
              )
              incidence[edge] += 1
            end
          end
          incidence.filter_map { |edge, count| edge if count == 1 }
        end

        def sliver_face(
          x_mm:,
          persistent_id:,
          support_top:,
          support_bottom:,
          width_mm: 0.2,
          height_mm: 100
        )
          vertices = [
            SliverVertex.new(mm_point(x_mm, 0, 0)),
            SliverVertex.new(mm_point(x_mm + width_mm, 0, 0)),
            SliverVertex.new(mm_point(x_mm + width_mm, 0, height_mm)),
            SliverVertex.new(mm_point(x_mm, 0, height_mm))
          ]
          edges = 4.times.map do |index|
            SliverEdge.new(vertices[index], vertices[(index + 1) % 4])
          end
          face = SliverFace.new(SliverLoop.new(vertices, edges), persistent_id)
          edges.each { |edge| edge.faces = [face] }
          edges[0].faces << support_top
          edges[2].faces << support_bottom
          [face, edges]
        end
      end
    end
  end
end
