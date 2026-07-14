# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/indoor_model/editor_control'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ValidationFocusRowCellCreationTest < Minitest::Test
        def test_created_cell_is_logged_after_selected_row_refs_are_updated
          payload = {
            row_id: 'validation-error-row-0',
            cells: %w[A B],
            states: [],
            transitions: [],
            focus_ids: %w[cell_A cell_B],
            code: '203',
            label: 'cell_A and cell_B'
          }
          model = FakeIndoorModel.new(payload)

          output, = capture_io do
            model.add_validation_focus_highlight_cell(Struct.new(:id).new('B'))
          end

          assert_equal payload, model.updated_payload
          assert_equal "[IndoorGML] validation focus ref-cells: [\"A\", \"B\"]\n", output
        end

        class FakeIndoorModel
          include IndoorModel::EditorControl

          attr_reader :updated_payload

          def initialize(payload)
            @editor_session = Struct.new(:payload) do
              def add_validation_focus_highlight_cell(_cell_space)
                payload
              end
            end.new(payload)
          end

          private

          def update_validation_focus_report_row(payload)
            @updated_payload = payload
          end
        end
      end
    end
  end
end
