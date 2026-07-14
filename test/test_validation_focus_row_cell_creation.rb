# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/indoor_model/editor_control'
require_relative '../indoor3d/infrastructure/scene/editor_session/validation_focus_controller'

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

        def test_replacement_batch_emits_only_the_final_row_refs
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          controller.set_focus_rows([{ id: 'row-1', cells: ['A'], focus_ids: ['cell_A'], code: '203' }])
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1', row_cells: ['A'])
          editor_session = FakeBatchEditorSession.new(controller)
          model = FakeBatchIndoorModel.new(editor_session)

          model.with_validation_focus_mutation_batch do
            model.remove_validation_focus_highlight_cell(Struct.new(:id).new('A'))
            assert_empty model.updated_payloads
            model.add_validation_focus_highlight_cell(Struct.new(:id).new('B'))
            assert_empty model.updated_payloads
          end

          assert_equal 1, editor_session.refresh_count
          assert_equal 1, model.updated_payloads.length
          assert_equal ['B'], model.updated_payloads.first[:cells]
          assert_equal 'cell_B', model.updated_payloads.first[:label]
          assert_equal ['B'], controller.highlighted_row_cells
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

        class FakeBatchIndoorModel
          include IndoorModel::EditorControl

          attr_reader :updated_payloads

          def initialize(editor_session)
            @editor_session = editor_session
            @updated_payloads = []
          end

          def flush_validation_focus_row_topology_sync; end

          def discard_validation_focus_row_topology_sync; end

          private

          def update_validation_focus_report_row(payload)
            @updated_payloads << payload
          end
        end

        class FakeBatchEditorSession
          attr_reader :refresh_count

          def initialize(controller)
            @controller = controller
            @refresh_count = 0
          end

          def validation_focus_highlight_row_id
            @controller.highlight_row_id
          end

          def validation_focus_snapshot
            @controller.snapshot
          end

          def restore_validation_focus_snapshot(snapshot)
            @controller.restore!(snapshot)
          end

          def add_validation_focus_highlight_cell(cell_space, refresh: true)
            payload = @controller.add_highlight_cell(cell_space.id)
            refresh_validation_focus_after_mutation if payload && refresh
            payload
          end

          def remove_validation_focus_highlight_cell(cell_space, refresh: true)
            payloads = @controller.remove_cell(cell_space.id)
            refresh_validation_focus_after_mutation if !payloads.empty? && refresh
            payloads
          end

          def refresh_validation_focus_after_mutation
            @refresh_count += 1
          end
        end
      end
    end
  end
end
