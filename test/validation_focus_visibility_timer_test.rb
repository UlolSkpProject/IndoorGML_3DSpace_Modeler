# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session'

module Sketchup
  class << self
    attr_accessor :active_model
  end
end

module UI
  @validation_timers = []
  def self.validation_timers
    @validation_timers ||= []
  end

  def self.flush_validation_timers
    queued = validation_timers.dup
    @validation_timers = []
    queued.each { |_delay, callback| callback.call }
  end
end

class ValidationFocusVisibilityTimerTest < Minitest::Test
  EditorSession = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession
  FakeModel = Struct.new(:valid_value) do
    def valid?
      valid_value
    end
  end
  FakeIndoorModel = Struct.new(:model)
  FakeService = Struct.new(:validation_visibility_generation)

  def setup
    UI.validation_timers.clear
    @previous_start_timer = UI.method(:start_timer) if UI.respond_to?(:start_timer)
    UI.define_singleton_method(:start_timer) do |delay, _repeat, &callback|
      validation_timers << [delay, callback]
      validation_timers.length
    end
    @model = FakeModel.new(true)
    Sketchup.active_model = @model
    @session = EditorSession.allocate
    @session.instance_variable_set(:@indoor_model, FakeIndoorModel.new(@model))
    @session.instance_variable_set(:@validation_focus_visibility_row_generation, 0)
    @session.instance_variable_set(:@edit_visibility_service, FakeService.new(10))
    @applies = []
    applies = @applies
    @session.define_singleton_method(:validation_focus_active?) { true }
    @session.define_singleton_method(:apply_validation_focus_visibility) do
      applies << :apply
      true
    end
    @session.define_singleton_method(:invalidate_overlay_transition_visibility) {}
    @session.define_singleton_method(:selection_changed) {}
    @session.define_singleton_method(:invalidate_view) { |_model| }
  end

  def teardown
    UI.validation_timers.clear
    if @previous_start_timer
      UI.define_singleton_method(:start_timer, @previous_start_timer)
    else
      UI.singleton_class.remove_method(:start_timer)
    end
    Sketchup.active_model = nil
  end

  def test_delays_are_preserved
    assert @session.send(:defer_validation_focus_visibility)
    assert_equal [0, 0.05, 0.15, 0.35], UI.validation_timers.map(&:first)
    UI.flush_validation_timers
    assert_equal 4, @applies.length
  end

  def test_old_session_callbacks_do_not_touch_new_session
    assert @session.send(:defer_validation_focus_visibility)
    @session.send(:edit_visibility_service).validation_visibility_generation = 11
    UI.flush_validation_timers
    assert_empty @applies
  end

  def test_old_row_generation_does_not_overwrite_new_row
    assert @session.send(:defer_validation_focus_visibility)
    @session.instance_variable_set(:@validation_focus_visibility_row_generation, 1)
    UI.flush_validation_timers
    assert_empty @applies
  end

  def test_model_switch_and_invalid_model_skip_pending_tasks
    assert @session.send(:defer_validation_focus_visibility)
    Sketchup.active_model = FakeModel.new(true)
    UI.flush_validation_timers
    assert_empty @applies

    Sketchup.active_model = @model
    assert @session.send(:defer_validation_focus_visibility)
    @model.valid_value = false
    UI.flush_validation_timers
    assert_empty @applies
  end

  def test_inactive_focus_skips_pending_tasks
    assert @session.send(:defer_validation_focus_visibility)
    @session.define_singleton_method(:validation_focus_active?) { false }
    UI.flush_validation_timers
    assert_empty @applies
  end
end
