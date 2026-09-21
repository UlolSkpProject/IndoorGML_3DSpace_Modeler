# frozen_string_literal: true

require_relative 'shared_tag_catalog'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module TagCellSpaceAdapter
        UNASSIGNED_TAG_NAMES = ['', 'Untagged', 'Layer0'].freeze
        SETTINGS_DICTIONARY = 'SeoulSpace'.freeze
        BUILDING_TYPE_KEY = 'building_type'.freeze

        def self.load_catalog!(path: SharedTagCatalog.default_path)
          @catalog = SharedTagCatalog.load(path: path)
        end

        def self.catalog
          @catalog ||= SharedTagCatalog.load
        end

        def self.building_type(model = nil)
          model ||= Sketchup.active_model if defined?(Sketchup)
          value = model&.get_attribute(SETTINGS_DICTIONARY, BUILDING_TYPE_KEY, 'subway')
          SharedTagCatalog::BUILDING_TYPES.key?(value) ? value : 'subway'
        end

        def self.set_building_type(model, value)
          raise ArgumentError, '건축물 구분이 올바르지 않습니다.' unless SharedTagCatalog::BUILDING_TYPES.key?(value)

          model.set_attribute(SETTINGS_DICTIONARY, BUILDING_TYPE_KEY, value)
        end

        def self.cell_space_type_from_tag(tag_name, building_type: self.building_type)
          catalog.classify(tag_name, building_type: building_type)
        end

        def self.cell_space_type_and_category(entity)
          model = entity.model if entity.respond_to?(:model)
          cell_space_type_from_tag(tag_name(entity), building_type: building_type(model))
        end

        def self.resolve_cell_space_type_and_category(entity, cell_type, category_code)
          cell_space_type_and_category(entity) || [cell_type, category_code]
        end

        def self.storey_from_tag(entity)
          model = entity.model if entity.respond_to?(:model)
          storey_from_tag_name(tag_name(entity), building_type: building_type(model))
        end

        def self.storey_from_tag_name(tag_name, building_type: self.building_type)
          return nil unless cell_space_type_from_tag(tag_name, building_type: building_type)

          match = tag_name.to_s.match(SharedTagCatalog::TAG_PATTERN)
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
          name = tag_name(entity)
          return false if UNASSIGNED_TAG_NAMES.include?(name)

          !cell_space_type_and_category(entity).nil?
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

        def self.storey_range_allowed?(cell_type, category_code)
          cell_type == CellSpaceType::TRANSITION &&
            %w[Stair Elevator].include?(category_code.to_s)
        end
        private_class_method :storey_range_allowed?
      end
    end
  end
end
