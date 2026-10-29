# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session/visibility_controller'
require_relative '../indoor3d/infrastructure/scene/editor_session/validation_focus_visibility_service'

module Sketchup
  class << self
    attr_accessor :active_model
  end
end

class ValidationFocusVisibilityServiceTest < Minitest::Test
  Session = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession
  VisibilityService = Session::ValidationFocusVisibilityService
  VisibilityController = Session::VisibilityController

  class Tag
    attr_reader :writes
    attr_accessor :fail_next

    def initialize(visible: true)
      @visible = visible
      @writes = 0
    end

    def visible?
      @visible
    end

    def visible=(value)
      @writes += 1
      @visible = value
      if @fail_next
        @fail_next = false
        raise 'Tag write interrupted'
      end
    end

    def valid?
      true
    end
  end

  class Group
    attr_reader :persistent_id, :entities, :writes, :layer
    attr_accessor :fail_next, :locked, :transform

    def initialize(pid, hidden: false, layer: nil, entities: [])
      @persistent_id = pid
      @hidden = hidden
      @layer = layer || Tag.new
      @entities = entities
      @writes = 0
      @valid = true
      @locked = false
    end

    def typename
      'Group'
    end

    def hidden?
      @hidden
    end

    def hidden=(value)
      raise 'Cannot write invalid group' unless valid?

      @writes += 1
      @hidden = value
      if @fail_next
        @fail_next = false
        raise 'Hidden write interrupted'
      end
    end

    def valid?
      @valid
    end

    def erase!
      @valid = false
    end

    def locked?
      @locked
    end

    def locked=(value)
      @locked = value
    end
  end

  class Component
    attr_reader :definition, :layer
    attr_accessor :fail_next

    def initialize(definition, hidden: false, layer: nil)
      @definition = definition
      @hidden = hidden
      @layer = layer || Tag.new
    end

    def typename
      'ComponentInstance'
    end

    def hidden?
      @hidden
    end

    def hidden=(value)
      @hidden = value
    end

    def valid?
      true
    end

    def persistent_id
      object_id
    end
  end

  Cell = Struct.new(:id, :sketchup_group) do
    def valid?
      sketchup_group&.valid? == true
    end
  end

  class Model
    attr_reader :entities, :primal_group, :cell_spaces, :model, :operations, :observer_calls, :unlocks, :invalidations
    attr_accessor :active_path

    def initialize(primal, cells, other)
      @primal_group = primal
      @cell_spaces = cells
      @entities = [primal, other]
      @model = self
      @operations = 0
      @observer_calls = 0
      @unlocks = 0
      @invalidations = 0
    end

    def valid?
      true
    end

    def with_indoor_model_operation(_name)
      @operations += 1
      yield
    end

    def with_runtime_observer_suppression
      @observer_calls += 1
      yield
    end

    def with_unlocked(entity)
      @unlocks += 1
      locked = entity.locked? if entity.respond_to?(:locked?)
      entity.locked = false if locked
      yield
    ensure
      entity.locked = true if locked && entity.valid?
    end

    def invalidate
      @invalidations += 1
    end
  end

  class Focus
    attr_reader :highlight_row_id
    attr_accessor :row

    def initialize(all)
      @all = all
      @row = nil
      @highlight_row_id = nil
    end

    def highlight_active?
      !@row.nil?
    end

    def highlight_row_id
      @row && @row.join('-')
    end

    def highlight_code
      '104'
    end

    def visible_cell_space?(cell)
      (@row || @all).include?(cell.id)
    end
  end

  def setup
    @a = Group.new(101, hidden: true)
    @b = Group.new(102)
    @c = Group.new(103)
    @unrelated = Group.new(900, hidden: true)
    @primal = Group.new(100, hidden: true, entities: [@a, @b, @c])
    @cells = [Cell.new('A', @a), Cell.new('B', @b), Cell.new('C', @c)]
    @model = Model.new(@primal, @cells, @unrelated)
    Sketchup.active_model = @model
    @focus = Focus.new(%w[A B C])
    @visibility = VisibilityController.new
    @service = VisibilityService.new(
      indoor_model: @model,
      validation_focus_controller: @focus,
      visibility_controller: @visibility,
      with_operation: ->(&block) {
        @model.with_indoor_model_operation('IndoorGML Edit Visibility') do
          @model.with_runtime_observer_suppression(&block)
        end
      },
      with_unlocked: ->(group, &block) { @model.with_unlocked(group, &block) },
      invalidate_view: ->(model) { model.invalidate }
    )
    assert @service.begin_session(@model, session_id: 1)[:ok]
  end

  def teardown
    Sketchup.active_model = nil
  end

  def apply_row(*ids)
    @focus.row = ids.empty? ? nil : ids
    result = @service.apply(@model, session_id: 1)
    assert result[:ok], result[:message]
    result
  end

  def test_hidden_true_and_false_restore_after_session
    apply_row
    refute @a.hidden?
    refute @b.hidden?
    refute @primal.hidden?
    apply_row('B')
    assert @a.hidden?
    refute @b.hidden?
    assert @c.hidden?
    assert @service.end_session(@model, session_id: 1)[:ok]
    assert @a.hidden?
    refute @b.hidden?
    refute @c.hidden?
    assert @primal.hidden?
  end

  def test_a_to_b_to_c_and_deselect_returns_to_session
    apply_row
    apply_row('A')
    refute @a.hidden?
    assert @b.hidden?
    apply_row('B')
    assert @a.hidden?
    refute @b.hidden?
    apply_row('C')
    assert @b.hidden?
    refute @c.hidden?
    apply_row
    refute @a.hidden?
    refute @b.hidden?
    refute @c.hidden?
  end

  def test_repeated_row_is_idempotent_and_no_empty_operation
    apply_row
    apply_row('B')
    counts = [@a.writes, @b.writes, @c.writes, @model.operations]
    3.times { apply_row('B') }
    assert_equal counts, [@a.writes, @b.writes, @c.writes, @model.operations]
    apply_row
    restored = [@a.writes, @b.writes, @c.writes, @model.operations]
    2.times { apply_row }
    assert_equal restored, [@a.writes, @b.writes, @c.writes, @model.operations]
  end

  def test_shared_cellspace_across_rows_does_not_overwrite_baseline
    apply_row
    apply_row('A', 'B')
    apply_row('B', 'C')
    apply_row
    assert [@a, @b, @c].all? { |g| !g.hidden? }
    @service.end_session(@model, session_id: 1)
    assert @a.hidden?
  end

  def test_hidden_ancestor_and_tag_are_temporarily_revealed
    hidden_parent = Group.new(200, hidden: true, layer: Tag.new(visible: false), entities: [@a])
    @primal.entities.delete(@a)
    @primal.entities << hidden_parent
    @a.layer.visible = false

    apply_row
    refute hidden_parent.hidden?
    assert hidden_parent.layer.visible?
    assert @a.layer.visible?
    apply_row('B')
    # The whole-session baseline still includes A's ancestor.
    refute hidden_parent.hidden?
    @service.end_session(@model, session_id: 1)
    assert hidden_parent.hidden?
    refute hidden_parent.layer.visible?
    refute @a.layer.visible?
  end

  def test_nested_component_instance_is_unhidden_without_changing_active_path
    nested = Group.new(701, hidden: true, entities: [@c])
    component = Component.new(Struct.new(:entities).new([nested]), hidden: true, layer: Tag.new(visible: false))
    @primal.entities.delete(@c)
    @primal.entities << component
    @model.active_path = [@primal]
    apply_row
    refute component.hidden?
    refute nested.hidden?
    assert component.layer.visible?
    assert_equal [@primal], @model.active_path
    @service.end_session(@model, session_id: 1)
    assert component.hidden?
    assert nested.hidden?
    refute component.layer.visible?
  end

  def test_unrelated_root_group_unchanged_and_shared_tag_restored
    shared_tag = Tag.new(visible: false)
    @a.instance_variable_set(:@layer, shared_tag)
    @unrelated.instance_variable_set(:@layer, shared_tag)
    apply_row
    assert shared_tag.visible?
    assert @unrelated.hidden?
    assert_equal 0, @unrelated.writes
    @service.end_session(@model, session_id: 1)
    refute shared_tag.visible?
    assert @unrelated.hidden?
  end

  def test_group_deletion_and_recreation_uses_new_reference
    apply_row
    apply_row('B')
    @a.erase!
    replacement = Group.new(999, hidden: false)
    @cells[0].sketchup_group = replacement
    @primal.entities[0] = replacement
    apply_row('B')
    assert replacement.hidden?
    assert @service.end_session(@model, session_id: 1)[:ok]
    refute replacement.hidden?
  end

  def test_geometry_transform_does_not_affect_visibility
    apply_row
    @a.transform = [12, 8, 45]
    apply_row('B')
    assert @a.hidden?
    apply_row
    refute @a.hidden?
  end

  def test_partial_hidden_setter_failure_rolls_back_and_preserves_row_a
    apply_row
    apply_row('A')
    @b.fail_next = true
    @focus.row = ['B']
    result = @service.apply(@model, session_id: 1)
    refute result[:ok]
    refute @a.hidden?
    assert @b.hidden?
    assert @c.hidden?
    @focus.row = ['A']
    assert @service.apply(@model, session_id: 1)[:ok]
  end

  def test_tag_setter_failure_rolls_back_without_partial_visibility
    @a.layer.visible = false
    @a.layer.fail_next = true
    result = @service.apply(@model, session_id: 1)

    refute result[:ok]
    assert @a.hidden?
    refute @a.layer.visible?
    assert @primal.hidden?
  end

  def test_session_restore_failure_keeps_snapshots_for_retry
    apply_row
    @a.fail_next = true
    failed = @service.end_session(@model, session_id: 1)
    refute failed[:ok]
    assert @service.active_for?(@model, session_id: 1)

    restored = @service.end_session(@model, session_id: 1)
    assert restored[:ok], restored[:message]
    assert @a.hidden?
    assert @primal.hidden?
  end

  def test_model_replacement_never_writes_to_previous_model
    apply_row
    previous_writes = @a.writes
    Sketchup.active_model = Model.new(Group.new(500), [], Group.new(600))
    result = @service.end_session(@model, session_id: 1)
    refute result[:ok]
    assert_equal previous_writes, @a.writes
    refute @service.active_for?(@model, session_id: 1)
  end

  def test_lock_is_restored_and_observer_suppression_wraps_changes
    @a.locked = true
    apply_row
    refute @a.hidden?
    assert @a.locked?
    assert_operator @model.observer_calls, :>, 0
    assert_operator @model.unlocks, :>, 0
  end

  def test_general_edit_mode_filters_are_not_modified
    @visibility.set_filter(storeys: ['F01'], cell_types: ['GENERAL'])
    original_storeys = @visibility.visible_storeys.dup
    original_types = @visibility.visible_cell_types.dup

    apply_row
    apply_row('A')
    apply_row
    assert @service.end_session(@model, session_id: 1)[:ok]

    assert_equal original_storeys, @visibility.visible_storeys
    assert_equal original_types, @visibility.visible_cell_types
    assert @visibility.storey_filter_active?
  end

  def test_focus_visibility_does_not_change_overlay_or_edit_context
    @model.active_path = [@primal]
    overlay_marker = Object.new
    @model.instance_variable_set(:@overlay, overlay_marker)

    apply_row
    apply_row('B')
    assert_equal [@primal], @model.active_path
    assert_same overlay_marker, @model.instance_variable_get(:@overlay)
    @service.end_session(@model, session_id: 1)
    assert_equal [@primal], @model.active_path
  end

  def test_stale_session_id_is_rejected
    result = @service.apply(@model, session_id: 99)
    refute result[:ok]
    assert @a.hidden?
  end

  def test_row_return_to_session_does_not_restore_prevalidation_state
    apply_row
    apply_row('B')
    apply_row
    refute @a.hidden? # Originally hidden, but the session temporarily shows it.
    assert @service.active_for?(@model, session_id: 1)
    assert @primal.hidden? == false
  end
end
