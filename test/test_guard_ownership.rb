# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
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
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/runtime_support'
require_relative '../indoor3d/application/indoor_model/entity_relocation'
require_relative '../indoor3d/application/indoor_model/primal_normalization'
require_relative '../indoor3d/application/indoor_model/editor_control'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class GuardOwnershipTest < Minitest::Test
        def setup
          Sketchup.test_active_model = fake_model
        end

        def teardown
          Sketchup.test_active_model = nil
        end

        def test_nested_refresh_does_not_release_outer_refresh_guard
          model = FakeIndoorModel.new

          assert_equal true, model.refresh_runtime_data

          assert_equal true, model.event_value(:before_nested_refresh)
          assert_equal true, model.event_value(:after_nested_refresh)
          assert_equal false, model.guard_value(:@refreshing_runtime)
        end

        def test_reentrant_relocation_return_preserves_outer_relocation_guard
          model = FakeIndoorModel.new
          model.set_guard(:@relocating_entity, true)

          result = model.relocate_without_operation(fake_entity, Object.new, nil)

          assert_nil result
          assert_equal true, model.guard_value(:@relocating_entity)
        end

        def test_primal_normalization_preserves_existing_relocation_guard
          model = FakeIndoorModel.new
          model.primal_group = fake_primal_group([])
          model.set_guard(:@relocating_entity, true)

          model.normalize_primal

          assert_equal true, model.guard_value(:@relocating_entity)
        end

        def test_finish_editing_preserves_existing_finish_guard
          model = FakeIndoorModel.new
          model.set_guard(:@finishing_editing, true)

          assert_equal false, model.finish_editing

          assert_equal true, model.guard_value(:@finishing_editing)
        end

        def test_guard_flag_restores_previous_value_after_exception
          model = FakeIndoorModel.new
          model.set_guard(:@relocating_entity, true)

          assert_raises(RuntimeError) { model.raise_inside_guard(:@relocating_entity) }

          assert_equal true, model.guard_value(:@relocating_entity)
        end

        private

        def fake_model
          Struct.new(:active_view).new(Struct.new(:invalidate).new(proc {}))
        end

        def fake_entity
          Class.new do
            def valid?
              true
            end
          end.new
        end

        def fake_primal_group(children)
          entities = Struct.new(:items) do
            def to_a
              items
            end
          end.new(children)

          Struct.new(:entities) do
            def valid?
              true
            end
          end.new(entities)
        end

        class FakeIndoorModel
          include IndoorModel::RuntimeSupport
          include IndoorModel::EntityRelocation
          include IndoorModel::PrimalNormalization
          include IndoorModel::EditorControl

          attr_writer :primal_group

          def initialize
            @events = []
            @refreshing_runtime = false
            @relocating_entity = false
            @finishing_editing = false
            @syncing = false
            @erasing = false
            @constraining_space_features = false
            @cell_spaces = []
            @states = []
            @transitions = []
            @storeys = []
            @runtime_restorer = Struct.new(:owner) do
              def restore(model:, primal_group:); end
            end.new(self)
            @editor_session = FakeEditorSession.new
            @model = nil
            @primal_group = fake_empty_primal_group
          end

          def event_value(name)
            @events.assoc(name)&.last
          end

          def guard_value(flag)
            instance_variable_get(flag)
          end

          def set_guard(flag, value)
            instance_variable_set(flag, value)
          end

          def relocate_without_operation(entity, target_entities, target_root_group)
            relocate_indoor_entity_without_operation(entity, target_entities, target_root_group)
          end

          def normalize_primal
            normalize_primal_children_for_finish
          end

          def raise_inside_guard(flag)
            with_guard_flag(flag) { raise 'expected' }
          end

          private

          def fake_empty_primal_group
            Struct.new(:entities) do
              def valid?
                true
              end
            end.new(Struct.new(:items) do
              def to_a
                items
              end
            end.new([]))
          end

          def with_indoor_model_operation(_name, transparent: false)
            yield
          end

          def find_existing_space_features_groups
            @events << [:before_nested_refresh, guard_active?(:@refreshing_runtime)]
            refresh_runtime_data
            @events << [:after_nested_refresh, guard_active?(:@refreshing_runtime)]
          end

          def attach_existing_space_features_observers; end

          def reset_runtime_collections; end

          def ensure_default_storey; end

          def assign_default_storey_to_unassigned_cell_spaces; end

          def write_storey_attributes; end

          def recenter_runtime_cell_spaces; end

          def rebuild_runtime_transitions_from_cell_adjacency; end

          def invalidate_overlay_transition_points; end

          def apply_indoor_lock_policy; end

          def lock_indoor_entity(_entity); end

          def unlock_indoor_entity(_entity); end

          def cell_space_entity?(_entity)
            false
          end

          def copy_entity_to_entities(_entity, _target_entities, _target_root_group)
            Object.new
          end

          def indoor_feature(_entity)
            nil
          end

          def auto_convert_tagged_primal_entity(_entity)
            false
          end

          def move_raw_primal_entities_to_root(_entities); end

          class FakeEditorSession
            def apply_display_state; end

            def validation_focus_active?
              false
            end

            def finish
              false
            end
          end
        end
      end
    end
  end
end
