# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class State < GML::AbstractFeature
        attr_reader :sketchup_component_instance
        attr_reader :sketchup_component_instance_id
        attr_reader :duality_cell
        attr_reader :position
        attr_reader :radius
        attr_reader :transitions
        attr_accessor :editable

        STATE_NODE_RADIUS = 2000.mm unless const_defined?(:STATE_NODE_RADIUS, false)

        @@sketchup_component_definition = nil
        @@display_radius = STATE_NODE_RADIUS

        def initialize(cell_space, parent_entities, local_position)
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
          @sketchup_component_instance = create_component_instance(@position, parent_entities)
          @sketchup_component_instance_id = @sketchup_component_instance.persistent_id
          @sketchup_component_instance.name = "[Node]-#{@id}"
          apply_radius(@radius)
        end

        def update_position(local_position)
          unless local_position.is_a?(Geom::Point3d)
            raise ArgumentError, 'Geom::Point3d local_position expected'
          end

          @position = local_position
        end

        def apply_radius(radius)
          radius = radius.to_f
          return false unless valid? && radius.positive?

          @radius = radius
          scale = @radius / STATE_NODE_RADIUS
          origin = @sketchup_component_instance.transformation.origin
          @sketchup_component_instance.transformation = Geom::Transformation.new(
            [
              scale, 0.0, 0.0, 0.0,
              0.0, scale, 0.0, 0.0,
              0.0, 0.0, scale, 0.0,
              origin.x, origin.y, origin.z, 1.0
            ]
          )
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
          @sketchup_component_instance&.valid? == true
        end

        def erase!
          @sketchup_component_instance.erase! if valid?
        end

        def self.restore(cell_space, component_instance, local_position, id: nil, name: nil)
          unless cell_space.is_a?(CellSpace)
            raise ArgumentError, 'IndoorCore::CellSpace expected'
          end

          unless component_instance.is_a?(Sketchup::ComponentInstance)
            raise ArgumentError, 'Sketchup::ComponentInstance expected'
          end

          state = allocate
          state.send(:initialize_restored, cell_space, component_instance, local_position, id, name)
          state
        end

        private

        def initialize_restored(cell_space, component_instance, local_position, id, name)
          @duality_cell = cell_space
          @position = local_position
          @radius = self.class.display_radius
          @transitions = []
          @editable = false
          @sketchup_component_instance = component_instance
          @sketchup_component_instance_id = component_instance.persistent_id
          @id = id unless id.to_s.empty?
          @name = name.to_s
          apply_radius(@radius)
        end

        def create_component_instance(position, parent_entities)
          definition = self.class.sketchup_component_definition
          entities = parent_entities || Sketchup.active_model.active_entities
          entities.add_instance(
            definition,
            Geom::Transformation.translation(position)
          )
        end

        def self.sketchup_component_definition
          return @@sketchup_component_definition if @@sketchup_component_definition&.valid?

          model = Sketchup.active_model
          @@sketchup_component_definition = model.definitions.add('IndoorGML_State')

          entities = @@sketchup_component_definition.entities
          faces = Utils::Geometry.add_sphere(entities, ORIGIN, STATE_NODE_RADIUS)
          faces.each { |face| face.material = Utils::Materials.state }

          @@sketchup_component_definition
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
