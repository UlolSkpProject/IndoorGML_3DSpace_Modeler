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
          service = build_lifecycle_service(callbacks)

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
          service = build_lifecycle_service(callbacks)

          error = assert_raises(ArgumentError) { service.create_from_group(Object.new) }

          assert_equal 'Group is already converted to CellSpace', error.message
          assert_equal [:converted_group?], calls
        end

        def test_invalid_geometry_raises_validation_reason
          calls = []
          callbacks = lifecycle_callbacks(calls).merge(
            prepare_cell_space_source_group!: proc { |_group| calls << :prepare_cell_space_source_group!; { valid: false, reason: 'not solid' } }
          )
          service = build_lifecycle_service(callbacks)

          error = assert_raises(ArgumentError) { service.create_from_group(Object.new) }

          assert_equal 'not solid', error.message
          refute_includes calls, :ensure_space_features_groups
        end

        def test_change_type_runs_existing_update_sequence
          calls = []
          cell_space = fake_mutable_cell_space(calls: calls)
          service = build_lifecycle_service(lifecycle_callbacks(calls))

          result = service.change_type(cell_space, cell_type: :transition, category_code: 'Door')

          assert_same cell_space, result
          assert_equal :transition, cell_space.cell_type
          assert_equal 'Door', cell_space.category_code
          assert_equal [
            :set_category,
            :name_cell_space_entity,
            :apply_cell_space_material,
            :write_cell_space_attributes,
            :synchronize_adjacency_and_transitions_for_cell_space,
            :apply_indoor_lock_policy
          ], calls
        end

        def test_change_type_keeps_existing_error_messages
          service = build_lifecycle_service(lifecycle_callbacks([]))

          assert_equal(
            'Selected entity is not a registered CellSpace',
            assert_raises(ArgumentError) { service.change_type(nil, cell_type: :general, category_code: nil) }.message
          )
          assert_equal(
            'CellSpace is no longer valid',
            assert_raises(ArgumentError) { service.change_type(fake_mutable_cell_space(valid: false), cell_type: :general, category_code: nil) }.message
          )
        end

        def test_erase_runs_existing_delete_sequence
          calls = []
          state = fake_state(calls)
          cell_space = fake_erasable_cell_space(state: state, calls: calls)
          service = build_lifecycle_service(lifecycle_callbacks(calls))

          service.erase(cell_space, erase_sketchup_group: true)

          assert_equal true, state.erased
          assert_equal true, cell_space.erased
          assert_equal [
            :erase_transitions_for_state,
            :state_erase,
            :unregister_state,
            :cell_space_erase,
            :unregister_cell_space,
            :erase_adjacency_for_cell_space
          ], calls
        end

        def test_erase_can_keep_sketchup_group
          calls = []
          cell_space = fake_erasable_cell_space(state: fake_state(calls), calls: calls)
          service = build_lifecycle_service(lifecycle_callbacks(calls))

          service.erase(cell_space, erase_sketchup_group: false)

          assert_equal false, cell_space.erased
          refute_includes calls, :cell_space_erase
          assert_includes calls, :unregister_cell_space
        end

        private

        def build_lifecycle_service(callbacks)
          CellSpaceLifecycleService.new(
            cell_space_class: callbacks.fetch(:cell_space_class),
            source_preparer: CellSpaceLifecycleSourcePreparer.new(
              converted_group: callbacks.fetch(:converted_group?),
              type_resolver: callbacks.fetch(:resolve_cell_space_type_and_category),
              geometry_preparer: callbacks.fetch(:prepare_cell_space_source_group!)
            ),
            context: CellSpaceLifecycleContext.new(
              ensure_space_features_groups: callbacks.fetch(:ensure_space_features_groups),
              place_cell_group: callbacks.fetch(:place_cell_group),
              default_storey_name: callbacks.fetch(:default_storey_name),
              fixed_state_height_offset: callbacks.fetch(:fixed_state_height_offset),
              recenter_cell_space_geometry: callbacks.fetch(:recenter_cell_space_geometry),
              name_cell_space_entity: callbacks.fetch(:name_cell_space_entity),
              apply_cell_space_material: callbacks.fetch(:apply_cell_space_material),
              track_cell_space_entity: callbacks.fetch(:track_cell_space_entity),
              apply_indoor_lock_policy: callbacks.fetch(:apply_indoor_lock_policy),
              register_cell_space: callbacks.fetch(:register_cell_space),
              register_state: callbacks.fetch(:register_state),
              unregister_cell_space: callbacks.fetch(:unregister_cell_space),
              unregister_state: callbacks.fetch(:unregister_state),
              write_attributes: callbacks.fetch(:write_attributes),
              write_cell_space_attributes: callbacks.fetch(:write_cell_space_attributes),
              synchronize_adjacency_and_transitions_for_cell_space: callbacks.fetch(:synchronize_adjacency_and_transitions_for_cell_space),
              erase_transitions_for_state: callbacks.fetch(:erase_transitions_for_state),
              erase_adjacency_for_cell_space: callbacks.fetch(:erase_adjacency_for_cell_space)
            )
          )
        end

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
            write_cell_space_attributes: proc { |_cell_space| calls << :write_cell_space_attributes },
            track_cell_space_entity: proc { |_group| calls << :track_cell_space_entity },
            synchronize_adjacency_and_transitions_for_cell_space: proc { |_cell_space| calls << :synchronize_adjacency_and_transitions_for_cell_space },
            apply_indoor_lock_policy: proc { calls << :apply_indoor_lock_policy },
            erase_transitions_for_state: proc { |_state| calls << :erase_transitions_for_state },
            unregister_state: proc { |_state| calls << :unregister_state },
            unregister_cell_space: proc { |_cell_space| calls << :unregister_cell_space },
            erase_adjacency_for_cell_space: proc { |_cell_space| calls << :erase_adjacency_for_cell_space }
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

        def fake_mutable_cell_space(valid: true, calls: [])
          Class.new do
            attr_accessor :cell_type
            attr_reader :category_code

            define_method(:initialize) do |valid_flag, call_log|
              @valid = valid_flag
              @calls = call_log
            end

            def valid?
              @valid == true
            end

            def set_category(category_code)
              @calls << :set_category
              @category_code = category_code
            end
          end.new(valid, calls).tap do |cell_space|
            cell_space.define_singleton_method(:calls) { calls }
          end
        end

        def fake_state(calls)
          Class.new do
            attr_reader :erased

            def initialize(calls)
              @calls = calls
              @erased = false
            end

            def valid?
              true
            end

            def erase!
              @calls << :state_erase
              @erased = true
            end
          end.new(calls)
        end

        def fake_erasable_cell_space(state:, calls:)
          Class.new do
            attr_reader :duality_state, :erased

            def initialize(state, calls)
              @duality_state = state
              @calls = calls
              @erased = false
            end

            def valid?
              true
            end

            def erase!
              @calls << :cell_space_erase
              @erased = true
            end
          end.new(state, calls)
        end
      end
    end
  end
end
