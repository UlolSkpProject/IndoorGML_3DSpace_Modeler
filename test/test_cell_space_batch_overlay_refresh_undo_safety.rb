# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class << self
    attr_accessor :undo_safety_active_model
  end

  def self.active_model
    undo_safety_active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      class EditorSession
        attr_reader :overlay_registration_count,
                    :overlay_enabled_update_count,
                    :geometry_visibility_count,
                    :transition_invalidation_count

        def initialize
          @overlay_registration_count = 0
          @overlay_enabled_update_count = 0
          @geometry_visibility_count = 0
          @transition_invalidation_count = 0
        end

        def dual_overlay_visible?
          true
        end

        def apply_display_state
          raise 'bulk refresh must not persist display state'
        end

        def apply_current_geometry_visibility
          @geometry_visibility_count += 1
          true
        end

        def invalidate_overlay_transition_points
          @transition_invalidation_count += 1
          true
        end

        private

        def ensure_overlay_registered(_model)
          @overlay_registration_count += 1
          true
        end

        def update_overlay_enabled
          @overlay_enabled_update_count += 1
          true
        end
      end

      class IndoorModel
        attr_reader :editor_session

        def initialize(model:, editor_session:, fail_conversion: false)
          @model = model
          @editor_session = editor_session
          @fail_conversion = fail_conversion
        end

        def with_bulk_cell_space_conversion
          raise 'conversion failed' if @fail_conversion

          :converted
        end

        def guard_active?(_flag)
          false
        end
      end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/cell_space_batch_overlay_refresh'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceBatchOverlayRefreshUndoSafetyTest < Minitest::Test
        class FakeView
          attr_reader :invalidate_count

          def initialize
            @invalidate_count = 0
          end

          def invalidate
            @invalidate_count += 1
          end
        end

        class FakeModel
          attr_reader :active_view

          def initialize
            @active_view = FakeView.new
          end
        end

        def setup
          @model = FakeModel.new
          @session = EditorSession.new
          Sketchup.undo_safety_active_model = @model
        end

        def teardown
          Sketchup.undo_safety_active_model = nil
        end

        def test_success_refreshes_runtime_display_without_apply_display_state
          indoor_model = IndoorModel.new(model: @model, editor_session: @session)

          assert_equal :converted, indoor_model.with_bulk_cell_space_conversion
          assert_equal 1, @session.overlay_registration_count
          assert_equal 1, @session.overlay_enabled_update_count
          assert_equal 1, @session.geometry_visibility_count
          assert_equal 1, @session.transition_invalidation_count
          assert_equal 1, @model.active_view.invalidate_count
        end

        def test_failed_conversion_does_not_run_post_commit_display_refresh
          indoor_model = IndoorModel.new(
            model: @model,
            editor_session: @session,
            fail_conversion: true
          )

          assert_raises(RuntimeError) do
            indoor_model.with_bulk_cell_space_conversion
          end
          assert_equal 0, @session.overlay_registration_count
          assert_equal 0, @session.overlay_enabled_update_count
          assert_equal 0, @session.geometry_visibility_count
          assert_equal 0, @session.transition_invalidation_count
          assert_equal 0, @model.active_view.invalidate_count
        end
      end
    end
  end
end
