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
require_relative '../indoor3d/ui/commands/conversion_message_formatter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionTest < Minitest::Test
        def setup
          transformation = ULOL::Indoor3DGmlModeler::Utils::Transformation
          @original_entity_transformation_in_active_context =
            if transformation.respond_to?(:entity_transformation_in_active_context)
              transformation.method(:entity_transformation_in_active_context)
            end
          transformation.define_singleton_method(:entity_transformation_in_active_context) do |entity|
            entity.context_transformation
          end
        end

        def teardown
          transformation = ULOL::Indoor3DGmlModeler::Utils::Transformation
          if @original_entity_transformation_in_active_context
            original = @original_entity_transformation_in_active_context
            transformation.define_singleton_method(:entity_transformation_in_active_context) do |*args|
              original.call(*args)
            end
          else
            singleton_class = class << transformation; self; end
            singleton_class.remove_method(:entity_transformation_in_active_context) if singleton_class.method_defined?(:entity_transformation_in_active_context)
          end
        end

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

        def test_job_builder_preserves_world_transform_for_active_context_nested_selection
          parent_transform = FakeTransformation.new(['parent_world'])
          child_transform = FakeTransformation.new(['child_local'])
          child = FakeGroup.new(manifold: true, transformation: child_transform)
          parent = FakeGroup.new(
            children: [child],
            context_transformation: parent_transform
          )

          jobs = CellSpaceConversionJobBuilder.new(
            entities: [child],
            ancestors: [parent]
          ).build

          assert_equal 1, jobs.length
          assert_equal parent_transform * child_transform, jobs.first[:transformation]
          assert_equal [0], jobs.first[:source_path_indices]
        end

        def test_job_builder_marks_shared_definition_nested_sources_for_instance_isolation
          child = FakeGroup.new(manifold: true)
          shared_definition = FakeDefinition.new([child])
          parent_a = FakeGroup.new(definition: shared_definition, context_transformation: FakeTransformation.new(['parent_a']))
          parent_b = FakeGroup.new(definition: shared_definition, context_transformation: FakeTransformation.new(['parent_b']))

          jobs = CellSpaceConversionJobBuilder.new(entities: [parent_a, parent_b]).build

          assert_equal 2, jobs.length
          assert_equal [child, child], jobs.map { |job| job[:source] }
          assert_equal [[0], [0]], jobs.map { |job| job[:source_path_indices] }
          assert_equal [true, true], jobs.map { |job| job[:requires_instance_isolation] }
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

        def test_executor_uses_prepared_label_when_source_is_deleted_before_error_reporting
          source = FakeGroup.new(manifold: true, name: 'Deleted Source', entity_id: 77)
          executor = CellSpaceConversionExecutor.new(
            target_entities: FakeTargetEntities.new,
            converter: proc do |group, _cell_type, _category_code|
              group.erase!
              raise 'failed after erase'
            end,
            preserve_source: proc { |_group| true },
            logger: FakeLogger.new,
            labeler: proc do |entity|
              raise 'label touched deleted source' unless entity.valid?

              entity.name
            end
          )

          result = executor.execute(
            job_for(source, source_label: 'Deleted Source (entity 77)'),
            fallback_target: [:general, nil]
          )

          refute result.converted?
          assert_equal [{ group: 'Deleted Source (entity 77)', reason: 'failed after erase' }], result.errors
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

        def test_executor_isolates_shared_definition_nested_source_before_erasing_original
          shared_child = FakeGroup.new(manifold: true, name: 'Nested Source')
          shared_definition = FakeDefinition.new([shared_child])
          parent_a = FakeGroup.new(definition: shared_definition, name: 'Parent A')
          parent_b = FakeGroup.new(definition: shared_definition, name: 'Parent B')
          converted = []
          target_entities = FakeTargetEntities.new
          executor = CellSpaceConversionExecutor.new(
            target_entities: target_entities,
            converter: proc { |group, cell_type, category_code| converted << [group, cell_type, category_code] },
            logger: FakeLogger.new
          )

          result = executor.execute(
            job_for(
              shared_child,
              ancestors: [parent_a],
              source_path_indices: [0],
              requires_instance_isolation: true,
              target: [:room, 'Room']
            ),
            fallback_target: [:general, nil]
          )

          assert result.converted?
          refute shared_child.erased?
          refute_same shared_definition, parent_a.definition
          assert_same shared_definition, parent_b.definition
          assert parent_a.definition.entities.to_a.first.erased?
          refute parent_b.definition.entities.to_a.first.erased?
          assert_equal [[target_entities.last_copy, :room, 'Room']], converted
        end

        def test_executor_resolves_isolated_source_by_signature_when_make_unique_reorders_definition
          shared_child = FakeGroup.new(manifold: true, name: 'Nested Source')
          shared_definition = FakeReorderedDefinition.new([shared_child])
          parent_a = FakeGroup.new(definition: shared_definition, name: 'Parent A')
          parent_b = FakeGroup.new(definition: shared_definition, name: 'Parent B')
          target_entities = FakeTargetEntities.new
          converted = []
          executor = CellSpaceConversionExecutor.new(
            target_entities: target_entities,
            converter: proc { |group, _cell_type, _category_code| converted << group },
            logger: FakeLogger.new
          )

          result = executor.execute(
            job_for(
              shared_child,
              ancestors: [parent_a],
              source_path_indices: [0],
              source_signature: {
                class_name: shared_child.class.name.to_s,
                name: shared_child.name,
                transformation: shared_child.transformation
              },
              requires_instance_isolation: true
            ),
            fallback_target: [:general, nil]
          )

          assert result.converted?
          assert_equal [target_entities.last_copy], converted
          refute shared_child.erased?
          assert parent_a.definition.entities.to_a[1].erased?
          refute parent_b.definition.entities.to_a.first.erased?
        end

        def test_bulk_service_uses_one_synchronous_operation_without_timer
          UI.timers = []
          calls = []
          model = FakeOperationModel.new(calls: calls)
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true)), job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            synchronize_all: proc { calls << :synchronize_all; { pair_comparison_count: 1, total_duration: 0.01 } },
            apply_lock_policy: proc { calls << :apply_lock_policy },
            clear_dirty_topology: proc { calls << :clear_dirty_topology },
            restore_active_path: proc { calls << :restore_active_path },
            activate_root_context: proc { calls << :activate_root_context; true }
          )

          result = service.call

          assert_equal 2, result.converted_count
          assert_equal [[:start, 'Bulk Convert', true], [:commit]], model.operations
          assert_empty UI.timers
          assert_equal [
            :activate_root_context,
            :start_operation,
            :convert,
            :convert,
            :synchronize_all,
            :apply_lock_policy,
            :clear_dirty_topology,
            :commit_operation,
            :restore_active_path
          ], calls
          assert_equal 1, result.metrics[:pair_comparison_count]
        end

        def test_bulk_service_skips_jobs_without_cell_type_and_converts_remaining_jobs
          calls = []
          model = FakeOperationModel.new(calls: calls)
          missing_target = FakeGroup.new(manifold: true, name: 'Missing Target')
          valid_target = FakeGroup.new(manifold: true, name: 'Valid Target')
          service = bulk_service(
            model: model,
            fallback_target: [nil, nil],
            jobs: [
              job_for(missing_target),
              job_for(valid_target, target: [:room, 'Room'])
            ],
            converter: proc do |source, cell_type, category_code|
              calls << [:convert, source.name, cell_type, category_code]
            end,
            synchronize_all: proc { calls << :synchronize_all; {} },
            apply_lock_policy: proc { calls << :apply_lock_policy },
            clear_dirty_topology: proc { calls << :clear_dirty_topology },
            restore_active_path: proc { calls << :restore_active_path }
          )

          result = service.call

          assert_equal 1, result.converted_count
          assert_equal [{ group: 'Missing Target', reason: 'CellSpace type is required' }], result.errors
          assert_equal [[:start, 'Bulk Convert', true], [:commit]], model.operations
          assert_equal [
            :start_operation,
            [:convert, 'Valid Target', :room, 'Room'],
            :synchronize_all,
            :apply_lock_policy,
            :clear_dirty_topology,
            :commit_operation,
            :restore_active_path
          ], calls
        end

        def test_bulk_service_reports_preflight_errors_without_starting_operation
          calls = []
          model = FakeOperationModel.new(calls: calls)
          missing_target = FakeGroup.new(manifold: true, name: 'Missing Target')
          service = bulk_service(
            model: model,
            fallback_target: [nil, nil],
            jobs: [job_for(missing_target)],
            converter: proc { |_source, _cell_type, _category_code| calls << :convert }
          )

          result = service.call

          assert_equal 0, result.converted_count
          assert_equal [{ group: 'Missing Target', reason: 'CellSpace type is required' }], result.errors
          assert_empty model.operations
          assert_empty calls
        end

        def test_bulk_service_reports_prepared_label_when_source_is_deleted_before_apply
          calls = []
          model = FakeOperationModel.new(calls: calls)
          source = FakeGroup.new(manifold: true, name: 'Transient Source', entity_id: 42)
          service = bulk_service(
            model: model,
            jobs: [job_for(source)],
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            activate_root_context: proc { calls << :activate_root_context; source.erase!; true },
            restore_active_path: proc { calls << :restore_active_path }
          )

          result = service.call

          assert_equal 0, result.converted_count
          assert_equal [{ group: 'Transient Source', reason: 'Conversion source is no longer valid' }], result.errors
          assert_equal [[:start, 'Bulk Convert', true], [:abort]], model.operations
          assert_equal [:activate_root_context, :start_operation, :abort_operation, :restore_active_path], calls
        end

        def test_bulk_service_converts_successful_jobs_and_reports_apply_failures
          calls = []
          model = FakeOperationModel.new(calls: calls)
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true)), job_for(FakeGroup.new(manifold: true))],
            converter: proc do |_source, _cell_type, _category_code|
              calls << (calls.include?(:convert_first) ? :convert_second : :convert_first)
              raise 'creation failed' if calls.include?(:convert_second)
            end,
            synchronize_all: proc { calls << :synchronize_all; { pair_comparison_count: 1, total_duration: 0.01 } },
            apply_lock_policy: proc { calls << :apply_lock_policy },
            clear_dirty_topology: proc { calls << :clear_dirty_topology },
            runtime_restore: proc { |_snapshot| calls << :runtime_restore },
            restore_active_path: proc { calls << :restore_active_path }
          )

          result = service.call

          assert_equal 1, result.converted_count
          assert_equal [{ group: 'source', reason: 'creation failed' }], result.errors
          assert_equal [[:start, 'Bulk Convert', true], [:commit]], model.operations
          assert_equal [
            :start_operation,
            :convert_first,
            :convert_second,
            :synchronize_all,
            :apply_lock_policy,
            :clear_dirty_topology,
            :commit_operation,
            :restore_active_path
          ], calls
        end

        def test_bulk_service_aborts_and_restores_runtime_when_commit_fails
          calls = []
          model = FakeOperationModel.new(commit_result: false, calls: calls)
          restored = []
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            synchronize_all: proc { calls << :synchronize_all; {} },
            runtime_restore: proc { |snapshot| calls << :runtime_restore; restored << snapshot },
            restore_active_path: proc { calls << :restore_active_path }
          )

          error = assert_raises(RuntimeError) { service.call }

          assert_equal 'Failed to commit CellSpace conversion operation', error.message
          assert_equal [[:start, 'Bulk Convert', true], [:commit], [:abort]], model.operations
          assert_equal [:runtime_snapshot], restored
          assert_equal [
            :start_operation,
            :convert,
            :synchronize_all,
            :commit_operation,
            :abort_operation,
            :runtime_restore,
            :restore_active_path
          ], calls
        end

        def test_bulk_service_returns_apply_error_when_active_path_restore_also_fails
          calls = []
          model = FakeOperationModel.new(calls: calls)
          restore_calls = 0
          logger = FakeLogger.new
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| raise 'creation failed' },
            runtime_restore: proc { |_snapshot| calls << :runtime_restore },
            restore_active_path: proc { calls << :restore_active_path; restore_calls += 1; raise 'restore failed' },
            logger: logger
          )

          result = service.call

          assert_equal 0, result.converted_count
          assert_equal [{ group: 'source', reason: 'creation failed' }], result.errors
          assert_equal 1, restore_calls
          assert_equal [[:start, 'Bulk Convert', true], [:abort]], model.operations
          assert_equal [:start_operation, :abort_operation, :runtime_restore, :restore_active_path], calls
          assert_includes logger.messages.join("\n"), 'Active path restore failed during CellSpace conversion rollback'
        end

        def test_bulk_service_returns_apply_error_when_abort_fails
          calls = []
          model = FakeOperationModel.new(calls: calls, abort_error: RuntimeError.new('abort failed'))
          logger = FakeLogger.new
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| raise 'creation failed' },
            runtime_restore: proc { |_snapshot| calls << :runtime_restore },
            restore_active_path: proc { calls << :restore_active_path },
            logger: logger
          )

          result = service.call

          assert_equal 0, result.converted_count
          assert_equal [{ group: 'source', reason: 'creation failed' }], result.errors
          assert_equal [[:start, 'Bulk Convert', true], [:abort]], model.operations
          assert_equal [:start_operation, :abort_operation, :runtime_restore, :restore_active_path], calls
          assert_includes logger.messages.join("\n"), 'CellSpace conversion abort failed: RuntimeError: abort failed'
        end

        def test_bulk_service_returns_apply_error_when_runtime_restore_fails
          calls = []
          model = FakeOperationModel.new(calls: calls)
          logger = FakeLogger.new
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| raise 'creation failed' },
            runtime_restore: proc { |_snapshot| calls << :runtime_restore; raise 'runtime restore failed' },
            restore_active_path: proc { calls << :restore_active_path },
            logger: logger
          )

          result = service.call

          assert_equal 0, result.converted_count
          assert_equal [{ group: 'source', reason: 'creation failed' }], result.errors
          assert_equal [[:start, 'Bulk Convert', true], [:abort]], model.operations
          assert_equal [:start_operation, :abort_operation, :runtime_restore, :restore_active_path], calls
          assert_includes logger.messages.join("\n"), 'CellSpace conversion runtime restore failed: RuntimeError: runtime restore failed'
        end

        def test_bulk_service_does_not_abort_when_active_path_restore_fails_after_commit
          calls = []
          model = FakeOperationModel.new(calls: calls)
          logger = FakeLogger.new
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            runtime_restore: proc { |_snapshot| calls << :runtime_restore },
            restore_active_path: proc { calls << :restore_active_path; raise 'restore failed' },
            logger: logger
          )

          result = service.call

          assert_equal 1, result.converted_count
          assert_equal [[:start, 'Bulk Convert', true], [:commit]], model.operations
          assert_equal [:start_operation, :convert, :commit_operation, :restore_active_path], calls
          refute_includes calls, :runtime_restore
          assert_includes logger.messages.join("\n"), 'Active path restore failed after CellSpace conversion commit'
        end

        def test_bulk_service_does_not_convert_or_abort_when_start_operation_fails
          calls = []
          model = FakeOperationModel.new(calls: calls, start_result: false)
          restored = []
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            runtime_restore: proc { |snapshot| calls << :runtime_restore; restored << snapshot },
            restore_active_path: proc { calls << :restore_active_path }
          )

          error = assert_raises(RuntimeError) { service.call }

          assert_equal 'Failed to start CellSpace conversion operation', error.message
          assert_equal [[:start, 'Bulk Convert', true]], model.operations
          assert_equal [:start_operation, :runtime_restore, :restore_active_path], calls
          assert_equal [:runtime_snapshot], restored
        end

        def test_bulk_service_rejects_non_true_root_context_activation_result
          [false, nil, :not_true].each do |activation_result|
            calls = []
            model = FakeOperationModel.new(calls: calls)
            restored = []
            service = bulk_service(
              model: model,
              jobs: [job_for(FakeGroup.new(manifold: true))],
              activate_root_context: proc { calls << :activate_root_context; activation_result },
              converter: proc { |_source, _cell_type, _category_code| calls << :convert },
              synchronize_all: proc { calls << :synchronize_all; {} },
              apply_lock_policy: proc { calls << :apply_lock_policy },
              clear_dirty_topology: proc { calls << :clear_dirty_topology },
              runtime_restore: proc { |snapshot| calls << :runtime_restore; restored << snapshot },
              restore_active_path: proc { calls << :restore_active_path }
            )

            error = assert_raises(RuntimeError) { service.call }

            assert_equal 'Failed to activate root context for CellSpace conversion', error.message
            assert_empty model.operations
            assert_equal [:runtime_snapshot], restored
            assert_equal [:activate_root_context, :runtime_restore, :restore_active_path], calls
          end
        end

        def test_bulk_service_preserves_root_context_activation_exception
          calls = []
          model = FakeOperationModel.new(calls: calls)
          restored = []
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            activate_root_context: proc { calls << :activate_root_context; raise 'close failed' },
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            synchronize_all: proc { calls << :synchronize_all; {} },
            apply_lock_policy: proc { calls << :apply_lock_policy },
            clear_dirty_topology: proc { calls << :clear_dirty_topology },
            runtime_restore: proc { |snapshot| calls << :runtime_restore; restored << snapshot },
            restore_active_path: proc { calls << :restore_active_path }
          )

          error = assert_raises(RuntimeError) { service.call }

          assert_equal 'close failed', error.message
          assert_empty model.operations
          assert_equal [:runtime_snapshot], restored
          assert_equal [:activate_root_context, :runtime_restore, :restore_active_path], calls
        end

        def test_bulk_service_allows_missing_root_context_activation_callback
          calls = []
          model = FakeOperationModel.new(calls: calls)
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            activate_root_context: nil,
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            restore_active_path: proc { calls << :restore_active_path }
          )

          result = service.call

          assert_equal 1, result.converted_count
          assert_equal [[:start, 'Bulk Convert', true], [:commit]], model.operations
          assert_equal [:start_operation, :convert, :commit_operation, :restore_active_path], calls
        end

        def test_bulk_service_aborts_and_preserves_commit_exception
          calls = []
          model = FakeOperationModel.new(calls: calls, commit_error: RuntimeError.new('commit exploded'))
          service = bulk_service(
            model: model,
            jobs: [job_for(FakeGroup.new(manifold: true))],
            converter: proc { |_source, _cell_type, _category_code| calls << :convert },
            runtime_restore: proc { |_snapshot| calls << :runtime_restore },
            restore_active_path: proc { calls << :restore_active_path }
          )

          error = assert_raises(RuntimeError) { service.call }

          assert_equal 'commit exploded', error.message
          assert_equal [[:start, 'Bulk Convert', true], [:commit], [:abort]], model.operations
          assert_equal [:start_operation, :convert, :commit_operation, :abort_operation, :runtime_restore, :restore_active_path], calls
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

        def test_conversion_message_formatter_does_not_read_name_from_deleted_group
          group = Class.new do
            def valid?
              false
            end

            def name
              raise 'name should not be read for a deleted group'
            end

            def entityID
              314
            end
          end.new

          assert_equal 'deleted group (entity 314)', ConversionMessageFormatter.group_label(group)
        end

        private

        def job_for(source, target: nil, ancestors: [], source_label: nil, source_path_indices: [], source_signature: nil, requires_instance_isolation: false)
          {
            source: source,
            transformation: FakeTransformation.new(['job']),
            target: target,
            ancestors: ancestors,
            source_path_indices: source_path_indices,
            source_signature: source_signature,
            requires_instance_isolation: requires_instance_isolation
          }.tap do |job|
            job[:source_label] = source_label unless source_label.nil?
          end
        end

        def failing_converter
          proc { |_group, _cell_type, _category_code| raise 'not solid' }
        end

        def method_source(relative_path, method_name, next_method_name)
          source = File.read(File.expand_path("../#{relative_path}", __dir__))
          source[/def #{method_name}.*?^\s*def #{next_method_name}/m].sub(/^\s*def #{next_method_name}.*/m, '')
        end

        def bulk_service(model:, jobs:, fallback_target: [:general, nil], converter: proc { |_source, _cell_type, _category_code| true }, synchronize_all: proc { {} }, apply_lock_policy: proc {}, runtime_restore: proc { |_snapshot| }, restore_active_path: proc {}, activate_root_context: proc { true }, clear_dirty_topology: proc {}, logger: FakeLogger.new)
          BulkCellSpaceConversionService.new(
            model: model,
            jobs: jobs,
            fallback_target: fallback_target,
            target_entities: FakeTargetEntities.new,
            converter: converter,
            synchronize_all: synchronize_all,
            apply_lock_policy: apply_lock_policy,
            runtime_snapshot: proc { :runtime_snapshot },
            runtime_restore: runtime_restore,
            apply_guards: proc { |&block| block.call },
            restore_active_path: restore_active_path,
            activate_root_context: activate_root_context,
            clear_dirty_topology: clear_dirty_topology,
            logger: logger,
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
          attr_reader :items

          def initialize(entities)
            @items = entities
          end

          def to_a
            @items
          end

          def empty?
            @items.empty?
          end
        end

        class FakeDefinition
          attr_reader :entities, :instances

          def initialize(children)
            @entities = FakeEntityCollection.new(children)
            @instances = []
          end

          def valid?
            true
          end

          def duplicate
            self.class.new(@entities.to_a.map { |entity| entity.duplicate_for_definition })
          end
        end

        class FakeReorderedDefinition < FakeDefinition
          def duplicate
            self.class.new([FakeRawEntity.new] + entities.to_a.map { |entity| entity.duplicate_for_definition })
          end
        end

        class FakeRawEntity
          def valid?
            true
          end
        end

        class FakeGroup < Sketchup::Group
          attr_accessor :name, :material, :layer
          attr_reader :definition, :transformation, :context_transformation, :tag_target, :entityID

          def initialize(manifold: false, children: [], definition: nil, feature: nil, tag_target: nil, tag_assigned: false, transformation: FakeTransformation.new(['entity']), context_transformation: nil, name: 'source', entity_id: 1)
            @definition = definition || FakeDefinition.new(children)
            @definition.instances << self if @definition.respond_to?(:instances)
            @manifold = manifold
            @attributes = {}
            @attributes['feature'] = feature unless feature.nil?
            @tag_target = tag_target
            @tag_assigned = tag_assigned
            @transformation = transformation
            @context_transformation = context_transformation || transformation
            @name = name
            @entityID = entity_id
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

          def make_unique
            return self unless @definition.respond_to?(:duplicate)

            @definition.instances.delete(self) if @definition.respond_to?(:instances)
            @definition = @definition.duplicate
            @definition.instances << self if @definition.respond_to?(:instances)
            self
          end

          def duplicate_for_definition
            self.class.new(
              manifold: @manifold,
              children: @definition.entities.to_a.map { |entity| entity.duplicate_for_definition },
              feature: @attributes['feature'],
              tag_target: @tag_target,
              tag_assigned: @tag_assigned,
              transformation: @transformation,
              context_transformation: @context_transformation,
              name: @name,
              entity_id: @entityID
            )
          end
        end

        class FakeTargetEntities
          attr_reader :last_copy

          def add_instance(_definition, _transformation)
            @last_copy = FakeGroup.new(manifold: true, name: 'copy')
          end
        end

        class FakeOperationModel
          attr_reader :operations

          def initialize(commit_result: true, calls: nil, commit_error: nil, abort_error: nil, start_result: true)
            @commit_result = commit_result
            @commit_error = commit_error
            @abort_error = abort_error
            @start_result = start_result
            @calls = calls
            @operations = []
          end

          def start_operation(name, transparent)
            @operations << [:start, name, transparent]
            @calls << :start_operation if @calls
            @start_result
          end

          def commit_operation
            @operations << [:commit]
            @calls << :commit_operation if @calls
            raise @commit_error if @commit_error

            @commit_result
          end

          def abort_operation
            @operations << [:abort]
            @calls << :abort_operation if @calls
            raise @abort_error if @abort_error

            true
          end
        end
      end
    end
  end
end
