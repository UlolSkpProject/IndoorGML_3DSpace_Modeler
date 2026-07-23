# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/integration/tag_cell_space_adapter'
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
            :tag_cell_space_storey,
            :resolve_cell_space_storey,
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

        def test_create_from_group_deferred_skips_immediate_adjacency_and_lock_policy
          calls = []
          source_group = Object.new
          placed_group = Object.new
          state = Object.new
          callbacks = lifecycle_callbacks(calls, source_group: source_group, placed_group: placed_group, state: state)
          service = build_lifecycle_service(callbacks)

          cell_space = service.create_from_group_deferred(source_group, cell_type: :input_type, category_code: 'Room')

          assert_equal placed_group, cell_space.sketchup_group
          assert_equal [
            :converted_group?,
            :resolve_cell_space_type_and_category,
            :prepare_cell_space_source_group!,
            :ensure_space_features_groups,
            :place_cell_group,
            :default_storey_name,
            :tag_cell_space_storey,
            :resolve_cell_space_storey,
            :fixed_state_height_offset,
            :recenter_cell_space_geometry,
            :name_cell_space_entity,
            :apply_cell_space_material,
            :create_duality_state,
            :register_cell_space,
            :register_state,
            :write_attributes,
            :track_cell_space_entity
          ], calls
        end

        def test_create_from_group_uses_resolved_storey_from_source
          calls = []
          source_group = Object.new
          callbacks = lifecycle_callbacks(calls).merge(
            resolve_cell_space_storey: proc do |group, cell_type, category_code, default_storey|
              calls << :resolve_cell_space_storey
              assert_equal :resolved_type, cell_type
              assert_equal 'resolved_category', category_code
              assert_equal 'F01', default_storey
              assert_same source_group, group
              'B02~F01'
            end
          )
          service = build_lifecycle_service(callbacks)

          cell_space = service.create_from_group(source_group, cell_type: :input_type, category_code: 'Room')

          assert_equal 'B02~F01', cell_space.storey
        end

        def test_create_from_group_uses_tag_range_for_stair
          calls = []
          source_group = fake_tagged_group('F01F03_MV_RM_02')
          callbacks = lifecycle_callbacks(calls).merge(tag_resolver_callbacks(calls))
          service = build_lifecycle_service(callbacks)

          cell_space = service.create_from_group(source_group, cell_type: CellSpaceType::GENERAL, category_code: 'Room')

          assert_equal CellSpaceType::TRANSITION, cell_space.cell_type
          assert_equal 'Stair', cell_space.category_code
          assert_equal 'F01~F03', cell_space.storey
        end

        def test_create_from_group_keeps_state_creation_for_geometry_only_cell_space
          calls = []
          state = Object.new
          callbacks = lifecycle_callbacks(calls, state: state).merge(
            resolve_cell_space_type_and_category: proc do |_group, _cell_type, _category_code|
              calls << :resolve_cell_space_type_and_category
              [CellSpaceType::GEOMETRY_ONLY, 'Window']
            end
          )
          service = build_lifecycle_service(callbacks)

          cell_space = service.create_from_group(Object.new, cell_type: CellSpaceType::GEOMETRY_ONLY, category_code: 'Window')

          assert_equal CellSpaceType::GEOMETRY_ONLY, cell_space.cell_type
          assert_equal 'Window', cell_space.category_code
          assert_equal state, cell_space.state
          assert_includes calls, :create_duality_state
          assert_includes calls, :synchronize_adjacency_and_transitions_for_cell_space
        end

        def test_create_from_group_deferred_uses_propagated_storey_override
          calls = []
          source_group = fake_tagged_group('Untagged')
          callbacks = lifecycle_callbacks(calls).merge(tag_resolver_callbacks(calls))
          service = build_lifecycle_service(callbacks)

          cell_space = service.create_from_group_deferred(
            source_group,
            cell_type: CellSpaceType::TRANSITION,
            category_code: 'Elevator',
            storey: 'B02~F01'
          )

          assert_equal CellSpaceType::TRANSITION, cell_space.cell_type
          assert_equal 'Elevator', cell_space.category_code
          assert_equal 'B02~F01', cell_space.storey
          refute_includes calls, :resolve_cell_space_storey
        end

        def test_create_from_group_deferred_always_prefers_source_tag_storey_over_override
          calls = []
          source_group = fake_tagged_group('F02F04_MV_RM_02')
          callbacks = lifecycle_callbacks(calls).merge(tag_resolver_callbacks(calls))
          service = build_lifecycle_service(callbacks)

          cell_space = service.create_from_group_deferred(
            source_group,
            cell_type: CellSpaceType::GENERAL,
            category_code: 'Room',
            storey: 'B02~F01'
          )

          assert_equal CellSpaceType::TRANSITION, cell_space.cell_type
          assert_equal 'Stair', cell_space.category_code
          assert_equal 'F02~F04', cell_space.storey
          assert_includes calls, :tag_cell_space_storey
          refute_includes calls, :resolve_cell_space_storey
        end

        def test_create_from_group_deferred_trims_propagated_room_range_to_start_floor
          calls = []
          source_group = fake_tagged_group('Untagged')
          callbacks = lifecycle_callbacks(calls).merge(tag_resolver_callbacks(calls))
          service = build_lifecycle_service(callbacks)

          cell_space = service.create_from_group_deferred(
            source_group,
            cell_type: CellSpaceType::GENERAL,
            category_code: 'Room',
            storey: 'F01~F03'
          )

          assert_equal 'F01', cell_space.storey
        end

        def test_create_from_group_uses_start_floor_for_tagged_room_range
          calls = []
          source_group = fake_tagged_group('F01F03_IP_RM_23')
          callbacks = lifecycle_callbacks(calls).merge(tag_resolver_callbacks(calls))
          service = build_lifecycle_service(callbacks)

          cell_space = service.create_from_group(source_group, cell_type: CellSpaceType::TRANSITION, category_code: 'Stair')

          assert_equal CellSpaceType::GENERAL, cell_space.cell_type
          assert_equal 'Room', cell_space.category_code
          assert_equal 'F01', cell_space.storey
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

        def test_register_failure_aborts_before_state_persistence
          calls = []
          callbacks = lifecycle_callbacks(calls).merge(
            register_cell_space: proc { |_cell_space| calls << :register_cell_space; false }
          )
          service = build_lifecycle_service(callbacks)

          error = assert_raises(ArgumentError) { service.create_from_group(Object.new, cell_type: :input_type, category_code: 'Room') }

          assert_equal 'CellSpace scale normalization failed', error.message
          assert_equal [
            :converted_group?,
            :resolve_cell_space_type_and_category,
            :prepare_cell_space_source_group!,
            :ensure_space_features_groups,
            :place_cell_group,
            :default_storey_name,
            :tag_cell_space_storey,
            :resolve_cell_space_storey,
            :fixed_state_height_offset,
            :recenter_cell_space_geometry,
            :name_cell_space_entity,
            :apply_cell_space_material,
            :create_duality_state,
            :register_cell_space
          ], calls
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
              geometry_preparer: callbacks.fetch(:prepare_cell_space_source_group!),
              tag_storey_resolver: callbacks.fetch(:tag_cell_space_storey),
              storey_resolver: callbacks.fetch(:resolve_cell_space_storey),
              storey_value_resolver: callbacks.fetch(:resolve_cell_space_storey_value)
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

        def lifecycle_callbacks(calls, placed_group: Object.new, state: Object.new, **)
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
            tag_cell_space_storey: proc { |_group| calls << :tag_cell_space_storey; nil },
            resolve_cell_space_storey: proc do |_group, _cell_type, _category_code, default_storey|
              calls << :resolve_cell_space_storey
              default_storey
            end,
            resolve_cell_space_storey_value: proc do |storey, _cell_type, _category_code, _default_storey|
              storey
            end,
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

        def tag_resolver_callbacks(calls)
          {
            tag_cell_space_storey: proc do |group|
              calls << :tag_cell_space_storey
              TagCellSpaceAdapter.storey_from_tag(group)
            end,
            resolve_cell_space_type_and_category: proc do |group, cell_type, category_code|
              calls << :resolve_cell_space_type_and_category
              TagCellSpaceAdapter.resolve_cell_space_type_and_category(group, cell_type, category_code)
            end,
            resolve_cell_space_storey: proc do |group, cell_type, category_code, default_storey|
              calls << :resolve_cell_space_storey
              TagCellSpaceAdapter.resolve_cell_space_storey(group, cell_type, category_code, default_storey)
            end,
            resolve_cell_space_storey_value: proc do |storey, cell_type, category_code, default_storey|
              TagCellSpaceAdapter.resolve_cell_space_storey_value(storey, cell_type, category_code, default_storey)
            end
          }
        end

        def fake_tagged_group(tag_name)
          Struct.new(:layer).new(Struct.new(:name).new(tag_name))
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

            def navigable?
              true
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
