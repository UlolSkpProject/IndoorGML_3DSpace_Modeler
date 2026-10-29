# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session'

class ValidationRenderingEditorSessionTest < Minitest::Test
  EditorSession = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession
  Policy = EditorSession::RenderingOptionsPolicy

  class Model
    attr_reader :rendering_options, :active_view
    attr_accessor :active_path

    def initialize(values)
      @rendering_options = values.dup
      @active_view = Struct.new(:invalidate_count) do
        def invalidate
          self.invalidate_count += 1
        end
      end.new(0)
    end

    def valid?
      true
    end
  end

  class Focus
    attr_accessor :active, :highlight_row_id

    def active?
      @active == true
    end
  end

  class Cell
    attr_reader :sketchup_group

    def initialize(group)
      @sketchup_group = group
    end

    def valid?
      true
    end
  end

  class Indoor
    attr_reader :model, :primal_group, :cell_spaces

    def initialize(model, primal_group, cells)
      @model = model
      @primal_group = primal_group
      @cell_spaces = cells
    end
  end

  def setup
    @primal = Object.new
    @group = Object.new
    @original = {
      'RenderMode' => 5, 'Texture' => true,
      'InactiveHidden' => true, 'ModelTransparency' => false,
      'DrawHidden' => true
    }
    @model = Model.new(@original)
    @focus = Focus.new
    @focus.active = false
    @focus.highlight_row_id = nil
    @session = EditorSession.allocate
    @session.instance_variable_set(:@indoor_model, Indoor.new(@model, @primal, [Cell.new(@group)]))
    @session.instance_variable_set(:@validation_focus_controller, @focus)
    @session.instance_variable_set(:@rendering_options_manager, Policy::Manager.new)
    @session.instance_variable_set(:@editing, true)
  end

  def test_edit_to_validation_row_to_geometry_and_back
    assert @session.capture_and_apply_edit_mode_rendering_options
    assert_equal 2, @model.rendering_options['RenderMode']
    assert @session.capture_and_apply_validation_focus_rendering_options(1)
    @focus.active = true
    @focus.highlight_row_id = 'A'

    assert @session.apply_rendering_context(@model, [@primal])
    assert_equal true, @model.rendering_options['InactiveHidden']
    assert @session.apply_rendering_context(@model, [@primal, @group])
    assert_equal 5, @model.rendering_options['RenderMode']
    assert_equal true, @model.rendering_options['ModelTransparency']
    assert_equal false, @model.rendering_options['InactiveHidden']

    assert @session.apply_rendering_context(@model, [@primal])
    assert_equal 2, @model.rendering_options['RenderMode']
    @focus.highlight_row_id = nil
    assert @session.apply_rendering_context(@model, [@primal])
    assert_equal false, @model.rendering_options['InactiveHidden']

    assert @session.restore_validation_focus_rendering_options
    assert_equal @original, @model.rendering_options
  end

  def test_direct_primal_child_is_transparent_but_remains_shaded
    assert @session.capture_and_apply_edit_mode_rendering_options
    assert @session.capture_and_apply_validation_focus_rendering_options(1)
    @focus.active = true
    @focus.highlight_row_id = 'A'
    assert @session.apply_rendering_context(@model, [@primal, Object.new])
    assert_equal true, @model.rendering_options['ModelTransparency']
    assert_equal 2, @model.rendering_options['RenderMode']
  end

  def test_row_policy_reapply_has_no_redundant_view_invalidate
    assert @session.capture_and_apply_edit_mode_rendering_options
    assert @session.capture_and_apply_validation_focus_rendering_options(1)
    @focus.active = true
    @focus.highlight_row_id = 'A'
    assert @session.apply_rendering_context(@model, [@primal])
    count = @model.active_view.invalidate_count
    3.times { assert @session.apply_rendering_context(@model, [@primal]) }
    assert_equal count, @model.active_view.invalidate_count
  end

  def test_row_policy_recovers_when_sketchup_changes_transparency
    assert @session.capture_and_apply_edit_mode_rendering_options
    assert @session.capture_and_apply_validation_focus_rendering_options(1)
    @focus.active = true
    @focus.highlight_row_id = 'A'
    assert @session.apply_rendering_context(@model, [@primal])

    @model.rendering_options['ModelTransparency'] = true

    assert @session.apply_rendering_context(@model, [@primal])
    assert_equal false, @model.rendering_options['ModelTransparency']
    assert @session.restore_validation_focus_rendering_options
    assert_equal @original, @model.rendering_options
  end

  def test_failed_validation_entry_preserves_existing_edit_mode
    assert @session.capture_and_apply_edit_mode_rendering_options
    edit_baseline = @model.rendering_options.dup
    assert_equal 2, edit_baseline['RenderMode']
    assert @session.capture_and_apply_validation_focus_rendering_options(1)
    @focus.active = true
    @focus.highlight_row_id = 'A'
    assert @session.apply_rendering_context(@model, [@primal])

    assert @session.send(:restore_rendering_after_failed_validation_entry, true)
    assert_equal edit_baseline, @model.rendering_options
    assert @session.rendering_options_manager.captured?(:edit)
    assert @session.restore_validation_focus_rendering_options
    assert_equal @original, @model.rendering_options
  end

  def test_policy_never_changes_camera_visibility_or_dualgraph
    camera = Object.new
    visibility = Object.new
    dualgraph = Object.new
    @model.instance_variable_set(:@camera, camera)
    @model.instance_variable_set(:@visibility, visibility)
    @model.instance_variable_set(:@dual_graph_overlay, dualgraph)
    @session.capture_and_apply_edit_mode_rendering_options
    @session.capture_and_apply_validation_focus_rendering_options(1)
    @focus.active = true
    @focus.highlight_row_id = 'A'
    assert @session.apply_rendering_context(@model, [@primal])
    assert_same camera, @model.instance_variable_get(:@camera)
    assert_same visibility, @model.instance_variable_get(:@visibility)
    assert_same dualgraph, @model.instance_variable_get(:@dual_graph_overlay)
  end
end
