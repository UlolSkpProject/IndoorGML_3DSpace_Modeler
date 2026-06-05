# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Transition < GML::AbstractFeature
        attr_reader :state1
        attr_reader :state2
        attr_reader :cell1
        attr_reader :cell2
        attr_accessor :editable

        TRANSITION_RADIUS = State::STATE_NODE_RADIUS * 0.5 unless const_defined?(:TRANSITION_RADIUS, false)
        TRANSITION_BASE_HEIGHT = 1.0 unless const_defined?(:TRANSITION_BASE_HEIGHT, false)

        def initialize(state1 = nil, state2 = nil, _parent_entities = nil, cell1: nil, cell2: nil)
          super()

          @state1 = state1
          @state2 = state2
          @cell1 = cell1
          @cell2 = cell2
          @editable = false
        end

        def update(_point1, _point2)
          return false unless valid_states?

          true
        end

        def valid?
          valid_states?
        end

        def connected_to?(state)
          @state1 == state || @state2 == state
        end

        def erase!
          @state1 = nil
          @state2 = nil
          @cell1 = nil
          @cell2 = nil
        end

        def self.restore(state1, state2, cell1: nil, cell2: nil, id: nil, name: nil)
          transition = allocate
          transition.send(:initialize_restored, state1, state2, cell1, cell2, id, name)
          transition
        end

        def edge
          nil
        end

        def valid_edge
          entity = edge
          return nil unless entity&.valid?

          entity
        rescue StandardError
          nil
        end

        private

        def initialize_restored(state1, state2, cell1, cell2, id, name)
          @state1 = state1
          @state2 = state2
          @cell1 = cell1
          @cell2 = cell2
          @editable = false
          @id = id unless id.to_s.empty?
          @name = name.to_s
        end

        def valid_states?
          return false if @state1.nil? || @state2.nil?
          return false if @state1 == @state2
          return false unless @state1.is_a?(State)
          return false unless @state2.is_a?(State)
          return false unless @state1.valid?
          return false unless @state2.valid?

          true
        end
      end

    end
  end
end
