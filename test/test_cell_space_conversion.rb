# frozen_string_literal: true

require 'minitest/autorun'

module UI
  class << self
    attr_accessor :timers
  end

  def self.start_timer(interval, repeat, &block)
    self.timers ||= []
    timers << { interval: interval, repeat: repeat, block: block }
    true
  end
end

module Sketchup
  class Group; end unless const_defined?(:Group, false)
  class ComponentInstance; end unless const_defined?(:ComponentInstance, false)
end

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Transformation
        def self.entity_transformation_in_active_context(entity)
          entity.context_transformation
        end
      end
    end

    module IndoorCore
      class IndoorModel
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml' unless const_defined?(:ATTRIBUTE_DICTIONARY_NAME, false)
      end

      def self.tag_cell_space_type_and_category(entity)
        entity.respond_to?(:tag_target) ? entity.tag_target : nil
      end

      def self.tag_assigned?(entity)
        entity.respond_to?(:tag_assigned?) && entity.tag_assigned?
      end
    end
  end
end

require_relative '../indoor3d/infrastructure/scene/entity_copy_helper'
require_relative '../indoor3d/application/cell_space_conversion'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionTest < Minitest::Test
        def test_job_builder_collects_nested_solid_with_parent_target_and_cleanup_ancestor
          parent_target = [:room, 'Room']
          parent_transform = FakeTransformation.new(['parent'])
          child_transform = FakeTransformation.new(['child'])
          child = FakeGroup.new(manifold: true, transformation: child_transform)
          parent = FakeGroup.new(
            children: [child],
            tag_target: parent_target,
            context_transformation: parent_transform
          )

          jobs = CellSpaceConversionJobBuilder.new(entities: [parent]).build

          assert_equal 1, jobs.length
          assert_same child, jobs.first[:source]
          assert_equal parent_transform * child_transform, jobs.first[:transformation]
          assert_equal [parent], jobs.first[:ancestors]
          assert_equal parent_target, jobs.first[:target]
        end

        def test_job_builder_skips_existing_cell_spaces_and_prefers_entity_target
          existing = FakeGroup.new(manifold: true, feature: 'CellSpace')
          door_target = [:transition, 'Door']
          door = FakeGroup.new(manifold: true, tag_target: door_target)

          jobs = CellSpaceConversionJobBuilder.new(
            entities: [existing, door],
            parent_target: [:room, 'Room'],
            ancestors: []
          ).build

          assert_equal [door], jobs.map { |job| job[:source] }
          assert_equal door_target, jobs.first[:target]
        end

        def test_executor_keeps_preserved_source_when_conversion_fails
          source = FakeGroup.new(manifold: true, name: 'EditMode Solid')
          executor = CellSpaceConversionExecutor.new(
            target_entities: FakeTargetEntities.new,
            converter: failing_converter,
            preserve_source: proc { |_group| true },
            logger: FakeLogger.new,
            labeler: proc { |entity| entity.name }
          )

          result = executor.execute(job_for(source), fallback_target: [:general, nil])

          refute result.converted?
          refute source.erased?
          assert_equal [{ group: 'EditMode Solid', reason: 'not solid' }], result.errors
        end

        def test_executor_removes_copy_but_keeps_original_when_conversion_fails
          source = FakeGroup.new(manifold: true)
          target_entities = FakeTargetEntities.new
          executor = CellSpaceConversionExecutor.new(
            target_entities: target_entities,
            converter: failing_converter,
            logger: FakeLogger.new
          )

          result = executor.execute(job_for(source), fallback_target: [:general, nil])

          refute result.converted?
          refute source.erased?
          assert target_entities.last_copy.erased?
        end

        def test_executor_erases_original_only_after_copied_conversion_succeeds
          source = FakeGroup.new(manifold: true)
          target_entities = FakeTargetEntities.new
          converted = []
          executor = CellSpaceConversionExecutor.new(
            target_entities: target_entities,
            converter: proc { |group, cell_type, category_code| converted << [group, cell_type, category_code] },
            logger: FakeLogger.new
          )

          result = executor.execute(job_for(source, target: [:room, 'Room']), fallback_target: [:general, nil])

          assert result.converted?
          assert source.erased?
          refute target_entities.last_copy.erased?
          assert_equal [[target_entities.last_copy, :room, 'Room']], converted
        end

        def test_executor_keeps_preserved_source_after_success
          source = FakeGroup.new(manifold: true)
          executor = CellSpaceConversionExecutor.new(
            target_entities: FakeTargetEntities.new,
            converter: proc { |_group, _cell_type, _category_code| true },
            preserve_source: proc { |_group| true },
            logger: FakeLogger.new
          )

          result = executor.execute(job_for(source), fallback_target: [:general, nil])

          assert result.converted?
          refute source.erased?
        end

        def test_bulk_service_uses_one_synchronous_operation_without_timer
          UI.timers = []
          model = FakeOperationModel.new
          calls = []
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true)), job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            synchronize_all: proc { calls << :synchronize_all; { pair_comparison_count: 1, total_duration: 0.01 } },
            apply_lock_policy: proc { calls << :apply_lock_policy }
          )

          result = service.call

          assert_equal 2, result.converted_count
          assert_equal [[:start, 'Bulk Convert', true], [:commit]], model.operations
          assert_empty UI.timers
          assert_equal [:convert, :convert, :synchronize_all, :apply_lock_policy], calls
          assert_equal 1, result.metrics[:pair_comparison_count]
        end

        def test_bulk_service_aborts_once_and_restores_runtime_when_apply_fails
          model = FakeOperationModel.new
          restored = []
          calls = []
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true)), job_for(FakeGroup.new(manifold: true))],
            converter: proc do |_source, _cell_type, _category_code|
              calls << :convert
              raise 'creation failed' if calls.length == 2
            end,
            runtime_restore: proc { |snapshot| restored << snapshot }
          )

          error = assert_raises(RuntimeError) { service.call }

          assert_equal 'creation failed', error.message
          assert_equal [[:start, 'Bulk Convert', true], [:abort]], model.operations
          assert_equal [:runtime_snapshot], restored
        end

        def test_bulk_service_aborts_and_restores_runtime_when_commit_fails
          model = FakeOperationModel.new(commit_result: false)
          restored = []
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            runtime_restore: proc { |snapshot| restored << snapshot }
          )

          error = assert_raises(RuntimeError) { service.call }

          assert_equal 'Failed to commit CellSpace conversion operation', error.message
          assert_equal [[:start, 'Bulk Convert', true], [:commit], [:abort]], model.operations
          assert_equal [:runtime_snapshot], restored
        end

        def test_bulk_service_keeps_original_error_when_active_path_restore_also_fails
          model = FakeOperationModel.new
          restore_calls = 0
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| raise 'creation failed' },
            restore_active_path: proc { restore_calls += 1; raise 'restore failed' }
          )

          error = assert_raises(RuntimeError) { service.call }

          assert_equal 'creation failed', error.message
          assert_equal 1, restore_calls
          assert_equal [[:start, 'Bulk Convert', true], [:abort]], model.operations
        end

        def test_multi_conversion_entrypoints_do_not_use_run_batched
          toolbar_method = method_source('indoor3d/ui/commands/cell_space_commands.rb', 'convert_selected_solid_groups_to_cell_spaces', 'change_selected_cell_space_type')
          edit_mode_method = method_source('indoor3d/application/indoor_model/editor_control.rb', 'convert_selected_solid_groups_to_cell_spaces', 'set_selected_cell_space_type')

          assert_includes toolbar_method, 'convert_cell_space_jobs_bulk'
          assert_includes edit_mode_method, 'convert_cell_space_jobs_bulk'
          refute_includes toolbar_method, 'run_batched'
          refute_includes edit_mode_method, 'run_batched'
          refute_includes toolbar_method, 'start_operation'
          refute_includes edit_mode_method, 'start_operation'
        end

        private

        def job_for(source, target: nil, ancestors: [])
          {
            source: source,
            transformation: FakeTransformation.new(['job']),
            target: target,
            ancestors: ancestors
          }
        end

        def failing_converter
          proc { |_group, _cell_type, _category_code| raise 'not solid' }
        end

        def method_source(relative_path, method_name, next_method_name)
          source = File.read(File.expand_path("../#{relative_path}", __dir__))
          source[/def #{method_name}.*?^\s*def #{next_method_name}/m].sub(/^\s*def #{next_method_name}.*/m, '')
        end

        def bulk_service(model:, jobs:, converter: proc { |_source, _cell_type, _category_code| true }, synchronize_all: proc { {} }, apply_lock_policy: proc {}, runtime_restore: proc { |_snapshot| }, restore_active_path: proc {})
          BulkCellSpaceConversionService.new(
            model: model,
            jobs: jobs,
            fallback_target: [:general, nil],
            target_entities: FakeTargetEntities.new,
            converter: converter,
            synchronize_all: synchronize_all,
            apply_lock_policy: apply_lock_policy,
            runtime_snapshot: proc { :runtime_snapshot },
            runtime_restore: runtime_restore,
            apply_guards: proc { |&block| block.call },
            restore_active_path: restore_active_path,
            activate_root_context: proc {},
            clear_dirty_topology: proc {},
            progress: BulkCellSpaceConversionProgress.new(
              start: proc { |_total, _message| },
              update: proc { |_current, _message| },
              finish: proc {}
            ),
            logger: FakeLogger.new,
            labeler: proc { |entity| entity.respond_to?(:name) ? entity.name : 'entity' },
            preserve_source: proc { |_source| true },
            operation_name: 'Bulk Convert'
          )
        end

        class FakeLogger
          attr_reader :messages

          def initialize
            @messages = []
          end

          def puts(message)
            @messages << message
          end
        end

        class FakeTransformation
          attr_reader :steps

          def initialize(steps)
            @steps = Array(steps)
          end

          def *(other)
            self.class.new(steps + other.steps)
          end

          def ==(other)
            other.is_a?(self.class) && steps == other.steps
          end
        end

        class FakeEntityCollection
          def initialize(entities)
            @entities = entities
          end

          def to_a
            @entities
          end
        end

        class FakeDefinition
          attr_reader :entities

          def initialize(children)
            @entities = FakeEntityCollection.new(children)
          end

          def valid?
            true
          end
        end

        class FakeGroup < Sketchup::Group
          attr_accessor :name, :material, :layer
          attr_reader :definition, :transformation, :context_transformation, :tag_target

          def initialize(manifold: false, children: [], feature: nil, tag_target: nil, tag_assigned: false, transformation: FakeTransformation.new(['entity']), context_transformation: nil, name: 'source')
            @definition = FakeDefinition.new(children)
            @manifold = manifold
            @attributes = {}
            @attributes['feature'] = feature unless feature.nil?
            @tag_target = tag_target
            @tag_assigned = tag_assigned
            @transformation = transformation
            @context_transformation = context_transformation || transformation
            @name = name
            @visible = true
            @valid = true
            @erased = false
          end

          def valid?
            @valid == true
          end

          def erased?
            @erased == true
          end

          def erase!
            @erased = true
            @valid = false
          end

          def manifold?
            @manifold == true
          end

          def tag_assigned?
            @tag_assigned == true
          end

          def get_attribute(_dictionary, key)
            @attributes[key]
          end

          def visible?
            @visible == true
          end

          def visible=(value)
            @visible = value == true
          end

          def to_group
            self
          end

          def make_unique; end
        end

        class FakeTargetEntities
          attr_reader :last_copy

          def add_instance(_definition, _transformation)
            @last_copy = FakeGroup.new(manifold: true, name: 'copy')
          end
        end

        class FakeOperationModel
          attr_reader :operations

          def initialize(commit_result: true)
            @commit_result = commit_result
            @operations = []
          end

          def start_operation(name, transparent)
            @operations << [:start, name, transparent]
            true
          end

          def commit_operation
            @operations << [:commit]
            @commit_result
          end

          def abort_operation
            @operations << [:abort]
            true
          end
        end
      end
    end
  end
end
