# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Materials

        MATERIAL_ALPHA = 0.5 unless const_defined?(:MATERIAL_ALPHA, false)

        DEFINITIONS = {
          state: ['Indoor3DGml_State', [40, 105, 255]],
          transition: ['Indoor3DGml_Transition', [255, 198, 41]],
          general_space: ['Indoor3DGml_GeneralSpace', [80, 180, 120]],
          transfer_space: ['Indoor3DGml_TransferSpace', [75, 170, 225]],
          transition_space: ['Indoor3DGml_TransitionSpace', [245, 130, 65]],
          connection_space: ['Indoor3DGml_ConnetcionSpace', [155, 115, 220]],
          anchor_space: ['Indoor3DGml_AnchorSpace', [235, 85, 120]]
        }.freeze unless const_defined?(:DEFINITIONS, false)

        CELL_SPACE_TYPE_KEYS = {
          IndoorCore::CellSpaceType::GENERAL => :general_space,
          IndoorCore::CellSpaceType::TRANSFER => :transfer_space,
          IndoorCore::CellSpaceType::TRANSITION => :transition_space,
          IndoorCore::CellSpaceType::CONNECTION => :connection_space,
          IndoorCore::CellSpaceType::ANCHOR => :anchor_space
        }.freeze unless const_defined?(:CELL_SPACE_TYPE_KEYS, false)

        def self.state
          fetch(:state)
        end

        def self.transition
          fetch(:transition)
        end

        def self.cell_space(cell_type)
          fetch(CELL_SPACE_TYPE_KEYS[cell_type] || :general_space)
        end

        def self.ensure_all
          DEFINITIONS.each_key { |key| fetch(key) }
        end

        def self.fetch(key)
          name, rgb = DEFINITIONS.fetch(key)
          material = Sketchup.active_model.materials[name] || Sketchup.active_model.materials.add(name)
          material.color = Sketchup::Color.new(*rgb)
          material.alpha = MATERIAL_ALPHA if material.respond_to?(:alpha=)
          material
        end
        private_class_method :fetch

      end
    end
  end
end
