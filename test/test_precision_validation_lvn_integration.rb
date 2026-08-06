# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Edge; end
  class Face; end

  def self.active_model
    @active_model ||= Struct.new(:active_view).new(Struct.new(:invalidated) do
      def invalidate
        self.invalidated = true
      end
    end.new(false))
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      class LocalVertexNormalizer
        DEFAULT_TOLERANCE_MM = 0.001
        class OperationError < StandardError; end

        def self.normalized?(group, _tolerance)
          group.normalized == true
        end
      end

      class CellSpaceLifecycleContext
        def initialize_scene(_cell_space, **_options)
          :initialized
        end
      end

      class IndoorModel
        attr_accessor :baseline_handler, :result_overrides, :normalized_effects
        attr_reader :baseline_call, :baseline_call_count, :operation_names,
                    :normalization_calls, :topology_sync_count,
                    :committed_operations, :aborted_operations

        def initialize
          @operation_names = []
          @normalization_calls = []
          @topology_sync_count = 0
          @baseline_call_count = 0
          @committed_operations = []
          @aborted_operations = []
          @result_overrides = {}
          @normalized_effects = {}
        end

        def local_vertex_normalize(*args, **options)
          @baseline_call_count += 1
          @baseline_call = [args, options]
          return @baseline_handler.call(*args, **options) if @baseline_handler

          :baseline
        end

        def cell_space_changed(_entity)
          true
        end

        private

        def normalization_targets(cell_spaces)
          Array(cell_spaces)
        end

        def with_indoor_model_operation(name)
          @operation_names << name
          result = yield
          @committed_operations << name
          result
        rescue StandardError
          @aborted_operations << name
          raise
        end

        def sync
          yield
        end

        def normalize_cell_space_group(cell_space, group, _tolerance, **_options)
          @normalization_calls << cell_space.id
          raise 'forced failure' if cell_space.id == 'B'

          group.normalized = @normalized_effects.fetch(cell_space.id, true)
          @result_overrides.fetch(cell_space.id, normalization_result(cell_space.id))
        end

        def normalization_result(_cell_space_id)
          {
            normalization_complete: true,
            vertex_count: 3,
            moved_vertex_count: 1,
            max_displacement_mm: 0.001,
            max_grid_residual_mm: 0.0,
            max_unprotected_grid_residual_mm: 0.0,
            protected_coincident_vertex_count: 0,
            normalization_passes: [],
            source_triangle_count: 1,
            added_face_count: 1,
            skipped_collinear_triangle_count: 0,
            surface_border_repair_count: 0,
            strict_coplanar_edge_removal_count: 0,
            coplanar_edge_removal_count: 0,
            collinear_vertex_removal_count: 0,
            reoriented_face_count: 0,
            volume_before_mm3: 1.0,
            volume_after_mm3: 1.0
          }
        end

        def topology_coordinator
          @topology_coordinator ||= Struct.new(:owner) do
            def synchronize_all
              owner.send(:increment_topology_sync)
              { synchronized: true }
            end
          end.new(self)
        end

        def increment_topology_sync
          @topology_sync_count += 1
        end

        def aggregate_local_normalization_report(_tolerance, results, topology, activate_edit_context:)
          {
            cell_space_count: results.length,
            already_normalized_cell_space_count: 0,
            topology_metrics: topology,
            activate_edit_context: activate_edit_context,
            cell_spaces: results
          }
        end

        def remember_cell_space_change_snapshot(_group); end
        def invalidate_overlay_transition_points; end
        def observer_routing_suppressed?; false; end
        def guard_active?(_name); false; end
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/lvn_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationLvnIntegrationTest < Minitest::Test
        class Group
          attr_accessor :normalized
          attr_reader :name

          def initialize(name)
            @name = name
            @normalized = false
            @attributes = {}
          end

          def valid?; true; end
          def persistent_id; @name.hash; end

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

        CellSpace = Struct.new(:id, :group) do
          def valid?; true; end
          def valid_sketchup_group; group; end
        end

        def test_default_policy_delegates_to_existing_atomic_api
          model = IndoorModel.new
          result = model.local_vertex_normalize(0.002, cell_spaces: [:cell])

          assert_equal :baseline, result
          assert_equal [[0.002], { cell_spaces: [:cell], activate_edit_context: false,
                                  diagnostics: false, report: false, report_path: nil }],
                       model.baseline_call
        end

        def test_continue_policy_runs_each_target_in_independent_operations
          cells = %w[A C].map { |id| CellSpace.new(id, Group.new(id)) }
          model = IndoorModel.new

          report = model.local_vertex_normalize(
            cell_spaces: cells,
            failure_policy: :continue
          )

          assert_equal %w[A C], model.normalization_calls
          assert_equal :per_cell_operations, report[:undo_mode]
          assert_equal 2, report[:cell_space_count]
          assert_equal %i[normalized normalized], report[:cell_spaces].map { |row| row[:status] }
          assert_equal 0, model.baseline_call_count
          assert_equal 1, model.topology_sync_count
          assert_includes model.operation_names, 'IndoorGML LVN A'
          assert_includes model.operation_names, 'IndoorGML LVN C'
        end

        def test_per_cell_failure_is_rolled_back_marked_and_does_not_stop_later_targets
          cells = %w[A B C].map { |id| CellSpace.new(id, Group.new(id)) }
          model = IndoorModel.new

          report = model.local_vertex_normalize(
            cell_spaces: cells,
            failure_policy: :continue
          )

          assert_equal %w[A B C], model.normalization_calls
          assert_equal 2, report[:cell_space_count]
          assert_equal 1, report[:normalization_failed_cell_space_count]
          assert_equal ['B'], report[:failed_cell_space_ids]
          assert_equal 1, model.topology_sync_count
          assert_equal :per_cell_operations, report[:undo_mode]
          assert PrecisionValidation::LvnState.failed?(cells[1].group)
          assert_includes model.aborted_operations, 'IndoorGML LVN B'
          assert_includes model.committed_operations, 'Mark CellSpace LVN Failure B'
          refute PrecisionValidation::LvnState.failed?(cells[0].group)
          refute PrecisionValidation::LvnState.failed?(cells[2].group)
        end

        def test_previous_failure_is_unconditionally_skipped
          cell = CellSpace.new('B', Group.new('B'))
          PrecisionValidation::LvnState.set_failed(cell.group, true)
          model = IndoorModel.new

          report = model.local_vertex_normalize(
            cell_spaces: [cell],
            failure_policy: :continue
          )

          assert_empty model.normalization_calls
          assert_equal 1, report[:skipped_previous_failure_cell_space_count]
          assert_equal ['B'], report[:failed_cell_space_ids]
          assert_equal :none, report[:undo_mode]
        end

        def test_incomplete_result_fails_postcondition
          cell = CellSpace.new('A', Group.new('A'))
          model = IndoorModel.new
          model.result_overrides['A'] = model.send(:normalization_result, 'A').merge(
            normalization_complete: false
          )

          report = model.local_vertex_normalize(
            cell_spaces: [cell],
            failure_policy: :continue
          )

          row = report[:cell_spaces].first
          assert_equal :failed, row[:status]
          assert_equal 'ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer::OperationError',
                       row[:error_class]
          assert PrecisionValidation::LvnState.failed?(cell.group)
          assert_includes model.aborted_operations, 'IndoorGML LVN A'
          assert_equal 0, report[:cell_space_count]
        end

        def test_false_normalized_predicate_fails_postcondition
          cell = CellSpace.new('A', Group.new('A'))
          model = IndoorModel.new
          model.normalized_effects['A'] = false

          report = model.local_vertex_normalize(
            cell_spaces: [cell],
            failure_policy: :continue
          )

          assert_equal :failed, report[:cell_spaces].first[:status]
          assert PrecisionValidation::LvnState.failed?(cell.group)
        end

        def test_existing_cell_space_observer_path_clears_failure_state
          group = Group.new('changed')
          PrecisionValidation::LvnState.set_failed(group, true)
          model = IndoorModel.new

          assert_equal true, model.cell_space_changed(group)
          refute PrecisionValidation::LvnState.failed?(group)
        end

        def test_false_state_removes_compatibility_signature_attribute
          group = Group.new('legacy')
          group.set_attribute('IndoorGml', 'lvn_failed', true)
          group.set_attribute('IndoorGml', 'lvn_failed_geometry_signature', 'legacy-value')

          PrecisionValidation::LvnState.set_failed(group, false)

          assert_equal false, group.get_attribute('IndoorGml', 'lvn_failed')
          assert_nil group.get_attribute('IndoorGml', 'lvn_failed_geometry_signature')
        end

        def test_new_cell_space_is_initialized_with_false_failure_flag
          cell = CellSpace.new('new', Group.new('new'))
          context = CellSpaceLifecycleContext.new

          assert_equal :initialized, context.initialize_scene(cell)
          assert_equal false, cell.group.get_attribute('IndoorGml', 'lvn_failed')
        end

        def test_unknown_failure_policy_is_rejected
          assert_raises(ArgumentError) do
            IndoorModel.new.local_vertex_normalize(
              cell_spaces: [],
              failure_policy: :unknown
            )
          end
        end
      end
    end
  end
end
