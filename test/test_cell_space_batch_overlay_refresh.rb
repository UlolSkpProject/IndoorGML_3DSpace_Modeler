# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel; end unless const_defined?(:IndoorModel, false)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/cell_space_batch_overlay_refresh'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceBatchOverlayRefreshTest < Minitest::Test
        class FakeView
          attr_reader :invalidations

          def initialize
            @invalidations = 0
          end

          def invalidate
            @invalidations += 1
          end
        end

        class FakeSketchupModel
          attr_reader :active_view

          def initialize
            @active_view = FakeView.new
          end
        end

        class FakeSession
          attr_reader :events

          def initialize(events, fail_display: false)
            @events = events
            @fail_display = fail_display
          end

          def refresh_display_state_after_bulk_conversion
            raise 'forced display failure' if @fail_display

            @events << :refresh_display_state
          end

          def invalidate_overlay_transition_points
            @events << :invalidate_overlay_cache
          end
        end

        module BaseBulkConversion
          private

          def with_bulk_cell_space_conversion
            with_guard_flag(:@bulk_cell_space_conversion) do
              @events << :conversion
              yield
            end
          end
        end

        class FakeIndoorModel
          include BaseBulkConversion
          prepend IndoorModel::CellSpaceBatchOverlayRefresh

          attr_reader :events, :model

          def initialize(fail_display: false)
            @events = []
            @model = FakeSketchupModel.new
            @editor_session = FakeSession.new(@events, fail_display: fail_display)

            # The production module is prepended, so a regular class method with
            # the same name cannot override it. Stub the receiver itself to keep
            # this test isolated when it runs inside a real SketchUp process.
            define_singleton_method(:active_sketchup_model) { @model }
          end

          private

          def guard_active?(flag)
            instance_variable_get(flag) == true
          end

          def with_guard_flag(flag)
            previous = instance_variable_get(flag)
            instance_variable_set(flag, true)
            yield
          ensure
            instance_variable_set(flag, previous)
          end
        end

        def test_successful_outermost_batch_refreshes_then_invalidates_overlay_once
          model = FakeIndoorModel.new

          result = model.send(:with_bulk_cell_space_conversion) do
            model.events << :body
            :result
          end

          assert_equal :result, result
          assert_equal [
            :conversion,
            :body,
            :refresh_display_state,
            :invalidate_overlay_cache
          ], model.events
          assert_equal 1, model.model.active_view.invalidations
        end

        def test_nested_batch_refreshes_only_after_outermost_batch
          model = FakeIndoorModel.new

          model.send(:with_bulk_cell_space_conversion) do
            model.send(:with_bulk_cell_space_conversion) do
              model.events << :nested_body
            end
          end

          assert_equal 1, model.events.count(:refresh_display_state)
          assert_equal 1, model.events.count(:invalidate_overlay_cache)
          assert_equal 1, model.model.active_view.invalidations
        end

        def test_overlay_refresh_failure_does_not_replace_successful_batch_result
          model = FakeIndoorModel.new(fail_display: true)

          result = model.send(:with_bulk_cell_space_conversion) { :result }

          assert_equal :result, result
          assert_equal 0, model.model.active_view.invalidations
        end

        def test_failed_batch_does_not_run_success_refresh
          model = FakeIndoorModel.new

          assert_raises(RuntimeError) do
            model.send(:with_bulk_cell_space_conversion) { raise 'conversion failed' }
          end

          refute_includes model.events, :refresh_display_state
          refute_includes model.events, :invalidate_overlay_cache
          assert_equal 0, model.model.active_view.invalidations
        end
      end
    end
  end
end
