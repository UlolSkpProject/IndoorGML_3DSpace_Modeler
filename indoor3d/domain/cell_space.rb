# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class CellSpace < AbstractFeature
        attr_reader :sketchup_group
        attr_reader :sketchup_group_id
        attr_accessor :cell_type
        attr_accessor :category_code
        attr_accessor :navigation_class
        attr_accessor :navigation_class_code_space
        attr_accessor :navigation_function
        attr_accessor :navigation_function_code_space
        attr_accessor :navigation_usage
        attr_accessor :navigation_usage_code_space
        attr_accessor :storey
        attr_accessor :editable
        attr_reader :duality_state

        DEFAULT_STOREY = 'F01'

        def initialize(sketchup_group, cell_type = CellSpaceType::GENERAL, category_code = nil)
          self.class.validate_sketchup_group!(sketchup_group)

          super()

          @sketchup_group = sketchup_group
          @sketchup_group_id = sketchup_group.persistent_id
          @cell_type = cell_type
          set_category(category_code)
          @storey = DEFAULT_STOREY
          @editable = false
          @duality_state = nil
        end

        def set_category(category_code = nil)
          category = CellSpaceCategory.normalize(
            @cell_type,
            category_code
          )
          @category_code = category[:code]
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

        def navigable?
          CellSpaceType.navigable?(@cell_type)
        end

        def geometry_only?
          CellSpaceType.geometry_only?(@cell_type)
        end

        def set_navigation_semantics(navigation_class:, navigation_function:, navigation_usage:)
          return false unless navigable?

          @navigation_class = normalize_navigation_semantic(navigation_class)
          @navigation_function = normalize_navigation_semantic(navigation_function)
          @navigation_usage = normalize_navigation_semantic(navigation_usage)
          @navigation_class_code_space = CellSpaceCategory::DEFAULT_CODE_SPACE unless @navigation_class.to_s.empty?
          @navigation_function_code_space = CellSpaceCategory::DEFAULT_CODE_SPACE unless @navigation_function.to_s.empty?
          @navigation_usage_code_space = CellSpaceCategory::DEFAULT_CODE_SPACE unless @navigation_usage.to_s.empty?
          true
        end

        def set_storey(value)
          @storey = normalize_storey(value)
        end

        def self.restore(sketchup_group, cell_type, id: nil, name: nil, category_code: nil, navigation_class: nil, navigation_class_code_space: nil, navigation_function: nil, navigation_function_code_space: nil, navigation_usage: nil, navigation_usage_code_space: nil, storey: nil)
          validate_sketchup_group!(sketchup_group)

          cell_space = allocate
          cell_space.send(:initialize_restored, sketchup_group, cell_type, id, name, category_code, navigation_class, navigation_class_code_space, navigation_function, navigation_function_code_space, navigation_usage, navigation_usage_code_space, storey)
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

        def initialize_restored(sketchup_group, cell_type, id, name, category_code, navigation_class, navigation_class_code_space, navigation_function, navigation_function_code_space, navigation_usage, navigation_usage_code_space, storey)
          @sketchup_group = sketchup_group
          @sketchup_group_id = sketchup_group.persistent_id
          @cell_type = cell_type
          set_category(category_code)
          restore_navigation_semantics(
            navigation_class,
            navigation_class_code_space,
            navigation_function,
            navigation_function_code_space,
            navigation_usage,
            navigation_usage_code_space
          )
          @storey = normalize_storey(storey)
          @editable = false
          @duality_state = nil
          @id = id unless id.to_s.empty?
          @name = name.to_s
        end

        def clear_navigation_semantics
          @navigation_class = nil
          @navigation_class_code_space = nil
          @navigation_function = nil
          @navigation_function_code_space = nil
          @navigation_usage = nil
          @navigation_usage_code_space = nil
        end

        def apply_default_navigation_semantics
          return clear_navigation_semantics unless navigable?

          semantic = NavigationSemanticResolver.default_for(@cell_type, @category_code)
          return clear_navigation_semantics unless semantic

          @navigation_class = semantic.class_value
          @navigation_class_code_space = semantic.class_code_space
          @navigation_function = semantic.function_value
          @navigation_function_code_space = semantic.function_code_space
          @navigation_usage = semantic.usage_value
          @navigation_usage_code_space = semantic.usage_code_space
        end

        def restore_navigation_semantics(navigation_class, class_code_space, navigation_function, function_code_space, navigation_usage, usage_code_space)
          return unless navigable?

          restored_class = normalize_navigation_semantic(navigation_class)
          restored_function = normalize_navigation_semantic(navigation_function)
          restored_usage = normalize_navigation_semantic(navigation_usage)

          return if restored_class.to_s.empty? && restored_function.to_s.empty? && restored_usage.to_s.empty?

          @navigation_class = restored_class
          @navigation_class_code_space = blank_to_nil(class_code_space) unless @navigation_class.to_s.empty?
          @navigation_function = restored_function
          @navigation_function_code_space = blank_to_nil(function_code_space) unless @navigation_function.to_s.empty?
          @navigation_usage = restored_usage
          @navigation_usage_code_space = blank_to_nil(usage_code_space) unless @navigation_usage.to_s.empty?
        end

        def normalize_navigation_semantic(value)
          normalized = value.to_s.strip
          normalized.empty? ? nil : normalized
        end

        def normalize_storey(value)
          normalized = value.to_s.strip.upcase
          return DEFAULT_STOREY if normalized.empty?

          normalized = normalized.gsub(/\AFLOOR_?(\d{1,2})\z/, 'F\1')
          normalized = normalized.gsub(/\A([FB])(\d{1})\z/) { "#{$1}0#{$2}" }
          normalized = normalized.gsub(/~([FB])(\d{1})\z/) { "~#{$1}0#{$2}" }
          normalized.match?(/\A[FB](0[1-9]|[1-9][0-9])(?:~[FB](0[1-9]|[1-9][0-9]))?\z/) ? normalized : DEFAULT_STOREY
        end

        def blank_to_nil(value)
          value.to_s.empty? ? nil : value
        end

      end

    end
  end
end
