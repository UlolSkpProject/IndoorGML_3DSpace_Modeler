# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/application/cell_space_lifecycle_service'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceBatchPersistencePolicyTest < Minitest::Test
        class FakeSourcePreparer
          def converted?(_group)
            false
          end

          def resolve_type_and_category(_group, cell_type, category_code)
            [cell_type, category_code]
          end

          def prepare!(_group)
            { valid: true }
          end

          def resolve_storey(_group, _cell_type, _category_code, _default_storey, storey)
            storey || 'F01'
          end
        end

        class FakeCellSpace
          attr_reader :sketchup_group, :cell_type, :category_code, :state

          def initialize(group, cell_type, category_code)
            @sketchup_group = group
            @cell_type = cell_type
            @category_code = category_code
          end

          def create_duality_state(_position)
            @state = Object.new
          end
        end

        class RecordingContext
          attr_reader :register_options

          def prepare_cell_group(group)
            group
          end

          def default_storey_name
            'F01'
          end

          def initialize_scene(_cell_space, storey:)
            @storey = storey
          end

          def register_created(_cell_space, _state, **options)
            @register_options = options
          end
        end

        def test_existing_deferred_create_keeps_eager_persistence_contract
          context = RecordingContext.new
          service = build_service(context)

          service.create_from_group_deferred(
            Object.new,
            cell_type: CellSpaceType::GENERAL,
            category_code: 'Room',
            storey: 'F02'
          )

          assert_equal false, context.register_options[:synchronize_adjacency]
          assert_equal false, context.register_options[:apply_lock_policy]
          assert_equal true, context.register_options[:persist_attributes]
        end

        def test_batch_deferred_create_defers_only_attribute_persistence
          context = RecordingContext.new
          service = build_service(context)

          service.create_from_group_batch_deferred(
            Object.new,
            cell_type: CellSpaceType::GENERAL,
            category_code: 'Room',
            storey: 'F02'
          )

          assert_equal false, context.register_options[:synchronize_adjacency]
          assert_equal false, context.register_options[:apply_lock_policy]
          assert_equal false, context.register_options[:persist_attributes]
        end

        def test_lifecycle_context_skips_write_but_keeps_registration_and_tracking
          calls = []
          context = build_real_context(calls)
          cell_space = Struct.new(:sketchup_group).new(Object.new)
          state = Object.new

          context.register_created(
            cell_space,
            state,
            synchronize_adjacency: false,
            apply_lock_policy: false,
            persist_attributes: false
          )

          assert_equal [
            :register_cell_space,
            :register_state,
            :track_cell_space_entity
          ], calls
        end

        def test_lifecycle_context_default_still_writes_attributes
          calls = []
          context = build_real_context(calls)
          cell_space = Struct.new(:sketchup_group).new(Object.new)
          state = Object.new

          context.register_created(
            cell_space,
            state,
            synchronize_adjacency: false,
            apply_lock_policy: false
          )

          assert_equal [
            :register_cell_space,
            :register_state,
            :write_attributes,
            :track_cell_space_entity
          ], calls
        end

        private

        def build_service(context)
          CellSpaceLifecycleService.new(
            source_preparer: FakeSourcePreparer.new,
            context: context,
            cell_space_class: FakeCellSpace
          )
        end

        def build_real_context(calls)
          CellSpaceLifecycleContext.new(
            ensure_space_features_groups: proc {},
            place_cell_group: proc { |group| group },
            default_storey_name: proc { 'F01' },
            fixed_state_height_offset: proc { 0.0 },
            recenter_cell_space_geometry: proc {},
            name_cell_space_entity: proc {},
            apply_cell_space_material: proc {},
            track_cell_space_entity: proc { |_group| calls << :track_cell_space_entity },
            apply_indoor_lock_policy: proc { calls << :apply_indoor_lock_policy },
            register_cell_space: proc { |_cell_space| calls << :register_cell_space; true },
            register_state: proc { |_state| calls << :register_state },
            unregister_cell_space: proc {},
            unregister_state: proc {},
            write_attributes: proc { |_cell_space| calls << :write_attributes },
            write_cell_space_attributes: proc {},
            synchronize_adjacency_and_transitions_for_cell_space: proc { calls << :synchronize_adjacency },
            erase_transitions_for_state: proc {},
            erase_adjacency_for_cell_space: proc {}
          )
        end
      end
    end
  end
end
