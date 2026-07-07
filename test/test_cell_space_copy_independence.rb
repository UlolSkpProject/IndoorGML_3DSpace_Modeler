# frozen_string_literal: true

require 'minitest/autorun'

class Numeric
  def mm
    self
  end unless method_defined?(:mm)
end

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end unless const_defined?(:Point3d, false)
end

module Sketchup
  class Group; end unless const_defined?(:Group, false)
  class ComponentInstance; end unless const_defined?(:ComponentInstance, false)
  class Face; end unless const_defined?(:Face, false)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      ORIGIN = Geom::Point3d.new unless const_defined?(:ORIGIN)
    end
  end
end

require_relative '../indoor3d/utils/logger'
require_relative '../indoor3d/domain/abstract_feature'
require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/domain/cell_space_category'
require_relative '../indoor3d/domain/navigation_semantic'
require_relative '../indoor3d/domain/cell_space'
require_relative '../indoor3d/domain/state'
require_relative '../indoor3d/domain/transition'
require_relative '../indoor3d/infrastructure/persistence/attribute_serializer'
require_relative '../indoor3d/application/feature_registry'
require_relative '../indoor3d/application/indoor_model/runtime_support'
require_relative '../indoor3d/application/indoor_model/feature_lifecycle'
require_relative '../indoor3d/application/indoor_model/observer_routing'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceCopyIndependenceTest < Minitest::Test
        def test_duplicate_cell_space_copy_gets_independent_ids_and_runtime
          model = FakeIndoorModel.new
          original = model.add_registered_cell('original_cell', 'original_state')
          copy = FakeGroup.new('copy')
          write_cell_attributes(copy, id: original.id, state_id: original.duality_state.id)

          model.primal_entity_added(copy)

          copied_cell = model.registry.find_cell_space_for_entity(copy)
          refute_nil copied_cell
          refute_equal original.id, copied_cell.id
          refute_equal original.duality_state.id, copied_cell.duality_state.id
          assert_same original, model.registry.find_cell_space_by_persistent_id(original.sketchup_group_id)
          assert_equal copied_cell.id, copy.get_attribute('IndoorGml', 'id')
          assert_equal copied_cell.duality_state.id, copy.get_attribute('IndoorGml', 'duality_state_id')
          assert_equal 2, model.cell_spaces.length
          assert_empty model.deferred_messages
          assert_equal 1, copy.make_unique_count
        end

        def test_failed_copy_independence_rolls_back_runtime_and_clears_copied_attributes
          model = FakeIndoorModel.new(fail_during_sync: true)
          original = model.add_registered_cell('original_cell', 'original_state')
          copy = FakeGroup.new('copy')
          copy.set_attribute('OtherExtension', 'keep', 'yes')
          write_cell_attributes(copy, id: original.id, state_id: original.duality_state.id)

          out, = capture_io { model.primal_entity_added(copy) }

          assert_includes out, 'CellSpace copy independence failed'
          assert_equal [original], model.cell_spaces
          assert_equal [original.duality_state], model.states
          assert_empty model.transitions
          assert_empty original.duality_state.transitions
          assert_empty model.registry.adjacent_pair_keys
          assert_nil model.registry.find_cell_space_for_entity(copy)
          assert_nil copy.get_attribute('IndoorGml', 'feature')
          assert_nil copy.get_attribute('IndoorGml', 'id')
          assert_nil copy.get_attribute('IndoorGml', 'duality_state_id')
          assert_equal 'yes', copy.get_attribute('OtherExtension', 'keep')
          assert_equal 1, model.deferred_messages.length

          model.primal_entity_added(copy)

          assert_equal [original], model.cell_spaces
          assert_equal [original.duality_state], model.states
          assert_empty model.transitions
        end

        private

        def write_cell_attributes(group, id:, state_id:)
          group.set_attribute('IndoorGml', 'feature', 'CellSpace')
          group.set_attribute('IndoorGml', 'id', id)
          group.set_attribute('IndoorGml', 'duality_state_id', state_id)
          group.set_attribute('IndoorGml', 'cell_type', 'GeneralSpace')
          group.set_attribute('IndoorGml', 'category_code', 'Room')
          group.set_attribute('IndoorGml', 'storey', 'F01')
        end

        class FakeIndoorModel
          include IndoorModel::RuntimeSupport
          include IndoorModel::FeatureLifecycle
          include IndoorModel::ObserverRouting

          attr_reader :cell_spaces, :states, :transitions, :registry, :deferred_messages

          def initialize(fail_during_sync: false)
            @feature_registry = FeatureRegistry.new
            @registry = @feature_registry
            bind_registry_collections
            @attribute_serializer = AttributeSerializer.new
            @scene_group_guard = FakeSceneGroupGuard.new
            @cell_space_observer = Object.new
            @cell_space_observed_ids = {}
            @space_features_observed_ids = {}
            @entities_observed_ids = {}
            @cell_space_change_snapshots = {}
            @space_features_change_snapshots = {}
            @dirty_cell_space_pids = {}
            @cell_space_sync_scheduled = false
            @syncing = false
            @erasing = false
            @relocating_entity = false
            @bulk_cell_space_conversion = false
            @transaction_reconciliation = false
            @transaction_replay_pending = false
            @constraining_space_features = false
            @finishing_editing = false
            @adjacency_service = FakeAdjacencyService.new(@feature_registry, fail_during_sync: fail_during_sync)
            @deferred_messages = []
          end

          def add_registered_cell(id, state_id)
            group = FakeGroup.new(id)
            group.set_attribute('IndoorGml', 'feature', 'CellSpace')
            cell_space = CellSpace.new(group, CellSpaceType::GENERAL, 'Room')
            cell_space.instance_variable_set(:@id, id)
            state = cell_space.create_duality_state(nil)
            state.instance_variable_set(:@id, state_id)
            register_cell_space(cell_space)
            register_state(state)
            cell_space
          end

          private

          def ensure_space_features_groups(**)
            true
          end

          def with_indoor_model_operation(_name, **)
            yield
          end

          def with_transparent_cell_space_operation(_name)
            yield
          end

          def apply_cell_space_material(_cell_space)
            true
          end

          def write_cell_space_attributes(cell_space)
            @attribute_serializer.write_cell_space(cell_space)
          end

          def synchronize_adjacency_and_transitions_for_cell_space(cell_space)
            @adjacency_service.synchronize_for(cell_space)
          end

          def defer_ui_message(message)
            @deferred_messages << message
          end
        end

        class FakeAdjacencyService
          def initialize(registry, fail_during_sync:)
            @registry = registry
            @fail_during_sync = fail_during_sync
          end

          def synchronize_for(cell_space)
            return unless @fail_during_sync

            original = @registry.cell_spaces.find { |candidate| candidate != cell_space }
            pair_key = cell_pair_key(cell_space, original)
            @registry.set_adjacent_pair(pair_key, cell_space, original)
            transition = Transition.new(cell_space.duality_state, original.duality_state, nil, cell1: cell_space, cell2: original)
            @registry.add_transition(transition, pair_key: pair_key)
            cell_space.duality_state.add_transition(transition)
            original.duality_state.add_transition(transition)
            raise 'forced sync failure'
          end

          def cell_pair_key(cell1, cell2)
            [cell1.id, cell2.id].sort.join(':')
          end
        end

        class FakeSceneGroupGuard
          def initialize
            @tracking = {}
          end

          def track(group, name)
            @tracking[group.persistent_id] = name
          end

          def snapshot
            @tracking.dup
          end

          def restore!(snapshot)
            @tracking = Hash(snapshot).dup
          end
        end

        class FakeAttributeDictionary
          def initialize(values)
            @values = values
          end

          def each_pair(&block)
            @values.each_pair(&block)
          end
        end

        class FakeEntities
          def grep(_klass)
            []
          end
        end

        class FakeTransformation
          def to_a
            Array.new(16, 0.0)
          end
        end

        class FakeGroup < Sketchup::Group
          attr_accessor :name, :material
          attr_reader :persistent_id, :entityID, :entities, :make_unique_count

          @@next_id = 10_000

          def initialize(name)
            @name = name
            @persistent_id = (@@next_id += 1)
            @entityID = (@@next_id += 1)
            @entities = FakeEntities.new
            @attributes = {}
            @valid = true
            @make_unique_count = 0
          end

          def valid?
            @valid == true
          end

          def manifold?
            true
          end

          def transformation
            FakeTransformation.new
          end

          def make_unique
            @make_unique_count += 1
            true
          end

          def add_observer(_observer)
            true
          end

          def get_attribute(dictionary, key)
            @attributes.dig(dictionary, key)
          end

          def set_attribute(dictionary, key, value)
            @attributes[dictionary] ||= {}
            @attributes[dictionary][key] = value
          end

          def delete_attribute(dictionary, key)
            @attributes[dictionary]&.delete(key)
          end

          def attribute_dictionary(dictionary)
            values = @attributes[dictionary]
            return nil if values.nil?

            FakeAttributeDictionary.new(values)
          end
        end
      end
    end
  end
end
