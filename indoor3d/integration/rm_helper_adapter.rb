# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module RmHelperAdapter
        def self.cell_space_type_and_category(group)
          return nil unless group&.respond_to?(:get_attribute)

          space_type = group.get_attribute(
            ::ULOL::Indoor3DGmlModeler::RM_HELPER_DICT,
            ::ULOL::Indoor3DGmlModeler::RM_HELPER_SPACE_TYPE_KEY
          ).to_s.strip.upcase
          category_code = ::ULOL::Indoor3DGmlModeler::RM_HELPER_SPACE_TYPE_TO_CATEGORY_CODE[space_type]
          return nil if category_code.nil?

          option = CellSpaceCategory.selection_options.find do |candidate|
            candidate[:category_code] == category_code
          end
          return nil if option.nil?

          [option[:cell_type], option[:category_code]]
        end

        def self.resolve_cell_space_type_and_category(group, cell_type, category_code)
          cell_space_type_and_category(group) || [cell_type, category_code]
        end
      end
    end
  end
end
