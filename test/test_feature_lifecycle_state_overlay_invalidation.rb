# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel; end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/feature_lifecycle'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class FeatureLifecycleStateOverlayInvalidationTest < Minitest::Test
        def test_register_state_invalidates_overlay_cache
          model = FakeIndoorModel.new
          state = Object.new

          model.register_state_for_test(state)

          assert_equal [state], model.registry.states
          assert_equal 1, model.overlay_invalidations
        end

        def test_unregister_state_invalidates_overlay_cache
          model = FakeIndoorModel.new
          state = Object.new
          model.registry.add_state(state)

          model.unregister_state_for_test(state)

          assert_empty model.registry.states
          assert_equal 1, model.overlay_invalidations
        end

        class FakeIndoorModel
          include IndoorModel::FeatureLifecycle

          attr_reader :registry, :overlay_invalidations

          def initialize
            @registry = FakeRegistry.new
            @feature_registry = @registry
            @overlay_invalidations = 0
          end

          def register_state_for_test(state)
            register_state(state)
          end

          def unregister_state_for_test(state)
            unregister_state(state)
          end

          def invalidate_overlay_transition_points
            @overlay_invalidations += 1
          end
        end

        class FakeRegistry
          attr_reader :states

          def initialize
            @states = []
          end

          def add_state(state)
            @states << state unless @states.include?(state)
          end

          def remove_state(state)
            @states.delete(state)
          end
        end
      end
    end
  end
end
