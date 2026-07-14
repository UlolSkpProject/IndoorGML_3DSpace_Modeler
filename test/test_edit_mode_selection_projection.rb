# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/domain/cell_space_category'
require_relative '../indoor3d/application/indoor_model/edit_mode_selection_projection'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditModeSelectionProjectionTest < Minitest::Test
        FakeGroup = Struct.new(:name)
        FakeState = Struct.new(:transition_ids)

        def test_empty_snapshot_includes_counts_and_visibility_filter
          projection = build_projection(
            cell_spaces: [
              fake_cell_space(cell_type: CellSpaceType::GENERAL),
              fake_cell_space(cell_type: CellSpaceType::TRANSITION)
            ],
            states: [valid_item, invalid_item],
            transitions: [valid_item]
          )

          snapshot = projection.snapshot(selected_cell_spaces: [], solid_jobs: [])

          assert_equal 'empty', snapshot[:mode]
          assert_equal 1, snapshot[:state_count]
          assert_equal 1, snapshot[:total_transition_count]
          assert_equal({ storeys: %w[1F], cell_types: %w[GeneralSpace] }, snapshot[:visibility_filter])
          assert_equal 1, count_for(snapshot, 'GeneralSpace')
          assert_equal 1, count_for(snapshot, 'TransitionSpace')
        end

        def test_single_cell_space_snapshot_projects_dialog_fields
          cell_space = fake_cell_space(
            id: 'cell_A',
            name: 'Room A',
            cell_type: CellSpaceType::GENERAL,
            category_code: 'Room',
            storey: '2F',
            transition_ids: %w[t1 t2]
          )
          projection = build_projection

          snapshot = projection.snapshot(selected_cell_spaces: [cell_space], solid_jobs: [])

          assert_equal 'cell_space', snapshot[:mode]
          assert_equal 'cell_A', snapshot[:id]
          assert_equal 'Room A', snapshot[:name]
          assert_equal CellSpaceCategory.selection_value(CellSpaceType::GENERAL, 'Room'), snapshot[:classification]
          assert_equal '2F', snapshot[:storey]
          assert_equal 2, snapshot[:transition_count]
        end

        def test_solid_jobs_snapshot_uses_common_tag_classification
          target = [CellSpaceType::TRANSITION, 'Stair']
          projection = build_projection

          snapshot = projection.snapshot(
            selected_cell_spaces: [],
            solid_jobs: [
              { source: Object.new, target: target, storey: 'F01~F03' },
              { source: Object.new, target: target, storey: 'F01~F03' }
            ]
          )

          assert_equal 'solid_groups', snapshot[:mode]
          assert_equal 2, snapshot[:solid_group_count]
          assert_equal CellSpaceCategory.selection_value(*target), snapshot[:classification]
          assert_equal true, snapshot[:classification_locked]
          assert_equal 'F01~F03', snapshot[:storey]
        end

        def test_multi_cell_space_snapshot_counts_selected_types
          projection = build_projection

          snapshot = projection.snapshot(
            selected_cell_spaces: [
              fake_cell_space(cell_type: CellSpaceType::GENERAL),
              fake_cell_space(cell_type: CellSpaceType::GENERAL),
              fake_cell_space(cell_type: CellSpaceType::TRANSITION, category_code: 'Stair')
            ],
            solid_jobs: []
          )

          assert_equal 'cell_spaces', snapshot[:mode]
          assert_equal 3, snapshot[:cell_space_count]
          assert_equal [
            { label: 'GeneralSpace', count: 2 },
            { label: 'TransitionSpace', count: 1 }
          ], snapshot[:selected_cell_type_counts]
        end

        private

        def build_projection(cell_spaces: [], states: [], transitions: [], editor_session: FakeSession.new(nil))
          EditModeSelectionProjection.new(
            cell_spaces: cell_spaces,
            states: states,
            transitions: transitions,
            editor_session: editor_session,
            visibility_filter: { storeys: %w[1F], cell_types: %w[GeneralSpace] },
            tag_classifier: ->(_entity) { nil }
          )
        end

        def fake_cell_space(id: 'cell', name: 'Cell', cell_type: CellSpaceType::GENERAL, category_code: 'Room', storey: '1F', transition_ids: [])
          Struct.new(
            :id,
            :sketchup_group,
            :cell_type,
            :category_code,
            :storey,
            :duality_state,
            keyword_init: true
          ) do
            def valid?
              true
            end
          end.new(
            id: id,
            sketchup_group: FakeGroup.new(name),
            cell_type: cell_type,
            category_code: category_code,
            storey: storey,
            duality_state: FakeState.new(transition_ids)
          )
        end

        def valid_item
          Struct.new(:valid?).new(true)
        end

        def invalid_item
          Struct.new(:valid?).new(false)
        end

        def count_for(snapshot, label)
          snapshot[:cell_type_counts].find { |item| item[:label] == label }[:count]
        end

        class FakeSession
          def initialize(editing_cell_space)
            @editing_cell_space = editing_cell_space
          end

          attr_reader :editing_cell_space
        end
      end
    end
  end
end
