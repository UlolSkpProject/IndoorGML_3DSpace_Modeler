# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session'

module Sketchup
  class << self
    attr_accessor :active_model
  end
end unless defined?(Sketchup)

class ValidationFocusReportRefreshTest < Minitest::Test
  EditorSession = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession

  class Focus
    attr_reader :ids, :rows, :restored
    attr_accessor :highlight_row_id

    def initialize
      @active = true
      @highlight_row_id = nil
      @ids = %w[old]
      @rows = [{ id: 'old-row' }]
    end

    def active?
      @active
    end

    def begin(ids)
      @ids = ids
      true
    end

    def set_focus_rows(rows)
      @rows = rows
      true
    end

    def snapshot
      { ids: @ids.dup, rows: @rows.dup, highlight_row_id: @highlight_row_id }
    end

    def restore!(snapshot)
      @ids = snapshot[:ids]
      @rows = snapshot[:rows]
      @highlight_row_id = snapshot[:highlight_row_id]
      @restored = true
    end
  end

  class Overlay
    attr_reader :clears, :invalidated_cell_ids

    def initialize
      @clears = 0
    end

    def clear_validation_geometry
      @clears += 1
      true
    end

    def invalidate_validation_geometry_cache(cell_ids:)
      @invalidated_cell_ids = cell_ids
      true
    end
  end

  Model = Struct.new(:active_path)
  Indoor = Struct.new(:model)

  def setup
    @model = Model.new(nil)
    Sketchup.active_model = @model
    @focus = Focus.new
    @overlay = Overlay.new
    @session = EditorSession.allocate
    @session.instance_variable_set(:@indoor_model, Indoor.new(@model))
    @session.instance_variable_set(:@validation_focus_controller, @focus)
    @session.instance_variable_set(:@overlay_controller, @overlay)
    @events = []
    events = @events
    @session.define_singleton_method(:cancel_validation_focus_zoom) { events << :cancel }
    @session.define_singleton_method(:apply_validation_focus_visibility) do
      events << :visibility
      true
    end
    @session.define_singleton_method(:apply_rendering_context) { |_model, _path| events << :rendering; true }
    @session.define_singleton_method(:defer_validation_focus_visibility) { events << :defer; true }
    @session.define_singleton_method(:invalidate_overlay_transition_visibility) { events << :overlay_visibility }
    @session.define_singleton_method(:selection_changed) { events << :selection }
    @session.define_singleton_method(:invalidate_view) { |_model| events << :view }
  end

  def teardown
    Sketchup.active_model = nil
  end

  def test_active_session_replaces_old_report_rows_in_place
    rows = [{ id: 'validation-error-row-0', cells: %w[new-a new-b] }]

    assert @session.refresh_validation_focus_editing(%w[cell_new-a cell_new-b], row_states: rows)

    assert_equal %w[cell_new-a cell_new-b], @focus.ids
    assert_equal rows, @focus.rows
    assert_equal 1, @overlay.clears
    assert_equal %i[cancel visibility rendering defer overlay_visibility selection view], @events
  end

  def test_failed_visibility_restores_previous_report_mapping
    @session.define_singleton_method(:apply_validation_focus_visibility) { false }

    refute @session.refresh_validation_focus_editing(
      %w[cell_new-a],
      row_states: [{ id: 'validation-error-row-0', cells: %w[new-a] }]
    )

    assert @focus.restored
    assert_equal %w[old], @focus.ids
    assert_equal [{ id: 'old-row' }], @focus.rows
  end

  def test_recheck_cache_reset_is_scoped_to_focused_cells
    assert @session.invalidate_validation_focus_geometry_cache(cell_ids: %w[A B])
    assert_equal %w[A B], @overlay.invalidated_cell_ids
  end
end
