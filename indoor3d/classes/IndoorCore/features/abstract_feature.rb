# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module GML
      class AbstractFeature
        attr_reader :name
        attr_reader :id

        def initialize
          @name = ''
          @id = rand(36**8).to_s(36)
        end
      end
    end
  end
end
