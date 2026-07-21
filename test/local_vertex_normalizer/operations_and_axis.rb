# frozen_string_literal: true

require_relative '../support/local_vertex_normalizer_test_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerTest < Minitest::Test
        def test_operation_commits_successful_reconstruction
          model = FakeModel.new
          result = normalizer(model: model).send(:with_normalization_operation, Object.new) do
            :rebuilt
          end

          assert_equal :rebuilt, result
          assert_equal :start_operation, model.calls[0][0]
          assert_equal [[:commit_operation]], model.calls.drop(1)
        end

        def test_operation_aborts_when_reconstruction_raises
          model = FakeModel.new
          error = assert_raises(RuntimeError) do
            normalizer(model: model).send(:with_normalization_operation, Object.new) do
              raise 'rebuild failed'
            end
          end

          assert_equal 'rebuild failed', error.message
          assert_equal [:start_operation, :abort_operation], model.calls.map(&:first)
        end

        def test_operation_can_commit_failed_state_for_development_inspection
          model = FakeModel.new
          error = assert_raises(RuntimeError) do
            normalizer(model: model).send(
              :with_normalization_operation,
              Object.new,
              commit_on_failure: true
            ) do
              raise 'rebuild failed'
            end
          end

          assert_equal 'rebuild failed', error.message
          assert_equal [:start_operation, :commit_operation], model.calls.map(&:first)
        end

        def test_failed_state_commit_failure_falls_back_to_abort
          model = FakeModel.new
          model.commit_result = false

          error = assert_raises(LocalVertexNormalizer::OperationError) do
            normalizer(model: model).send(
              :with_normalization_operation,
              Object.new,
              commit_on_failure: true
            ) do
              raise 'rebuild failed'
            end
          end

          assert_includes error.message, 'committing the failed state also failed'
          assert_equal(
            [:start_operation, :commit_operation, :abort_operation],
            model.calls.map(&:first)
          )
        end

        def test_operation_aborts_when_commit_fails
          model = FakeModel.new
          model.commit_result = false

          assert_raises(LocalVertexNormalizer::OperationError) do
            normalizer(model: model).send(:with_normalization_operation, Object.new) { :rebuilt }
          end

          assert_equal(
            [:start_operation, :commit_operation, :abort_operation],
            model.calls.map(&:first)
          )
        end

        def test_inward_shell_is_reversed_as_a_whole
          faces = tetrahedron_faces.map do |points|
            FakeFace.new(points.reverse)
          end

          result = normalizer(face_class: FakeFace).send(:orient_shell_outward, faces)

          assert_equal 4, result[:reversed_faces]
          assert_operator result[:signed_volume_before_in3], :<, 0.0
          assert_operator result[:signed_volume_after_in3], :>, 0.0
          assert faces.all? { |face| face.reverse_count == 1 }
        end

        def test_outward_shell_is_not_reversed
          faces = tetrahedron_faces.map { |points| FakeFace.new(points) }

          result = normalizer(face_class: FakeFace).send(:orient_shell_outward, faces)

          assert_equal 0, result[:reversed_faces]
          assert_operator result[:signed_volume_before_in3], :>, 0.0
          assert_equal result[:signed_volume_before_in3], result[:signed_volume_after_in3]
          assert faces.all? { |face| face.reverse_count.zero? }
        end

        def test_zero_signed_volume_is_rejected
          faces = [FakeFace.new([point(0, 0, 0), point(1, 0, 0), point(0, 1, 0)])]

          assert_raises(LocalVertexNormalizer::TopologyChangedError) do
            normalizer(face_class: FakeFace).send(:orient_shell_outward, faces)
          end
        end

        def test_connected_axis_faces_share_one_grid_plane_before_vertex_rounding
          vertices = [
            AxisVertex.new(mm_point(0, 0, 10.0001), 1),
            AxisVertex.new(mm_point(1, 0, 10.0007), 2),
            AxisVertex.new(mm_point(0, 1, 9.9999), 3),
            AxisVertex.new(mm_point(1, 1, 10.0003), 4)
          ]
          shared_edge = AxisEdge.new(100)
          faces = [
            AxisFace.new(
              [vertices[0], vertices[1], vertices[2]],
              point(0, 0, 1),
              [shared_edge]
            ),
            AxisFace.new(
              [vertices[1], vertices[3], vertices[2]],
              point(0, 0, 1),
              [shared_edge]
            )
          ]
          instance = normalizer(face_class: AxisFace)

          plan = instance.send(:axis_plane_normalization_plan, AxisEntities.new(faces))
          target = instance.send(:normalized_target, vertices[1].position, plan)

          assert_equal 1, plan[:cluster_count]
          assert_equal 2, plan[:face_count]
          assert_equal 4, plan[:constrained_vertex_count]
          assert_equal({ 2 => 1 }, plan[:axis_cluster_counts])
          assert_in_delta 10.0, target.z * 25.4, 1.0e-9
          assert_in_delta 0.0007, plan[:max_displacement_mm], 1.0e-9
        end

        def test_edge_connected_axis_faces_are_unified_without_distance_cutoff
          vertices = [
            AxisVertex.new(mm_point(0, 0, 0.000), 1),
            AxisVertex.new(mm_point(1, 0, 0.009), 2),
            AxisVertex.new(mm_point(0, 1, 0.000), 3),
            AxisVertex.new(mm_point(1, 1, 0.018), 4),
            AxisVertex.new(mm_point(2, 0, 0.009), 5)
          ]
          shared_edge = AxisEdge.new(200)
          faces = [
            AxisFace.new(
              [vertices[0], vertices[1], vertices[2]],
              point(0, 0, 1),
              [shared_edge]
            ),
            AxisFace.new(
              [vertices[1], vertices[3], vertices[2], vertices[4]],
              point(0, 0, 1),
              [shared_edge]
            )
          ]
          instance = normalizer(face_class: AxisFace)

          plan = instance.send(:axis_plane_normalization_plan, AxisEntities.new(faces))

          assert_equal 1, plan[:cluster_count]
          assert_equal 2, plan[:face_count]
          assert_equal 5, plan[:constrained_vertex_count]
          assert_equal({ 2 => 1 }, plan[:axis_cluster_counts])
          vertices.each do |vertex|
            target = instance.send(:normalized_target, vertex.position, plan)
            assert_in_delta 0.009, target.z * 25.4, 1.0e-9
          end
          assert_in_delta 0.009, plan[:max_displacement_mm], 1.0e-9
        end

        def test_face_outside_axis_angle_tolerance_uses_ordinary_grid_projection
          vertices = [
            AxisVertex.new(mm_point(0, 0, 10.0001), 1),
            AxisVertex.new(mm_point(1, 0, 10.0007), 2),
            AxisVertex.new(mm_point(0, 1, 9.9999), 3)
          ]
          angle = 0.02 * Math::PI / 180.0
          face = AxisFace.new(
            vertices,
            point(Math.sin(angle), 0, Math.cos(angle))
          )
          instance = normalizer(face_class: AxisFace)

          plan = instance.send(:axis_plane_normalization_plan, AxisEntities.new([face]))
          target = instance.send(:normalized_target, vertices[1].position, plan)

          assert_equal 0, plan[:cluster_count]
          assert_in_delta 10.001, target.z * 25.4, 1.0e-9
        end

        def test_disconnected_parallel_faces_are_not_forced_onto_one_plane
          first_vertices = [
            AxisVertex.new(mm_point(0, 0, 10.0004), 1),
            AxisVertex.new(mm_point(1, 0, 10.0004), 2),
            AxisVertex.new(mm_point(0, 1, 10.0004), 3)
          ]
          second_vertices = [
            AxisVertex.new(mm_point(2, 0, 10.0006), 4),
            AxisVertex.new(mm_point(3, 0, 10.0006), 5),
            AxisVertex.new(mm_point(2, 1, 10.0006), 6)
          ]
          faces = [
            AxisFace.new(first_vertices, point(0, 0, 1), [AxisEdge.new(301)]),
            AxisFace.new(second_vertices, point(0, 0, 1), [AxisEdge.new(302)])
          ]
          instance = normalizer(face_class: AxisFace)

          plan = instance.send(:axis_plane_normalization_plan, AxisEntities.new(faces))
          first_target = instance.send(:normalized_target, first_vertices[0].position, plan)
          second_target = instance.send(:normalized_target, second_vertices[0].position, plan)

          assert_equal 2, plan[:cluster_count]
          assert_in_delta 10.000, first_target.z * 25.4, 1.0e-9
          assert_in_delta 10.001, second_target.z * 25.4, 1.0e-9
        end
      end
    end
  end
end
