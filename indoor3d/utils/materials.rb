# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Materials

        remove_const(:MATERIAL_DEFINITIONS) if const_defined?(:MATERIAL_DEFINITIONS, false)
        MATERIAL_DEFINITIONS = {
          'GeneralSpace|Room' => ['Indoor3DGml_GeneralSpace', Sketchup::Color.new(255, 0, 0), 0.2],
          'TransitionSpace|Stair' => ['Indoor3DGml_TransitionSpace_Stair', Sketchup::Color.new(0, 128, 0), 0.6],
          'TransitionSpace|Escalator' => ['Indoor3DGml_TransitionSpace_Escalator', Sketchup::Color.new(0, 128, 0), 0.6],
          'TransitionSpace|Elevator' => ['Indoor3DGml_TransitionSpace_Elevator', Sketchup::Color.new(0, 128, 0), 0.6],
          'ConnectionSpace|Door' => ['Indoor3DGml_ConnectionSpace', Sketchup::Color.new(145, 95, 210), 0.5]
        }.freeze

        def self.cell_space(cell_type, category_code)
          key = "#{::ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceType.label(cell_type)}|#{category_code}"
          return nil unless MATERIAL_DEFINITIONS.key?(key)

          fetch_solid(key)
        end

        def self.ensure_all
          MATERIAL_DEFINITIONS.each_key { |key| fetch_solid(key) }
        end

        def self.fetch_solid(key)
          name, color, alpha = MATERIAL_DEFINITIONS.fetch(key)
          material = find_material(name) || Sketchup.active_model.materials.add(name)
          material.texture = nil if material.respond_to?(:texture=)
          material.color = color
          material.alpha = alpha if alpha && material.respond_to?(:alpha=)
          material
        end
        private_class_method :fetch_solid

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

      end
    end
  end
end
