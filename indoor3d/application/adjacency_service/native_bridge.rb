# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module NativeAdjacencyBridge
        INPUT_MAGIC = "IGMLADJ\0".b.freeze
        OUTPUT_MAGIC = "IGMLRES\0".b.freeze
        PROTOCOL_VERSION = 1
        NORMAL_TOLERANCE = 0.000001
        POLL_INTERVAL_SECONDS = 0.01

        NATIVE_EXTENSION_PATH = File.expand_path(
          File.join(__dir__, '..', '..', 'native', 'adjacency', 'indoor_gml_adjacency_native.so')
        ).freeze

        class ProtocolError < StandardError; end

        class BinaryReader
          attr_reader :position

          def initialize(bytes)
            @bytes = String(bytes).b
            @position = 0
          end

          def size
            @bytes.bytesize
          end

          def remaining
            size - @position
          end

          def finished?
            @position == size
          end

          def read_bytes(length)
            length = Integer(length)
            raise ProtocolError, 'negative binary read length' if length.negative?
            raise ProtocolError, 'native result is truncated' if length > remaining

            value = @bytes.byteslice(@position, length)
            @position += length
            value
          end

          def read_u64
            read_bytes(8).unpack1('Q<')
          end

          def read_f64
            read_bytes(8).unpack1('E')
          end
        end

        module_function

        def available?
          return true if native_loaded?
          return false if @load_failed

          native
          true
        rescue LoadError, StandardError => e
          @load_error = e
          @load_failed = true
          false
        end

        def load_error
          @load_error
        end

        def native_loaded?
          defined?(ULOL::Indoor3DGmlModeler::AdjacencyNative) &&
            ULOL::Indoor3DGmlModeler::AdjacencyNative.respond_to?(:load_batch)
        end

        def native
          require NATIVE_EXTENSION_PATH unless native_loaded?
          ULOL::Indoor3DGmlModeler::AdjacencyNative
        end

        def compute(snapshots, tolerance:)
          snapshots = Array(snapshots)
          serialization_started_at = monotonic_time
          input_bytes = encode_input(snapshots)
          serialization_duration = elapsed_since(serialization_started_at)

          native_module = native
          parse_started_at = monotonic_time
          loaded_count = native_module.load_batch(input_bytes)
          parse_duration = elapsed_since(parse_started_at)
          unless loaded_count.to_i == snapshots.length
            raise ProtocolError,
                  "native adjacency loaded #{loaded_count} cells, expected #{snapshots.length}"
          end
          yield(:loaded, { cell_count: loaded_count.to_i }) if block_given?

          candidate_count = native_module.start_check(tolerance.to_f, NORMAL_TOLERANCE).to_i
          progress = normalize_hash(native_module.get_progress)
          progress[:candidate_count] = candidate_count
          yield(:candidate_complete, progress) if block_given?

          loop do
            progress = normalize_hash(native_module.get_progress)
            yield(:detailed_progress, progress) if block_given?
            break if progress[:completed]

            sleep(POLL_INTERVAL_SECONDS)
          end

          decode_started_at = monotonic_time
          output_bytes = native_module.get_result_bytes
          decoded = decode_result(output_bytes, snapshots)
          decode_duration = elapsed_since(decode_started_at)

          metrics = normalize_hash(native_module.get_metrics)
          metrics[:serialization_duration] = serialization_duration
          metrics[:parse_duration] = parse_duration
          metrics[:result_decode_duration] = decode_duration
          metrics[:input_bytes] = input_bytes.bytesize
          metrics[:output_bytes] = output_bytes.bytesize
          metrics[:candidate_count] = candidate_count unless metrics.key?(:candidate_count)

          decoded.merge(metrics: metrics.freeze)
        ensure
          begin
            native_module&.clear_session
          rescue StandardError
            nil
          end
        end

        def encode_input(snapshots)
          snapshots = Array(snapshots)
          records = snapshots.each_with_index.map do |snapshot, cell_index|
            encode_cell(snapshot, cell_index)
          end
          INPUT_MAGIC +
            [PROTOCOL_VERSION, snapshots.length, 0].pack('Q<Q<Q<') +
            records.join
        end

        def decode_result(bytes, snapshots)
          snapshots = Array(snapshots)
          reader = BinaryReader.new(bytes)
          raise ProtocolError, 'native result header is truncated' if reader.remaining < 32

          magic = reader.read_bytes(8)
          raise ProtocolError, 'native result magic mismatch' unless magic == OUTPUT_MAGIC

          version = reader.read_u64
          raise ProtocolError, "unsupported native result version #{version}" unless version == PROTOCOL_VERSION

          pair_count = checked_count(reader.read_u64, 'pair count')
          expected_candidate_total = checked_count(reader.read_u64, 'candidate total')
          pair_results = []
          contexts = []
          observed_candidate_total = 0
          previous_pair = nil

          pair_count.times do
            record_start = reader.position
            record_size = checked_count(reader.read_u64, 'pair record size')
            raise ProtocolError, 'pair record is too small' if record_size < 40
            raise ProtocolError, 'pair record exceeds native result' if record_start + record_size > reader.size

            index1 = checked_index(reader.read_u64, snapshots.length, 'cell index 1')
            index2 = checked_index(reader.read_u64, snapshots.length, 'cell index 2')
            raise ProtocolError, 'native pair indices are not normalized' unless index1 < index2

            axis = decode_axis(reader.read_u64)
            candidate_count = checked_count(reader.read_u64, 'candidate count')
            pair_key = [index1, index2]
            if previous_pair && ((pair_key <=> previous_pair) || 0) <= 0
              raise ProtocolError, 'native pair ordering is not strictly increasing'
            end
            previous_pair = pair_key

            faces1 = Array(snapshots[index1] && snapshots[index1][:faces])
            faces2 = Array(snapshots[index2] && snapshots[index2][:faces])
            candidates = []

            candidate_count.times do
              face1_index = checked_index(reader.read_u64, faces1.length, 'face1 index')
              face2_index = checked_index(reader.read_u64, faces2.length, 'face2 index')
              candidate_axis = decode_axis(reader.read_u64)
              reserved = reader.read_u64
              raise ProtocolError, 'candidate reserved field is non-zero' unless reserved.zero?

              area = finite_f64(reader.read_f64, 'candidate area')
              centroid_x = finite_f64(reader.read_f64, 'candidate centroid x')
              centroid_y = finite_f64(reader.read_f64, 'candidate centroid y')
              raise ProtocolError, 'candidate area must be positive' unless area.positive?

              candidates << {
                area: area,
                centroid_2d: [centroid_x, centroid_y].freeze,
                axis: candidate_axis,
                face1: faces1.fetch(face1_index),
                face2: faces2.fetch(face2_index)
              }.freeze
            end

            unless reader.position == record_start + record_size
              raise ProtocolError, 'pair record size does not match decoded payload'
            end

            observed_candidate_total += candidate_count
            pair_results << [index1, index2, axis].freeze
            contexts << [
              index1,
              index2,
              {
                supported: true,
                adjacent: true,
                axis: axis,
                waypoint_snapshot_candidates: candidates.freeze
              }.freeze
            ].freeze
          end

          raise ProtocolError, 'native result has trailing bytes' unless reader.finished?
          unless observed_candidate_total == expected_candidate_total
            raise ProtocolError,
                  "native candidate total mismatch: #{observed_candidate_total} != #{expected_candidate_total}"
          end

          {
            pair_results: pair_results.freeze,
            contexts: contexts.freeze
          }
        end

        def encode_cell(snapshot, cell_index)
          snapshot = Hash(snapshot)
          bounds = Hash(snapshot.fetch(:bounds))
          min = vec3(bounds.fetch(:min), "cell #{cell_index} bounds min")
          max = vec3(bounds.fetch(:max), "cell #{cell_index} bounds max")
          3.times do |axis|
            raise ProtocolError, "cell #{cell_index} bounds are inverted" if min[axis] > max[axis]
          end

          faces = Array(snapshot[:faces])
          face_records = faces.each_with_index.map do |face, face_index|
            encode_face(face, cell_index, face_index)
          end
          body = face_records.join
          record_size = 80 + body.bytesize
          [record_size, cell_index, faces.length, 0].pack('Q<Q<Q<Q<') +
            (min + max).pack('E6') +
            body
        end
        private_class_method :encode_cell

        def encode_face(face, cell_index, face_index)
          face = Hash(face)
          normal = vec3(face.fetch(:normal), "cell #{cell_index} face #{face_index} normal")
          points = Array(face[:points]).map.with_index do |point, point_index|
            vec3(point, "cell #{cell_index} face #{face_index} point #{point_index}")
          end
          if points.length < 3
            raise ProtocolError, "cell #{cell_index} face #{face_index} has fewer than 3 outer points"
          end

          triangles = Array(face[:triangles]).map.with_index do |triangle, triangle_index|
            vertices = Array(triangle)
            unless vertices.length == 3
              raise ProtocolError,
                    "cell #{cell_index} face #{face_index} triangle #{triangle_index} is not a triangle"
            end
            vertices.map.with_index do |point, point_index|
              vec3(
                point,
                "cell #{cell_index} face #{face_index} triangle #{triangle_index} point #{point_index}"
              )
            end
          end

          point_bytes = points.flatten.pack('E*')
          triangle_bytes = triangles.flatten.pack('E*')
          record_size = 56 + point_bytes.bytesize + triangle_bytes.bytesize
          [record_size, points.length, triangles.length, 0].pack('Q<Q<Q<Q<') +
            normal.pack('E3') +
            point_bytes +
            triangle_bytes
        end
        private_class_method :encode_face

        def vec3(value, label)
          values = Array(value)
          raise ProtocolError, "#{label} must contain exactly 3 values" unless values.length == 3

          values.map.with_index do |component, index|
            finite_f64(Float(component), "#{label}[#{index}]")
          rescue ArgumentError, TypeError
            raise ProtocolError, "#{label}[#{index}] is not numeric"
          end
        end
        private_class_method :vec3

        def finite_f64(value, label)
          number = Float(value)
          raise ProtocolError, "#{label} is not finite" unless number.finite?

          number
        rescue ArgumentError, TypeError
          raise ProtocolError, "#{label} is not numeric"
        end
        private_class_method :finite_f64

        def checked_count(value, label)
          count = Integer(value)
          raise ProtocolError, "#{label} is negative" if count.negative?

          count
        rescue ArgumentError, TypeError
          raise ProtocolError, "#{label} is invalid"
        end
        private_class_method :checked_count

        def checked_index(value, size, label)
          index = checked_count(value, label)
          raise ProtocolError, "#{label} #{index} is out of range #{size}" if index >= size

          index
        end
        private_class_method :checked_index

        def decode_axis(value)
          case Integer(value)
          when 0 then :x
          when 1 then :y
          when 2 then :z
          else
            raise ProtocolError, "invalid native adjacency axis #{value}"
          end
        end
        private_class_method :decode_axis

        def normalize_hash(value)
          Hash(value).each_with_object({}) do |(key, item), output|
            normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
            output[normalized_key] = item
          end
        rescue StandardError
          {}
        end
        private_class_method :normalize_hash

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        private_class_method :monotonic_time

        def elapsed_since(started_at)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        end
        private_class_method :elapsed_since
      end
    end
  end
end
