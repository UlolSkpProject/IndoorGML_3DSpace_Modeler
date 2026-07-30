# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Materials

        remove_const(:MATERIAL_DEFINITIONS) if const_defined?(:MATERIAL_DEFINITIONS, false)
        MATERIAL_DEFINITIONS = {
          'GeneralSpace' => ['Indoor3DGml_GeneralSpace', Sketchup::Color.new(255, 0, 0), 0.2],
          'TransitionSpace' => ['Indoor3DGml_TransitionSpace', Sketchup::Color.new(0, 128, 0), 0.6],
          'ConnectionSpace' => ['Indoor3DGml_ConnectionSpace', Sketchup::Color.new(145, 95, 210), 0.5],
          'AnchorSpace' => ['Indoor3DGml_AnchorSpace', Sketchup::Color.new(245, 175, 35), 0.5],
          'CellSpace' => ['Indoor3DGml_CellSpace', Sketchup::Color.new(25, 25, 25), 0.35]
        }.freeze

        def self.cell_space(cell_type, _category_code = nil)
          key = ::ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceType.label(cell_type)
          return nil unless MATERIAL_DEFINITIONS.key?(key)

          ensure_keys([key])[key]
        end

        def self.ensure_all
          ensure_keys(MATERIAL_DEFINITIONS.keys)
        end

        # Ensures each requested material exactly once and returns a stable map
        # keyed by the CellSpace type label. Callers performing batch work can
        # resolve a material once per type and reuse it for every CellSpace.
        def self.ensure_keys(keys)
          Array(keys).map(&:to_s).uniq.each_with_object({}) do |key, materials|
            next unless MATERIAL_DEFINITIONS.key?(key)

            materials[key] = fetch_solid(key)
          end
        end

        def self.fetch_solid(key)
          name, color, alpha = MATERIAL_DEFINITIONS.fetch(key)
          material = find_material(name) || Sketchup.active_model.materials.add(name)

          if material.respond_to?(:texture) && material.respond_to?(:texture=) && !material.texture.nil?
            material.texture = nil
          end
          material.color = color if material.respond_to?(:color=) && material.color != color
          if alpha && material.respond_to?(:alpha=) && material.alpha.to_f != alpha.to_f
            material.alpha = alpha
          end
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
