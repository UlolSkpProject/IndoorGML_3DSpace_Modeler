# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class GlobalSnappingMap
          CanonicalVertex = Struct.new(:x, :y, :z)

          attr_reader :tolerance
          attr_reader :input_vertex_count
          attr_reader :merged_vertex_count
          attr_reader :max_displacement

          def initialize(tolerance:)
            @tolerance = tolerance.to_f
            raise ArgumentError, 'snap tolerance must be positive' unless @tolerance.positive?

            @cell_size = @tolerance
            @tolerance_squared = @tolerance * @tolerance
            @grid = Hash.new { |hash, key| hash[key] = [] }
            @input_vertex_count = 0
            @merged_vertex_count = 0
            @max_displacement = 0.0
          end

          def canonicalize(point)
            @input_vertex_count += 1
            candidate = canonical_for(point)
            if candidate
              @merged_vertex_count += 1
              track_displacement(point, candidate)
              return candidate
            end

            add_canonical(point)
          end

          def canonical_point(point)
            canonical_for(point) || add_canonical(point)
          end

          def canonical_vertex_count
            @grid.values.sum(&:length)
          end

          private

          def add_canonical(point)
            canonical = CanonicalVertex.new(point.x.to_f, point.y.to_f, point.z.to_f)
            @grid[cell_key(canonical)] << canonical
            canonical
          end

          def canonical_for(point)
            base_key = cell_key(point)
            nearest = nil
            nearest_distance_squared = @tolerance_squared

            neighbor_keys(base_key).each do |key|
              @grid[key].each do |candidate|
                distance_squared = squared_distance(point, candidate)
                next if distance_squared > nearest_distance_squared

                nearest = candidate
                nearest_distance_squared = distance_squared
              end
            end

            nearest
          end

          def neighbor_keys(key)
            x, y, z = key
            keys = []
            (x - 1).upto(x + 1) do |ix|
              (y - 1).upto(y + 1) do |iy|
                (z - 1).upto(z + 1) do |iz|
                  keys << [ix, iy, iz]
                end
              end
            end
            keys
          end

          def cell_key(point)
            [
              (point.x.to_f / @cell_size).floor,
              (point.y.to_f / @cell_size).floor,
              (point.z.to_f / @cell_size).floor
            ]
          end

          def squared_distance(point, candidate)
            dx = point.x.to_f - candidate.x
            dy = point.y.to_f - candidate.y
            dz = point.z.to_f - candidate.z
            (dx * dx) + (dy * dy) + (dz * dz)
          end

          def track_displacement(point, canonical)
            distance = Math.sqrt(squared_distance(point, canonical))
            @max_displacement = distance if distance > @max_displacement
          end
        end

      end
    end
  end
end
