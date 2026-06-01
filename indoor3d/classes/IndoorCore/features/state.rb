# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class State < GML::AbstractFeature
        attr_reader :duality_cell
        attr_reader :position
        attr_reader :radius
        attr_reader :transitions
        attr_accessor :editable

        STATE_NODE_RADIUS = 2000.mm unless const_defined?(:STATE_NODE_RADIUS, false)

        @@display_radius = STATE_NODE_RADIUS

        def initialize(cell_space, _parent_entities, local_position)
          unless cell_space.is_a?(CellSpace)
            raise ArgumentError, 'IndoorCore::CellSpace expected'
          end

          unless local_position.is_a?(Geom::Point3d)
            raise ArgumentError, 'Geom::Point3d local_position expected'
          end

          super()

          @duality_cell = cell_space
          @position = local_position
          @radius = self.class.display_radius
          @transitions = []
          @editable = false
        end

        def update_position(local_position)
          unless local_position.is_a?(Geom::Point3d)
            raise ArgumentError, 'Geom::Point3d local_position expected'
          end

          @position = local_position
        end

        def apply_radius(radius)
          radius = radius.to_f
          return false unless radius.positive?

          @radius = radius
          true
        end

        def add_transition(transition)
          @transitions << transition unless @transitions.include?(transition)
        end

        def remove_transition(transition)
          @transitions.delete(transition)
        end

        def transition_ids
          @transitions.select(&:valid?).map(&:id)
        end

        def valid?
          @duality_cell&.valid? == true
        end

        def erase!
          @transitions.clear
        end

        def self.restore(cell_space, local_position, id: nil, name: nil)
          unless cell_space.is_a?(CellSpace)
            raise ArgumentError, 'IndoorCore::CellSpace expected'
          end

          state = allocate
          state.send(:initialize_restored, cell_space, local_position, id, name)
          state
        end

        def sketchup_component_instance
          nil
        end

        def sketchup_component_instance_id
          nil
        end

        private

        def initialize_restored(cell_space, local_position, id, name)
          @duality_cell = cell_space
          @position = local_position
          @radius = self.class.display_radius
          @transitions = []
          @editable = false
          @id = id unless id.to_s.empty?
          @name = name.to_s
        end

        def self.display_radius
          @@display_radius
        end

        def self.display_radius=(radius)
          radius = radius.to_f
          @@display_radius = radius if radius.positive?
        end
      end

    end
  end
end
