# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/native_bridge'

class AdjacencyNativeBridgeTest < Minitest::Test
  Bridge = ULOL::Indoor3DGmlModeler::IndoorCore::NativeAdjacencyBridge

  def test_input_encoding_uses_versioned_little_endian_batch
    bytes = Bridge.encode_input(sample_snapshots)

    assert_equal "IGMLADJ\0".b, bytes.byteslice(0, 8)
    assert_equal 1, bytes.byteslice(8, 8).unpack1('Q<')
    assert_equal 2, bytes.byteslice(16, 8).unpack1('Q<')
    assert_equal 0, bytes.byteslice(24, 8).unpack1('Q<')
  end

  def test_optimized_input_encoding_is_byte_identical_to_legacy_layout
    assert_equal legacy_encode_input(sample_snapshots), Bridge.encode_input(sample_snapshots)
  end

  def test_geometry_v2_encoding_carries_state_flags
    bytes = Bridge.encode_geometry_input(
      sample_snapshots,
      [
        { needs_state: true, fixed_z: 0.25 },
        { needs_state: false, adjacency_dirty: true }
      ]
    )

    assert_equal "IGMLADJ\0".b, bytes.byteslice(0, 8)
    assert_equal 2, bytes.byteslice(8, 8).unpack1('Q<')
    assert_equal 2, bytes.byteslice(16, 8).unpack1('Q<')

    first_cell = 32
    assert_equal 0, bytes.byteslice(first_cell + 8, 8).unpack1('Q<')
    assert_equal 7, bytes.byteslice(first_cell + 16, 8).unpack1('Q<')
    assert_equal 0.25, bytes.byteslice(first_cell + 88, 8).unpack1('E')
    second_cell = first_cell + bytes.byteslice(first_cell, 8).unpack1('Q<')
    assert_equal 1, bytes.byteslice(second_cell + 8, 8).unpack1('Q<')
    assert_equal 10, bytes.byteslice(second_cell + 16, 8).unpack1('Q<')
  end

  def test_state_result_decoder_maps_cell_indices_to_points
    bytes =
      "IGMLSTA\0".b +
      [1, 2, 0].pack('Q<Q<Q<') +
      [0].pack('Q<') + [1.0, 2.0, 3.0].pack('E3') +
      [1].pack('Q<') + [4.0, 5.0, 6.0].pack('E3')

    assert_equal(
      {
        0 => [1.0, 2.0, 3.0],
        1 => [4.0, 5.0, 6.0]
      },
      Bridge.decode_state_result(bytes)
    )
  end

  def test_state_result_v5_includes_debug_graph_and_preserves_v4
    v4 = "IGMLSTA\0".b + [4, 1, 0].pack('Q<3')
    v4 << [0].pack('Q<') << [0.5, 0.5, 0.5].pack('E3')
    v4 << [1, 0].pack('Q<2')
    prior = Bridge.decode_state_result(v4)
    assert_equal [], prior[:graph_nodes][0]
    assert_equal [], prior[:graph_edges][0]
    assert_equal [0.5, 0.5, 0.5], prior[:points][0]

    v5 = "IGMLSTA\0".b + [5, 1, 0].pack('Q<3')
    v5 << [0].pack('Q<') << [0.5, 0.5, 0.5].pack('E3')
    v5 << [1, 1].pack('Q<2')
    v5 << [0.25, 0.5, 0.5].pack('E3') << [4].pack('Q<')
    v5 << [2].pack('Q<')
    v5 << [0.5, 0.5, 0.5, 1.0].pack('E4')
    v5 << [0.25, 0.5, 0.5, 0.5].pack('E4')
    v5 << [1, 0, 1].pack('Q<3')
    decoded = Bridge.decode_state_result(v5)
    assert_equal 4, decoded[:reference_kinds][0][0]
    assert_equal 2, decoded[:graph_nodes][0].length
    assert_equal({ point: [0.5, 0.5, 0.5], radius: 1.0 }, decoded[:graph_nodes][0][0])
    assert_equal [[0, 1]], decoded[:graph_edges][0]
  end

  def test_v6_state_result_decodes_native_validated_triangle_candidates
    v6 = "IGMLSTA\0".b + [6, 1, 0].pack('Q<3')
    v6 << [0].pack('Q<') << [0.5, 0.5, 0.5].pack('E3')
    v6 << [1, 0].pack('Q<2')
    v6 << [4].pack('Q<')
    [
      [0.5, 0.5, 0.5, 0.49],
      [0.3, 0.3, 0.5, 0.29],
      [0.7, 0.3, 0.5, 0.29],
      [0.5, 0.7, 0.5, 0.29]
    ].each { |node| v6 << node.pack('E4') }
    v6 << [3, 1, 2, 1, 3, 2, 3].pack('Q<7')
    v6 << [1, 1, 2, 3].pack('Q<4')
    v6 << [0.5, 1.3 / 3.0, 0.5, 0.4].pack('E4')
    v6 << [1, 0].pack('Q<2')

    decoded = Bridge.decode_state_result(v6)
    assert_equal 4, decoded[:graph_nodes][0].size
    assert_equal 3, decoded[:graph_edges][0].size
    assert_equal 1, decoded[:graph_loop_candidates][0].size
    candidate = decoded[:graph_loop_candidates][0].first
    assert_equal [1, 2, 3], candidate[:triangle]
    assert_equal [0], candidate[:visible_neighbors]
    assert_in_delta(0.5, candidate[:point][0], 1.0e-9)
  end

  def test_result_decoding_restores_snapshot_face_references
    snapshots = sample_snapshots
    candidate =
      [0, 0, 0, 0].pack('Q<Q<Q<Q<') +
      [1.0, 0.5, 0.5].pack('E3')
    pair =
      [40 + candidate.bytesize, 0, 1, 0, 1].pack('Q<Q<Q<Q<Q<') +
      candidate
    bytes =
      "IGMLRES\0".b +
      [1, 1, 1].pack('Q<Q<Q<') +
      pair

    decoded = Bridge.decode_result(bytes, snapshots)

    assert_equal [[0, 1, :x]], decoded[:pair_results]
    context = decoded[:contexts].first.fetch(2)
    assert_equal :x, context[:axis]
    assert context[:adjacent]
    assert_equal 1, context[:waypoint_snapshot_candidates].length
    result_candidate = context[:waypoint_snapshot_candidates].first
    assert_same snapshots[0][:faces][0], result_candidate[:face1]
    assert_same snapshots[1][:faces][0], result_candidate[:face2]
    assert_equal [0.5, 0.5], result_candidate[:centroid_2d]
  end

  def test_result_decoder_rejects_trailing_bytes
    bytes = "IGMLRES\0".b + [1, 0, 0].pack('Q<Q<Q<') + "x"

    assert_raises(Bridge::ProtocolError) do
      Bridge.decode_result(bytes, sample_snapshots)
    end
  end

  def legacy_encode_input(snapshots)
    records = snapshots.each_with_index.map do |snapshot, cell_index|
      faces = Array(snapshot[:faces])
      face_records = faces.map do |face|
        points = Array(face[:points])
        triangles = Array(face[:triangles])
        point_bytes = points.flatten.pack('E*')
        triangle_bytes = triangles.flatten.pack('E*')
        record_size = 56 + point_bytes.bytesize + triangle_bytes.bytesize
        [record_size, points.length, triangles.length, 0].pack('Q<Q<Q<Q<') +
          Array(face[:normal]).pack('E3') +
          point_bytes +
          triangle_bytes
      end
      body = face_records.join
      bounds = snapshot.fetch(:bounds)
      record_size = 80 + body.bytesize
      [record_size, cell_index, faces.length, 0].pack('Q<Q<Q<Q<') +
        (Array(bounds.fetch(:min)) + Array(bounds.fetch(:max))).pack('E6') +
        body
    end

    "IGMLADJ\0".b +
      [1, snapshots.length, 0].pack('Q<Q<Q<') +
      records.join
  end

  private

  def sample_snapshots
    @sample_snapshots ||= [
      snapshot(0.0, 1.0, [1.0, 0.0, 0.0]),
      snapshot(1.0, 2.0, [-1.0, 0.0, 0.0])
    ]
  end

  def snapshot(min_x, max_x, normal)
    points = [
      [max_x, 0.0, 0.0],
      [max_x, 1.0, 0.0],
      [max_x, 1.0, 1.0],
      [max_x, 0.0, 1.0]
    ]
    {
      bounds: {
        min: [min_x, 0.0, 0.0],
        max: [max_x, 1.0, 1.0]
      },
      faces: [
        {
          normal: normal,
          points: points,
          triangles: [
            [points[0], points[1], points[2]],
            [points[0], points[2], points[3]]
          ]
        }
      ]
    }
  end
end
