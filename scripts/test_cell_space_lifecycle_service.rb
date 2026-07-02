# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceType
        GENERAL = :general
      end unless const_defined?(:CellSpaceType)
    end
  end
end

require_relative '../indoor3d/application/cell_space_lifecycle_service'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceLifecycleServiceTest < Minitest::Test
        def test_create_from_group_runs_existing_creation_sequence
          calls = []
          source_group = Object.new
          placed_group = Object.new
          state = Object.new
          callbacks = lifecycle_callbacks(calls, source_group: source_group, placed_group: placed_group, state: state)
          service = CellSpaceLifecycleService.new(callbacks)

          cell_space = service.create_from_group(source_group, cell_type: :input_type, category_code: 'Room')

          assert_equal placed_group, cell_space.sketchup_group
          assert_equal :resolved_type, cell_space.cell_type
          assert_equal 'resolved_category', cell_space.category_code
          assert_equal 'F01', cell_space.storey
          assert_equal state, cell_space.state
          assert_equal [
            :converted_group?,
            :resolve_cell_space_type_and_category,
            :prepare_cell_space_source_group!,
            :ensure_space_features_groups,
            :place_cell_group,
            :default_storey_name,
            :fixed_state_height_offset,
            :recenter_cell_space_geometry,
            :name_cell_space_entity,
            :apply_cell_space_material,
            :create_duality_state,
            :register_cell_space,
            :register_state,
            :write_attributes,
            :track_cell_space_entity,
            :synchronize_adjacency_and_transitions_for_cell_space,
            :apply_indoor_lock_policy
          ], calls
        end

        def test_duplicate_source_raises_before_geometry_validation
          calls = []
          callbacks = lifecycle_callbacks(calls).merge(converted_group?: proc { |_group| calls << :converted_group?; true })
          service = CellSpaceLifecycleService.new(callbacks)

          error = assert_raises(ArgumentError) { service.create_from_group(Object.new) }

          assert_equal 'Group is already converted to CellSpace', error.message
          assert_equal [:converted_group?], calls
        end

        def test_invalid_geometry_raises_validation_reason
          calls = []
          callbacks = lifecycle_callbacks(calls).merge(
            prepare_cell_space_source_group!: proc { |_group| calls << :prepare_cell_space_source_group!; { valid: false, reason: 'not solid' } }
          )
          service = CellSpaceLifecycleService.new(callbacks)

          error = assert_raises(ArgumentError) { service.create_from_group(Object.new) }

          assert_equal 'not solid', error.message
          refute_includes calls, :ensure_space_features_groups
        end

        private

        def lifecycle_callbacks(calls, source_group: Object.new, placed_group: Object.new, state: Object.new)
          {
            cell_space_class: fake_cell_space_class(calls, state),
            converted_group?: proc { |_group| calls << :converted_group?; false },
            resolve_cell_space_type_and_category: proc do |group, cell_type, category_code|
              calls << :resolve_cell_space_type_and_category
              refute_nil group
              assert_equal :input_type, cell_type if cell_type == :input_type
              assert_equal 'Room', category_code if category_code == 'Room'
              [:resolved_type, 'resolved_category']
            end,
            prepare_cell_space_source_group!: proc { |_group| calls << :prepare_cell_space_source_group!; { valid: true } },
            ensure_space_features_groups: proc { calls << :ensure_space_features_groups },
            place_cell_group: proc { |_group| calls << :place_cell_group; placed_group },
            default_storey_name: proc { calls << :default_storey_name; 'F01' },
            fixed_state_height_offset: proc { |_cell_space| calls << :fixed_state_height_offset; 1.25 },
            recenter_cell_space_geometry: proc do |_group, fixed_z_offset_from_bottom: nil|
              calls << :recenter_cell_space_geometry
              assert_equal 1.25, fixed_z_offset_from_bottom
            end,
            name_cell_space_entity: proc { |_cell_space| calls << :name_cell_space_entity },
            apply_cell_space_material: proc { |_cell_space| calls << :apply_cell_space_material },
            register_cell_space: proc { |_cell_space| calls << :register_cell_space },
            register_state: proc { |_state| calls << :register_state },
            write_attributes: proc { |_cell_space| calls << :write_attributes },
            track_cell_space_entity: proc { |_group| calls << :track_cell_space_entity },
            synchronize_adjacency_and_transitions_for_cell_space: proc { |_cell_space| calls << :synchronize_adjacency_and_transitions_for_cell_space },
            apply_indoor_lock_policy: proc { calls << :apply_indoor_lock_policy }
          }
        end

        def fake_cell_space_class(calls, state)
          Class.new do
            attr_reader :sketchup_group, :cell_type, :category_code, :storey, :state

            define_method(:initialize) do |group, cell_type, category_code|
              @sketchup_group = group
              @cell_type = cell_type
              @category_code = category_code
            end

            define_method(:set_storey) do |storey|
              @storey = storey
            end

            define_method(:create_duality_state) do |parent_entities|
              calls << :create_duality_state
              raise 'unexpected parent entities' unless parent_entities.nil?

              @state = state
            end
          end
        end
      end
    end
  end
end
