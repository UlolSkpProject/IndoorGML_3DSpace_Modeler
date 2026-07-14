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

        def test_row_selection_logs_the_memory_backed_refs_that_are_applied
          model = FakeIndoorModel.new(nil)

          output, = capture_io do
            model.set_validation_focus_highlight(
              %w[cell_A cell_B],
              '203',
              row_id: 'validation-error-row-0',
              row_cells: %w[A B]
            )
          end

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

              def set_validation_focus_highlight(*)
                true
              end

              def validation_focus_row(_row_id)
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
