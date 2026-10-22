# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/storey_filter'
require_relative '../indoor3d/infrastructure/scene/editor_session/visibility_controller'
require_relative '../indoor3d/infrastructure/scene/editor_session/edit_visibility_service'

class EditVisibilityServiceTest < Minitest::Test
  EditorSession = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession
  VisibilityController = EditorSession::VisibilityController
  EditVisibilityService = EditorSession::EditVisibilityService
  CellSpace = Struct.new(:storey, :cell_type) do
    def valid?
      true
    end
  end
  ValidationFocus = Struct.new(:active?)

  def setup
    @controller = VisibilityController.new
    @service = EditVisibilityService.new(
      indoor_model: Struct.new(:cell_spaces).new([]),
      visibility_controller: @controller,
      validation_focus_controller: ValidationFocus.new(false),
      geometry_visible: -> { true },
      with_unlocked: ->(_entity, &block) { block.call },
      invalidate_view: ->(_model) {},
      invalidate_overlay: -> {}
    )
  end

  def test_unset_storey_filter_keeps_all_storeys_visible
    refute @controller.storey_filter_active?
    assert @service.edit_mode_visible_cell_space?(CellSpace.new('F01', 'Room'))
    assert @service.edit_mode_visible_cell_space?(CellSpace.new('F02', 'Room'))
  end

  def test_explicit_empty_storey_filter_hides_all_storeys
    assert @controller.set_filter(storeys: [], cell_types: [])

    assert @controller.storey_filter_active?
    assert @controller.filter_active?
    refute @service.edit_mode_visible_cell_space?(CellSpace.new('F01', 'Room'))
    refute @service.edit_mode_visible_cell_space?(CellSpace.new('F02', 'Room'))
    refute @controller.set_filter(storeys: [], cell_types: [])
  end

  def test_selected_storey_remains_visible_and_reset_restores_all
    @controller.set_filter(storeys: ['F01'], cell_types: [])

    assert @service.edit_mode_visible_cell_space?(CellSpace.new('F01', 'Room'))
    refute @service.edit_mode_visible_cell_space?(CellSpace.new('F02', 'Room'))

    @controller.reset_filter
    refute @controller.storey_filter_active?
    refute @controller.filter_active?
    assert @service.edit_mode_visible_cell_space?(CellSpace.new('F02', 'Room'))
  end
end
