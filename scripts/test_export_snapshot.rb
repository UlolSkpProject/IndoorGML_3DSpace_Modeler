# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/export/export_snapshot'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ExportSnapshotTest < Minitest::Test
          def test_build_filters_exportable_cells_and_transitions
            cell_a = fake_cell_space(valid_group: true, state_valid: true)
            cell_b = fake_cell_space(valid_group: true, state_valid: true)
            invalid_cell = fake_cell_space(valid_group: false, state_valid: true)
            transition_inside = fake_transition(cell_a.duality_state, cell_b.duality_state)
            transition_with_invalid_cell = fake_transition(cell_a.duality_state, invalid_cell.duality_state)
            invalid_transition = fake_transition(cell_a.duality_state, cell_b.duality_state, valid: false)
            indoor_model = fake_indoor_model(
              cell_spaces: [cell_a, cell_a, cell_b, invalid_cell],
              transitions: [transition_inside, transition_inside, transition_with_invalid_cell, invalid_transition]
            )

            snapshot = ExportSnapshot.build(indoor_model: indoor_model)

            assert_equal [cell_a, cell_b], snapshot.cell_spaces
            assert_equal [transition_inside], snapshot.transitions
            assert snapshot.cell_spaces.frozen?
            assert snapshot.transitions.frozen?
          end

          def test_build_uses_requested_sources_when_provided
            model_cell = fake_cell_space(valid_group: true, state_valid: true)
            requested_cell = fake_cell_space(valid_group: true, state_valid: true)
            requested_transition = fake_transition(requested_cell.duality_state, requested_cell.duality_state)
            indoor_model = fake_indoor_model(cell_spaces: [model_cell], transitions: [])

            snapshot = ExportSnapshot.build(
              indoor_model: indoor_model,
              cell_spaces: [requested_cell],
              transitions: [requested_transition]
            )

            assert_equal [requested_cell], snapshot.cell_spaces
            assert_equal [requested_transition], snapshot.transitions
          end

          private

          def fake_indoor_model(cell_spaces:, transitions:)
            Struct.new(:cell_spaces, :transitions).new(cell_spaces, transitions)
          end

          def fake_cell_space(valid_group:, state_valid:)
            cell_class = Struct.new(:valid_sketchup_group, :duality_state)
            state_class = Struct.new(:duality_cell, :valid?)
            cell = cell_class.new(valid_group ? Object.new : nil, nil)
            cell.duality_state = state_class.new(cell, state_valid)
            cell
          end

          def fake_transition(state1, state2, valid: true)
            Struct.new(:state1, :state2, :valid?) do
            end.new(state1, state2, valid)
          end
        end
      end
    end
  end
end
