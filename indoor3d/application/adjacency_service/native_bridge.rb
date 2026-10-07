# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module NativeAdjacencyBridge
        INPUT_MAGIC = "IGMLADJ\0".b.freeze
        OUTPUT_MAGIC = "IGMLRES\0".b.freeze
        STATE_OUTPUT_MAGIC = "IGMLSTA\0".b.freeze
        PROTOCOL_VERSION = 1
        GEOMETRY_PROTOCOL_VERSION = 2
        NORMAL_TOLERANCE = 0.000001
        POLL_INTERVAL_SECONDS = 0.01
        INPUT_HEADER_SIZE = 32
        CELL_FIXED_SIZE = 80
        GEOMETRY_CELL_FIXED_SIZE = 96
        FACE_FIXED_SIZE = 56
        VEC3_SIZE = 24
        TRIANGLE_SIZE = 72

        CELL_FLAG_NEEDS_STATE = 1 << 0
        CELL_FLAG_ADJACENCY_TARGET = 1 << 1
        CELL_FLAG_HAS_FIXED_Z = 1 << 2
        CELL_FLAG_ADJACENCY_DIRTY = 1 << 3

        NATIVE_EXTENSION_PATH = File.expand_path(
          File.join(__dir__, '..', '..', 'native', 'indoor_gml_native.so')
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

        def shared_session_supported?
          return false unless available?

          native_module = native
          [
            :start_state_check,
            :get_state_result_bytes,
            :start_adjacency_check,
            :get_adjacency_result_bytes
          ].all? { |name| native_module.respond_to?(name) }
        rescue StandardError
          false
        end

        def incremental_supported?
          shared_session_supported?
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

        def shared_session_active?
          @shared_session_active == true
        end

        def open_geometry_session(snapshots, keys:, state_options:)
          raise ProtocolError, 'native geometry session is already active' if shared_session_active?
          raise ProtocolError, 'native extension does not support geometry sessions' unless shared_session_supported?

          snapshots = Array(snapshots)
          keys = Array(keys)
          options = Array(state_options)
          raise ProtocolError, 'native geometry session key count mismatch' unless keys.length == snapshots.length
          raise ProtocolError, 'native State option count mismatch' unless options.length == snapshots.length

          serialization_started_at = monotonic_time
          input_bytes = encode_geometry_input(snapshots, options)
          serialization_duration = elapsed_since(serialization_started_at)

          native_module = native
          parse_started_at = monotonic_time
          loaded_count = native_module.load_batch(input_bytes).to_i
          parse_duration = elapsed_since(parse_started_at)
          unless loaded_count == snapshots.length
            raise ProtocolError,
                  "native geometry session loaded #{loaded_count} cells, expected #{snapshots.length}"
          end

          @shared_session_active = true
          @shared_session_keys = keys.map(&:to_s).freeze
          @shared_session_metrics = {
            serialization_duration: serialization_duration,
            parse_duration: parse_duration,
            input_bytes: input_bytes.bytesize
          }.freeze
          loaded_count
        rescue StandardError
          begin
            native_module&.clear_session
          rescue StandardError
            nil
          end
          reset_shared_session_state
          raise
        end

        def compute_state_from_open_session
          raise ProtocolError, 'native geometry session is not active' unless shared_session_active?

          native_module = native
          target_count = native_module.start_state_check.to_i
          loop do
            progress = normalize_hash(native_module.get_progress)
            yield(:state_progress, progress) if block_given?
            break if progress[:completed]

            sleep(POLL_INTERVAL_SECONDS)
          end

          output_bytes = native_module.get_state_result_bytes
          points = decode_state_result(output_bytes)
          metrics = normalize_hash(native_module.get_metrics)
          metrics[:state_target_count] = target_count unless metrics.key?(:state_target_count)
          metrics[:state_output_bytes] = output_bytes.bytesize
          {
            points: points.freeze,
            metrics: metrics.freeze
          }
        end

        def close_geometry_session
          begin
            native.clear_session if native_loaded?
          ensure
            reset_shared_session_state
          end
          true
        rescue StandardError
          reset_shared_session_state
          false
        end

        def compute_incremental(snapshots, dirty_indices:, tolerance:, keys: nil, &block)
          raise ProtocolError, 'native extension does not support incremental adjacency' unless incremental_supported?

          snapshots = Array(snapshots)
          dirty = Array(dirty_indices).map { |index| Integer(index) }.uniq.sort
          raise ProtocolError, 'incremental adjacency requires at least one dirty Cell' if dirty.empty?

          dirty.each do |index|
            if index.negative? || index >= snapshots.length
              raise ProtocolError, "incremental dirty cell index #{index} is out of range"
            end
          end

          close_geometry_session if shared_session_active?

          serialization_started_at = monotonic_time
          dirty_lookup = dirty.each_with_object({}) { |index, out| out[index] = true }
          options = snapshots.each_index.map do |index|
            {
              needs_state: false,
              adjacency_dirty: dirty_lookup.key?(index)
            }
          end
          input_bytes = encode_geometry_input(snapshots, options)
          serialization_duration = elapsed_since(serialization_started_at)

          native_module = native
          parse_started_at = monotonic_time
          loaded_count = native_module.load_batch(input_bytes).to_i
          parse_duration = elapsed_since(parse_started_at)
          unless loaded_count == snapshots.length
            raise ProtocolError,
                  "native incremental adjacency loaded #{loaded_count} cells, expected #{snapshots.length}"
          end
          yield(:loaded, { cell_count: loaded_count }) if block_given?

          candidate_count =
            native_module.start_adjacency_check(tolerance.to_f, NORMAL_TOLERANCE).to_i
          progress = normalize_hash(native_module.get_progress)
          progress[:candidate_count] = candidate_count
          yield(:candidate_complete, progress) if block_given?

          poll_adjacency_progress(native_module) do |event, payload|
            yield(event, payload) if block_given?
          end

          decode_started_at = monotonic_time
          output_bytes = native_module.get_adjacency_result_bytes
          decoded = decode_result(output_bytes, snapshots)
          decode_duration = elapsed_since(decode_started_at)

          metrics = normalize_hash(native_module.get_metrics)
          metrics[:serialization_duration] = serialization_duration
          metrics[:parse_duration] = parse_duration
          metrics[:result_decode_duration] = decode_duration
          metrics[:input_bytes] = input_bytes.bytesize
          metrics[:output_bytes] = output_bytes.bytesize
          metrics[:candidate_count] = candidate_count unless metrics.key?(:candidate_count)
          metrics[:incremental_dirty_count] = dirty.length

          decoded.merge(metrics: metrics.freeze)
        ensure
          begin
            native_module&.clear_session
          rescue StandardError
            nil
          end
          reset_shared_session_state
        end

        def compute(snapshots, tolerance:, keys: nil, &block)
          snapshots = Array(snapshots)
          if shared_session_active?
            if keys && Array(keys).map(&:to_s) == @shared_session_keys
              return compute_adjacency_from_open_session(
                snapshots,
                tolerance: tolerance,
                &block
              )
            end

            close_geometry_session
          end

          compute_standalone(snapshots, tolerance: tolerance, &block)
        end

        def compute_standalone(snapshots, tolerance:)
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

          poll_adjacency_progress(native_module) { |event, payload| yield(event, payload) if block_given? }

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
        private_class_method :compute_standalone

        def compute_adjacency_from_open_session(snapshots, tolerance:)
          native_module = native
          candidate_count =
            native_module.start_adjacency_check(tolerance.to_f, NORMAL_TOLERANCE).to_i
          progress = normalize_hash(native_module.get_progress)
          progress[:candidate_count] = candidate_count
          yield(:candidate_complete, progress) if block_given?

          poll_adjacency_progress(native_module) { |event, payload| yield(event, payload) if block_given? }

          decode_started_at = monotonic_time
          output_bytes = native_module.get_adjacency_result_bytes
          decoded = decode_result(output_bytes, snapshots)
          decode_duration = elapsed_since(decode_started_at)

          metrics = normalize_hash(native_module.get_metrics)
          metrics.merge!(Hash(@shared_session_metrics))
          metrics[:result_decode_duration] = decode_duration
          metrics[:output_bytes] = output_bytes.bytesize
          metrics[:candidate_count] = candidate_count unless metrics.key?(:candidate_count)
          decoded.merge(metrics: metrics.freeze)
        end
        private_class_method :compute_adjacency_from_open_session

        def poll_adjacency_progress(native_module)
          loop do
            progress = normalize_hash(native_module.get_progress)
            yield(:detailed_progress, progress) if block_given?
            break if progress[:completed]

            sleep(POLL_INTERVAL_SECONDS)
          end
        end
        private_class_method :poll_adjacency_progress

        # V1 encoder retained for standalone adjacency compatibility.
        def encode_input(snapshots)
          snapshots = Array(snapshots)
          buffer = String.new(
            capacity: encoded_input_size(snapshots, CELL_FIXED_SIZE),
            encoding: Encoding::BINARY
          )
          buffer << INPUT_MAGIC
          append_pack(buffer, [PROTOCOL_VERSION, snapshots.length, 0], 'Q<Q<Q<')

          snapshots.each_with_index do |snapshot, cell_index|
            append_cell_v1(buffer, snapshot, cell_index)
          end
          buffer
        end

        def encode_geometry_input(snapshots, state_options)
          snapshots = Array(snapshots)
          state_options = Array(state_options)
          raise ProtocolError, 'State option count does not match snapshots' unless state_options.length == snapshots.length

          buffer = String.new(
            capacity: encoded_input_size(snapshots, GEOMETRY_CELL_FIXED_SIZE),
            encoding: Encoding::BINARY
          )
          buffer << INPUT_MAGIC
          append_pack(buffer, [GEOMETRY_PROTOCOL_VERSION, snapshots.length, 0], 'Q<Q<Q<')

          snapshots.each_with_index do |snapshot, cell_index|
            append_cell_v2(buffer, snapshot, cell_index, Hash(state_options[cell_index]))
          end
          buffer
        end

        def decode_state_result(bytes)
          reader = BinaryReader.new(bytes)
          raise ProtocolError, 'native State result header is truncated' if reader.remaining < 32

          magic = reader.read_bytes(8)
          raise ProtocolError, 'native State result magic mismatch' unless magic == STATE_OUTPUT_MAGIC

          version = reader.read_u64
          raise ProtocolError, "unsupported native State result version #{version}" unless version == PROTOCOL_VERSION

          result_count = checked_count(reader.read_u64, 'State result count')
          reserved = reader.read_u64
          raise ProtocolError, 'native State result reserved field is non-zero' unless reserved.zero?

          points = {}
          previous_index = nil
          result_count.times do
            cell_index = checked_count(reader.read_u64, 'State cell index')
            if @shared_session_keys && cell_index >= @shared_session_keys.length
              raise ProtocolError, "State cell index #{cell_index} is out of range"
            end
            if previous_index && cell_index <= previous_index
              raise ProtocolError, 'native State result indices are not strictly increasing'
            end
            previous_index = cell_index

            point = [
              finite_f64(reader.read_f64, 'State x'),
              finite_f64(reader.read_f64, 'State y'),
              finite_f64(reader.read_f64, 'State z')
            ].freeze
            points[cell_index] = point
          end

          raise ProtocolError, 'native State result has trailing bytes' unless reader.finished?
          points
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

        def encoded_input_size(snapshots, cell_fixed_size)
          total = INPUT_HEADER_SIZE
          snapshots.each do |snapshot|
            faces = Array(Hash(snapshot)[:faces])
            total += cell_fixed_size
            faces.each { |face| total += encoded_face_size(face) }
          end
          total
        end
        private_class_method :encoded_input_size

        def encoded_face_size(face)
          face = Hash(face)
          points = Array(face[:points])
          triangles = Array(face[:triangles])
          FACE_FIXED_SIZE +
            (points.length * VEC3_SIZE) +
            (triangles.length * TRIANGLE_SIZE)
        end
        private_class_method :encoded_face_size

        def cell_geometry(snapshot, cell_index)
          snapshot = Hash(snapshot)
          bounds = Hash(snapshot.fetch(:bounds))
          minimum = Array(bounds.fetch(:min))
          maximum = Array(bounds.fetch(:max))
          validate_vec3!(minimum, "cell #{cell_index} bounds min")
          validate_vec3!(maximum, "cell #{cell_index} bounds max")
          3.times do |axis|
            raise ProtocolError, "cell #{cell_index} bounds are inverted" if minimum[axis] > maximum[axis]
          end
          [minimum, maximum, Array(snapshot[:faces])]
        end
        private_class_method :cell_geometry

        def append_cell_v1(buffer, snapshot, cell_index)
          minimum, maximum, faces = cell_geometry(snapshot, cell_index)
          record_size = CELL_FIXED_SIZE
          faces.each { |face| record_size += encoded_face_size(face) }

          append_pack(buffer, [record_size, cell_index, faces.length, 0], 'Q<Q<Q<Q<')
          append_vec3(buffer, minimum, 'cell bounds min')
          append_vec3(buffer, maximum, 'cell bounds max')
          faces.each_with_index { |face, face_index| append_face(buffer, face, cell_index, face_index) }
        end
        private_class_method :append_cell_v1

        def append_cell_v2(buffer, snapshot, cell_index, option)
          minimum, maximum, faces = cell_geometry(snapshot, cell_index)
          flags = CELL_FLAG_ADJACENCY_TARGET
          flags |= CELL_FLAG_NEEDS_STATE if option[:needs_state] == true
          flags |= CELL_FLAG_ADJACENCY_DIRTY if option[:adjacency_dirty] == true

          fixed_z = option[:fixed_z]
          unless fixed_z.nil?
            fixed_z = finite_f64(fixed_z, "cell #{cell_index} fixed z")
            flags |= CELL_FLAG_HAS_FIXED_Z
          end
          fixed_z ||= 0.0

          record_size = GEOMETRY_CELL_FIXED_SIZE
          faces.each { |face| record_size += encoded_face_size(face) }

          append_pack(
            buffer,
            [record_size, cell_index, flags, faces.length, 0],
            'Q<Q<Q<Q<Q<'
          )
          append_vec3(buffer, minimum, 'cell bounds min')
          append_vec3(buffer, maximum, 'cell bounds max')
          append_pack(buffer, [fixed_z], 'E')
          faces.each_with_index { |face, face_index| append_face(buffer, face, cell_index, face_index) }
        end
        private_class_method :append_cell_v2

        def append_face(buffer, face, cell_index, face_index)
          face = Hash(face)
          normal = Array(face.fetch(:normal))
          points = Array(face[:points])
          triangles = Array(face[:triangles])
          face_label = "cell #{cell_index} face #{face_index}"

          validate_vec3!(normal, "#{face_label} normal")
          if points.length < 3
            raise ProtocolError, "#{face_label} has fewer than 3 outer points"
          end

          record_size =
            FACE_FIXED_SIZE +
            (points.length * VEC3_SIZE) +
            (triangles.length * TRIANGLE_SIZE)
          append_pack(buffer, [record_size, points.length, triangles.length, 0], 'Q<Q<Q<Q<')
          append_vec3(buffer, normal, "#{face_label} normal")

          points.each { |point| append_vec3(buffer, point, "#{face_label} outer point") }

          triangles.each_with_index do |triangle, triangle_index|
            vertices = Array(triangle)
            unless vertices.length == 3
              raise ProtocolError, "#{face_label} triangle #{triangle_index} is not a triangle"
            end
            vertices.each { |point| append_vec3(buffer, point, "#{face_label} triangle point") }
          end
        end
        private_class_method :append_face

        def append_vec3(buffer, value, label)
          values = Array(value)
          validate_vec3!(values, label)
          append_pack(buffer, values, 'E3')
        end
        private_class_method :append_vec3

        def validate_vec3!(values, label)
          raise ProtocolError, "#{label} must contain exactly 3 values" unless values.length == 3

          values.each_with_index do |component, index|
            unless component.is_a?(Numeric) && component.finite?
              raise ProtocolError, "#{label}[#{index}] is not a finite number"
            end
          end
        end
        private_class_method :validate_vec3!

        def append_pack(buffer, values, format)
          values.pack(format, buffer: buffer)
          buffer
        end
        private_class_method :append_pack

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

        def reset_shared_session_state
          @shared_session_active = false
          @shared_session_keys = nil
          @shared_session_metrics = nil
        end
        private_class_method :reset_shared_session_state

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
