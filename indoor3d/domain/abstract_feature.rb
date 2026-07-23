# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AbstractFeature
        attr_reader :name
        attr_reader :id

        def self.generate_id
          rand(36**8).to_s(36)
        end

        def initialize
          @name = ''
          @id = self.class.generate_id
        end
      end
    end
  end
end
