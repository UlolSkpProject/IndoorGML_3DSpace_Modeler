# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Group
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      class IndoorModel
      end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/local_grid_runtime_dispatch_v2'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalGridEditFinishRuntimePolicyTest < Minitest::Test
        def test_clean_edit_finish_skips_full_refresh_and_incremental_flush
          model = FakeIndoorModel.new(
            model_groups: [fake_cell_group],
            runtime_cells: nil,
            dirty: false
          )
          model.install_consistent_runtime!

          assert_equal true, model.finish_editing

          assert_equal 1, model.editor_finish_calls
          assert_equal 1, model.normalize_calls
          assert_equal 0, model.soft_refresh_calls
          assert_equal 0, model.flush_calls
          assert_equal true, model.finish_guard_seen_during_normalize
          assert_equal false, model.finishing_guard_active?
        end

        def test_dirty_edit_finish_flushes_incremental_topology_without_full_refresh
          model = FakeIndoorModel.new(
            model_groups: [fake_cell_group],
            runtime_cells: nil,
            dirty: true
          )
          model.install_consistent_runtime!

          assert_equal true, model.finish_editing

          assert_equal 0, model.soft_refresh_calls
          assert_equal 1, model.flush_calls
          assert_equal true, model.dirty_queue.empty?
        end

        def test_runtime_mismatch_falls_back_to_soft_refresh_without_dirty_flush
          model = FakeIndoorModel.new(
            model_groups: [fake_cell_group],
            runtime_cells: [],
            dirty: true
          )

          assert_equal true, model.finish_editing

          assert_equal 1, model.soft_refresh_calls
          assert_equal 0, model.flush_calls
        end

        def test_failed_editor_finish_does_not_finalize_runtime
          model = FakeIndoorModel.new(
            model_groups: [fake_cell_group],
            runtime_cells: nil,
            dirty: true,
            editor_finish_result: false
          )
          model.install_consistent_runtime!

          assert_equal false, model.finish_editing

          assert_equal 1, model.editor_finish_calls
          assert_equal 0, model.normalize_calls
          assert_equal 0, model.soft_refresh_calls
          assert_equal 0, model.flush_calls
          assert_equal false, model.finishing_guard_active?
        end

        private

        def fake_cell_group
          FakeGroup.new('CellSpace')
        end

        class FakeGroup < Sketchup::Group
          attr_reader :feature

          def initialize(feature)
            @feature = feature
          end

          def valid?
            true
          end
        end

        class FakeState
          def valid?
            true
          end
        end

        class FakeCellSpace
          attr_reader :sketchup_group
          attr_reader :duality_state

          def initialize(group)
            @sketchup_group = group
            @duality_state = FakeState.new
          end

          def valid?
            true
          end
        end

        class FakePrimalGroup
          attr_reader :entities

          def initialize(entities)
            @entities = entities
          end

          def valid?
            true
          end
        end

        class FakeRegistry
          def initialize(cells)
            @cells_by_group = Array(cells).each_with_object({}) do |cell_space, index|
              index[cell_space.sketchup_group] = cell_space
            end
          end

          def find_cell_space_for_entity(group)
            @cells_by_group[group]
          end
        end

        class FakeDirtyQueue
          def initialize(dirty)
            @dirty = dirty
          end

          def empty?
            !@dirty
          end

          def clear!
            @dirty = false
          end
        end

        class FakeEditorSession
          attr_reader :finish_calls

          def initialize(result)
            @result = result
            @finish_calls = 0
          end

          def finish
            @finish_calls += 1
            @result
          end
        end

        class FakeIndoorModel < IndoorModel
          attr_reader :normalize_calls
          attr_reader :soft_refresh_calls
          attr_reader :flush_calls
          attr_reader :finish_guard_seen_during_normalize
          attr_reader :dirty_queue

          def initialize(model_groups:, runtime_cells:, dirty:, editor_finish_result: true)
            @primal_group = FakePrimalGroup.new(model_groups)
            @cell_spaces = runtime_cells || []
            @feature_registry = FakeRegistry.new(@cell_spaces)
            @dirty_queue = FakeDirtyQueue.new(dirty)
            @editor_session = FakeEditorSession.new(editor_finish_result)
            @normalize_calls = 0
            @soft_refresh_calls = 0
            @flush_calls = 0
            @finish_guard_seen_during_normalize = false
            @finishing_editing = false
          end

          def install_consistent_runtime!
            groups = @primal_group.entities.grep(Sketchup::Group).select do |group|
              indoor_feature(group) == 'CellSpace'
            end
            @cell_spaces = groups.map { |group| FakeCellSpace.new(group) }
            @feature_registry = FakeRegistry.new(@cell_spaces)
          end

          def editor_finish_calls
            @editor_session.finish_calls
          end

          def finishing_guard_active?
            @finishing_editing == true
          end

          def local_grid_coordinate_v2_enabled?
            true
          end

          def validation_focus_recheck_running?
            false
          end

          def with_guard_flag(flag)
            previous = instance_variable_get(flag)
            instance_variable_set(flag, true)
            yield
          ensure
            instance_variable_set(flag, previous)
          end

          def normalize_primal_children_for_finish
            @normalize_calls += 1
            @finish_guard_seen_during_normalize = finishing_guard_active?
            true
          end

          def soft_refresh_runtime_data_local_grid_v2
            @soft_refresh_calls += 1
            true
          end

          def flush_dirty_cell_space_sync
            @flush_calls += 1
            @dirty_queue.clear!
            true
          end

          def indoor_feature(group)
            group.feature
          end

          private

          def dirty_topology_queue
            @dirty_queue
          end
        end
      end
    end
  end
end
