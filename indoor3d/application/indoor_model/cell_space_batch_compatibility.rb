# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module CellSpaceBatchCompatibility
          # Local Grid V2 single-create follows the same batch orchestration as
          # every other Create path. Batch size one is the only special case.
          def convert_single_group_to_cell_space_local_grid_v2(
            sketchup_group,
            cell_type = CellSpaceType::GENERAL,
            category_code = nil
          )
            create_cell_spaces(
              [
                {
                  source: sketchup_group,
                  cell_type: cell_type,
                  category_code: category_code,
                  local_grid_v2: true
                }
              ],
              operation_name: 'IndoorGML Convert Group to CellSpace Local Grid V2'
            ).first
          end
        end
      end
    end
  end
end
