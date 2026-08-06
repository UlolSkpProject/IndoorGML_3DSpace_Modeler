# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Group; end
  class ComponentInstance; end
end

require_relative '../indoor3d/infrastructure/scene/editor_session/edit_active_path_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionFixModeActivePathTest < Minitest::Test
        def test_fix_mode_accepts_direct_primal_group_and_keeps_shaded_style
          primal = FakeGroup.new
          child = FakeGroup.new
          primal.add_child(child)
          indoor_model = FakeIndoorModel.new(primal, [], validation_focus_active: true)
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, child])

          controller.set_target_path([primal])
          model.reset_active_path_write_count
          controller.active_path_changed(model, editing: true, reenter: -> {})

          assert_equal [primal, child], controller.target_path
          assert_equal [primal, child], model.active_path
          assert_equal 0, model.active_path_write_count
          refute controller.cell_space_geometry_editing?(editing: true)
          assert_equal false, model.rendering_options['InactiveHidden']
          assert_equal true, model.rendering_options['ModelTransparency']
          assert_equal 2, model.rendering_options['RenderMode']
          assert_equal false, model.rendering_options['Texture']
        end

        def test_fix_mode_accepts_direct_primal_component_instance
          primal = FakeGroup.new
          child = FakeComponentInstance.new
          primal.add_child(child)
          indoor_model = FakeIndoorModel.new(primal, [], validation_focus_active: true)
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, child])

          controller.set_target_path([primal])
          model.reset_active_path_write_count
          controller.active_path_changed(model, editing: true, reenter: -> {})

          assert_equal [primal, child], controller.target_path
          assert_equal 0, model.active_path_write_count
          assert_equal false, model.rendering_options['InactiveHidden']
          assert_equal true, model.rendering_options['ModelTransparency']
        end

        def test_edit_mode_rejects_non_cell_primal_child
          primal = FakeGroup.new
          child = FakeGroup.new
          primal.add_child(child)
          indoor_model = FakeIndoorModel.new(primal, [], validation_focus_active: false)
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, child])

          controller.set_target_path([primal])
          model.reset_active_path_write_count
          controller.active_path_changed(model, editing: true, reenter: -> {})

          assert_equal [primal], controller.target_path
          assert_equal [primal], model.active_path
          assert_equal 1, model.active_path_write_count
        end

        def test_fix_mode_rejects_group_that_is_not_direct_primal_child
          primal = FakeGroup.new
          other_parent = FakeGroup.new
          child = FakeGroup.new
          other_parent.add_child(child)
          indoor_model = FakeIndoorModel.new(primal, [], validation_focus_active: true)
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, child])

          controller.set_target_path([primal])
          model.reset_active_path_write_count
          controller.active_path_changed(model, editing: true, reenter: -> {})

          assert_equal [primal], controller.target_path
          assert_equal [primal], model.active_path
          assert_equal 1, model.active_path_write_count
        end

        def test_fix_mode_rejects_path_deeper_than_primal_direct_child
          primal = FakeGroup.new
          child = FakeGroup.new
          nested = FakeGroup.new
          primal.add_child(child)
          child.add_child(nested)
          indoor_model = FakeIndoorModel.new(primal, [], validation_focus_active: true)
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, child, nested])

          controller.set_target_path([primal, child])
          model.reset_active_path_write_count
          controller.active_path_changed(model, editing: true, reenter: -> {})

          assert_equal [primal, child], controller.target_path
          assert_equal [primal, child], model.active_path
          assert_equal 1, model.active_path_write_count
        end

        def test_fix_mode_cell_space_path_remains_monochrome
          primal = FakeGroup.new
          cell_group = FakeGroup.new
          primal.add_child(cell_group)
          cell_space = FakeCellSpace.new(cell_group)
          indoor_model = FakeIndoorModel.new(primal, [cell_space], validation_focus_active: true)
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, cell_group])

          controller.set_target_path([primal])
          model.reset_active_path_write_count
          controller.active_path_changed(model, editing: true, reenter: -> {})

          assert_equal [primal, cell_group], controller.target_path
          assert controller.cell_space_geometry_editing?(editing: true)
          assert_equal cell_space, controller.editing_cell_space
          assert_equal false, model.rendering_options['InactiveHidden']
          assert_equal true, model.rendering_options['ModelTransparency']
          assert_equal 5, model.rendering_options['RenderMode']
          assert_equal false, model.rendering_options['Texture']
        end

        def test_fix_mode_primal_path_hides_rest_for_selected_row_without_xray
          primal = FakeGroup.new
          indoor_model = FakeIndoorModel.new(primal, [], validation_focus_active: true)
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal])
          model.rendering_options['InactiveHidden'] = false
          model.rendering_options['ModelTransparency'] = true

          controller.set_target_path([primal])
          controller.active_path_changed(model, editing: true, reenter: -> {})

          assert_equal true, model.rendering_options['InactiveHidden']
          assert_equal false, model.rendering_options['ModelTransparency']
          assert_equal 2, model.rendering_options['RenderMode']
        end

        def test_fix_mode_transaction_replay_adopts_direct_primal_group_without_write
          primal = FakeGroup.new
          child = FakeGroup.new
          primal.add_child(child)
          indoor_model = FakeIndoorModel.new(primal, [], validation_focus_active: true)
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, child])

          controller.set_target_path([primal])
          model.reset_active_path_write_count
          controller.reconcile_transaction_replay_path(model, editing: true)

          assert_equal [primal, child], controller.target_path
          assert_equal 0, model.active_path_write_count
        end

        private

        def build_controller(indoor_model)
          EditorSession::EditActivePathController.new(
            indoor_model: indoor_model,
            on_lock: -> {},
            on_selection: -> {},
            on_invalidate: ->(_model) {}
          )
        end

        class FakeEntities
          include Enumerable

          def initialize
            @entities = []
          end

          def add(entity)
            @entities << entity
            entity.parent = self if entity.respond_to?(:parent=)
            entity
          end

          def each(&block)
            @entities.each(&block)
          end

          def include?(entity)
            @entities.include?(entity)
          end
        end

        module FakeEntityBehavior
          attr_accessor :parent

          def initialize(valid: true)
            @valid = valid
            @entities = FakeEntities.new
          end

          def valid?
            @valid == true
          end

          def entities
            @entities
          end

          def add_child(entity)
            @entities.add(entity)
          end
        end

        class FakeGroup < Sketchup::Group
          include FakeEntityBehavior
        end

        class FakeComponentInstance < Sketchup::ComponentInstance
          include FakeEntityBehavior
        end

        class FakeCellSpace
          attr_reader :sketchup_group

          def initialize(group)
            @sketchup_group = group
          end

          def valid?
            true
          end
        end

        class FakeIndoorModel
          attr_reader :primal_group, :cell_spaces

          def initialize(primal_group, cell_spaces, validation_focus_active:, highlight_row_id: nil)
            @primal_group = primal_group
            @cell_spaces = cell_spaces
            @validation_focus_active = validation_focus_active
            @highlight_row_id = highlight_row_id || (validation_focus_active ? 'row-1' : nil)
          end

          def validation_focus_active?
            @validation_focus_active == true
          end

          def validation_focus_highlight_row_id
            @highlight_row_id
          end
        end

        class FakeView
          def invalidate; end
        end

        class FakeModel
          attr_reader :active_path, :active_path_write_count, :rendering_options, :active_view

          def initialize(active_path)
            @active_path = active_path
            @active_path_write_count = 0
            @rendering_options = {
              'InactiveHidden' => true,
              'ModelTransparency' => false,
              'RenderMode' => 2,
              'Texture' => false
            }
            @active_view = FakeView.new
          end

          def active_path=(path)
            @active_path_write_count += 1
            @active_path = path
          end

          def reset_active_path_write_count
            @active_path_write_count = 0
          end

          def close_active
            @active_path = nil
          end
        end
      end
    end
  end
end
