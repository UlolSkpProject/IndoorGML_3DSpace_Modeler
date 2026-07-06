# frozen_string_literal: true

require 'minitest/autorun'

class Numeric
  def mm
    self
  end unless method_defined?(:mm)
end

module Geom
  unless const_defined?(:Point3d, false)
    class Point3d
      attr_reader :x, :y, :z

      def initialize(x = 0.0, y = 0.0, z = 0.0)
        @x = x.to_f
        @y = y.to_f
        @z = z.to_f
      end

      def distance(other)
        Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
      end
    end
  end

  unless const_defined?(:Vector3d, false)
    class Vector3d
      attr_reader :x, :y, :z

      def initialize(x = 0.0, y = 0.0, z = 0.0)
        @x = x.to_f
        @y = y.to_f
        @z = z.to_f
      end

      def length
        Math.sqrt(x**2 + y**2 + z**2)
      end

      def normalize!
        len = length
        return self if len <= 0.0

        @x /= len
        @y /= len
        @z /= len
        self
      end
    end
  end
end

module Sketchup
  class Group; end unless const_defined?(:Group, false)
  class ComponentInstance; end unless const_defined?(:ComponentInstance, false)

  class << self
    attr_accessor :test_active_model
  end

  def self.active_model
    @test_active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      ORIGIN = Object.new unless const_defined?(:ORIGIN)

      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/domain/abstract_feature'
require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/domain/cell_space_category'
require_relative '../indoor3d/domain/navigation_semantic'
require_relative '../indoor3d/domain/cell_space'
require_relative '../indoor3d/domain/state'
require_relative '../indoor3d/domain/transition'
require_relative '../indoor3d/infrastructure/persistence/attribute_serializer'
require_relative '../indoor3d/infrastructure/persistence/runtime_restorer'
require_relative '../indoor3d/infrastructure/scene/scene_group_guard'
require_relative '../indoor3d/application/feature_registry'
require_relative '../indoor3d/application/indoor_model/topology'
require_relative '../indoor3d/application/indoor_model/runtime_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures' unless const_defined?(:PRIMAL_GROUP_NAME, false)
        PRIMAL_GROUP_FEATURE = 'primalspace' unless const_defined?(:PRIMAL_GROUP_FEATURE, false)
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml' unless const_defined?(:ATTRIBUTE_DICTIONARY_NAME, false)
      end

      class RuntimeReconciliationTest < Minitest::Test
        def setup
          @model = FakeSketchupModel.new
          Sketchup.test_active_model = @model
        end

        def teardown
          Sketchup.test_active_model = nil
        end

        def test_undo_state_reconciliation_clears_runtime_when_primal_is_missing
          indoor = FakeIndoorModel.new(@model)
          primal = @model.create_primal_group
          cell_group = primal.entities.add_group('redo_cell')
          write_cell_attributes(cell_group, id: 'cell_undo', state_id: 'state_undo')
          indoor.reconcile_runtime_after_transaction(source: :redo, generation: 1)
          assert_equal 1, indoor.cell_spaces.length

          @model.entities.delete(primal)
          indoor.queue_dirty(123)
          indoor.reconcile_runtime_after_transaction(source: :undo, generation: 2)

          assert_nil indoor.primal_group
          assert_empty indoor.cell_spaces
          assert_empty indoor.states
          assert_empty indoor.transitions
          assert_empty indoor.dirty_pids
          assert_empty indoor.cell_observer_keys
        end

        def test_redo_state_reconciliation_restores_cell_space_and_state_from_attributes
          indoor = FakeIndoorModel.new(@model)
          primal = @model.create_primal_group
          cell_group = primal.entities.add_group('redo_cell')
          write_cell_attributes(cell_group, id: 'cell_redo', state_id: 'state_redo')

          indoor.reconcile_runtime_after_transaction(source: :redo, generation: 1)

          assert_equal 1, indoor.cell_spaces.length
          assert_equal 1, indoor.states.length
          cell_space = indoor.cell_spaces.first
          state = indoor.states.first
          assert_equal 'cell_redo', cell_space.id
          assert_equal 'state_redo', state.id
          assert_same state, cell_space.duality_state
          assert_same cell_space, state.duality_cell
          assert_same cell_space, indoor.registry.find_cell_space_for_entity(cell_group)
          assert_equal [cell_group.object_id], indoor.cell_observer_keys
        end

        def test_transition_runtime_is_rebuilt_without_attribute_writes
          indoor = FakeIndoorModel.new(@model, adjacent: true)
          primal = @model.create_primal_group
          cell_a = primal.entities.add_group('cell_a')
          cell_b = primal.entities.add_group('cell_b')
          write_cell_attributes(cell_a, id: 'cell_a', state_id: 'state_a')
          write_cell_attributes(cell_b, id: 'cell_b', state_id: 'state_b')

          indoor.reconcile_runtime_after_transaction(source: :redo, generation: 1)

          assert_equal 1, indoor.transitions.length
          transition = indoor.transitions.first
          assert transition.valid?
          assert_includes indoor.states[0].transitions, transition
          assert_includes indoor.states[1].transitions, transition
          assert_same transition, indoor.registry.transition_for_pair('cell_a:cell_b')
          assert_equal 0, indoor.serializer.write_count
          assert_equal 0, indoor.operation_count
          assert_equal 0, indoor.recenter_count
        end

        def test_non_adjacent_cells_do_not_create_transition
          indoor = FakeIndoorModel.new(@model, adjacent: false)
          primal = @model.create_primal_group
          cell_a = primal.entities.add_group('cell_a')
          cell_b = primal.entities.add_group('cell_b')
          write_cell_attributes(cell_a, id: 'cell_a', state_id: 'state_a')
          write_cell_attributes(cell_b, id: 'cell_b', state_id: 'state_b')

          indoor.reconcile_runtime_after_transaction(source: :redo, generation: 1)

          assert_empty indoor.transitions
          assert_empty indoor.states.flat_map(&:transitions)
        end

        def test_repeated_reconciliation_does_not_duplicate_runtime_or_observers
          indoor = FakeIndoorModel.new(@model)
          primal = @model.create_primal_group
          cell_group = primal.entities.add_group('redo_cell')
          write_cell_attributes(cell_group, id: 'cell_redo', state_id: 'state_redo')

          indoor.reconcile_runtime_after_transaction(source: :redo, generation: 1)
          indoor.reconcile_runtime_after_transaction(source: :redo, generation: 2)

          assert_equal 1, indoor.cell_spaces.length
          assert_equal 1, indoor.states.length
          assert_empty indoor.transitions
          assert_equal 1, cell_group.observer_count
          assert_equal [cell_group.object_id], indoor.cell_observer_keys
        end

        def test_reconciliation_notifies_editor_session_without_refresh_writes
          editor_session = FakeEditorSession.new
          indoor = FakeIndoorModel.new(@model, editor_session: editor_session)
          primal = @model.create_primal_group
          cell_group = primal.entities.add_group('redo_cell')
          write_cell_attributes(cell_group, id: 'cell_redo', state_id: 'state_redo')

          metrics = indoor.reconcile_runtime_after_transaction(source: :redo, generation: 7)

          assert_equal [[:redo]], editor_session.reconciliations
          assert_equal 1, metrics[:cell_spaces]
          assert_equal 1, metrics[:states]
          assert_equal 0, indoor.serializer.write_count
          assert_equal 0, indoor.operation_count
          assert_equal 0, indoor.recenter_count
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
          include IndoorModel::Topology

          attr_reader :cell_spaces, :states, :transitions, :primal_group, :serializer, :operation_count, :recenter_count

          def initialize(model, adjacent: false, editor_session: FakeEditorSession.new)
            @model = model
            @feature_registry = FeatureRegistry.new
            @cell_space_change_snapshots = {}
            @space_features_change_snapshots = {}
            @dirty_cell_space_pids = {}
            @cell_space_sync_scheduled = false
            @cell_space_observed_ids = {}
            @space_features_observed_ids = {}
            @entities_observed_ids = {}
            @syncing = false
            @erasing = false
            @transaction_reconciliation = false
            @primal_group = nil
            @serializer = SpySerializer.new
            @attribute_serializer = @serializer
            @adjacency_service = FakeAdjacencyService.new(adjacent: adjacent)
            @runtime_restorer = RuntimeRestorer.new(
              registry: @feature_registry,
              serializer: @attribute_serializer,
              cell_space_registrar: method(:register_cell_space),
              state_registrar: method(:register_state)
            )
            @scene_group_guard = SceneGroupGuard.new(with_unlocked: proc { |_group, &block| block.call })
            @editor_session = editor_session
            @operation_count = 0
            @recenter_count = 0
            bind_registry_collections
          end

          def registry
            @feature_registry
          end

          def queue_dirty(pid)
            @dirty_cell_space_pids[pid] = true
          end

          def dirty_pids
            @dirty_cell_space_pids.keys
          end

          def cell_observer_keys
            @cell_space_observed_ids.keys
          end

          private

          def find_existing_space_features_groups
            @primal_group = @model.primal_group
          end

          def attach_existing_space_features_observers
            attach_entities_observer(:root, @model.entities, Object.new)
            return unless @primal_group&.valid?

            @scene_group_guard.track(@primal_group, IndoorModel::PRIMAL_GROUP_NAME)
            attach_entity_observer(@primal_group, Object.new, @space_features_observed_ids)
            attach_entities_observer(:primal, @primal_group.entities, Object.new)
          end

          def register_cell_space(cell_space)
            @feature_registry.add_cell_space(cell_space)
            attach_entity_observer(cell_space.sketchup_group, Object.new, @cell_space_observed_ids)
            @scene_group_guard.track(cell_space.sketchup_group, cell_space.sketchup_group.name)
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
          end

          def register_state(state)
            @feature_registry.add_state(state)
          end

          def attach_entity_observer(entity, observer, observed_ids)
            return unless entity&.valid?

            key = entity_observer_key(entity)
            return if observed_ids[key]

            entity.add_observer(observer)
            observed_ids[key] = true
          end

          def attach_entities_observer(scope, entities, _observer)
            key = [scope, entities.object_id]
            @entities_observed_ids[key] = true
          end

          def remember_cell_space_change_snapshot(entity, snapshot = nil)
            @cell_space_change_snapshots[entity_observer_key(entity)] = snapshot || {}
          end

          def update_transition(_transition)
            true
          end

          def with_indoor_model_operation(_name, transparent: false)
            transparent
            @operation_count += 1
            yield
          end

          def write_cell_space_attributes(cell_space)
            @serializer.write_cell_space(cell_space)
          end

          def write_state_attributes(state)
            @serializer.write_state(state)
          end

          def write_transition_attributes(transition)
            @serializer.write_transition(transition)
          end

          def recenter_runtime_cell_spaces
            @recenter_count += 1
          end
        end

        class FakeAdjacencyService
          attr_reader :last_metrics

          def initialize(adjacent:)
            @adjacent = adjacent
            @last_metrics = {}
          end

          def synchronize_all(transition_builder: nil, transition_eraser: nil)
            transition_eraser
            cells = @registry&.cell_spaces || []
            if @adjacent && cells.length >= 2
              transition_builder.call(cells[0], cells[1])
              @registry.set_adjacent_pair(cell_pair_key(cells[0], cells[1]), cells[0], cells[1])
            end
            @last_metrics = { pair_comparison_count: cells.length >= 2 ? 1 : 0, total_duration: 0.0 }
          end

          def cell_pair_key(cell1, cell2)
            [cell1.id, cell2.id].sort.join(':')
          end

          def registry=(registry)
            @registry = registry
          end
        end

        class FakeIndoorModel
          alias original_initialize initialize

          def initialize(*args, **kwargs)
            original_initialize(*args, **kwargs)
            @adjacency_service.registry = @feature_registry
          end
        end

        class SpySerializer
          attr_reader :write_count

          def initialize
            @write_count = 0
          end

          def attribute(entity, key)
            entity.get_attribute('IndoorGml', key)
          end

          def feature(entity)
            attribute(entity, 'feature')
          end

          def write_cell_space(*)
            @write_count += 1
          end

          def write_state(*)
            @write_count += 1
          end

          def write_transition(*)
            @write_count += 1
          end
        end

        class FakeEditorSession
          attr_reader :reconciliations

          def initialize
            @reconciliations = []
          end

          def reconcile_after_transaction(_model, source: nil)
            @reconciliations << [source]
          end
        end

        class FakeSketchupModel
          attr_reader :entities, :active_view

          def initialize
            @entities = FakeEntities.new
            @active_view = Object.new
          end

          def primal_group
            @entities.to_a.find do |entity|
              entity.valid? && entity.get_attribute('IndoorGml', 'feature') == IndoorModel::PRIMAL_GROUP_FEATURE
            end
          end

          def create_primal_group
            group = @entities.add_group(IndoorModel::PRIMAL_GROUP_NAME)
            group.set_attribute('IndoorGml', 'feature', IndoorModel::PRIMAL_GROUP_FEATURE)
            group
          end
        end

        class FakeEntities
          def initialize
            @items = []
          end

          def add_group(name = '')
            group = FakeGroup.new(name)
            @items << group
            group
          end

          def delete(entity)
            entity.invalidate!
            @items.delete(entity)
          end

          def to_a
            @items.dup
          end

          def grep(klass)
            @items.grep(klass)
          end
        end

        class FakeGroup < Sketchup::Group
          attr_accessor :name
          attr_reader :entities, :persistent_id, :entityID

          @@next_id = 10

          def initialize(name)
            @name = name
            @entities = FakeEntities.new
            @attributes = {}
            @valid = true
            @observers = []
            @persistent_id = (@@next_id += 1)
            @entityID = (@@next_id += 1)
          end

          def valid?
            @valid == true
          end

          def invalidate!
            @valid = false
          end

          def manifold?
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

          def add_observer(observer)
            @observers << observer
            true
          end

          def observer_count
            @observers.length
          end
        end
      end
    end
  end
end
