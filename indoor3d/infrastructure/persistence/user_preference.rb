# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module UserPreferences
        SECTION = 'ULOL.IndoorGML3DModeler'.freeze

        class << self
          
          def read_float(key, fallback:, min: nil, max: nil)
            value = read(key, fallback)
            clamp_float(value, fallback: fallback, min: min, max: max)
          end

          def write_float(key, value, fallback:, min: nil, max: nil)
            number = clamp_float(value, fallback: fallback, min: min, max: max)
            write(key, number)
            number
          end

          def read_int(key, fallback:, min: nil, max: nil)
            value = read(key, fallback)
            clamp_int(value, fallback: fallback, min: min, max: max)
          end

          def write_int(key, value, fallback:, min: nil, max: nil)
            number = clamp_int(value, fallback: fallback, min: min, max: max)
            write(key, number)
            number
          end

          def read_bool(key, fallback:)
            value = read(key, fallback)
            cast_bool(value, fallback)
          end

          def write_bool(key, value)
            bool = cast_bool(value, false)
            write(key, bool)
            bool
          end

          def read_string(key, fallback: '')
            value = read(key, fallback)
            value.nil? ? fallback : value.to_s
          rescue StandardError
            fallback
          end

          def write_string(key, value)
            string = value.to_s
            write(key, string)
            string
          end

          private

          def read(key, fallback = nil)
            Sketchup.read_default(SECTION, key.to_s, fallback)
          rescue StandardError
            fallback
          end

          def write(key, value)
            Sketchup.write_default(SECTION, key.to_s, value)
            value
          rescue StandardError
            nil
          end

          def clamp_float(value, fallback:, min: nil, max: nil)
            number = Float(value)
            return fallback unless number.finite?

            number = [number, min].max unless min.nil?
            number = [number, max].min unless max.nil?
            number
          rescue StandardError
            fallback
          end

          def clamp_int(value, fallback:, min: nil, max: nil)
            number = Integer(value)
            number = [number, min].max unless min.nil?
            number = [number, max].min unless max.nil?
            number
          rescue StandardError
            fallback
          end

          def cast_bool(value, fallback)
            return value if value == true || value == false

            case value.to_s.downcase
            when 'true', '1', 'yes', 'y', 'on'
              true
            when 'false', '0', 'no', 'n', 'off'
              false
            else
              fallback
            end
          rescue StandardError
            fallback
          end
        end
      end
    end
  end
end