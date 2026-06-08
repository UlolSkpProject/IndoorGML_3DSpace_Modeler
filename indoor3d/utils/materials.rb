# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Materials

        remove_const(:TEXTURE_DEFINITIONS) if const_defined?(:TEXTURE_DEFINITIONS, false)
        TEXTURE_DEFINITIONS = {
          'GeneralSpace|Room' => ['Indoor3DGml_GeneralSpace', 'cellspace_room.png', 1.0],
          'TransitionSpace|Stair' => ['Indoor3DGml_TransitionSpace_Stair', 'cellspace_stair.png', 1.0],
          'TransitionSpace|Escalator' => ['Indoor3DGml_TransitionSpace_Escalator', 'cellspace_escalator.png', 1.0],
          'TransitionSpace|Elevator' => ['Indoor3DGml_TransitionSpace_Elevator', 'cellspace_elevator.png', 1.0],
          'ConnectionSpace|Door' => ['Indoor3DGml_ConnectionSpace', 'cellspace_door.png', 1.0]
        }.freeze

        def self.cell_space_text(cell_type, category_code)
          key = "#{::ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceType.label(cell_type)}|#{category_code}"
          return nil unless TEXTURE_DEFINITIONS.key?(key)

          fetch_textured(key)
        end

        def self.ensure_all
          TEXTURE_DEFINITIONS.each_key { |key| fetch_textured(key) }
        end

        def self.fetch_textured(key)
          name, texture_name, alpha = TEXTURE_DEFINITIONS.fetch(key)
          material = find_material(name) || Sketchup.active_model.materials.add(name)
          material.texture = texture_path(texture_name)
          material.alpha = alpha if alpha && material.respond_to?(:alpha=)
          material
        end
        private_class_method :fetch_textured

        def self.find_material(name)
          Sketchup.active_model.materials.find do |material|
            material_names(material).include?(name)
          end
        end
        private_class_method :find_material

        def self.material_names(material)
          [
            material.respond_to?(:name) ? material.name.to_s : nil,
            material.respond_to?(:display_name) ? material.display_name.to_s : nil
          ].compact.uniq
        end
        private_class_method :material_names

        def self.texture_path(texture_name)
          File.expand_path("../assets/textures/#{texture_name}", __dir__)
        end
        private_class_method :texture_path

      end
    end
  end
end
