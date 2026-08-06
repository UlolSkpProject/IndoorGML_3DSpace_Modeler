# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/utils/logger'
require_relative '../indoor3d/application/cell_space_lifecycle_service'
require_relative '../indoor3d/application/indoor_model/local_grid_coordinate'
require_relative '../indoor3d/application/indoor_model/local_grid_runtime_dispatch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalGridRuntimeRefreshPolicyTest < Minitest::Test
        FakeEditorSession = Struct.new(:calls) do
          def apply_display_state
            calls << :apply_display_state
          end
        end

        def test_initial_model_load_dispatches_to_hard_refresh
          model, calls = build_dispatch_model(enabled: false)
          model.define_singleton_method(:hard_refresh_runtime_data_local_grid) do |initial_model_load: false|
            calls << [:hard, initial_model_load]
            :hard
          end
          model.define_singleton_method(:soft_refresh_runtime_data_local_grid) do
            calls << :soft
            :soft
          end

          result = IndoorModel.instance_method(:refresh_runtime_data).bind(model).call(initial_model_load: true)

          assert_equal :hard, result
          assert_equal [:enable, [:hard, true]], calls
        end

        def test_enabled_generic_refresh_dispatches_to_soft_refresh
          model, calls = build_dispatch_model(enabled: true)
          model.define_singleton_method(:hard_refresh_runtime_data_local_grid) do |initial_model_load: false|
            calls << [:hard, initial_model_load]
            :hard
          end
          model.define_singleton_method(:soft_refresh_runtime_data_local_grid) do
            calls << :soft
            :soft
          end

          result = IndoorModel.instance_method(:refresh_runtime_data).bind(model).call

          assert_equal :soft, result
          assert_equal [:soft], calls
        end

        def test_generic_entrypoint_is_soft_unless_initial_load
          model, calls = build_dispatch_model(enabled: false)
          model.define_singleton_method(:hard_refresh_runtime_data_local_grid) do |initial_model_load: false|
            calls << [:hard, initial_model_load]
            :hard
          end
          model.define_singleton_method(:soft_refresh_runtime_data_local_grid) do
            calls << :soft
            :soft
          end

          result = IndoorModel.instance_method(:refresh_runtime_data_local_grid).bind(model).call

          assert_equal :soft, result
          assert_equal [:enable, :soft], calls
        end

        def test_soft_refresh_does_not_touch_coordinate_pipeline
          model = IndoorModel.allocate
          calls = []
          model.instance_variable_set(:@editor_session, FakeEditorSession.new(calls))
          model.instance_variable_set(:@cell_spaces, [])
          model.instance_variable_set(:@states, [])
          model.instance_variable_set(:@transitions, [])

          model.define_singleton_method(:enable_local_grid_coordinate!) { calls << :enable; true }
          model.define_singleton_method(:with_indoor_model_operation) { |_name, **_options, &block| block.call }
          model.define_singleton_method(:guard_active?) { |_flag| false }
          model.define_singleton_method(:with_guard_flag) { |_flag, &block| block.call }
          model.define_singleton_method(:sync) { |&block| block.call }
          model.define_singleton_method(:restore_runtime_from_current_model) do |persist_repaired_ids: false|
            calls << [:restore_runtime, persist_repaired_ids]
          end
          model.define_singleton_method(:rebuild_runtime_transitions_from_cell_adjacency) { calls << :rebuild_transitions }
          model.define_singleton_method(:invalidate_overlay_transition_points) { calls << :invalidate_overlay }
          model.define_singleton_method(:apply_indoor_lock_policy) { calls << :apply_lock }

          model.define_singleton_method(:align_cell_space_local_frame_local_grid) do |_group|
            raise 'soft refresh must not evaluate axes'
          end
          model.define_singleton_method(:normalize_cell_space_local_grid!) do |_group, **_options|
            raise 'soft refresh must not invoke LVN'
          end
          model.define_singleton_method(:recenter_cell_space_geometry_local_grid) do |_group, **_options|
            raise 'soft refresh must not recenter geometry'
          end

          result = IndoorModel.instance_method(:soft_refresh_runtime_data_local_grid).bind(model).call

          assert_equal true, result
          assert_equal [
            :enable,
            [:restore_runtime, true],
            :rebuild_transitions,
            :invalidate_overlay,
            :apply_lock,
            :apply_display_state
          ], calls
        end

        private

        def build_dispatch_model(enabled:)
          model = IndoorModel.allocate
          calls = []
          state = enabled

          model.define_singleton_method(:enable_local_grid_coordinate!) do
            calls << :enable
            state = true
            true
          end
          model.define_singleton_method(:local_grid_coordinate_enabled?) { state }

          [model, calls]
        end
      end
    end
  end
end
