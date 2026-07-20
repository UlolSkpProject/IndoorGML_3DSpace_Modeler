# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Face; end unless const_defined?(:Face, false)

  class << self
    attr_accessor :demotion_test_active_model
  end

  def self.active_model
    @demotion_test_active_model
  end
end

module UI
  def self.messagebox(_message, *_arguments)
    nil
  end unless respond_to?(:messagebox)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/infrastructure/persistence/attribute_serializer'
require_relative '../indoor3d/application/indoor_model/feature_lifecycle'
require_relative '../indoor3d/application/indoor_model/editor_control'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class SelectedCellSpaceDemotionTest < Minitest::Test
        def setup
          Sketchup.demotion_test_active_model = FakeSketchupModel.new
        end

        def teardown
          Sketchup.demotion_test_active_model = nil
        end

        def test_keeps_geometry_and_removes_runtime_attributes_and_materials
          face = FakeFace.new('front', 'back')
          group = FakeGroup.new(face)
          cell_space = FakeCellSpace.new(group)
          subject = Harness.new(cell_space)

          assert subject.remove_selected_cell_spaces_indoor_gml_attributes

          assert group.valid?
          assert_equal [cell_space, false], subject.erased
          assert_empty group.attributes
          assert_nil group.material
          assert_nil face.material
          assert_nil face.back_material
          assert_equal [group], subject.scene_group_guard.untracked
          assert_equal [group.entityID], subject.primal_observer.untracked
          assert_empty subject.change_snapshots
          assert_equal 1, subject.editor_session.refresh_count
          assert_equal 1, subject.editor_session.selection_count
          assert_equal 1, subject.lock_policy_count
          assert_equal 1, Sketchup.active_model.active_view.invalidate_count
        end

        def test_restores_runtime_when_attribute_dictionary_cannot_be_cleared
          group = FakeGroup.new(FakeFace.new(nil, nil))
          cell_space = FakeCellSpace.new(group)
          subject = Harness.new(cell_space, clear_attributes: false)

          refute subject.remove_selected_cell_spaces_indoor_gml_attributes

          assert_equal :runtime_snapshot, subject.restored_snapshot
          refute_empty group.attributes
          assert_empty subject.primal_observer.untracked
        end

        class Harness
          include IndoorModel::FeatureLifecycle
          include IndoorModel::EditorControl

          attr_reader :erased, :change_snapshots,
                      :editor_session, :lock_policy_count, :restored_snapshot

          def scene_group_guard
            @scene_group_guard
          end

          def primal_observer
            @primal_entities_observer
          end

          def change_snapshots
            @cell_space_change_snapshots
          end

          def initialize(cell_space, clear_attributes: true)
            @selected_cell_spaces = [cell_space]
            @clear_attributes = clear_attributes
            @attribute_serializer = FakeSerializer.new(clear_attributes)
            @scene_group_guard = FakeSceneGuard.new
            @primal_entities_observer = FakePrimalObserver.new
            @cell_space_change_snapshots = { cell_space.sketchup_group.object_id => :snapshot }
            @editor_session = FakeEditorSession.new
            @lock_policy_count = 0
          end

          def validation_focus_recheck_running?
            false
          end

          def validation_focus_active?
            false
          end

          def selected_cell_spaces
            @selected_cell_spaces
          end

          def confirm_selected_cell_space_demotion(_count)
            true
          end

          def bulk_conversion_runtime_snapshot
            :runtime_snapshot
          end

          def restore_bulk_conversion_runtime(snapshot)
            @restored_snapshot = snapshot
          end

          def with_validation_focus_mutation_batch
            yield
          end

          def with_indoor_model_operation(_name)
            yield
          end

          def sync
            yield
          end

          def erase_cell_space(cell_space, erase_sketchup_group: true)
            @erased = [cell_space, erase_sketchup_group]
          end

          def unlock_indoor_entity(_group)
            true
          end

          def apply_indoor_lock_policy
            @lock_policy_count += 1
          end

          def entity_observer_key(group)
            group.object_id
          end
        end

        class FakeSerializer
          def initialize(clear_attributes)
            @clear_attributes = clear_attributes
          end

          def clear_indoor_gml_attributes(group)
            group.attributes.clear if @clear_attributes
            @clear_attributes
          end
        end

        class FakeSceneGuard
          attr_reader :untracked

          def initialize
            @untracked = []
          end

          def untrack(group)
            @untracked << group
          end
        end

        class FakePrimalObserver
          attr_reader :untracked

          def initialize
            @untracked = []
          end

          def untrack_entity_id(entity_id)
            @untracked << entity_id
          end
        end

        class FakeEditorSession
          attr_reader :refresh_count, :selection_count

          def initialize
            @refresh_count = 0
            @selection_count = 0
          end

          def refresh_visibility_filter
            @refresh_count += 1
          end

          def selection_changed
            @selection_count += 1
          end
        end

        class FakeSketchupModel
          attr_reader :active_view

          def initialize
            @active_view = Struct.new(:invalidate_count) do
              def invalidate
                self.invalidate_count += 1
              end
            end.new(0)
          end
        end

        class FakeCellSpace
          attr_reader :sketchup_group

          def initialize(group)
            @sketchup_group = group
          end

          def valid?
            @sketchup_group.valid?
          end
        end

        class FakeGroup
          attr_accessor :material
          attr_reader :attributes, :entityID

          def initialize(face)
            @valid = true
            @material = 'cell-space-material'
            @attributes = { 'feature' => 'CellSpace', 'id' => 'cell-1' }
            @entityID = 101
            @definition = FakeDefinition.new([face])
          end

          def valid?
            @valid
          end

          def definition
            @definition
          end

          def attribute_dictionary(name)
            return nil unless name == AttributeSerializer::ATTRIBUTE_DICTIONARY_NAME

            @attributes
          end
        end

        class FakeDefinition
          attr_reader :entities

          def initialize(faces)
            @entities = FakeEntities.new(faces)
          end

          def valid?
            true
          end
        end

        class FakeEntities
          def initialize(faces)
            @faces = faces
          end

          def grep(klass)
            klass == Sketchup::Face ? @faces : []
          end
        end

        class FakeFace < Sketchup::Face
          attr_accessor :material, :back_material

          def initialize(material, back_material)
            @material = material
            @back_material = back_material
          end
        end
      end
    end
  end
end
