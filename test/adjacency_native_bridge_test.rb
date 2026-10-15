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

  def test_geometry_v4_serializes_hole_loops_and_keeps_triangle_payload
    snapshots = sample_snapshots
    hole = [
      [1.0, 0.2, 0.2], [1.0, 0.8, 0.2],
      [1.0, 0.8, 0.8], [1.0, 0.2, 0.8]
    ]
    snapshots[0][:faces][0][:inner_loops] = [hole]
    bytes = Bridge.encode_geometry_input(
      snapshots,
      [{ needs_state: true, fixed_z: 0.25 },
       { needs_state: false, adjacency_dirty: true }]
    )
    assert_equal "IGMLADJ\0".b, bytes.byteslice(0, 8)
    assert_equal 4, bytes.byteslice(8, 8).unpack1('Q<')
    assert_equal 2, bytes.byteslice(16, 8).unpack1('Q<')

    first_cell = 32
    assert_equal 7, bytes.byteslice(first_cell + 16, 8).unpack1('Q<')
    assert_equal 0.25, bytes.byteslice(first_cell + 88, 8).unpack1('E')
    first_face = first_cell + 104
    assert_equal 4, bytes.byteslice(first_face + 8, 8).unpack1('Q<')
    assert_equal 2, bytes.byteslice(first_face + 16, 8).unpack1('Q<')
    assert_equal 1, bytes.byteslice(first_face + 24, 8).unpack1('Q<')
    inner_offset = first_face + 56 + 4 * 24
    assert_equal 4, bytes.byteslice(inner_offset, 8).unpack1('Q<')
    assert_equal hole.flatten, bytes.byteslice(inner_offset + 8, 4 * 24).unpack('E*')
    triangles_offset = inner_offset + 8 + 4 * 24
    assert_equal snapshots[0][:faces][0][:triangles].flatten,
                 bytes.byteslice(triangles_offset, 2 * 72).unpack('E*')
    second_cell = first_cell + bytes.byteslice(first_cell, 8).unpack1('Q<')
    assert_equal 10, bytes.byteslice(second_cell + 16, 8).unpack1('Q<')
    assert_equal 0, bytes.byteslice(second_cell + 104 + 24, 8).unpack1('Q<')
  end

  def test_legacy_v1_encoding_ignores_hole_metadata_and_remains_byte_identical
    snapshots = sample_snapshots
    snapshots[0][:faces][0][:inner_loops] = [
      [[1.0, 0.2, 0.2], [1.0, 0.8, 0.2], [1.0, 0.8, 0.8]]
    ]
    assert_equal legacy_encode_input(snapshots), Bridge.encode_input(snapshots)
  end

  def test_reference_v8_decodes_state_success_failure_and_optional_graph
    bytes = "IGMLSTA\0".b + [8, 3, 0].pack('Q<3')
    # Cell 0: valid State with one debug reference and two graph nodes
    bytes << [0, 1].pack('Q<2') << [1.0, 2.0, 3.0].pack('E3')
    bytes << [1].pack('Q<') # graph present
    bytes << [1].pack('Q<') << [4.0, 5.0, 6.0].pack('E3') << [4].pack('Q<')
    bytes << [2].pack('Q<')
    bytes << [1.0, 2.0, 3.0, 1.0].pack('E4')
    bytes << [4.0, 5.0, 6.0, 0.5].pack('E4')
    bytes << [1, 0, 1].pack('Q<3') # one edge
    bytes << [0].pack('Q<') # no collapse candidates
    # Cell 1: valid State without a Graph
    bytes << [1, 1].pack('Q<2') << [7.0, 8.0, 9.0].pack('E3')
    bytes << [0].pack('Q<')
    # Cell 2: valid native computation, but no State candidate.
    bytes << [2, 0, 0].pack('Q<3')

    decoded = Bridge.decode_state_result(bytes).fetch(:results)
    assert_equal({ success: true, state_point: [1.0, 2.0, 3.0] },
                 decoded[0].slice(:success, :state_point))
    assert_equal [[0, 1]], decoded[0][:graph][:edges]
    assert_equal [[4.0, 5.0, 6.0]], decoded[0][:graph][:debug_points]
    assert_equal [4], decoded[0][:graph][:debug_kinds]
    assert_equal({ success: true, state_point: [7.0, 8.0, 9.0], graph: nil },
                 decoded[1])
    assert_equal({ success: false, state_point: nil, graph: nil }, decoded[2])
  end

  def test_reference_v8_rejects_contradictory_failure_with_graph
    bytes = "IGMLSTA\0".b + [8, 1, 0, 0, 0, 1].pack('Q<6')
    assert_raises(Bridge::ProtocolError) { Bridge.decode_state_result(bytes) }
  end

  def test_reference_v8_rejects_old_native_protocol
    bytes = "IGMLSTA\0".b + [7, 0, 0].pack('Q<3')
    assert_raises(Bridge::ProtocolError) { Bridge.decode_state_result(bytes) }
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
