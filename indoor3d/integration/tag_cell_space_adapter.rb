# frozen_string_literal: true
# [미완] TAG를 이용한 CellSpaceType 자동 결정과 관련된 부분입니다.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module TagCellSpaceAdapter
        UNASSIGNED_TAG_NAMES = ['', 'Untagged', 'Layer0'].freeze

        TAG_SUFFIX_MAP = {
          'MV_RM_01' => [CellSpaceType::TRANSITION, 'Elevator'],
          'MV_RM_02' => [CellSpaceType::TRANSITION, 'Stair'],
          'IP_RM_05' => [CellSpaceType::TRANSITION, 'Stair'],
          'IP_RM_23' => [CellSpaceType::GENERAL, 'Room'],
          'RM_DR' => [CellSpaceType::CONNECTION, 'Door']
        }.freeze

        def self.cell_space_type_from_tag(tag_name)
          name = tag_name.to_s
          return nil unless name[0..5].to_s.match?(/\A[FB]\d{2}[FB]\d{2}\z/)
          return nil unless name[6] == '_'

          TAG_SUFFIX_MAP[name[7..]]
        end

        def self.cell_space_type_and_category(entity)
          cell_space_type_from_tag(tag_name(entity))
        end

        def self.resolve_cell_space_type_and_category(entity, cell_type, category_code)
          cell_space_type_and_category(entity) || [cell_type, category_code]
        end

        def self.tag_assigned?(entity)
          !UNASSIGNED_TAG_NAMES.include?(tag_name(entity))
        end

        def self.tag_name(entity)
          tag = entity_tag(entity)
          tag.respond_to?(:name) ? tag.name.to_s : ''
        rescue StandardError
          ''
        end

        def self.entity_tag(entity)
          if entity&.respond_to?(:layer)
            tag = entity.layer
            return tag if tag
          end
          return entity.tag if entity&.respond_to?(:tag)

          nil
        end
        private_class_method :entity_tag
      end
    end
  end
end
