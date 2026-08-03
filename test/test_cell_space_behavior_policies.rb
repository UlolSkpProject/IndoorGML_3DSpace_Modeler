# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      module TagCellSpaceAdapter
        def self.cell_space_type_and_category(entity)
          entity&.mapped_tag? ? [:general, 'Room'] : nil
        end
      end

      def self.tag_cell_space_type_and_category(entity)
        TagCellSpaceAdapter.cell_space_type_and_category(entity)
      end

      class IndoorModel
        attr_reader :base_auto_convert_calls,
                    :base_recursive_convert_calls,
                    :base_register_calls,
                    :legacy_etc_operation_calls,
                    :snapshot_calls

        def initialize
          @base_auto_convert_calls = 0
          @base_recursive_convert_calls = 0
          @base_register_calls = 0
          @legacy_etc_operation_calls = 0
          @snapshot_calls = 0
        end

        private

        def demote_cell_space_to_solid_group(cell_space)
          cell_space.sketchup_group
        end

        def auto_convert_tagged_primal_entity(_entity)
          @base_auto_convert_calls += 1
          true
        end

        def auto_convert_tagged_descendants(_container, _transformation)
          @base_recursive_convert_calls += 1
          true
        end

        def target_for_tagged_child(_child, _parent_target)
          :target
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

        def test_explicit_demotion_blocks_tag_auto_conversion_without_changing_tag
          group = FakeGroup.new(mapped_tag: true)
          cell_space = FakeCellSpace.new(group)

          assert_same group, @model.send(:demote_cell_space_to_solid_group, cell_space)
          assert Policy.disabled?(group)
          assert group.mapped_tag?

          refute @model.send(:auto_convert_tagged_primal_entity, group)
          assert_equal 0, @model.base_auto_convert_calls
          refute @model.send(:auto_convert_tagged_descendants, group, :transformation)
          assert_equal 0, @model.base_recursive_convert_calls
          assert_nil @model.send(:target_for_tagged_child, group, :parent_target)
        end

        def test_manual_registration_reenables_normal_tag_conversion_policy
          group = FakeGroup.new(mapped_tag: true)
          cell_space = FakeCellSpace.new(group)
          assert Policy.disable!(group)

          assert @model.send(:register_cell_space, cell_space)

          refute Policy.disabled?(group)
          assert_equal 1, @model.base_register_calls
        end

        def test_unmapped_demotion_clears_stale_policy_marker
          group = FakeGroup.new(mapped_tag: false)
          cell_space = FakeCellSpace.new(group)
          assert Policy.disable!(group)

          assert_same group, @model.send(:demote_cell_space_to_solid_group, cell_space)

          refute Policy.disabled?(group)
        end

        def test_untracked_change_does_not_open_legacy_transparent_operation
          group = FakeGroup.new(mapped_tag: false)
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
          attr_reader :entityID, :name

          def initialize(mapped_tag:)
            @mapped_tag = mapped_tag
            @entityID = 101
            @name = 'group'
            @attributes = {}
          end

          def valid?
            true
          end

          def mapped_tag?
            @mapped_tag
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
