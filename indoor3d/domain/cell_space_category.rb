# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      module CellSpaceCategory
        DEFAULT_CODE_SPACE = 'urn:ogc:def:nil:OGC::IndoorGML:AnnexD'

        DEFAULTS = {
          CellSpaceType::GENERAL => [
            { code: 'Room', label: 'Room', code_space: DEFAULT_CODE_SPACE, standard: true, texture: 'cellspace_room.png' }
          ],
          CellSpaceType::TRANSITION => [
            { code: 'Stair',     label: 'Stair',     code_space: DEFAULT_CODE_SPACE, standard: true, texture: 'cellspace_stair.png'     },
            { code: 'Escalator', label: 'Escalator', code_space: DEFAULT_CODE_SPACE, standard: true, texture: 'cellspace_escalator.png' },
            { code: 'Elevator',  label: 'Elevator',  code_space: DEFAULT_CODE_SPACE, standard: true, texture: 'cellspace_elevator.png'  },
          ],
          CellSpaceType::CONNECTION => [
            { code: 'Door', label: 'Door', code_space: DEFAULT_CODE_SPACE, standard: true, texture: 'cellspace_door.png' }
          ]
          # CellSpaceType::ANCHOR => [
          #   { code: 'Anchor', label: 'Anchor', code_space: DEFAULT_CODE_SPACE, standard: true, texture: 'cellspace_anchor.png' }
          # ]
        }.freeze unless const_defined?(:DEFAULTS, false)

        def self.default_for(cell_type)
          list_for(cell_type).first
        end

        def self.list_for(cell_type)
          DEFAULTS[cell_type] || DEFAULTS[CellSpaceType::GENERAL]
        end

        def self.texture_for(cell_type, category_code)
          category = find(cell_type, category_code) || default_for(cell_type)
          category[:texture]
        end

        def self.find(cell_type, code)
          list_for(cell_type).find { |category| category[:code] == code.to_s }
        end

        def self.normalize(cell_type, category_code = nil, category_label = nil, category_code_space = nil, category_standard = nil)
          category = find(cell_type, category_code) || default_for(cell_type)
          {
            code: category_code.to_s.empty? ? category[:code] : category_code.to_s,
            label: category_label.to_s.empty? ? category[:label] : category_label.to_s,
            code_space: category_code_space.to_s.empty? ? category[:code_space] : category_code_space.to_s,
            standard: category_standard.nil? ? category[:standard] : truthy?(category_standard)
          }
        end

        def self.valid_for_type?(cell_type, category_code)
          !find(cell_type, category_code).nil?
        end

        def self.selection_options
          CellSpaceType::SELECTABLE_TYPES.flat_map do |cell_type|
            list_for(cell_type).map do |category|
              {
                cell_type: cell_type,
                category_code: category[:code],
                label: selection_label(cell_type, category[:code]),
                value: selection_value(cell_type, category[:code])
              }
            end
          end
        end

        def self.selection_label(cell_type, category_code)
          "#{category_code} : #{CellSpaceType.label(cell_type)}"
        end

        def self.selection_value(cell_type, category_code)
          "#{CellSpaceType.label(cell_type)}|#{category_code}"
        end

        def self.parse_selection_value(value)
          cell_type_label, category_code = value.to_s.split('|', 2)
          cell_type = CellSpaceType.from_label(cell_type_label)
          category_code = nil unless valid_for_type?(cell_type, category_code)
          [cell_type, category_code || default_for(cell_type)[:code]]
        end

        def self.truthy?(value)
          value == true || value.to_s.downcase == 'true'
        end
        private_class_method :truthy?
      end

    end
  end
end
