# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class CellSpace < AbstractFeature
        attr_reader :sketchup_group
        attr_reader :sketchup_group_id
        attr_accessor :cell_type
        attr_accessor :category_code
        attr_accessor :category_label
        attr_accessor :category_code_space
        attr_accessor :category_standard
        attr_accessor :navigation_class
        attr_accessor :navigation_function
        attr_accessor :navigation_usage
        attr_accessor :navigation_code_space
        attr_accessor :storey_id
        attr_accessor :editable
        attr_reader :duality_state

        def initialize(sketchup_group, cell_type = CellSpaceType::GENERAL, category_code = nil)
          self.class.validate_sketchup_group!(sketchup_group)

          super()

          @sketchup_group = sketchup_group
          @sketchup_group_id = sketchup_group.persistent_id
          @cell_type = cell_type
          set_category(category_code)
          apply_default_navigation_semantics
          @editable = false
          @duality_state = nil
        end

        def set_category(category_code = nil, category_label = nil, category_code_space = nil, category_standard = nil)
          category = CellSpaceCategory.normalize(
            @cell_type,
            category_code,
            category_label,
            category_code_space,
            category_standard
          )
          @category_code = category[:code]
          @category_label = category[:label]
          @category_code_space = category[:code_space]
          @category_standard = category[:standard]
          apply_default_navigation_semantics
        end

        def create_duality_state(parent_entities, local_position = nil)
          @duality_state ||= State.new(self, parent_entities, local_position)
        end

        def restore_duality_state(state)
          @duality_state = state
        end

        def valid?
          @sketchup_group&.valid? == true
        end

        def valid_sketchup_group
          return nil unless @sketchup_group&.valid?

          @sketchup_group
        rescue StandardError
          nil
        end

        def erase!
          @sketchup_group.erase! if valid?
        end

        def self.restore(sketchup_group, cell_type, id: nil, name: nil, category_code: nil, category_label: nil, category_code_space: nil, category_standard: nil, navigation_class: nil, navigation_function: nil, navigation_usage: nil, navigation_code_space: nil, storey_id: nil)
          validate_sketchup_group!(sketchup_group)

          cell_space = allocate
          cell_space.send(:initialize_restored, sketchup_group, cell_type, id, name, category_code, category_label, category_code_space, category_standard, navigation_class, navigation_function, navigation_usage, navigation_code_space, storey_id)
          cell_space
        end

        def self.validate_sketchup_group!(sketchup_group)
          unless sketchup_group.is_a?(Sketchup::Group) || sketchup_group.is_a?(Sketchup::ComponentInstance)
            raise ArgumentError, 'Sketchup::Group or Sketchup::ComponentInstance expected'
          end

          unless sketchup_group.valid?
            raise ArgumentError, 'Valid Sketchup::Group or Sketchup::ComponentInstance expected'
          end

          unless sketchup_group.respond_to?(:manifold?) && sketchup_group.manifold?
            raise ArgumentError, 'Solid Group expected'
          end
        end

        private

        def initialize_restored(sketchup_group, cell_type, id, name, category_code, category_label, category_code_space, category_standard, navigation_class, navigation_function, navigation_usage, navigation_code_space, storey_id)
          @sketchup_group = sketchup_group
          @sketchup_group_id = sketchup_group.persistent_id
          @cell_type = cell_type
          set_category(category_code, category_label, category_code_space, category_standard)
          @navigation_class = blank_to_nil(navigation_class) || @navigation_class
          @navigation_function = blank_to_nil(navigation_function) || @navigation_function
          @navigation_usage = blank_to_nil(navigation_usage) || @navigation_usage
          @navigation_code_space = blank_to_nil(navigation_code_space) || @navigation_code_space
          @storey_id = blank_to_nil(storey_id)
          @editable = false
          @duality_state = nil
          @id = id unless id.to_s.empty?
          @name = name.to_s
        end

        def apply_default_navigation_semantics
          default_code = @category_label.to_s.empty? ? @category_code.to_s : @category_label.to_s
          default_code = CellSpaceType.label(@cell_type) if default_code.empty?
          @navigation_class = default_code
          @navigation_function = default_code
          @navigation_usage = default_code
          @navigation_code_space = @category_code_space
        end

        def blank_to_nil(value)
          value.to_s.empty? ? nil : value
        end

      end

    end
  end
end
