# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      Tag = Struct.new(:name) unless const_defined?(:Tag, false)

      class IndoorModel
        attr_reader :base_auto_convert_calls,
                    :base_direct_child_convert_calls,
                    :base_register_calls,
                    :legacy_etc_operation_calls,
                    :snapshot_calls

        def initialize
          @base_auto_convert_calls = 0
          @base_direct_child_convert_calls = 0
          @base_register_calls = 0
          @legacy_etc_operation_calls = 0
          @snapshot_calls = 0
        end

        private

        def auto_convert_tagged_primal_entity(_entity)
          @base_auto_convert_calls += 1
          true
        end

        def auto_convert_direct_tagged_children(_container)
          @base_direct_child_convert_calls += 1
          true
        end

        def register_cell_space(_cell_space)
          @base_register_calls += 1
          true
        end

        def handle_cell_space_etc_changed(_cell_space)
          @legacy_etc_operation_calls += 1
          false
        end

        def remember_cell_space_change_snapshot(_entity)
          @snapshot_calls += 1
        end
      end

      class CellSpaceLifecycleContext
        attr_reader :calls

        def initialize
          @calls = []
        end

        def default_storey_name
          'F01'
        end

        def initialize_scene(cell_space, storey: default_storey_name)
          @calls << [:initialize_scene, cell_space, storey]
          true
        end
      end

      class BulkCellSpaceConversionService
        attr_reader :calls

        def initialize(calls:, rollback: false, commit_error: nil)
          @calls = calls
          @rollback = rollback
          @commit_error = commit_error
          @restore_active_path = proc { @calls << :restore_active_path }
          @operation_runner = proc do |_name, rollback_if: nil, &block|
            @calls << :operation_start
            result = block.call
            if rollback_if&.call
              @calls << :abort
            else
              @calls << :commit
              raise @commit_error if @commit_error
            end
            result
          end
        end

        def call
          result = @operation_runner.call(
            'Bulk Convert',
            rollback_if: proc { @rollback }
          ) do
            @calls << :work
            :result
          end

          if @rollback
            @calls << :runtime_restore
            safely_restore_active_path(success: false)
          else
            safely_restore_active_path(success: true)
          end
          result
        rescue StandardError
          @calls << :runtime_restore
          safely_restore_active_path(success: false)
          raise
        end

        private

        def safely_restore_active_path(success:)
          @restore_active_path.call
          true
        rescue StandardError => e
          Logger.puts("restore failed success=#{success}: #{e.message}")
          false
        end
      end
    end
  end
end

require_relative '../indoor3d/application/cell_space_behavior_policies'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceBehaviorPoliciesTest < Minitest::Test
        Policy = CellSpaceBehaviorPolicies::ExplicitDemotionPolicy

        def setup
          @model = IndoorModel.new
        end

        def test_success_restores_active_path_before_commit_once
          calls = []
          service = BulkCellSpaceConversionService.new(calls: calls)

          assert_equal :result, service.call
          assert_equal [
            :operation_start,
            :work,
            :restore_active_path,
            :commit
          ], calls
        end

        def test_rollback_restores_active_path_after_abort_and_runtime_restore
          calls = []
          service = BulkCellSpaceConversionService.new(calls: calls, rollback: true)

          assert_equal :result, service.call
          assert_equal [
            :operation_start,
            :work,
            :abort,
            :runtime_restore,
            :restore_active_path
          ], calls
        end

        def test_commit_failure_allows_restore_retry_after_runtime_restore
          calls = []
          service = BulkCellSpaceConversionService.new(
            calls: calls,
            commit_error: RuntimeError.new('commit failed')
          )

          error = assert_raises(RuntimeError) { service.call }

          assert_equal 'commit failed', error.message
          assert_equal [
            :operation_start,
            :work,
            :restore_active_path,
            :commit,
            :runtime_restore,
            :restore_active_path
          ], calls
        end

        def test_finish_and_load_tag_auto_conversion_is_disabled
          tagged_group = FakeGroup.new('F01F01_IP_RM_23')

          refute @model.send(:auto_convert_tagged_primal_entity, tagged_group)
          refute @model.send(:auto_convert_direct_tagged_children, tagged_group)
          assert_equal 0, @model.base_auto_convert_calls
          assert_equal 0, @model.base_direct_child_convert_calls
          assert_equal 'F01F01_IP_RM_23', tagged_group.layer.name
        end

        def test_explicit_create_scene_keeps_source_tag
          tagged_group = FakeGroup.new('F01F01_RM_DR')
          cell_space = FakeCellSpace.new(tagged_group)
          context = CellSpaceLifecycleContext.new

          assert context.initialize_scene(cell_space, storey: 'F01')

          assert_equal 'F01F01_RM_DR', tagged_group.layer.name
          assert_equal 0, tagged_group.layer_assignments
          assert_equal [[:initialize_scene, cell_space, 'F01']], context.calls
        end

        def test_explicit_registration_clears_only_legacy_marker
          tagged_group = FakeGroup.new('F01F01_IP_RM_23')
          cell_space = FakeCellSpace.new(tagged_group)
          assert Policy.disable!(tagged_group)

          assert @model.send(:register_cell_space, cell_space)

          refute Policy.disabled?(tagged_group)
          assert_equal 'F01F01_IP_RM_23', tagged_group.layer.name
          assert_equal 0, tagged_group.layer_assignments
          assert_equal 1, @model.base_register_calls
        end

        def test_untracked_change_does_not_open_legacy_transparent_operation
          group = FakeGroup.new('Untagged')
          cell_space = FakeCellSpace.new(group)

          refute @model.send(:handle_cell_space_etc_changed, cell_space)

          assert_equal 0, @model.legacy_etc_operation_calls
          assert_equal 1, @model.snapshot_calls
        end

        class FakeCellSpace
          attr_reader :sketchup_group

          def initialize(group)
            @sketchup_group = group
          end
        end

        class FakeGroup
          attr_reader :entityID, :name, :layer_assignments
          attr_accessor :layer

          def initialize(tag_name)
            @entityID = 101
            @name = 'group'
            @attributes = {}
            @layer = Tag.new(tag_name)
            @layer_assignments = 0
          end

          def valid?
            true
          end

          def layer=(value)
            @layer_assignments += 1
            @layer = value
          end

          def get_attribute(dictionary, key, default = nil)
            @attributes.fetch([dictionary, key], default)
          end

          def set_attribute(dictionary, key, value)
            @attributes[[dictionary, key]] = value
          end

          def delete_attribute(dictionary, key)
            @attributes.delete([dictionary, key])
          end
        end
      end
    end
  end
end
