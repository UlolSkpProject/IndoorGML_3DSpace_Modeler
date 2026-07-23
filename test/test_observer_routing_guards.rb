# frozen_string_literal: true

require 'minitest/autorun'

class Numeric
  def mm
    self
  end unless method_defined?(:mm)
end

module Sketchup
  def self.active_model
    nil
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end

    module Utils
      module Transformation
      end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/scene_groups'
require_relative '../indoor3d/application/indoor_model/observer_routing'
require_relative '../indoor3d/application/indoor_model/runtime_support'
require_relative '../indoor3d/application/indoor_model/feature_lifecycle'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ObserverRoutingGuardsTest < Minitest::Test
        def test_sync_guard_suppresses_entity_added_and_removed_routes
          model = FakeIndoorModel.new(syncing: true)

          model.root_entity_added(FakeEntity.new)
          model.primal_entity_added(FakeEntity.new)
          model.primal_entity_removed(123)

          assert_empty model.calls
        end

        def test_bulk_guard_suppresses_entity_added_routes
          model = FakeIndoorModel.new(bulk: true)

          model.root_entity_added(FakeEntity.new)
          model.primal_entity_added(FakeEntity.new)

          assert_empty model.calls
        end

        def test_primal_merge_guard_suppresses_temporary_entity_routes
          model = FakeIndoorModel.new(merging: true)

          model.root_entity_added(FakeEntity.new)
          model.primal_entity_added(FakeEntity.new)
          model.primal_entity_removed(123)

          assert_empty model.calls
        end

        def test_reconciliation_guard_suppresses_space_features_changes
          model = FakeIndoorModel.new(reconciling: true)

          result = model.space_features_changed(FakeEntity.new)

          assert_equal false, result
          assert_empty model.calls
        end

        def test_replay_pending_suppresses_entity_routes
          model = FakeIndoorModel.new(replay_pending: true)

          assert_equal false, model.space_features_changed(FakeEntity.new)
          model.root_entity_added(FakeEntity.new)
          model.primal_entity_added(FakeEntity.new)
          model.primal_entity_removed(123)

          assert_empty model.calls
        end

        def test_suppressed_observer_context_does_not_start_nested_operation
          model = FakeOperationModel.new(syncing: true)

          result = model.run_operation

          assert_equal :ran, result
          assert_equal 0, model.sketchup_model.start_count
          assert_equal 0, model.sketchup_model.commit_count
        end

        def test_replay_pending_suppresses_cell_space_lifecycle_observer_routes
          model = FakeLifecycleModel.new(replay_pending: true)

          assert_equal false, model.cell_space_changed(FakeEntity.new)
          model.cell_space_closed(FakeEntity.new)
          model.cell_space_erased(FakeEntity.new)

          assert_empty model.calls
        end

        def test_primal_group_erase_clears_runtime_dual_graph_and_focus_state
          primal_group = FakeEntity.new
          model = FakePrimalEraseModel.new(primal_group)

          assert model.space_features_erased(primal_group)

          assert_nil model.primal_group
          assert_equal 1, model.runtime_reset_count
          assert_empty model.cell_space_observed_ids
          assert_empty model.cell_space_change_snapshots
          assert_equal 1, model.primal_tracking_clear_count
          assert_equal 1, model.root_tracking_clear_count
          assert_equal 1, model.focus_clear_count
          assert_equal 1, model.overlay_invalidation_count
          assert_equal [[:untrack, primal_group], [:restore, {}]], model.scene_guard_calls
        end

        def test_non_primal_space_feature_erase_does_not_clear_runtime
          primal_group = FakeEntity.new
          other_group = FakeEntity.new
          model = FakePrimalEraseModel.new(primal_group)

          assert model.space_features_erased(other_group)

          assert_equal primal_group, model.primal_group
          assert_equal 0, model.runtime_reset_count
          assert_equal [[:untrack, other_group]], model.scene_guard_calls
        end

        def test_root_entity_removal_fallback_clears_primal_runtime_once
          primal_group = FakeEntity.new(101)
          model = FakePrimalEraseModel.new(primal_group)

          assert model.root_entity_removed(101)
          refute model.root_entity_removed(101)

          assert_nil model.primal_group
          assert_equal 1, model.runtime_reset_count
          assert_equal 1, model.overlay_invalidation_count
        end

        def test_transform_change_marks_dirty_without_transparent_operation
          model = FakeLifecycleModel.new
          cell_space = FakeCellSpace.new(FakeEntity.new)

          assert_equal true, model.run_transform_changed(cell_space)

          assert_equal [:sync, :dirty, :snapshot], model.calls
        end

        def test_scaled_cell_space_transform_is_baked_before_dirty_sync
          with_transformation_scale_stubs do
            model = FakeLifecycleModel.new
            group = FakeScaledCellGroup.new(model.calls)
            cell_space = FakeCellSpace.new(group)

            assert_equal true, model.run_transform_changed(cell_space)

            assert_equal [
              [:operation, 'IndoorGML Normalize CellSpace Scale'],
              :sync,
              :make_unique,
              [:set_transform, :unscaled],
              [:transform_entities, :bake, [:face]],
              :sync,
              :dirty,
              :snapshot
            ], model.calls
            assert_equal :unscaled, group.transformation
          end
        end

        def test_scaled_room_cell_space_is_recentered_after_scale_bake
          with_transformation_scale_stubs do
            model = FakeLifecycleModel.new(fixed_height_offset: 1000)
            group = FakeScaledCellGroup.new(model.calls)
            cell_space = FakeCellSpace.new(group)

            assert_equal true, model.run_transform_changed(cell_space)

            assert_equal [
              [:operation, 'IndoorGML Normalize CellSpace Scale'],
              :sync,
              :make_unique,
              [:set_transform, :unscaled],
              [:transform_entities, :bake, [:face]],
              :recenter,
              :sync,
              :dirty,
              :snapshot
            ], model.calls
          end
        end

        def test_cell_space_scale_bake_failure_does_not_dirty_or_snapshot
          with_transformation_scale_stubs(unscaled: nil, bake: nil) do
            model = FakeLifecycleModel.new
            group = FakeScaledCellGroup.new(model.calls)
            cell_space = FakeCellSpace.new(group)

            assert_equal false, model.run_transform_changed(cell_space)

            assert_equal [
              [:operation, 'IndoorGML Normalize CellSpace Scale'],
              :sync,
              :make_unique
            ], model.calls
            assert_equal :scaled, group.transformation
          end
        end

        def test_scaled_primal_transform_is_rejected_with_unscaled_fallback
          with_transformation_scale_stubs do
            model = FakeSpaceFeatureScaleModel.new
            entity = FakeScaledSpaceFeatureGroup.new

            assert_equal true, model.reject_scale(entity)

            assert_equal [
              [:operation, 'IndoorGML Reject Primal Scale'],
              [:guard, :@constraining_space_features],
              [:set_transform, :unscaled],
              :invalidate,
              :snapshot
            ], model.calls
            assert_equal :unscaled, entity.transformation
          end
        end

        def test_first_scaled_primal_change_without_snapshot_is_rejected
          with_transformation_scale_stubs do
            model = FakeInitialScaledSpaceFeatureModel.new
            entity = FakeInitialScaledSpaceFeatureGroup.new

            assert_equal true, model.space_features_changed(entity)

            assert_equal [
              [:operation, 'IndoorGML Reject Primal Scale'],
              [:guard, :@constraining_space_features],
              [:set_transform, :unscaled],
              :invalidate,
              :snapshot
            ], model.calls
            assert_equal :unscaled, entity.transformation
          end
        end

        def test_attach_space_features_observer_normalizes_scaled_primal_before_snapshot
          with_transformation_scale_stubs do
            model = FakeSpaceFeatureAttachModel.new
            entity = FakeObservedSpaceFeatureGroup.new(model.calls)

            model.attach(entity)

            assert_equal [
              [:track, 'IndoorGML_PrimalSpaceFeatures'],
              [:operation, 'IndoorGML Reject Primal Scale', true],
              [:guard, :@constraining_space_features],
              [:set_transform, :unscaled],
              :invalidate,
              :snapshot,
              :snapshot,
              :add_observer
            ], model.calls
            assert_equal :unscaled, entity.transformation
          end
        end

        def with_transformation_scale_stubs(unscaled: :unscaled, bake: :bake)
          transformation = ULOL::Indoor3DGmlModeler::Utils::Transformation
          originals = capture_transformation_methods(transformation, :scaled?, :unscaled, :scale_bake_transform)
          transformation.define_singleton_method(:scaled?) { |value| value == :scaled }
          transformation.define_singleton_method(:unscaled) { |value| value == :scaled ? unscaled : nil }
          transformation.define_singleton_method(:scale_bake_transform) { |value| value == :scaled ? bake : nil }
          yield
        ensure
          restore_transformation_methods(transformation, originals)
        end

        def capture_transformation_methods(transformation, *names)
          names.each_with_object({}) do |name, memo|
            memo[name] = transformation.respond_to?(name) ? transformation.method(name) : nil
          end
        end

        def restore_transformation_methods(transformation, originals)
          singleton_class = class << transformation; self; end
          originals.each do |name, original|
            if original
              transformation.define_singleton_method(name) { |*args| original.call(*args) }
            else
              singleton_class.remove_method(name) if singleton_class.method_defined?(name)
            end
          end
        end

        class FakeIndoorModel
          include IndoorModel::ObserverRouting

          attr_reader :calls

          def initialize(syncing: false, bulk: false, merging: false, reconciling: false, replay_pending: false)
            @syncing = syncing
            @bulk_cell_space_conversion = bulk
            @merging_space_features = merging
            @transaction_reconciliation = reconciling
            @transaction_replay_pending = replay_pending
            @erasing = false
            @relocating_entity = false
            @constraining_space_features = false
            @finishing_editing = false
            @calls = []
          end

          private

          def guard_active?(flag)
            instance_variable_get(flag)
          end

          def transaction_replay_pending?
            @transaction_replay_pending == true
          end

          def indoor_gml_entity?(_entity)
            @calls << :indoor_gml_entity?
            true
          end

          def classify_space_features_change(_entity)
            @calls << :classify_space_features_change
            :name
          end

          def with_indoor_model_operation(name, transparent: false)
            @calls << [:operation, name, transparent]
            yield
          end
        end

        class FakeOperationModel
          include IndoorModel::RuntimeSupport

          attr_reader :sketchup_model

          def initialize(syncing: false)
            @syncing = syncing
            @indoor_operation_depth = 0
            @sketchup_model = FakeSketchupModel.new
            @model = @sketchup_model
          end

          def run_operation
            send(:with_indoor_model_operation, 'Nested Observer Operation') { :ran }
          end

          def observer_routing_suppressed?
            @syncing == true
          end
        end

        class FakeLifecycleModel
          include IndoorModel::FeatureLifecycle

          attr_reader :calls

          def initialize(replay_pending: false, fixed_height_offset: nil)
            @transaction_replay_pending = replay_pending
            @syncing = false
            @erasing = false
            @fixed_height_offset = fixed_height_offset
            @calls = []
          end

          def run_transform_changed(cell_space)
            send(:handle_cell_space_transform_changed, cell_space)
          end

          private

          def observer_routing_suppressed?
            @transaction_replay_pending == true
          end

          def guard_active?(flag)
            instance_variable_get(flag)
          end

          def find_cell_space_for_entity(_entity)
            @calls << :find_cell_space_for_entity
            nil
          end

          def with_transparent_cell_space_operation(_name)
            @calls << [:operation, _name]
            yield
          end

          def sync
            @calls << :sync
            yield
          end

          def mark_cell_space_dirty(_cell_space)
            @calls << :dirty
          end

          def remember_cell_space_change_snapshot(_entity)
            @calls << :snapshot
          end

          def set_group_transformation(group, transformation)
            @calls << [:set_transform, transformation]
            group.transformation = transformation
          end

          def fixed_state_height_offset(_cell_space)
            @fixed_height_offset
          end

          def recenter_cell_space_origin(_cell_space)
            @calls << :recenter
          end
        end

        class FakePrimalEraseModel
          include IndoorModel::ObserverRouting

          attr_reader :primal_group, :runtime_reset_count, :cell_space_observed_ids,
                      :cell_space_change_snapshots, :primal_tracking_clear_count,
                      :root_tracking_clear_count, :focus_clear_count,
                      :overlay_invalidation_count, :scene_guard_calls

          def initialize(primal_group)
            @primal_group = primal_group
            @space_features_observed_ids = { primal_group.object_id => true }
            @cell_space_observed_ids = { 1 => true }
            @cell_space_change_snapshots = { 1 => true }
            @runtime_reset_count = 0
            @overlay_invalidation_count = 0
            @scene_guard_calls = []
            @scene_group_guard = FakeSceneGroupGuard.new(@scene_guard_calls)
            @primal_entities_observer = FakePrimalTrackingObserver.new(self)
            @root_entities_observer = FakeRootTrackingObserver.new(self)
            @editor_session = FakeValidationFocusSession.new(self)
          end

          def increment_primal_tracking_clear
            @primal_tracking_clear_count = @primal_tracking_clear_count.to_i + 1
          end

          def increment_focus_clear
            @focus_clear_count = @focus_clear_count.to_i + 1
          end

          def increment_root_tracking_clear
            @root_tracking_clear_count = @root_tracking_clear_count.to_i + 1
          end

          private

          def delete_entity_observer_key(values, entity)
            values.delete(entity.object_id)
          end

          def reset_runtime_collections
            @runtime_reset_count += 1
          end

          def invalidate_overlay_transition_points
            @overlay_invalidation_count += 1
          end
        end

        class FakeSceneGroupGuard
          def initialize(calls)
            @calls = calls
          end

          def untrack(group)
            @calls << [:untrack, group]
          end

          def restore!(snapshot)
            @calls << [:restore, snapshot]
          end
        end

        class FakePrimalTrackingObserver
          def initialize(owner)
            @owner = owner
          end

          def clear_tracked_entities
            @owner.increment_primal_tracking_clear
          end
        end

        class FakeRootTrackingObserver
          def initialize(owner)
            @owner = owner
          end

          def clear_tracked_entities
            @owner.increment_root_tracking_clear
          end
        end

        class FakeValidationFocusSession
          def initialize(owner)
            @owner = owner
          end

          def validation_focus_active?
            true
          end

          def clear_validation_focus
            @owner.increment_focus_clear
          end
        end

        class FakeSpaceFeatureScaleModel
          include IndoorModel::ObserverRouting

          attr_reader :calls

          def initialize
            @calls = []
            @space_features_scale_revert_transforms = {}
          end

          def reject_scale(entity)
            send(:reject_scaled_space_features_transform, entity)
          end

          private

          def entity_observer_key(entity)
            entity.object_id
          end

          def with_transparent_space_features_operation(name)
            @calls << [:operation, name]
            yield
          end

          def with_guard_flag(flag)
            @calls << [:guard, flag]
            yield
          end

          def set_group_transformation(group, transformation)
            @calls << [:set_transform, transformation]
            group.transformation = transformation
          end

          def invalidate_overlay_transition_points
            @calls << :invalidate
          end

          def remember_space_features_change_snapshot(_entity)
            @calls << :snapshot
          end
        end

        class FakeInitialScaledSpaceFeatureModel
          include IndoorModel::ObserverRouting

          attr_reader :calls

          def initialize
            @calls = []
            @erasing = false
            @constraining_space_features = false
            @finishing_editing = false
            @space_features_scale_revert_transforms = {}
          end

          private

          def observer_routing_suppressed?
            false
          end

          def guard_active?(flag)
            instance_variable_get(flag)
          end

          def space_features_change_snapshot_for(_entity)
            nil
          end

          def build_space_features_change_snapshot(_entity)
            {
              name: 'IndoorGML_PrimalSpaceFeatures',
              transformation: :scaled_snapshot
            }
          end

          def expected_space_features_name_for(_entity)
            'IndoorGML_PrimalSpaceFeatures'
          end

          def scaled_transform_values?(values)
            values == :scaled_snapshot
          end

          def entity_observer_key(entity)
            entity.object_id
          end

          def log_space_features_change(*); end

          def with_transparent_space_features_operation(name)
            @calls << [:operation, name]
            yield
          end

          def with_guard_flag(flag)
            @calls << [:guard, flag]
            yield
          end

          def set_group_transformation(group, transformation)
            @calls << [:set_transform, transformation]
            group.transformation = transformation
          end

          def invalidate_overlay_transition_points
            @calls << :invalidate
          end

          def remember_space_features_change_snapshot(_entity)
            @calls << :snapshot
          end
        end

        class FakeSpaceFeatureAttachModel
          include IndoorModel::SceneGroups
          include IndoorModel::ObserverRouting

          attr_reader :calls

          def initialize
            @calls = []
            @scene_group_guard = FakeSceneGroupGuard.new(calls)
            @space_features_observed_ids = {}
            @space_features_observer = Object.new
            @space_features_scale_revert_transforms = {}
          end

          def attach(entity)
            send(:attach_space_features_observer, entity, 'IndoorGML_PrimalSpaceFeatures', normalize: false)
          end

          private

          def entity_observer_key(entity)
            entity.object_id
          end

          def with_indoor_model_operation(name, transparent: false)
            @calls << [:operation, name, transparent]
            yield
          end

          def with_guard_flag(flag)
            @calls << [:guard, flag]
            yield
          end

          def set_group_transformation(group, transformation)
            @calls << [:set_transform, transformation]
            group.transformation = transformation
          end

          def invalidate_overlay_transition_points
            @calls << :invalidate
          end

          def remember_space_features_change_snapshot(_entity)
            @calls << :snapshot
          end
        end

        class FakeCellSpace
          attr_reader :sketchup_group

          def initialize(group)
            @sketchup_group = group
          end
        end

        class FakeScaledCellGroup
          attr_accessor :transformation
          attr_reader :definition

          def initialize(calls)
            @transformation = :scaled
            @calls = calls
            @definition = FakeDefinition.new(calls)
          end

          def valid?
            true
          end

          def entityID
            42
          end

          def make_unique
            @calls << :make_unique
          end
        end

        class FakeScaledSpaceFeatureGroup
          attr_accessor :transformation

          def initialize
            @transformation = :scaled
          end

          def valid?
            true
          end

          def entityID
            51
          end
        end

        class FakeInitialScaledSpaceFeatureGroup
          attr_accessor :transformation

          def initialize
            @transformation = :scaled
          end

          def valid?
            true
          end

          def entityID
            53
          end

          def name
            'IndoorGML_PrimalSpaceFeatures'
          end
        end

        class FakeObservedSpaceFeatureGroup
          attr_accessor :transformation
          attr_reader :name

          def initialize(calls)
            @calls = calls
            @transformation = :scaled
            @name = 'IndoorGML_PrimalSpaceFeatures'
          end

          def valid?
            true
          end

          def entityID
            52
          end

          def add_observer(_observer)
            @calls << :add_observer
            true
          end
        end

        class FakeSceneGroupGuard
          def initialize(calls)
            @calls = calls
          end

          def track(_group, expected_name)
            @calls << [:track, expected_name]
          end
        end

        class FakeDefinition
          attr_reader :entities

          def initialize(calls)
            @entities = FakeEntities.new(calls)
          end
        end

        class FakeEntities
          def initialize(calls)
            @calls = calls
          end

          def to_a
            [:face]
          end

          def transform_entities(transform, entities)
            @calls << [:transform_entities, transform, entities]
          end
        end

        class FakeSketchupModel
          attr_reader :start_count, :commit_count, :abort_count

          def initialize
            @start_count = 0
            @commit_count = 0
            @abort_count = 0
          end

          def start_operation(*)
            @start_count += 1
            true
          end

          def commit_operation
            @commit_count += 1
            true
          end

          def abort_operation
            @abort_count += 1
            true
          end
        end

        class FakeEntity
          attr_reader :entityID

          def initialize(entity_id = nil)
            @entityID = entity_id || object_id
          end

          def valid?
            true
          end
        end
      end
    end
  end
end
