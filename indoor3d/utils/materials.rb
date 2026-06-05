# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Materials

        LEGACY_MATERIAL_NAMES = [
          'Indoor3DGml_State',
          'Indoor3DGml_Transition',
          'Indoor3DGml_GeneralSpace',
          'Indoor3DGml_TransitionSpace',
          'Indoor3DGml_ConnectionSpace',
          'Indoor3DGml_AnchorSpace'
        ].freeze unless const_defined?(:LEGACY_MATERIAL_NAMES, false)

        TEXTURE_DEFINITIONS = {
          'GeneralSpace|Room' => ['Indoor3DGml_GeneralSpace_Text', 'cellspace_room.png', 1.0],
          'TransitionSpace|Stair' => ['Indoor3DGml_TransitionSpace_Stair_Text', 'cellspace_stair.png', 1.0],
          'TransitionSpace|Escalator' => ['Indoor3DGml_TransitionSpace_Escalator_Text', 'cellspace_escalator.png', 1.0],
          'TransitionSpace|Elevator' => ['Indoor3DGml_TransitionSpace_Elevator_Text', 'cellspace_elevator.png', 1.0],
          'ConnectionSpace|Door' => ['Indoor3DGml_ConnectionSpace_Text', 'cellspace_door.png', 1.0],
          'AnchorSpace|Anchor' => ['Indoor3DGml_AnchorSpace_Text', 'cellspace_anchor.png', 1.0]
        }.freeze unless const_defined?(:TEXTURE_DEFINITIONS, false)

        def self.cell_space_text(cell_type, category_code)
          key = "#{::ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceType.label(cell_type)}|#{category_code}"
          return nil unless TEXTURE_DEFINITIONS.key?(key)

          fetch_textured(key)
        end

        def self.ensure_all
          remove_legacy_materials
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

        def self.remove_legacy_materials
          materials = Sketchup.active_model.materials
          return unless materials.respond_to?(:remove)

          materials.to_a.each do |material|
            next unless legacy_material?(material)

            begin
              materials.remove(material)
            rescue StandardError => e
              puts "[IndoorGML] Legacy material removal failed: #{material_names(material).first} #{e.class}: #{e.message}"
            end
          end
        end
        private_class_method :remove_legacy_materials

        def self.legacy_material?(material)
          material_names(material).any? do |name|
            LEGACY_MATERIAL_NAMES.any? do |base_name|
              name.match?(/\A#{Regexp.escape(base_name)}(?:[\s_#-]?\d+)?\z/)
            end
          end
        end
        private_class_method :legacy_material?

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
