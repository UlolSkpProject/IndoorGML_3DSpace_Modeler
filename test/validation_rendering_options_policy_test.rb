# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session/rendering_options_policy'

class ValidationRenderingOptionsPolicyTest < Minitest::Test
  Policy = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::RenderingOptionsPolicy

  class TrackedOptions < Hash
    attr_reader :writes
    attr_accessor :fail_key, :fail_once

    def initialize(values)
      super()
      update(values)
      @writes = []
    end

    def []=(key, value)
      @writes << [key, value] if @writes
      if fail_key == key && fail_once
        self.fail_once = false
        raise "Blocked #{key}"
      end
      super
    end
  end

  class FakeView
    attr_reader :invalidates

    def initialize
      @invalidates = 0
    end

    def invalidate
      @invalidates += 1
    end
  end

  class FakeModel
    attr_reader :rendering_options, :active_view

    def initialize(values)
      @rendering_options = TrackedOptions.new(values)
      @active_view = FakeView.new
    end

    def valid?
      true
    end
  end

  def setup
    @original = {
      'RenderMode' => 5,
      'Texture' => true,
      'InactiveHidden' => true,
      'ModelTransparency' => true,
      'ROPDrawHiddenObjects' => true,
      'ROPDrawHiddenGeometry' => true,
      'DrawHiddenObjects' => false,
      'DrawHiddenGeometry' => true,
      'DrawHidden' => false
    }
    @model = FakeModel.new(@original)
    @manager = Policy::Manager.new
  end

  def apply(scope, values)
    result = @manager.apply(@model, scope: scope, values: values)
    assert result[:ok], result[:errors].inspect
    result
  end

  def test_base_edit_policy_matches_existing_shaded_and_hidden_keys
    apply(:edit, Policy.base_edit)

    assert_equal 2, @model.rendering_options['RenderMode']
    assert_equal false, @model.rendering_options['Texture']
    assert_equal false, @model.rendering_options['InactiveHidden']
    assert_equal true, @model.rendering_options['ModelTransparency']
    assert_equal false, @model.rendering_options['ROPDrawHiddenObjects']
    assert_equal false, @model.rendering_options['ROPDrawHiddenGeometry']
    assert_equal false, @model.rendering_options['DrawHiddenGeometry']

    restored = @manager.restore_all(@model)
    assert restored[:ok], restored[:errors].inspect
    assert_equal @original, @model.rendering_options.to_h
  end

  def test_initial_shaded_monochrome_texture_and_transparency_restore
    [2, 5].each do |render_mode|
      initial = @original.merge('RenderMode' => render_mode)
      model = FakeModel.new(initial)
      manager = Policy::Manager.new
      assert manager.apply(model, scope: :edit, values: Policy.base_edit)[:ok]
      assert manager.apply(model, scope: :session, values: Policy.validation_session)[:ok]
      assert manager.restore_all(model)[:ok]
      assert_equal initial, model.rendering_options.to_h
    end
  end

  def test_three_scopes_restore_from_row_to_session_to_original
    apply(:edit, Policy.base_edit)
    apply(:session, Policy.validation_session)
    selected = Policy.context_values(validation_context(row: true))
    apply(:row, selected)
    assert_equal true, @model.rendering_options['InactiveHidden']
    assert_equal false, @model.rendering_options['ModelTransparency']

    geometry = Policy.context_values(validation_context(row: true, group: true, cell: true))
    apply(:row, geometry)
    assert_equal 5, @model.rendering_options['RenderMode']
    assert_equal true, @model.rendering_options['ModelTransparency']
    assert_equal false, @model.rendering_options['InactiveHidden']

    assert @manager.restore(@model, scope: :row)[:ok]
    assert_equal 2, @model.rendering_options['RenderMode']
    assert_equal false, @model.rendering_options['ModelTransparency']
    assert_equal false, @model.rendering_options['InactiveHidden']
    assert @manager.restore(@model, scope: :session)[:ok]
    assert_equal true, @model.rendering_options['ModelTransparency']
    assert @manager.restore(@model, scope: :edit)[:ok]
    assert_equal @original, @model.rendering_options.to_h
  end

  def test_row_a_b_and_deselection_preserve_first_baseline
    apply(:edit, Policy.base_edit)
    apply(:session, Policy.validation_session)
    row_policy = Policy.context_values(validation_context(row: true))
    apply(:row, row_policy) # Row A
    apply(:row, row_policy) # Row B, same policy
    assert_equal true, @model.rendering_options['InactiveHidden']
    assert @manager.restore(@model, scope: :row)[:ok] # Deselection
    assert_equal false, @model.rendering_options['InactiveHidden']
    assert @manager.restore_all(@model)[:ok]
    assert_equal @original, @model.rendering_options.to_h
  end

  def test_geometry_edit_to_row_focus_and_primal_restoration
    apply(:edit, Policy.base_edit)
    apply(:session, Policy.validation_session)
    apply(:row, Policy.context_values(validation_context(row: true)))
    apply(:row, Policy.context_values(validation_context(row: true, group: true, cell: true)))
    apply(:row, Policy.context_values(validation_context(row: true)))

    assert_equal 2, @model.rendering_options['RenderMode']
    assert_equal false, @model.rendering_options['ModelTransparency']
    assert_equal true, @model.rendering_options['InactiveHidden']
    assert @manager.restore_all(@model)[:ok]
    assert_equal @original, @model.rendering_options.to_h
  end

  def test_primal_direct_child_uses_transparency_but_not_monochrome
    context = validation_context(row: true, group: true, cell: false)
    values = Policy.context_values(context)
    assert_equal false, values['InactiveHidden']
    assert_equal true, values['ModelTransparency']
    assert_equal 2, values['RenderMode']
  end

  def test_normal_edit_context_keeps_shaded_style
    context = Policy.current_context(
      validation: false,
      path: [Object.new, Object.new],
      primal_group: Object.new,
      cell_space_editing: true,
      row_selected: true
    )
    assert_equal({ 'RenderMode' => 2, 'Texture' => false }, Policy.context_values(context))
  end

  def test_missing_keys_are_skipped_not_created
    model = FakeModel.new('RenderMode' => 5)
    manager = Policy::Manager.new
    result = manager.apply(model, scope: :edit, values: Policy.base_edit)
    assert result[:ok], result[:errors].inspect
    assert_equal ['RenderMode'], result[:changed_keys]
    assert_equal ['RenderMode'], model.rendering_options.keys
    assert manager.restore_all(model)[:ok]
    assert_equal 5, model.rendering_options['RenderMode']
  end

  def test_repeated_apply_and_restore_without_changes_do_not_invalidate
    apply(:edit, Policy.base_edit)
    before = @model.active_view.invalidates
    writes = @model.rendering_options.writes.dup
    3.times { apply(:edit, Policy.base_edit) }
    assert_equal before, @model.active_view.invalidates
    assert_equal writes, @model.rendering_options.writes

    assert @manager.restore_all(@model)[:ok]
    after = @model.active_view.invalidates
    assert @manager.restore_all(@model)[:ok]
    assert_equal after, @model.active_view.invalidates
  end

  def test_partial_apply_failure_rolls_back_keys
    options = @model.rendering_options
    options.fail_key = 'Texture'
    options.fail_once = true
    result = @manager.apply(@model, scope: :edit, values: Policy.base_edit)
    refute result[:ok]
    assert_includes result[:errors].keys, 'Texture'
    assert_equal @original, options.to_h
    refute @manager.captured?(:edit)
  end

  def test_partial_restore_failure_reports_key_and_can_retry
    apply(:edit, Policy.base_edit)
    options = @model.rendering_options
    options.fail_key = 'RenderMode'
    options.fail_once = true
    failed = @manager.restore(@model, scope: :edit)
    refute failed[:ok]
    assert_includes failed[:errors].keys, 'RenderMode'
    assert @manager.captured?(:edit)

    restored = @manager.restore_all(@model)
    assert restored[:ok], restored[:errors].inspect
    assert_equal @original, options.to_h
  end

  def test_outside_service_modification_is_reported_as_conflict
    apply(:edit, Policy.base_edit)
    @model.rendering_options['RenderMode'] = 99
    failure = @manager.restore_all(@model)
    refute failure[:ok]
    assert_includes failure[:errors][:edit].keys, 'RenderMode'
    assert @manager.captured?(:edit)
  end

  def test_model_invalid_or_replaced_is_rejected_without_writes
    apply(:edit, Policy.base_edit)
    model_b = FakeModel.new(@original)
    result = @manager.apply(model_b, scope: :row, values: Policy.context_values(validation_context(row: true)))
    refute result[:ok]
    assert_equal @original, model_b.rendering_options.to_h
    @model.define_singleton_method(:valid?) { false }
    refute @manager.restore_all(@model)[:ok]
  end

  def test_scope_errors_and_missing_model_are_explicit
    refute @manager.capture(nil, scope: :edit)[:ok]
    refute @manager.capture(@model, scope: :unknown)[:ok]
    refute @manager.apply(@model, scope: :unknown, values: {})[:ok]
  end

  def test_camera_and_visibility_state_objects_are_untouched
    camera = Object.new
    overlays = Object.new
    visibility = { cell_hidden: true, tag_visible: false }
    @model.instance_variable_set(:@camera, camera)
    @model.instance_variable_set(:@overlay, overlays)
    @model.instance_variable_set(:@visibility, visibility)
    apply(:edit, Policy.base_edit)
    apply(:session, Policy.validation_session)
    apply(:row, Policy.context_values(validation_context(row: true)))
    assert @manager.restore_all(@model)[:ok]
    assert_same camera, @model.instance_variable_get(:@camera)
    assert_same overlays, @model.instance_variable_get(:@overlay)
    assert_same visibility, @model.instance_variable_get(:@visibility)
  end

  private

  def validation_context(row: false, group: false, cell: false)
    {
      validation: true,
      group_editing: group,
      cell_space_editing: cell,
      row_selected: row
    }
  end
end
