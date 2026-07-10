# frozen_string_literal: true
# [미완] TAG를 이용한 CellSpaceType 자동 결정과 관련된 부분입니다.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module TagCellSpaceAdapter
        UNASSIGNED_TAG_NAMES = ['', 'Untagged', 'Layer0'].freeze
        STOREY_PART_PATTERN = /[FB](?:0[1-9]|[1-9][0-9])/.freeze
        STOREY_PREFIX_PATTERN = /\A(#{STOREY_PART_PATTERN})(#{STOREY_PART_PATTERN})_/.freeze

        TAG_SUFFIX_MAP = {
          'MV_RM_01' => [CellSpaceType::TRANSITION, 'Elevator'],
          'MV_RM_02' => [CellSpaceType::TRANSITION, 'Stair'],
          'IP_RM_05' => [CellSpaceType::TRANSITION, 'Stair'],
          'IP_RM_23' => [CellSpaceType::GENERAL, 'Room'],
          'RM_DR' => [CellSpaceType::CONNECTION, 'Door'],
          'RM_WD' => [CellSpaceType::GEOMETRY_ONLY, 'Window']
        }.freeze

        def self.cell_space_type_from_tag(tag_name)
          name = tag_name.to_s
          return nil unless valid_storey_prefixed_tag?(name)

          TAG_SUFFIX_MAP[name[7..]]
        end

        def self.cell_space_type_and_category(entity)
          cell_space_type_from_tag(tag_name(entity))
        end

        def self.resolve_cell_space_type_and_category(entity, cell_type, category_code)
          cell_space_type_and_category(entity) || [cell_type, category_code]
        end

        def self.storey_from_tag(entity)
          storey_from_tag_name(tag_name(entity))
        end

        def self.storey_from_tag_name(tag_name)
          match = tag_name.to_s.match(STOREY_PREFIX_PATTERN)
          return nil unless match

          from = match[1]
          to = match[2]
          from == to ? from : "#{from}~#{to}"
        end

        def self.resolve_cell_space_storey(entity, cell_type, category_code, default_storey)
          storey = storey_from_tag(entity)
          resolve_cell_space_storey_value(storey, cell_type, category_code, default_storey)
        end

        def self.resolve_cell_space_storey_value(storey, cell_type, category_code, default_storey)
          return default_storey if storey.to_s.empty?
          return storey if storey_range_allowed?(cell_type, category_code)

          storey.split('~', 2).first
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

        def self.valid_storey_prefixed_tag?(name)
          name.to_s.match?(STOREY_PREFIX_PATTERN)
        end
        private_class_method :valid_storey_prefixed_tag?

        def self.storey_range_allowed?(cell_type, category_code)
          cell_type == CellSpaceType::TRANSITION &&
            %w[Stair Elevator].include?(category_code.to_s)
        end
        private_class_method :storey_range_allowed?
      end
    end
  end
end
