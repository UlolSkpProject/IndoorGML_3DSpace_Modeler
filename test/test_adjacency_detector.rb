# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/utils/geometry'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      class AdjacencyDetectorTest < Minitest::Test
        Vector = Struct.new(:x, :y, :z)

        def setup
          @geometry_methods = %i[
            clip_polygon
            snapshot_faces
            snapshot_bounds
            touching_bounds?
            adjacent_face_axis
            entity_faces_in_parent_space
            coplanar_area_overlapping_faces?
          ].each_with_object({}) do |name, methods|
            methods[name] = Geometry.method(name)
          end
          @private_geometry_methods = @geometry_methods.keys.select do |name|
            Geometry.singleton_class.private_method_defined?(name)
          end
        end

        def teardown
          @geometry_methods.each do |name, method|
            Geometry.define_singleton_method(name, method)
          end
          @private_geometry_methods.each do |name|
            Geometry.singleton_class.send(:private, name)
          end
        end

        def test_axis_aligned_faces_use_six_direction_buckets
          cases = {
            [1.0, 0.0, 0.0] => :positive_x,
            [-1.0, 0.0, 0.0] => :negative_x,
            [0.0, 1.0, 0.0] => :positive_y,
            [0.0, -1.0, 0.0] => :negative_y,
            [0.0, 0.0, 1.0] => :positive_z,
            [0.0, 0.0, -1.0] => :negative_z
          }

          cases.each do |normal, expected|
            assert_equal expected, Geometry.send(:face_direction_bucket, normal)
          end
        end

        def test_uncertain_and_sloped_normals_use_fallback_bucket
          diagonal = ::Math.sqrt(0.5)
          tolerance = Geometry::FACE_DIRECTION_BUCKET_TOLERANCE

          assert_equal :fallback, Geometry.send(:face_direction_bucket, [diagonal, diagonal, 0.0])
          assert_equal :positive_x, Geometry.send(:face_direction_bucket, [1.0, tolerance, 0.0])
          assert_equal :fallback, Geometry.send(:face_direction_bucket, [1.0, tolerance * 1.1, 0.0])
        end

        def test_axis_buckets_only_compare_opposite_directions
          faces1 = axis_direction_faces('one')
          faces2 = axis_direction_faces('two')

          pairs = direction_candidate_ids(faces1, faces2)

          assert_equal [
            %i[one_positive_x two_negative_x],
            %i[one_negative_x two_positive_x],
            %i[one_positive_y two_negative_y],
            %i[one_negative_y two_positive_y],
            %i[one_positive_z two_negative_z],
            %i[one_negative_z two_positive_z]
          ], pairs
          refute_includes pairs, %i[one_positive_x two_positive_x]
          refute_includes pairs, %i[one_negative_z two_negative_z]
        end

        def test_axis_and_fallback_candidate_rules_do_not_drop_sloped_faces
          diagonal = ::Math.sqrt(0.5)
          faces1 = [
            candidate_face(:axis_positive_x, [1.0, 0.0, 0.0]),
            candidate_face(:fallback_one, [diagonal, diagonal, 0.0])
          ]
          faces2 = [
            candidate_face(:axis_negative_x, [-1.0, 0.0, 0.0]),
            candidate_face(:axis_positive_y, [0.0, 1.0, 0.0]),
            candidate_face(:fallback_two, [-diagonal, -diagonal, 0.0])
          ]

          assert_equal [
            %i[axis_positive_x axis_negative_x],
            %i[axis_positive_x fallback_two],
            %i[fallback_one axis_negative_x],
            %i[fallback_one axis_positive_y],
            %i[fallback_one fallback_two]
          ], direction_candidate_ids(faces1, faces2)
        end

        def test_dominant_axis_boundary_opposite_normals_remain_candidates
          diagonal = ::Math.sqrt(0.5)
          face1 = candidate_face(:one, [diagonal, diagonal, 0.0])
          face2 = candidate_face(:two, [-diagonal, -diagonal, 0.0])

          assert_equal [[:one, :two]], direction_candidate_ids([face1], [face2])
          assert Geometry.send(:snapshot_normals_opposite?, face1[:normal], face2[:normal])
        end

        def test_generated_opposite_normals_are_never_filtered_out
          random = Random.new(12_345)

          100.times do |index|
            normal = Array.new(3) { random.rand(-1.0..1.0) }
            length = ::Math.sqrt(normal.sum { |value| value * value })
            redo if length <= 0.000001

            normal.map! { |value| value / length }
            opposite = normal.map { |value| -value }
            face1 = candidate_face("one_#{index}".to_sym, normal)
            face2 = candidate_face("two_#{index}".to_sym, opposite)

            assert_equal [[face1[:id], face2[:id]]], direction_candidate_ids([face1], [face2])
          end
        end

        def test_exact_opposite_check_rejects_a_coarse_fallback_candidate
          face1 = candidate_face(:axis, [1.0, 0.0, 0.0])
          face2 = candidate_face(:fallback, [-0.999, 0.0447, 0.0])

          assert_equal [[:axis, :fallback]], direction_candidate_ids([face1], [face2])
          refute Geometry.send(:coplanar_area_overlapping_snapshot_faces?, face1, face2, 0.001)
        end

        def test_snapshot_stores_and_deep_freezes_face_direction_index
          faces = [
            candidate_face(:positive_x, [1.0, 0.0, 0.0]),
            candidate_face(:sloped, [::Math.sqrt(0.5), ::Math.sqrt(0.5), 0.0])
          ]
          Geometry.define_singleton_method(:snapshot_faces) { |_entity, _transformation| faces }
          Geometry.define_singleton_method(:snapshot_bounds) do |_bounds|
            { min: [0.0, 0.0, 0.0], max: [1.0, 1.0, 1.0] }
          end
          entity = Struct.new(:bounds, :definition, :transformation) do
            def valid?
              true
            end
          end.new(Object.new, Object.new, Object.new)

          snapshot = Geometry.adjacency_snapshot(entity)

          assert_equal %i[positive_x fallback], snapshot[:face_bucket_keys]
          assert_equal [faces[0]], snapshot[:face_buckets][:positive_x]
          assert_equal [faces[1]], snapshot[:face_buckets][:fallback]
          assert snapshot.frozen?
          assert snapshot[:face_buckets].frozen?
          assert snapshot[:face_buckets][:fallback].frozen?
          assert snapshot[:face_bucket_keys].frozen?
        end

        def test_bucketed_snapshot_result_matches_brute_force_face_pairs
          diagonal = ::Math.sqrt(0.5)
          cases = {
            adjacent_axis_face: [
              [horizontal_face(:one, 1.0, square(0.0, 0.0, 2.0, 2.0))],
              [horizontal_face(:two, -1.0, square(0.0, 0.0, 2.0, 2.0))],
              :z
            ],
            boundary_touch_only: [
              [horizontal_face(:one, 1.0, square(0.0, 0.0, 1.0, 1.0))],
              [horizontal_face(:two, -1.0, square(1.0, 0.0, 2.0, 1.0))],
              nil
            ],
            tolerance_plane_match: [
              [horizontal_face(:one, 1.0, square(0.0, 0.0, 1.0, 1.0), z: 0.0)],
              [horizontal_face(:two, -1.0, square(0.0, 0.0, 1.0, 1.0), z: 0.0005)],
              :z
            ],
            beyond_plane_tolerance: [
              [horizontal_face(:one, 1.0, square(0.0, 0.0, 1.0, 1.0), z: 0.0)],
              [horizontal_face(:two, -1.0, square(0.0, 0.0, 1.0, 1.0), z: 0.0011)],
              nil
            ],
            rotated_sloped_face: [
              [sloped_face(:one, [diagonal, diagonal, 0.0])],
              [sloped_face(:two, [-diagonal, -diagonal, 0.0])],
              :x
            ],
            concave_face: [
              [horizontal_face(:one, 1.0, [[0, 0], [2, 0], [2, 1], [1, 0.5], [0, 1]])],
              [horizontal_face(:two, -1.0, [[0, 0], [2, 0], [2, 1], [1, 0.5], [0, 1]])],
              :z
            ],
            pentagon_face: [
              [horizontal_face(:one, 1.0, [[0, 0], [2, 0], [3, 1], [1.5, 2], [0, 1]])],
              [horizontal_face(:two, -1.0, [[0, 0], [2, 0], [3, 1], [1.5, 2], [0, 1]])],
              :z
            ],
            same_plane_disjoint: [
              [horizontal_face(:one, 1.0, square(0.0, 0.0, 1.0, 1.0))],
              [horizontal_face(:two, -1.0, square(2.0, 2.0, 3.0, 3.0))],
              nil
            ],
            opposite_normal_different_plane: [
              [horizontal_face(:one, 1.0, square(0.0, 0.0, 1.0, 1.0), z: 0.0)],
              [horizontal_face(:two, -1.0, square(0.0, 0.0, 1.0, 1.0), z: 1.0)],
              nil
            ]
          }

          cases.each do |name, (faces1, faces2, expected_axis)|
            snapshot1 = snapshot(faces1)
            snapshot2 = snapshot(faces2)

            expected = brute_force_snapshot_axis(faces1, faces2, 0.001)
            actual = Geometry.send(:adjacent_snapshot_face_axis, snapshot1, snapshot2, 0.001)

            if expected_axis.nil?
              assert_nil expected, "brute-force fixture for #{name}"
            else
              assert_equal expected_axis, expected, "brute-force fixture for #{name}"
            end
            if expected.nil?
              assert_nil actual, "bucket regression for #{name}"
            else
              assert_equal expected, actual, "bucket regression for #{name}"
            end
          end
        end

        def test_snapshot_overlap_exits_after_first_threshold_exceeding_pair
          triangle = triangle_with_area(0.5)
          face1 = overlap_face([triangle, triangle])
          face2 = overlap_face([triangle, triangle])

          calls = with_clip_count do
            assert Geometry.send(:snapshot_coplanar_overlap_exceeds?, face1, face2, 0.1)
          end

          assert_equal 1, calls
        end

        def test_snapshot_overlap_uses_accumulated_area_before_exiting
          triangle = triangle_with_area(0.04)
          face1 = overlap_face([triangle])
          face2 = overlap_face([triangle, triangle, triangle, triangle])

          calls = with_clip_count do
            assert Geometry.send(:snapshot_coplanar_overlap_exceeds?, face1, face2, 0.1)
          end

          assert_equal 3, calls
        end

        def test_snapshot_overlap_equal_to_threshold_remains_false
          triangle = triangle_with_area(0.125)
          face1 = overlap_face([triangle])
          face2 = overlap_face([triangle, triangle])

          calls = with_clip_count do
            refute Geometry.send(:snapshot_coplanar_overlap_exceeds?, face1, face2, 0.25)
          end

          assert_equal 2, calls
        end

        def test_snapshot_overlap_below_threshold_and_empty_triangles_are_false
          triangle = triangle_with_area(0.125)
          face = overlap_face([triangle])

          refute Geometry.send(:snapshot_coplanar_overlap_exceeds?, face, face, 0.126)
          refute Geometry.send(:snapshot_coplanar_overlap_exceeds?, overlap_face([]), face, 0.0)
          refute Geometry.send(:snapshot_coplanar_overlap_exceeds?, face, overlap_face([]), 0.0)
        end

        def test_snapshot_bounds_check_is_default_and_can_be_safely_skipped
          face1 = horizontal_face(:one, 1.0, square(0.0, 0.0, 1.0, 1.0))
          face2 = horizontal_face(:two, -1.0, square(0.0, 0.0, 1.0, 1.0))
          snapshot1 = snapshot([face1], min: [0, 0, 0], max: [1, 1, 1])
          snapshot2 = snapshot([face2], min: [10, 10, 10], max: [11, 11, 11])

          assert_nil Geometry.adjacency_axis_from_snapshots(snapshot1, snapshot2, tolerance: 0.001)
          assert_equal :z, Geometry.adjacency_axis_from_snapshots(
            snapshot1,
            snapshot2,
            tolerance: 0.001,
            bounds_checked: true
          )
          assert_nil Geometry.adjacency_axis_from_snapshots(nil, snapshot2, bounds_checked: true)
        end

        def test_snapshot_axis_supports_existing_snapshots_without_direction_buckets
          face1 = horizontal_face(:one, 1.0, square(0.0, 0.0, 1.0, 1.0))
          face2 = horizontal_face(:two, -1.0, square(0.0, 0.0, 1.0, 1.0))
          bounds = { min: [0.0, 0.0, 0.0], max: [1.0, 1.0, 1.0] }
          snapshot1 = { bounds: bounds, faces: [face1] }
          snapshot2 = { bounds: bounds, faces: [face2] }

          assert_equal :z, Geometry.adjacency_axis_from_snapshots(snapshot1, snapshot2)
        end

        def test_entity_adjacency_path_keeps_bounds_prefilter
          bounds_calls = 0
          face_calls = 0
          Geometry.define_singleton_method(:touching_bounds?) do |_bounds1, _bounds2, _tolerance|
            bounds_calls += 1
            false
          end
          Geometry.define_singleton_method(:adjacent_face_axis) do |_entity1, _entity2, _tolerance|
            face_calls += 1
            :x
          end
          entity = Struct.new(:bounds) do
            def valid?
              true
            end
          end.new(Object.new)

          assert_nil Geometry.adjacency_axis(entity, entity)
          assert_equal 1, bounds_calls
          assert_equal 0, face_calls
        end

        def test_entity_face_path_uses_the_same_direction_candidates
          diagonal = ::Math.sqrt(0.5)
          faces1 = [
            candidate_face(:axis_positive_x, Vector.new(1.0, 0.0, 0.0)),
            candidate_face(:fallback_one, Vector.new(diagonal, diagonal, 0.0))
          ]
          faces2 = [
            candidate_face(:axis_negative_x, Vector.new(-1.0, 0.0, 0.0)),
            candidate_face(:axis_positive_y, Vector.new(0.0, 1.0, 0.0)),
            candidate_face(:fallback_two, Vector.new(-diagonal, -diagonal, 0.0))
          ]
          entity1 = Object.new
          entity2 = Object.new
          Geometry.define_singleton_method(:entity_faces_in_parent_space) do |entity, _transformation = nil|
            entity.equal?(entity1) ? faces1 : faces2
          end
          seen_pairs = []
          Geometry.define_singleton_method(:coplanar_area_overlapping_faces?) do |face1, face2, _tolerance|
            seen_pairs << [face1[:id], face2[:id]]
            false
          end

          assert_nil Geometry.send(:adjacent_face_axis, entity1, entity2, 0.001)
          assert_equal [
            %i[axis_positive_x axis_negative_x],
            %i[axis_positive_x fallback_two],
            %i[fallback_one axis_negative_x],
            %i[fallback_one axis_positive_y],
            %i[fallback_one fallback_two]
          ], seen_pairs
        end

        private

        def candidate_face(id, normal)
          {
            id: id,
            normal: normal,
            points: [[0.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            triangles: []
          }
        end

        def axis_direction_faces(prefix)
          {
            positive_x: [1.0, 0.0, 0.0],
            negative_x: [-1.0, 0.0, 0.0],
            positive_y: [0.0, 1.0, 0.0],
            negative_y: [0.0, -1.0, 0.0],
            positive_z: [0.0, 0.0, 1.0],
            negative_z: [0.0, 0.0, -1.0]
          }.map { |name, normal| candidate_face("#{prefix}_#{name}".to_sym, normal) }
        end

        def direction_candidate_ids(faces1, faces2)
          directions1 = Geometry.send(:face_direction_index, faces1)
          directions2 = Geometry.send(:face_direction_index, faces2)
          pairs = []
          Geometry.send(:each_face_direction_candidate, faces1, directions1, faces2, directions2) do |face1, face2|
            pairs << [face1[:id], face2[:id]]
          end
          pairs
        end

        def square(min_x, min_y, max_x, max_y)
          [[min_x, min_y], [max_x, min_y], [max_x, max_y], [min_x, max_y]]
        end

        def horizontal_face(id, normal_z, polygon, z: 0.0)
          points = polygon.map { |x, y| [x.to_f, y.to_f, z.to_f] }
          {
            id: id,
            normal: [0.0, 0.0, normal_z],
            points: points,
            triangles: triangulate(points)
          }
        end

        def sloped_face(id, normal)
          points = [[0.0, 0.0, 0.0], [1.0, -1.0, 0.0], [1.0, -1.0, 1.0], [0.0, 0.0, 1.0]]
          { id: id, normal: normal, points: points, triangles: triangulate(points) }
        end

        def triangulate(points)
          (1...(points.length - 1)).map { |index| [points.first, points[index], points[index + 1]] }
        end

        def snapshot(faces, min: [0.0, 0.0, 0.0], max: [1.0, 1.0, 1.0])
          directions = Geometry.send(:face_direction_index, faces)
          {
            bounds: { min: min, max: max },
            faces: faces,
            face_buckets: directions[:buckets],
            face_bucket_keys: directions[:keys]
          }
        end

        def brute_force_snapshot_axis(faces1, faces2, tolerance)
          faces1.each do |face1|
            faces2.each do |face2|
              next unless Geometry.send(:coplanar_area_overlapping_snapshot_faces?, face1, face2, tolerance)

              return Geometry.send(:dominant_snapshot_axis, face1[:normal])
            end
          end
          nil
        end

        def triangle_with_area(area)
          [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, area * 2.0, 0.0]]
        end

        def overlap_face(triangles)
          { normal: [0.0, 0.0, 1.0], triangles: triangles }
        end

        def with_clip_count
          calls = 0
          original = @geometry_methods.fetch(:clip_polygon)
          Geometry.define_singleton_method(:clip_polygon) do |subject, clipping|
            calls += 1
            original.call(subject, clipping)
          end
          yield
          calls
        ensure
          Geometry.define_singleton_method(:clip_polygon, original)
          Geometry.singleton_class.send(:private, :clip_polygon)
        end
      end
    end
  end
end
