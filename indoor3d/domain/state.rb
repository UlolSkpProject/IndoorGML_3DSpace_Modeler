# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class State < AbstractFeature
        attr_reader :duality_cell
        attr_reader :radius
        attr_reader :transitions
        attr_accessor :editable

        STATE_NODE_RADIUS = 2000.mm unless const_defined?(:STATE_NODE_RADIUS, false)

        @@display_radius = STATE_NODE_RADIUS

        def initialize(cell_space, _parent_entities, position)
          unless cell_space.is_a?(CellSpace)
            raise ArgumentError, 'IndoorCore::CellSpace expected'
          end

          unless position.nil? || position.is_a?(Geom::Point3d)
            raise ArgumentError, 'Geom::Point3d position expected'
          end

          super()

          @duality_cell = cell_space
          @fallback_position = position
          @radius = self.class.display_radius
          @transitions = []
          @editable = false
        end

        def position
          group = @duality_cell&.valid_sketchup_group
          return Utils::Transformation.entity_world_transformation(group).origin if group

          @fallback_position || ORIGIN
        rescue StandardError
          @fallback_position || ORIGIN
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

        def self.restore(cell_space, position, id: nil, name: nil)
          unless cell_space.is_a?(CellSpace)
            raise ArgumentError, 'IndoorCore::CellSpace expected'
          end

          state = allocate
          state.send(:initialize_restored, cell_space, position, id, name)
          state
        end

        private

        def initialize_restored(cell_space, position, id, name)
          @duality_cell = cell_space
          @fallback_position = position
          @radius = self.class.display_radius
          @transitions = []
          @editable = false
          @id = id.to_s.empty? ? self.class.generate_id : id.to_s
          @name = name.to_s
        end

        def self.display_radius
          @@display_radius
        end
      end

    end
  end
end
