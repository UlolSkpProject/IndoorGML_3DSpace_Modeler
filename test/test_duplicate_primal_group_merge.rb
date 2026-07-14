# frozen_string_literal: true

require 'minitest/autorun'

class Numeric
  def mm
    self
  end unless method_defined?(:mm)
end

module Sketchup
  class Group; end unless const_defined?(:Group)
  class ConstructionPoint; end unless const_defined?(:ConstructionPoint)

  class << self
    attr_accessor :test_active_model

    def active_model
      @test_active_model
    end
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures' unless const_defined?(:PRIMAL_GROUP_NAME)
        PRIMAL_GROUP_FEATURE = 'primalspace' unless const_defined?(:PRIMAL_GROUP_FEATURE)
      end

      module Utils
        module Materials
          def self.ensure_all; end
        end
      end

      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/infrastructure/scene/entity_copy_helper'
require_relative '../indoor3d/application/indoor_model/scene_groups'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DuplicatePrimalGroupMergeTest < Minitest::Test
        def setup
          @model = FakeModel.new
          Sketchup.test_active_model = @model
        end

        def teardown
          Sketchup.test_active_model = nil
        end

        def test_ensure_merges_duplicate_cell_spaces_into_current_canonical_group
          canonical = primal_group('canonical', transform: transform('canonical'))
          duplicate = primal_group('duplicate', transform: transform('duplicate'))
          cell = cell_group(duplicate, 'cell_A', transform: transform('child'))
          raw = duplicate.entities.add_group('raw geometry', transformation: transform('raw'))
          model = Harness.new(@model, primal_group: canonical)

          result = model.ensure_groups

          assert_same canonical, result
          assert_same canonical, model.primal_group
          assert_equal [canonical], model.primal_candidates
          refute duplicate.valid?
          refute cell.valid?
          refute raw.valid?
          copied = canonical.entities.to_a.find { |entity| entity.attribute('feature') == 'CellSpace' }
          refute_nil copied
          assert_equal 'cell_A', copied.attribute('id')
          assert_equal transform('canonical').inverse * transform('duplicate') * transform('child'), copied.transformation
          assert_equal 1, model.refresh_count
        end

        def test_register_keeps_existing_canonical_and_merges_new_primal_group
          canonical = primal_group('canonical')
          duplicate = primal_group('duplicate')
          cell_group(duplicate, 'cell_B')
          model = Harness.new(@model, primal_group: canonical)

          model.register_primal(duplicate)

          assert_same canonical, model.primal_group
          assert_equal [canonical], model.primal_candidates
          assert_equal ['cell_B'], canonical.entities.to_a.filter_map { |child| child.attribute('id') }
          assert_equal 1, model.refresh_count
        end

        def test_find_existing_merges_duplicates_before_runtime_restore_continues
          canonical = primal_group(IndoorModel::PRIMAL_GROUP_NAME)
          duplicate = primal_group('duplicate')
          cell_group(duplicate, 'cell_C')
          model = Harness.new(@model)

          assert model.find_groups

          assert_same canonical, model.primal_group
          assert_equal [canonical], model.primal_candidates
          assert_equal ['cell_C'], canonical.entities.to_a.filter_map { |child| child.attribute('id') }
          assert_equal 0, model.refresh_count
        end

        def test_canonical_selection_prefers_named_feature_then_feature_then_name_fallback
          name_only = @model.entities.add_group(IndoorModel::PRIMAL_GROUP_NAME)
          feature_only = primal_group('feature only')
          named_feature = primal_group(IndoorModel::PRIMAL_GROUP_NAME)
          model = Harness.new(@model)

          canonical = model.resolve_canonical

          assert_same named_feature, canonical
          refute_same feature_only, canonical
          refute_same name_only, canonical
        end

        def test_merge_mutations_run_while_space_features_guard_is_active
          canonical = primal_group('canonical')
          duplicate = primal_group('duplicate')
          cell_group(duplicate, 'cell_A')
          guard_states = []
          @model.entities.mutation_probe = proc { |active| guard_states << active }
          canonical.entities.mutation_probe = proc { |active| guard_states << active }
          duplicate.entities.mutation_probe = proc { |active| guard_states << active }
          model = Harness.new(@model, primal_group: canonical)
          @model.entities.guard_reader = proc { model.merging? }
          canonical.entities.guard_reader = proc { model.merging? }
          duplicate.entities.guard_reader = proc { model.merging? }

          model.ensure_groups

          refute_empty guard_states
          assert guard_states.all?
        end

        def test_failed_child_copy_removes_partial_copies_and_keeps_duplicate_source
          canonical = primal_group('canonical')
          duplicate = primal_group('duplicate')
          first = cell_group(duplicate, 'cell_A')
          second = cell_group(duplicate, 'cell_B')
          canonical.entities.fail_add_instance_at = 2
          model = Harness.new(@model, primal_group: canonical)

          assert_raises(RuntimeError) { model.ensure_groups }

          assert duplicate.valid?
          assert first.valid?
          assert second.valid?
          assert_empty canonical.entities.to_a.select { |child| child.attribute('feature') == 'CellSpace' }
          assert_equal 0, model.refresh_count
        end

        private

        def primal_group(name, transform: transform('identity'))
          group = @model.entities.add_group(name, transformation: transform)
          group.set_attribute('feature', IndoorModel::PRIMAL_GROUP_FEATURE)
          group
        end

        def cell_group(parent, id, transform: transform('identity'))
          group = parent.entities.add_group("cell_#{id}", transformation: transform)
          group.set_attribute('feature', 'CellSpace')
          group.set_attribute('id', id)
          group.set_attribute('duality_state_id', "state_#{id}")
          group
        end

        def transform(value)
          FakeTransformation.new(value)
        end

        class Harness
          include IndoorModel::SceneGroups

          attr_reader :primal_group, :refresh_count

          def initialize(model, primal_group: nil)
            @model = model
            @primal_group = primal_group
            @refresh_count = 0
            @cell_space_observed_ids = {}
            @cell_space_change_snapshots = {}
            @space_features_observed_ids = {}
            @space_features_change_snapshots = {}
            @entities_observed_ids = {}
            @scene_group_guard = FakeSceneGroupGuard.new
          end

          def ensure_groups
            send(:ensure_space_features_groups)
          end

          def register_primal(group)
            send(:register_space_features_entity, group, IndoorModel::PRIMAL_GROUP_FEATURE)
          end

          def find_groups
            send(:find_existing_space_features_groups)
          end

          def resolve_canonical
            candidates = send(:primal_group_candidates, @model.entities)
            send(:canonical_primal_group, @model.entities, candidates)
          end

          def primal_candidates
            send(:primal_group_candidates, @model.entities)
          end

          def merging?
            @merging_space_features == true
          end

          private

          def with_indoor_model_operation(_name, transparent: false)
            yield
          end

          def with_guard_flag(flag)
            previous = instance_variable_get(flag)
            instance_variable_set(flag, true)
            yield
          ensure
            instance_variable_set(flag, previous)
          end

          def guard_active?(flag)
            instance_variable_get(flag) == true
          end

          def indoor_feature(entity)
            entity.attribute('feature')
          end

          def copy_indoor_attributes(source, target)
            source.attributes.each { |key, value| target.set_attribute(key, value) }
          end

          def write_space_features_attributes(group, feature)
            group.set_attribute('feature', feature)
          end

          def attach_space_features_observer(*)
            true
          end

          def ensure_space_features_origin_point(*)
            true
          end

          def attach_entities_observers
            true
          end

          def attach_entities_observer(*)
            true
          end

          def refresh_runtime_data
            @refresh_count += 1
            true
          end

          def entity_observer_key(entity)
            entity.object_id
          end

          def delete_entity_observer_key(values, entity)
            values.delete(entity_observer_key(entity))
          end
        end

        class FakeSceneGroupGuard
          def track(*); end

          def untrack(*); end
        end

        class FakeModel
          attr_reader :entities

          def initialize
            @entities = FakeEntities.new
          end
        end

        class FakeEntities
          attr_accessor :mutation_probe, :guard_reader, :fail_add_instance_at

          def initialize
            @items = []
            @add_instance_count = 0
          end

          def add_group(name = '', transformation: FakeTransformation.new('identity'))
            add(FakeGroup.new(self, name: name, transformation: transformation))
          end

          def add_instance(definition, transformation)
            @add_instance_count += 1
            raise 'copy failed' if @fail_add_instance_at == @add_instance_count

            add(FakeGroup.new(self, definition: definition, transformation: transformation))
          end

          def add(group)
            @items << group
            @mutation_probe&.call(@guard_reader&.call)
            group
          end

          def delete(group)
            @items.delete(group)
            @mutation_probe&.call(@guard_reader&.call)
          end

          def add_cpoint(*)
            nil
          end

          def grep(klass)
            @items.grep(klass)
          end

          def to_a
            @items.dup
          end
        end

        class FakeGroup < Sketchup::Group
          attr_accessor :name, :material, :layer
          attr_reader :entities, :definition, :transformation, :attributes

          def initialize(parent_entities, name: '', transformation: FakeTransformation.new('identity'), definition: nil)
            @parent_entities = parent_entities
            @name = name
            @transformation = transformation
            @definition = definition || FakeDefinition.new
            @entities = FakeEntities.new
            @attributes = {}
            @valid = true
            @visible = true
          end

          def valid?
            @valid == true
          end

          def set_attribute(key, value)
            @attributes[key] = value
          end

          def attribute(key)
            @attributes[key]
          end

          def erase!
            @valid = false
            @entities.to_a.each(&:erase!)
            @parent_entities.delete(self)
            true
          end

          def to_group
            self
          end

          def make_unique
            @definition = FakeDefinition.new
          end

          def visible?
            @visible == true
          end

          def visible=(value)
            @visible = value == true
          end
        end

        class FakeDefinition
          def valid?
            true
          end
        end

        class FakeTransformation
          attr_reader :value

          def initialize(value)
            @value = value
          end

          def inverse
            self.class.new("inverse(#{value})")
          end

          def *(other)
            self.class.new("#{value}*#{other.value}")
          end

          def ==(other)
            other.is_a?(self.class) && other.value == value
          end
        end
      end
    end
  end
end
