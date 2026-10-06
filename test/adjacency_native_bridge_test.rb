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
