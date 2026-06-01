# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Materials

        DEFINITIONS = {
          state: ['Indoor3DGml_State', [0, 0, 255], 1.0],
          transition: ['Indoor3DGml_Transition', [0, 0, 255], 1.0],
          general_space: ['Indoor3DGml_GeneralSpace', [255, 0, 0], 0.3],
          transfer_space: ['Indoor3DGml_TransferSpace', [255, 255, 0], 0.3],
          transition_space: ['Indoor3DGml_TransitionSpace', [0, 128, 0], 0.8],
          connection_space: ['Indoor3DGml_ConnectionSpace', [145, 95, 210], 0.3],
          anchor_space: ['Indoor3DGml_AnchorSpace', [0, 200, 180], 0.8]
        }.freeze unless const_defined?(:DEFINITIONS, false)

        TEXTURE_DEFINITIONS = {
          general_space: ['Indoor3DGml_GeneralSpace_Text', 'cellspace_room.png', 0.3],
          transition_space: ['Indoor3DGml_TransitionSpace_Text', 'cellspace_stair.png', 0.8],
          connection_space: ['Indoor3DGml_ConnectionSpace_Text', 'cellspace_door.png', 0.3]
        }.freeze unless const_defined?(:TEXTURE_DEFINITIONS, false)

        def self.state
          fetch(:state)
        end

        def self.transition
          fetch(:transition)
        end

        def self.cell_space(cell_type)
          fetch(cell_space_type_keys()[cell_type] || :general_space)
        end

        def self.cell_space_text(cell_type)
          key = cell_space_type_keys()[cell_type]
          return nil unless TEXTURE_DEFINITIONS.key?(key)

          fetch_textured(key)
        end

        def self.ensure_all
          DEFINITIONS.each_key { |key| fetch(key) }
          TEXTURE_DEFINITIONS.each_key { |key| fetch_textured(key) }
        end

        def self.fetch(key)
          name, rgb, alpha = DEFINITIONS.fetch(key)
          material = Sketchup.active_model.materials[name] || Sketchup.active_model.materials.add(name)
          material.color = Sketchup::Color.new(*rgb)
          material.alpha = alpha if alpha && material.respond_to?(:alpha=)
          material
        end
        private_class_method :fetch

        def self.fetch_textured(key)
          name, texture_name, alpha = TEXTURE_DEFINITIONS.fetch(key)
          material = Sketchup.active_model.materials[name] || Sketchup.active_model.materials.add(name)
          material.texture = texture_path(texture_name)
          material.alpha = alpha if alpha && material.respond_to?(:alpha=)
          material
        end
        private_class_method :fetch_textured

        def self.texture_path(texture_name)
          File.expand_path("../assets/textures/#{texture_name}", __dir__)
        end
        private_class_method :texture_path

        def self.cell_space_type_keys
          cell_space_type = ::ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceType
          {
            cell_space_type::GENERAL => :general_space,
            cell_space_type::TRANSFER => :transfer_space,
            cell_space_type::TRANSITION => :transition_space,
            cell_space_type::CONNECTION => :connection_space,
            cell_space_type::ANCHOR => :anchor_space
          }
        end
        private_class_method :cell_space_type_keys

      end
    end
  end
end
