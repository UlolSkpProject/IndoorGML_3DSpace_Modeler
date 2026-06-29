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
        ANNEX_D_CODE_SPACE = 'urn:ogc:def:nil:OGC::IndoorGML:AnnexD'

        NAVIGATION_SEMANTICS = {
          [CellSpaceType::GENERAL, 'Room'] => NavigationSemantic.new(
            class_value: '1000',
            class_code_space: ANNEX_D_CODE_SPACE,
            function_value: '1000',
            function_code_space: ANNEX_D_CODE_SPACE,
            usage_value: '1000',
            usage_code_space: ANNEX_D_CODE_SPACE
          ),
          [CellSpaceType::TRANSITION, 'Stair'] => NavigationSemantic.new(
            class_value: '1010',
            class_code_space: ANNEX_D_CODE_SPACE,
            function_value: '1120',
            function_code_space: ANNEX_D_CODE_SPACE,
            usage_value: '1120',
            usage_code_space: ANNEX_D_CODE_SPACE
          ),
          [CellSpaceType::TRANSITION, 'Elevator'] => NavigationSemantic.new(
            class_value: '1010',
            class_code_space: ANNEX_D_CODE_SPACE,
            function_value: '1110',
            function_code_space: ANNEX_D_CODE_SPACE,
            usage_value: '1110',
            usage_code_space: ANNEX_D_CODE_SPACE
          ),
          [CellSpaceType::CONNECTION, 'Door'] => NavigationSemantic.new(
            class_value: '1000',
            class_code_space: ANNEX_D_CODE_SPACE,
            function_value: '1000',
            function_code_space: ANNEX_D_CODE_SPACE,
            usage_value: '1000',
            usage_code_space: ANNEX_D_CODE_SPACE
          )
        }.freeze

        def self.resolve(cell_space)
          cell_type = cell_space&.cell_type
          category_code = CellSpaceCategory.migrate_legacy_code(cell_space&.category_code)
          semantic = NAVIGATION_SEMANTICS[[cell_type, category_code]]
          semantic = general_space_override(cell_space, semantic) if cell_type == CellSpaceType::GENERAL && semantic
          return semantic if semantic

          raise NavigationSemanticError, missing_mapping_message(cell_space, cell_type, category_code)
        end

        def self.general_space_override(cell_space, default_semantic)
          NavigationSemantic.new(
            class_value: override_value(semantic_attr(cell_space, :navigation_class), default_semantic.class_value),
            class_code_space: override_value(semantic_attr(cell_space, :navigation_class_code_space), default_semantic.class_code_space),
            function_value: override_value(semantic_attr(cell_space, :navigation_function), default_semantic.function_value),
            function_code_space: override_value(semantic_attr(cell_space, :navigation_function_code_space), default_semantic.function_code_space),
            usage_value: override_value(semantic_attr(cell_space, :navigation_usage), default_semantic.usage_value),
            usage_code_space: override_value(semantic_attr(cell_space, :navigation_usage_code_space), default_semantic.usage_code_space)
          )
        end
        private_class_method :general_space_override

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
          category_label = cell_space&.category_label.to_s
          category_label = category_code.to_s if category_label.empty?
          [
            'Navigation semantic mapping is missing:',
            "cell_id=#{cell_space&.id}",
            "cell_type=#{CellSpaceType.label(cell_type)}",
            "category=#{category_code}",
            "category_label=#{category_label}"
          ].join("\n")
        end
        private_class_method :missing_mapping_message
      end

    end
  end
end
