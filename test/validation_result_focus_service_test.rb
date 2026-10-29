# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session/validation_result_focus_service'

module Sketchup
  class << self
    attr_accessor :active_model
  end
end unless defined?(Sketchup)

class ValidationResultFocusServiceTest < Minitest::Test
  Coordinator = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::ValidationResultFocusService

  class Model
    attr_accessor :is_valid, :active_path

    def initialize
      @is_valid = true
    end

    def valid?
      @is_valid
    end
  end

  class Indoor
    attr_accessor :model

    def initialize(model)
      @model = model
    end
  end

  class Focus
    attr_accessor :active, :highlight_row_id
    attr_reader :ids, :focus_rows, :set_count

    def initialize
      @active = true
      @ids = []
      @set_count = 0
      @focus_rows = {
        'A' => { cells: ['A'], states: [], transitions: [] },
        'B' => { cells: ['B'], states: [], transitions: [] },
        'C' => { cells: ['C'], states: [], transitions: [] }
      }
    end

    def active?
      @active
    end

    def snapshot
      { highlight_row_id: @highlight_row_id, ids: @ids.dup }
    end

    def set_highlight(ids, _code = nil, row_id: nil, **_options)
      @set_count += 1
      @ids = ids
      @highlight_row_id = row_id.to_s.empty? ? nil : row_id
      true
    end

    def restore!(snapshot)
      @highlight_row_id = snapshot[:highlight_row_id]
      @ids = snapshot[:ids].dup
    end
  end

  def setup
    @model = Model.new
    Sketchup.active_model = @model
    @indoor = Indoor.new(@model)
    @focus = Focus.new
    @calls = []
    @fail = nil
    @exception = nil
    @overlay_nil = false
    @camera_fail = false
    @context_fail = false
    @previous_paths = []
    @coordinator = Coordinator.new(
      indoor_model: @indoor,
      focus: @focus,
      cancel_async: -> { record(:cancel) },
      apply_visibility: -> { result_for(:visibility) },
      apply_rendering: -> { result_for(:rendering) },
      show_overlay: ->(row) { record(:overlay, row); @overlay_nil ? nil : { geometry: row } },
      clear_overlay: -> { record(:clear_overlay); true },
      schedule_camera: ->(row) { record(:camera, row); !@camera_fail },
      restore_camera: -> { record(:restore_camera); { ok: !@camera_fail } },
      restore_context: -> { record(:active_path); !@context_fail },
      restore_previous_context: ->(path) { @previous_paths << path; record(:restore_previous_path); true },
      refresh: -> { record(:refresh) }
    )
    assert @coordinator.begin_session(@model)[:ok]
  end

  def teardown
    Sketchup.active_model = nil
  end

  def record(name, arg = nil)
    @calls << [name, arg]
  end

  def result_for(name)
    record(name)
    raise "broken #{name}" if @exception == name

    @fail != name
  end

  def select(row)
    @coordinator.focus_row([row], '104', row_id: row, row_cells: [row], states: [], transitions: [])
  end

  def deselect
    @coordinator.focus_row([], '', row_id: '')
  end

  def test_session_starts_without_changing_scene
    assert_equal :session_active, @coordinator.state
    assert_empty @calls
    assert_nil @focus.highlight_row_id
  end

  def test_row_a_selection_orders_required_and_optional_services
    response = select('A')
    assert response[:ok]
    assert_equal :success, response[:status]
    assert_equal [:cancel, :clear_overlay, :visibility, :rendering, :overlay, :camera, :refresh],
                 @calls.map(&:first)
    assert_equal :row_focused, @coordinator.state
  end

  def test_row_selection_then_deselection_restores_session
    select('A')
    @calls.clear
    response = deselect
    assert response[:ok]
    assert_equal [:cancel, :clear_overlay, :visibility, :rendering, :restore_camera, :active_path, :refresh],
                 @calls.map(&:first)
    assert_nil @focus.highlight_row_id
    assert_equal :session_active, @coordinator.state
  end

  def test_a_to_b_then_c_transitions_keep_session_id
    generation = @coordinator.session_generation
    %w[A B C].each do |row|
      assert select(row)[:ok]
    end
    assert_equal generation, @coordinator.session_generation
    assert_equal 3, @coordinator.row_generation
    assert_equal 'C', @focus.highlight_row_id
    assert_equal :row_focused, @coordinator.state
  end

  def test_same_row_repeat_keeps_row_but_cancels_old_timer
    select('A')
    first = @coordinator.row_generation
    assert select('A')[:ok]
    assert_equal first + 1, @coordinator.row_generation
    assert_equal 'A', @focus.highlight_row_id
  end

  def test_overlay_failure_is_partial_not_transaction_failure
    @overlay_nil = true
    response = select('A')
    assert response[:ok]
    assert_equal :partial, response[:status]
    assert_includes response[:warnings].join, 'geometry'
    assert_equal 'A', @focus.highlight_row_id
  end

  def test_camera_scheduling_failure_is_partial
    @camera_fail = true
    response = select('B')
    assert response[:ok]
    assert_equal :partial, response[:status]
    assert_includes response[:warnings].join, 'Camera'
    assert_equal 'B', @focus.highlight_row_id
  end

  def test_overlay_exception_does_not_rollback_valid_row
    @coordinator.instance_variable_set(:@show_overlay, ->(_row) { raise 'missing geometry' })
    response = select('A')
    assert response[:ok]
    assert_equal :partial, response[:status]
    assert_equal 'A', @focus.highlight_row_id
  end

  def test_camera_exception_does_not_rollback_valid_row
    @coordinator.instance_variable_set(:@schedule_camera, ->(_row) { raise 'no camera bounds' })
    response = select('B')
    assert response[:ok]
    assert_equal :partial, response[:status]
    assert_equal 'B', @focus.highlight_row_id
  end

  def test_visibility_failure_rolls_back_focus_without_camera
    select('A')
    @calls.clear
    @fail = :visibility
    failed = select('B')
    refute failed[:ok]
    assert_equal 'A', @focus.highlight_row_id
    assert_equal :failed, failed[:status]
    refute_includes @calls.map(&:first), :camera
  end

  def test_rendering_failure_rolls_back_visibility_and_focus
    select('A')
    @calls.clear
    @fail = :rendering
    failed = select('B')
    refute failed[:ok]
    assert_equal 'A', @focus.highlight_row_id
    assert_equal [:cancel, :clear_overlay, :visibility, :rendering, :visibility, :rendering, :overlay],
                 @calls.map(&:first)
  end

  def test_partial_visibility_exception_attempts_rollback
    select('A')
    @exception = :visibility
    result = select('B')
    refute result[:ok]
    assert_equal 'A', @focus.highlight_row_id
    assert_equal :failed, @coordinator.state
    assert result[:errors].key?(:visibility)
  end

  def test_active_path_deselection_failure_does_not_claim_success
    select('A')
    @context_fail = true
    result = deselect
    refute result[:ok]
    assert_equal 'A', @focus.highlight_row_id
    assert_equal 'Primal edit context restoration failed', result[:errors][:transition]
  end

  def test_failed_deselection_restores_previous_edit_context
    @model.active_path = [:primal, :cell_a]
    select('A')
    @context_fail = true
    result = deselect
    refute result[:ok]
    assert_equal [[:primal, :cell_a]], @previous_paths
    assert_equal 'A', @focus.highlight_row_id
    assert_includes @calls.map(&:first), :restore_previous_path
  end

  def test_session_cleanup_exception_continues_rendering_and_camera
    select('A')
    @calls.clear
    response = @coordinator.end_session(
      model: @model,
      restore_visibility: -> { record(:restore_visibility); raise 'visibility native failure' },
      restore_rendering: -> { record(:restore_rendering); true }
    )
    refute response[:ok]
    assert_equal :failed, @coordinator.state
    assert_includes response[:errors][:visibility], 'visibility native failure'
    assert_includes @calls.map(&:first), :restore_rendering
    assert_includes @calls.map(&:first), :restore_camera
  end

  def test_camera_snapshot_restore_failure_prevents_deselection
    select('A')
    @camera_fail = true
    response = deselect
    refute response[:ok]
    assert_equal 'A', @focus.highlight_row_id
  end

  def test_outdated_row_id_is_rejected
    @focus.define_singleton_method(:focus_row) { |_id| nil }
    refute select('A')[:ok]
    assert_nil @focus.highlight_row_id
  end

  def test_invalid_empty_row_selection_is_rejected_without_changes
    @calls.clear
    result = @coordinator.focus_row([], '104', row_id: 'A')
    refute result[:ok]
    assert_empty @calls
    assert_nil @focus.highlight_row_id
  end

  def test_row_without_identifier_is_rejected
    result = @coordinator.focus_row(['A'], '104', row_id: '')
    refute result[:ok]
  end

  def test_invalid_model_and_model_switch_rejected_before_scene_change
    @calls.clear
    Sketchup.active_model = Model.new
    refute select('A')[:ok]
    assert_empty @calls
    Sketchup.active_model = @model
    @model.is_valid = false
    refute select('A')[:ok]
    assert_empty @calls
  end

  def test_runtime_refresh_new_row_data_does_not_leak_previous_reference
    select('A')
    @focus.focus_rows['A'] = { cells: ['A-new'], states: [], transitions: [] }
    assert @coordinator.focus_row(['A-new'], '104', row_id: 'A', row_cells: ['A-new'])[:ok]
    assert_equal ['A-new'], @focus.ids
  end

  def test_fast_selection_invalidation_advances_generation
    select('A')
    old = @coordinator.row_generation
    @coordinator.invalidate_async
    assert_equal old + 1, @coordinator.row_generation
    assert_equal [:cancel, nil], @calls.last
  end

  def test_end_session_runs_all_restores_and_clears_state
    select('B')
    @calls.clear
    outcome = @coordinator.end_session(
      model: @model,
      restore_visibility: -> { record(:restore_visibility); true },
      restore_rendering: -> { record(:restore_rendering); true }
    )
    assert outcome[:ok]
    assert_equal :inactive, @coordinator.state
    assert_equal [:cancel, :clear_overlay, :restore_visibility, :restore_rendering, :restore_camera],
                 @calls.map(&:first)
  end

  def test_end_session_from_session_without_row
    outcome = @coordinator.end_session(
      model: @model,
      restore_visibility: -> { true }, restore_rendering: -> { true }
    )
    assert outcome[:ok]
    assert_equal :inactive, @coordinator.state
  end

  def test_end_session_continues_after_restore_failure
    select('A')
    @calls.clear
    outcome = @coordinator.end_session(
      model: @model,
      restore_visibility: -> { record(:restore_visibility); false },
      restore_rendering: -> { record(:restore_rendering); true }
    )
    refute outcome[:ok]
    assert_equal :failed, @coordinator.state
    assert_equal [:cancel, :clear_overlay, :restore_visibility, :restore_rendering, :restore_camera],
                 @calls.map(&:first)
  end

  def test_end_session_model_changed_does_not_restore_previous_model
    select('A')
    Sketchup.active_model = Model.new
    @calls.clear
    outcome = @coordinator.end_session(
      model: @model,
      restore_visibility: -> { record(:restore_visibility); true },
      restore_rendering: -> { record(:restore_rendering); true }
    )
    refute outcome[:ok]
    refute_includes @calls.map(&:first), :restore_visibility
  end

  def test_discard_cancels_pending_and_does_not_modify_scene
    select('A')
    @calls.clear
    @coordinator.discard
    assert_equal :inactive, @coordinator.state
    assert_equal [:cancel], @calls.map(&:first)
    refute select('B')[:ok]
  end

  def test_inactive_validation_focus_prevents_selection
    @focus.active = false
    @calls.clear
    refute select('A')[:ok]
    assert_empty @calls
  end

  def test_unexpected_step_exception_rolls_back_previous_row
    select('A')
    @exception = :rendering
    response = select('B')
    refute response[:ok]
    assert_equal 'A', @focus.highlight_row_id
    assert response[:errors].key?(:rendering)
  end

  def test_warnings_do_not_modify_validation_or_dualgraph_state
    dualgraph = Object.new
    @indoor.instance_variable_set(:@dualgraph, dualgraph)
    @overlay_nil = true
    @camera_fail = true
    response = select('C')
    assert response[:ok]
    assert_equal :partial, response[:status]
    assert_same dualgraph, @indoor.instance_variable_get(:@dualgraph)
    assert @focus.active?
  end
end
