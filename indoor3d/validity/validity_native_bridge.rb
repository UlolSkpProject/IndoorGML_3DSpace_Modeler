# frozen_string_literal: true

require_relative '../application/adjacency_service/native_bridge'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ValidityNativeBridge
        REQUEST_MAGIC = "IGMLVLD\0".b.freeze
        RESULT_MAGIC = "IGMLVRS\0".b.freeze
        VALIDITY_FORMAT_ID = 1
        GEOMETRY_FORMAT_ID = 3
        GEOMETRY_MAGIC = "IGMLADJ\0".b.freeze
        NORMAL_TOLERANCE = 0.000001
        POLL_INTERVAL_SECONDS = 0.01
        RESULT_FIXED_SIZE = 80

        NATIVE_EXTENSION_PATH = File.expand_path(
          File.join(__dir__, '..', 'native', 'validity', 'indoor_gml_validity_native.so')
        ).freeze

        STATUS = {
          1 => :no_overlap,
          2 => :thin_overlap,
          3 => :overlap,
          4 => :adjacent,
          5 => :not_adjacent,
          6 => :uncertain
        }.freeze

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
            raise ProtocolError, 'negative validity binary read length' if length.negative?
            raise ProtocolError, 'validity native result is truncated' if length > remaining

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
          return false unless File.exist?(NATIVE_EXTENSION_PATH)

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
          defined?(ULOL::Indoor3DGmlModeler::ValidityNative) &&
            ULOL::Indoor3DGmlModeler::ValidityNative.respond_to?(:load_batch)
        end

        def native
          require NATIVE_EXTENSION_PATH unless native_loaded?
          ULOL::Indoor3DGmlModeler::ValidityNative
        end

        def compute(snapshots, requests, overlap_tolerance:, normal_tolerance: NORMAL_TOLERANCE)
          raise ProtocolError, 'validity native extension is unavailable' unless available?

          snapshots = Array(snapshots)
          requests = Array(requests)
          geometry_bytes = encode_geometry_input(snapshots)
          request_bytes = encode_requests(requests, snapshots.length)

          native_module = native
          loaded = native_module.load_batch(geometry_bytes).to_i
          unless loaded == snapshots.length
            raise ProtocolError,
                  "validity native loaded #{loaded} cells, expected #{snapshots.length}"
          end

          started = native_module.start_check(
            request_bytes,
            Float(overlap_tolerance),
            Float(normal_tolerance)
          ).to_i
          unless started == requests.length
            raise ProtocolError,
                  "validity native accepted #{started} requests, expected #{requests.length}"
          end

          loop do
            progress = normalize_hash(native_module.get_progress)
            yield(:progress, progress) if block_given?
            break if progress[:completed]

            sleep(POLL_INTERVAL_SECONDS)
          end

          results = decode_results(native_module.get_result_bytes, snapshots.length)
          metrics = normalize_hash(native_module.get_metrics)
          {
            results: results.freeze,
            metrics: metrics.freeze
          }
        ensure
          begin
            native_module&.clear_session
          rescue StandardError
            nil
          end
        end


        # Validity owns a compact geometry contract: no State flags, fixed Z,
        # category, inner loops, or plane. Triangles describe the occupied face.
        def encode_geometry_input(snapshots)
          snapshots = Array(snapshots)
          buffer = String.new(encoding: Encoding::BINARY)
          buffer << GEOMETRY_MAGIC
          append_pack(buffer, [GEOMETRY_FORMAT_ID, snapshots.length, 0], 'Q<Q<Q<')

          snapshots.each_with_index do |snapshot, cell_index|
            geometry = Hash(snapshot)
            bounds = Hash(geometry.fetch(:bounds))
            minimum = validity_vec3(bounds.fetch(:min), "cell #{cell_index} bounds minimum")
            maximum = validity_vec3(bounds.fetch(:max), "cell #{cell_index} bounds maximum")
            raise ProtocolError, "cell #{cell_index} bounds are inverted" if 3.times.any? { |axis| minimum[axis] > maximum[axis] }

            faces = Array(geometry[:faces])
            face_bytes = String.new(encoding: Encoding::BINARY)
            faces.each_with_index do |face_value, face_index|
              face = Hash(face_value)
              label = "cell #{cell_index} face #{face_index}"
              points = Array(face[:points]).map { |point| validity_vec3(point, "#{label} outer vertex") }
              raise ProtocolError, "#{label} requires at least three outer vertices" if points.length < 3
              triangles = Array(face[:triangles]).map do |triangle|
                vertices = Array(triangle)
                raise ProtocolError, "#{label} triangle must have three vertices" unless vertices.length == 3
                vertices.map { |vertex| validity_vec3(vertex, "#{label} triangle vertex") }
              end
              normal = face[:normal]
              if normal.nil?
                coefficients = Array(face[:plane]).first(3).map { |value| finite_f64(value, "#{label} plane normal") }
                raise ProtocolError, "#{label} plane normal must have three coefficients" unless coefficients.length == 3
                magnitude = Math.sqrt(coefficients.sum { |value| value * value })
                raise ProtocolError, "#{label} normal is degenerate" unless magnitude.finite? && magnitude > 1.0e-12
                normal = coefficients.map { |value| value / magnitude }
              end
              normal = validity_vec3(normal, "#{label} normal")
              raise ProtocolError, "#{label} normal is degenerate" if normal.sum { |value| value * value } <= 1.0e-24

              face_size = 56 + points.length * 24 + triangles.length * 72
              append_pack(face_bytes, [face_size, points.length, triangles.length, 0], 'Q<Q<Q<Q<')
              append_pack(face_bytes, normal, 'E3')
              points.each { |point| append_pack(face_bytes, point, 'E3') }
              triangles.each { |triangle| triangle.each { |point| append_pack(face_bytes, point, 'E3') } }
            end

            cell_size = 80 + face_bytes.bytesize
            append_pack(buffer, [cell_size, cell_index, faces.length, 0], 'Q<Q<Q<Q<')
            append_pack(buffer, minimum + maximum, 'E6')
            buffer << face_bytes
          end
          buffer
        end

        def validity_vec3(value, label)
          values = Array(value)
          raise ProtocolError, "#{label} must contain three values" unless values.length == 3
          values.map { |component| finite_f64(component, label) }
        end
        private_class_method :validity_vec3

        def encode_requests(requests, cell_count)
          buffer = String.new(capacity: 32 + requests.length * 24, encoding: Encoding::BINARY)
          buffer << REQUEST_MAGIC
          append_pack(buffer, [VALIDITY_FORMAT_ID, requests.length, 0], 'Q<Q<Q<')

          requests.each do |request|
            row = Hash(request)
            first = checked_index(row.fetch(:first), cell_count, 'validity first index')
            second = checked_index(row.fetch(:second), cell_count, 'validity second index')
            raise ProtocolError, 'validity pair indices must be normalized' unless first < second

            code = Integer(row.fetch(:code))
            raise ProtocolError, "unsupported validity code #{code}" unless code == 701 || code == 704

            append_pack(buffer, [first, second, code], 'Q<Q<Q<')
          end
          buffer
        rescue KeyError => e
          raise ProtocolError, "validity request field missing: #{e.message}"
        end

        def decode_results(bytes, cell_count)
          reader = BinaryReader.new(bytes)
          raise ProtocolError, 'validity result header is truncated' if reader.remaining < 32
          raise ProtocolError, 'validity result magic mismatch' unless reader.read_bytes(8) == RESULT_MAGIC

          version = reader.read_u64
          raise ProtocolError, "unsupported validity result format #{version}" unless version == VALIDITY_FORMAT_ID

          count = checked_count(reader.read_u64, 'validity result count')
          raise ProtocolError, 'validity result reserved field is non-zero' unless reader.read_u64.zero?

          results = []
          count.times do
            record_start = reader.position
            record_size = checked_count(reader.read_u64, 'validity record size')
            raise ProtocolError, 'validity record is too small' if record_size < RESULT_FIXED_SIZE
            raise ProtocolError, 'validity record exceeds result payload' if record_start + record_size > reader.size

            first = checked_index(reader.read_u64, cell_count, 'validity first index')
            second = checked_index(reader.read_u64, cell_count, 'validity second index')
            raise ProtocolError, 'validity result pair indices are not normalized' unless first < second

            code = reader.read_u64.to_i
            raise ProtocolError, "unsupported validity result code #{code}" unless code == 701 || code == 704

            status_value = reader.read_u64.to_i
            status = STATUS[status_value]
            raise ProtocolError, "unsupported validity status #{status_value}" unless status

            axis_value = reader.read_u64.to_i
            axis = case axis_value
                   when 0 then :x
                   when 1 then :y
                   when 2 then :z
                   when 3 then nil
                   else
                     raise ProtocolError, "invalid validity axis #{axis_value}"
                   end
            volume = finite_f64(reader.read_f64, 'validity overlap volume')
            component_count = checked_count(reader.read_u64, 'validity component count')
            vertex_count = checked_count(reader.read_u64, 'validity vertex count')
            triangle_count = checked_count(reader.read_u64, 'validity triangle count')

            vertices = Array.new(vertex_count) do
              [
                finite_f64(reader.read_f64, 'validity vertex x'),
                finite_f64(reader.read_f64, 'validity vertex y'),
                finite_f64(reader.read_f64, 'validity vertex z')
              ].freeze
            end
            triangles = Array.new(triangle_count) do
              3.times.map do
                checked_index(reader.read_u64, vertex_count, 'validity triangle vertex')
              end.freeze
            end

            unless reader.position == record_start + record_size
              raise ProtocolError, 'validity record size does not match decoded payload'
            end

            results << {
              first: first,
              second: second,
              code: code,
              status: status,
              axis: axis,
              volume: volume,
              component_count: component_count,
              vertices: vertices.freeze,
              triangles: triangles.freeze
            }.freeze
          end

          raise ProtocolError, 'validity result has trailing bytes' unless reader.finished?
          results
        end

        def append_pack(buffer, values, format)
          values.pack(format, buffer: buffer)
          buffer
        end
        private_class_method :append_pack

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

        def finite_f64(value, label)
          number = Float(value)
          raise ProtocolError, "#{label} is not finite" unless number.finite?
          number
        rescue ArgumentError, TypeError
          raise ProtocolError, "#{label} is invalid"
        end
        private_class_method :finite_f64

        def normalize_hash(value)
          Hash(value).each_with_object({}) do |(key, item), output|
            output[key.respond_to?(:to_sym) ? key.to_sym : key] = item
          end
        rescue StandardError
          {}
        end
        private_class_method :normalize_hash
      end
    end
  end
end
