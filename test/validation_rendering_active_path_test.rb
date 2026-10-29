# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session/edit_active_path_controller'

class ValidationRenderingActivePathTest < Minitest::Test
  Controller = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::EditActivePathController

  class Entity
    def valid?
      true
    end
  end

  class Model
    attr_accessor :active_path

    def initialize
      @active_path = nil
    end
  end

  class IndoorModel
    attr_reader :primal_group, :cell_spaces

    def initialize(primal)
      @primal_group = primal
      @cell_spaces = []
    end

    def validation_focus_active?
      true
    end
  end

  def setup
    @primal = Entity.new
    @cell = Entity.new
    @model = Model.new
    @indoor = IndoorModel.new(@primal)
    @paths = []
    @controller = Controller.new(
      indoor_model: @indoor,
      on_lock: -> {},
      on_selection: -> {},
      on_invalidate: ->(_model) {},
      on_rendering_context: ->(model, path) { @paths << [model, Array(path)] }
    )
  end

  def test_set_calls_rendering_after_active_path_update
    @controller.set(@model, [@primal, @cell])
    assert_equal 1, @paths.length
    assert_equal [@primal, @cell], @paths.first[1]
    assert_equal @paths.first[1], @model.active_path
  end

  def test_external_active_path_changed_calls_once_after_enforcement
    @controller.set_target_path([@primal])
    @controller.set(@model, [@primal])
    @paths.clear
    @controller.active_path_changed(@model, editing: true, reenter: -> {})
    assert_equal 1, @paths.length
    assert_equal [@primal], @paths.first[1]
  end

  def test_inactive_edit_mode_does_not_notify_rendering
    @controller.active_path_changed(@model, editing: false, reenter: -> {})
    assert_empty @paths
  end

  def test_callback_optional_for_existing_callers
    controller = Controller.new(
      indoor_model: @indoor,
      on_lock: -> {},
      on_selection: -> {},
      on_invalidate: ->(_model) {}
    )
    assert controller.set(@model, [@primal])
    assert_equal [@primal], @model.active_path
  end
end
