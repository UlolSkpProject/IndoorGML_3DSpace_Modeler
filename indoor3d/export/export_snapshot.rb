# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ExportSnapshot
          attr_reader :cell_spaces, :transitions

          def self.build(indoor_model:, cell_spaces: nil, transitions: nil)
            source_cell_spaces = cell_spaces || indoor_model.cell_spaces
            exportable_cell_spaces = Array(source_cell_spaces).select do |cell_space|
              cell_space&.valid_sketchup_group && cell_space.duality_state&.valid?
            end.uniq

            source_transitions = transitions || indoor_model.transitions
            exportable_transitions = Array(source_transitions).select do |transition|
              transition&.valid? &&
                transition.state1&.valid? &&
                transition.state2&.valid? &&
                exportable_cell_spaces.include?(transition.state1.duality_cell) &&
                exportable_cell_spaces.include?(transition.state2.duality_cell)
            end.uniq

            new(
              cell_spaces: exportable_cell_spaces,
              transitions: exportable_transitions
            )
          end

          def initialize(cell_spaces:, transitions:)
            @cell_spaces = Array(cell_spaces).freeze
            @transitions = Array(transitions).freeze
          end
        end
      end
    end
  end
end
