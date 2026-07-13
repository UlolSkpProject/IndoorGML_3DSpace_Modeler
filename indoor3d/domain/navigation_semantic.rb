# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      NavigationSemantic = Struct.new(
        :class_value,
        :class_code_space,
        :function_value,
        :function_code_space,
        :usage_value,
        :usage_code_space,
        keyword_init: true
      )

      class NavigationSemanticError < StandardError; end

      module NavigationSemanticResolver
        LEGACY_ANNEX_D_CODE_SPACE = 'urn:ogc:def:nil:OGC::IndoorGML:AnnexD'

        NAVIGATION_SEMANTICS = {
          [CellSpaceType::GENERAL, 'Room'] => NavigationSemantic.new(
            class_value: 'Space',
            class_code_space: nil,
            function_value: 'Space',
            function_code_space: nil,
            usage_value: 'Space',
            usage_code_space: nil
          ),
          [CellSpaceType::TRANSITION, 'Stair'] => NavigationSemantic.new(
            class_value: 'Stair',
            class_code_space: nil,
            function_value: 'Vertical Transition',
            function_code_space: nil,
            usage_value: 'Stair',
            usage_code_space: nil
          ),
          [CellSpaceType::TRANSITION, 'Elevator'] => NavigationSemantic.new(
            class_value: 'Elevator',
            class_code_space: nil,
            function_value: 'Vertical Transition',
            function_code_space: nil,
            usage_value: 'Elevator',
            usage_code_space: nil
          ),
          [CellSpaceType::CONNECTION, 'Door'] => NavigationSemantic.new(
            class_value: 'Door',
            class_code_space: nil,
            function_value: 'Door',
            function_code_space: nil,
            usage_value: 'Door',
            usage_code_space: nil
          ),
          [CellSpaceType::ANCHOR, 'ExteriorDoor'] => NavigationSemantic.new(
            class_value: 'Exterior door',
            class_code_space: nil,
            function_value: 'Gate',
            function_code_space: nil,
            usage_value: 'Exterior door',
            usage_code_space: nil
          )
        }.freeze

        def self.resolve(cell_space)
          cell_type = cell_space&.cell_type
          category_code = cell_space&.category_code.to_s
          semantic = default_for(cell_type, category_code)
          semantic = override_from_cell_space(cell_space, semantic) if semantic
          return semantic if semantic

          raise NavigationSemanticError, missing_mapping_message(cell_space, cell_type, category_code)
        end

        def self.default_for(cell_type, category_code)
          NAVIGATION_SEMANTICS[[cell_type, category_code.to_s]]
        end

        def self.legacy_default_semantic?(cell_type, category_code, semantic)
          return false unless semantic

          legacy_default_values?(cell_type, category_code, semantic) &&
            legacy_code_space?(semantic.class_code_space) &&
            legacy_code_space?(semantic.function_code_space) &&
            legacy_code_space?(semantic.usage_code_space)
        end

        def self.legacy_code_space?(value)
          normalized = value.to_s.strip
          normalized.empty? || normalized == LEGACY_ANNEX_D_CODE_SPACE
        end

        def self.legacy_default_values?(cell_type, category_code, semantic)
          values = [
            semantic.class_value.to_s,
            semantic.function_value.to_s,
            semantic.usage_value.to_s
          ]

          case [cell_type, category_code.to_s]
          when [CellSpaceType::GENERAL, 'Room'],
               [CellSpaceType::CONNECTION, 'Door']
            values == %w[1000 1000 1000]
          when [CellSpaceType::TRANSITION, 'Stair']
            values == %w[1010 1120 1120]
          when [CellSpaceType::TRANSITION, 'Elevator']
            values == %w[1010 1110 1110]
          when [CellSpaceType::ANCHOR, 'ExteriorDoor']
            values == %w[1020 1010 1010]
          else
            false
          end
        end
        private_class_method :legacy_default_values?

        def self.override_from_cell_space(cell_space, default_semantic)
          NavigationSemantic.new(
            class_value: override_value(semantic_attr(cell_space, :navigation_class), default_semantic.class_value),
            class_code_space: override_value(semantic_attr(cell_space, :navigation_class_code_space), default_semantic.class_code_space),
            function_value: override_value(semantic_attr(cell_space, :navigation_function), default_semantic.function_value),
            function_code_space: override_value(semantic_attr(cell_space, :navigation_function_code_space), default_semantic.function_code_space),
            usage_value: override_value(semantic_attr(cell_space, :navigation_usage), default_semantic.usage_value),
            usage_code_space: override_value(semantic_attr(cell_space, :navigation_usage_code_space), default_semantic.usage_code_space)
          )
        end
        private_class_method :override_from_cell_space

        def self.semantic_attr(cell_space, name)
          cell_space.respond_to?(name) ? cell_space.public_send(name) : nil
        end
        private_class_method :semantic_attr

        def self.override_value(value, fallback)
          normalized = value.to_s.strip
          normalized.empty? ? fallback : normalized
        end
        private_class_method :override_value

        def self.missing_mapping_message(cell_space, cell_type, category_code)
          [
            'Navigation semantic mapping is missing:',
            "cell_id=#{cell_space&.id}",
            "cell_type=#{CellSpaceType.label(cell_type)}",
            "category=#{category_code}"
          ].join("\n")
        end
        private_class_method :missing_mapping_message
      end

    end
  end
end
