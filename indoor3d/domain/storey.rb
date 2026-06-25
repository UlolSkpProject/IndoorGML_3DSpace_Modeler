# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class Storey < AbstractFeature
        attr_accessor :name
        attr_accessor :elevation
        attr_accessor :height

        DEFAULT_NAME = 'F01'

        def initialize(name = DEFAULT_NAME, elevation = nil, height = nil)
          super()
          @name = required_name(name)
          @elevation = numeric_or_nil(elevation)
          @height = numeric_or_nil(height)
        end

        def self.restore(id:, name:, elevation: nil, height: nil)
          storey = new(name, elevation, height)
          storey.instance_variable_set(:@id, id) unless id.to_s.empty?
          storey
        end

        private

        def required_name(value)
          normalized = value.to_s.strip
          normalized.empty? ? DEFAULT_NAME : normalized
        end

        def numeric_or_nil(value)
          return nil if value.to_s.empty?

          Float(value)
        rescue StandardError
          nil
        end
      end
    end
  end
end
