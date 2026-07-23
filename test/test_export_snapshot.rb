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

            assert_equal %w[cell_1 cell_2], snapshot.cell_spaces.map(&:id)
            assert_equal ['transition_1'], snapshot.transitions.map(&:id)
            assert_equal ['transition_1'], snapshot.cell_spaces[0].duality_state.transition_ids
            assert_equal ['transition_1'], snapshot.cell_spaces[1].duality_state.transition_ids
            assert snapshot.cell_spaces.frozen?
            assert snapshot.transitions.frozen?
            refute_same cell_a, snapshot.cell_spaces.first
            refute_same transition_inside, snapshot.transitions.first
          end

          def test_build_sets_empty_transition_ids_for_state_without_exported_transitions
            cell = fake_cell_space(valid_group: true, state_valid: true)
            indoor_model = fake_indoor_model(cell_spaces: [cell], transitions: [])

            snapshot = ExportSnapshot.build(indoor_model: indoor_model)

            assert_equal [], snapshot.cell_spaces.first.duality_state.transition_ids
          end

          def test_build_excludes_transition_ids_not_in_current_export
            cell_a = fake_cell_space(valid_group: true, state_valid: true)
            cell_b = fake_cell_space(valid_group: true, state_valid: true)
            cell_c = fake_cell_space(valid_group: true, state_valid: true)
            included_transition = fake_transition(cell_a.duality_state, cell_b.duality_state)
            excluded_transition = fake_transition(cell_a.duality_state, cell_c.duality_state)
            indoor_model = fake_indoor_model(
              cell_spaces: [cell_a, cell_b, cell_c],
              transitions: [included_transition, excluded_transition]
            )

            snapshot = ExportSnapshot.build(
              indoor_model: indoor_model,
              cell_spaces: [cell_a, cell_b],
              transitions: [included_transition, excluded_transition]
            )

            assert_equal [included_transition.id], snapshot.transitions.map(&:id)
            assert_equal [included_transition.id], snapshot.cell_spaces[0].duality_state.transition_ids
            assert_equal [included_transition.id], snapshot.cell_spaces[1].duality_state.transition_ids
            refute_includes snapshot.cell_spaces[0].duality_state.transition_ids, excluded_transition.id
          end

          def test_build_uses_requested_sources_when_provided
            model_cell = fake_cell_space(valid_group: true, state_valid: true)
            requested_cell_a = fake_cell_space(valid_group: true, state_valid: true)
            requested_cell_b = fake_cell_space(valid_group: true, state_valid: true)
            requested_transition = fake_transition(requested_cell_a.duality_state, requested_cell_b.duality_state)
            indoor_model = fake_indoor_model(cell_spaces: [model_cell], transitions: [])

            snapshot = ExportSnapshot.build(
              indoor_model: indoor_model,
              cell_spaces: [requested_cell_a, requested_cell_b],
              transitions: [requested_transition]
            )

            assert_equal [requested_cell_a.id, requested_cell_b.id], snapshot.cell_spaces.map(&:id)
            assert_equal [requested_transition.id], snapshot.transitions.map(&:id)
            assert_equal [requested_transition.id], snapshot.cell_spaces[0].duality_state.transition_ids
            assert_equal [requested_transition.id], snapshot.cell_spaces[1].duality_state.transition_ids
          end

          def test_build_deduplicates_transition_ids_for_same_state_transition
            cell = fake_cell_space(valid_group: true, state_valid: true)
            transition = fake_transition(cell.duality_state, cell.duality_state)
            indoor_model = fake_indoor_model(cell_spaces: [cell], transitions: [transition])

            snapshot = ExportSnapshot.build(indoor_model: indoor_model)

            assert_equal [transition.id], snapshot.cell_spaces.first.duality_state.transition_ids
          end

          private

          def fake_indoor_model(cell_spaces:, transitions:)
            Struct.new(:cell_spaces, :transitions).new(cell_spaces, transitions)
          end

          def fake_cell_space(valid_group:, state_valid:)
            @cell_index = @cell_index.to_i + 1
            cell_class = Struct.new(:id, :cell_type, :storey, :valid_sketchup_group, :duality_state, :category_code)
            state_class = Struct.new(:id, :duality_cell, :valid?, :position)
            cell = cell_class.new(nil, nil, nil, valid_group ? Object.new : nil, nil, nil)
            cell.id = "cell_#{@cell_index}"
            cell.cell_type = :general
            cell.storey = 'F01'
            cell.category_code = 'Room'
            cell.duality_state = state_class.new("state_#{@cell_index}", cell, state_valid, point(@cell_index, 0, 0))
            cell
          end

          def fake_transition(state1, state2, valid: true)
            @transition_index = @transition_index.to_i + 1
            Struct.new(:id, :state1, :state2, :valid?, :state1_point, :state2_point) do
            end.new("transition_#{@transition_index}", state1, state2, valid, nil, nil)
          end

          def point(x, y, z)
            Struct.new(:x, :y, :z).new(x, y, z)
          end
        end
      end
    end
  end
end
