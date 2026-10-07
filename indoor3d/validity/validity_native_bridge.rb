# frozen_string_literal: true

require_relative '../application/adjacency_service/native_bridge'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ValidityNativeBridge
        REQUEST_MAGIC = "IGMLVLD\0".b.freeze
        RESULT_MAGIC = "IGMLVRS\0".b.freeze
        PROTOCOL_VERSION = 1
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
          state_options = snapshots.map { { needs_state: false } }
          geometry_bytes = NativeAdjacencyBridge.encode_geometry_input(
            snapshots,
            state_options
          )
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

        def encode_requests(requests, cell_count)
          buffer = String.new(capacity: 32 + requests.length * 24, encoding: Encoding::BINARY)
          buffer << REQUEST_MAGIC
          append_pack(buffer, [PROTOCOL_VERSION, requests.length, 0], 'Q<Q<Q<')

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
          raise ProtocolError, "unsupported validity result version #{version}" unless version == PROTOCOL_VERSION

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
