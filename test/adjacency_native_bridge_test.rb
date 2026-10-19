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

  def test_geometry_v5_serializes_plane_holes_and_keeps_triangle_payload
    snapshots = Marshal.load(Marshal.dump(sample_snapshots))
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
    assert_equal 5, bytes.byteslice(8, 8).unpack1('Q<')
    assert_equal 2, bytes.byteslice(16, 8).unpack1('Q<')

    first_cell = 32
    assert_equal 7, bytes.byteslice(first_cell + 16, 8).unpack1('Q<')
    assert_equal 0.25, bytes.byteslice(first_cell + 88, 8).unpack1('E')
    first_face = first_cell + 104
    assert_equal 4, bytes.byteslice(first_face + 8, 8).unpack1('Q<')
    assert_equal 2, bytes.byteslice(first_face + 16, 8).unpack1('Q<')
    assert_equal 1, bytes.byteslice(first_face + 24, 8).unpack1('Q<')
    assert_equal [1.0, 0.0, 0.0, -1.0],
                 bytes.byteslice(first_face + 32, 32).unpack('E4')
    inner_offset = first_face + 64 + 4 * 24
    assert_equal 4, bytes.byteslice(inner_offset, 8).unpack1('Q<')
    assert_equal hole.flatten, bytes.byteslice(inner_offset + 8, 4 * 24).unpack('E*')
    triangles_offset = inner_offset + 8 + 4 * 24
    assert_equal snapshots[0][:faces][0][:triangles].flatten,
                 bytes.byteslice(triangles_offset, 2 * 72).unpack('E*')
    second_cell = first_cell + bytes.byteslice(first_cell, 8).unpack1('Q<')
    assert_equal 10, bytes.byteslice(second_cell + 16, 8).unpack1('Q<')
    assert_equal 0, bytes.byteslice(second_cell + 104 + 24, 8).unpack1('Q<')
  end

  def test_geometry_v5_encodes_moved_and_edited_flags_together
    # moved: adjacency only (target + dirty)
    # edited: State/Ref plus adjacency (target + needs_state + dirty)
    bytes = Bridge.encode_geometry_input(
      sample_snapshots,
      [
        { needs_state: false, adjacency_dirty: true },
        { needs_state: true, adjacency_dirty: true }
      ]
    )
    first_cell_offset = 32
    second_cell_offset = first_cell_offset +
      bytes.byteslice(first_cell_offset, 8).unpack1('Q<')

    assert_equal 10, bytes.byteslice(first_cell_offset + 16, 8).unpack1('Q<')
    assert_equal 11, bytes.byteslice(second_cell_offset + 16, 8).unpack1('Q<')
  end

  def test_geometry_v5_requires_authoritative_plane_and_ignores_normal_metadata
    snapshot = Marshal.load(Marshal.dump(sample_snapshots.first))
    original = snapshot[:faces].first
    bytes = Bridge.encode_geometry_input([snapshot], [{ needs_state: true }])

    original[:normal] = [-1.0, 0.0, 0.0] # deliberately contradictory
    modified = Bridge.encode_geometry_input([snapshot], [{ needs_state: true }])
    assert_equal bytes, modified, 'V5 must use plane exclusively, not normal'

    original.delete(:plane)
    assert_raises(Bridge::ProtocolError) do
      Bridge.encode_geometry_input([snapshot], [{ needs_state: true }])
    end

    original[:plane] = [0.0, 0.0, 0.0, 1.0]
    assert_raises(Bridge::ProtocolError) do
      Bridge.encode_geometry_input([snapshot], [{ needs_state: true }])
    end
  end

  def test_legacy_v1_normal_is_derived_and_normalized_from_plane_only
    snapshot = Marshal.load(Marshal.dump(sample_snapshots.first))
    face = snapshot.fetch(:faces).first
    face.delete(:normal)
    face[:plane] = [2.0, 0.0, 0.0, -2.0]
    bytes = Bridge.encode_input([snapshot])
    # 32-byte batch + 80-byte Cell + 32-byte Face header
    assert_equal [1.0, 0.0, 0.0],
                 bytes.byteslice(144, 24).unpack('E3')
    assert_equal 1, bytes.byteslice(8, 8).unpack1('Q<')
  end

  def test_legacy_v1_encoding_ignores_hole_metadata_and_remains_byte_identical
    snapshots = Marshal.load(Marshal.dump(sample_snapshots))
    snapshots[0][:faces][0][:inner_loops] = [
      [[1.0, 0.2, 0.2], [1.0, 0.8, 0.2], [1.0, 0.8, 0.8]]
    ]
    assert_equal legacy_encode_input(snapshots), Bridge.encode_input(snapshots)
  end

  def test_reference_v13_decodes_state_and_diagnostics_without_graph_payload
    bytes = "IGMLSTA\0".b + [13, 2, 0].pack('Q<3')
    bytes << [0, 0, 1].pack('Q<3') << [1.0, 2.0, 3.0].pack('E3')
    bytes << [10, 10, 9, 1, 12, 0, 2, 1, 9].pack('Q<9')
    bytes << [1, 60, 0].pack('Q<3')
    bytes << [1, 1, 1, 0, 1, 0, 1, 0, 0].pack('Q<9')

    decoded = Bridge.decode_state_result(bytes).fetch(:results)
    assert_equal [1.0, 2.0, 3.0], decoded.fetch(0).fetch(:state_point)
    assert_equal 1, decoded.fetch(0).fetch(:diagnostics).fetch(:failed_polygons)
    refute decoded.fetch(0).key?(:graph)
    assert_equal 60, decoded.fetch(1).fetch(:exit_code)
    assert_nil decoded.fetch(1).fetch(:state_point)
  end

  def test_reference_v13_rejects_unknown_exit_code
    bytes = "IGMLSTA\0".b + [13, 1, 0, 0, 999].pack('Q<5')
    assert_raises(Bridge::ProtocolError) { Bridge.decode_state_result(bytes) }
  end

  def test_reference_v13_rejects_old_native_protocol
    bytes = "IGMLSTA\0".b + [12, 0, 0].pack('Q<3')
    assert_raises(Bridge::ProtocolError) { Bridge.decode_state_result(bytes) }
  end

  def test_reference_exit_code_labels_have_distinct_failure_categories
    codes = Bridge::STATE_EXIT_CODES
    assert_equal :success, codes.fetch(0)
    assert_equal :no_floor_faces, codes.fetch(30)
    assert_equal :floor_preparation_failed, codes.fetch(31)
    assert_equal :partition_failed, codes.fetch(40)
    assert_equal :no_reference_candidates, codes.fetch(50)
    assert_equal :outside_solid, codes.fetch(60)
    assert_equal :insufficient_clearance, codes.fetch(61)
    assert_equal :mixed_reference_rejections, codes.fetch(62)
    assert_equal codes.size, codes.keys.uniq.size
  end

  def test_reference_waypoint_anchors_returns_two_native_points
    native = Module.new
    captured = nil
    native.define_singleton_method(:load_batch) { |_bytes| 0 }
    native.define_singleton_method(:get_reference_waypoint_anchors) do |first, second, bytes|
      captured = [first, second, bytes.unpack('E3')]
      [[1.0, 2.0, 10.0], [3.0, 4.0, 20.0]]
    end
    with_adjacency_native(native) do
      anchors = Bridge.reference_waypoint_anchors('first', 'second', [5.0, 6.0, 7.0])
      assert_equal [['first', 'second', [5.0, 6.0, 7.0]],
                    [[1.0, 2.0, 10.0], [3.0, 4.0, 20.0]]],
                   [captured, anchors]
    end
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

  def with_adjacency_native(native)
    owner = ULOL::Indoor3DGmlModeler
    existed = owner.const_defined?(:AdjacencyNative, false)
    original = owner.const_get(:AdjacencyNative, false) if existed
    owner.send(:remove_const, :AdjacencyNative) if existed
    owner.const_set(:AdjacencyNative, native)
    Bridge.instance_variable_set(:@load_failed, false)
    yield
  ensure
    owner.send(:remove_const, :AdjacencyNative) if
      owner.const_defined?(:AdjacencyNative, false)
    owner.const_set(:AdjacencyNative, original) if existed
    Bridge.instance_variable_set(:@load_failed, false)
  end

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
          normal: normal, # retained in fixture for V1 byte-compatibility
          plane: [normal[0], normal[1], normal[2], -(normal[0] * max_x)],
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
