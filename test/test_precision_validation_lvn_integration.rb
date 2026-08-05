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

        class << self
          attr_accessor :normalized_predicate

          def normalized?(group, tolerance)
            normalized_predicate ? normalized_predicate.call(group, tolerance) : false
          end
        end
      end

      class CellSpaceLifecycleContext
        def initialize_scene(_cell_space, **_options)
          :initialized
        end
      end

      class IndoorModel
        attr_reader :baseline_call, :operation_names, :normalization_calls, :topology_sync_count

        def initialize
          @operation_names = []
          @normalization_calls = []
          @topology_sync_count = 0
        end

        def local_vertex_normalize(*args, **options)
          @baseline_call = [args, options]
          :baseline
        end

        private

        def normalization_targets(cell_spaces)
          Array(cell_spaces)
        end

        def with_indoor_model_operation(name)
          @operation_names << name
          yield
        end

        def sync
          yield
        end

        def normalize_cell_space_group(cell_space, _group, _tolerance, **_options)
          @normalization_calls << cell_space.id
          raise 'forced failure' if cell_space.id == 'B'

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
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/lvn_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationLvnIntegrationTest < Minitest::Test
        Point = Struct.new(:x, :y, :z)
        Vector = Struct.new(:x, :y, :z)
        Vertex = Struct.new(:position)

        class Edge < Sketchup::Edge
          attr_reader :vertices

          def initialize(first, second)
            @vertices = [first, second]
          end
        end

        class Loop
          attr_reader :vertices

          def initialize(vertices)
            @vertices = vertices
          end
        end

        class Face < Sketchup::Face
          attr_reader :loops, :outer_loop, :normal

          def initialize(vertices)
            @outer_loop = Loop.new(vertices)
            @loops = [@outer_loop]
            @normal = Vector.new(0.0, 0.0, 1.0)
          end

          def vertices
            @outer_loop.vertices
          end
        end

        Definition = Struct.new(:entities, :guid)

        class Group
          attr_reader :definition

          def initialize(name)
            vertices = [
              Vertex.new(Point.new(0.0, 0.0, 0.0)),
              Vertex.new(Point.new(1.0, 0.0, 0.0)),
              Vertex.new(Point.new(0.0, 1.0, 0.0))
            ]
            @definition = Definition.new(
              [
                Edge.new(vertices[0], vertices[1]),
                Edge.new(vertices[1], vertices[2]),
                Edge.new(vertices[2], vertices[0]),
                Face.new(vertices)
              ],
              "definition-#{name}"
            )
            @attributes = {}
            @name = name
          end

          def valid?
            true
          end

          def persistent_id
            @name.hash
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

        CellSpace = Struct.new(:id, :group) do
          def valid?
            true
          end

          def valid_sketchup_group
            group
          end
        end

        def setup
          LocalVertexNormalizer.normalized_predicate = ->(_group, _tolerance) { false }
        end

        def test_default_policy_delegates_to_existing_atomic_api
          model = IndoorModel.new
          result = model.local_vertex_normalize(0.002, cell_spaces: [:cell])

          assert_equal :baseline, result
          assert_equal [[0.002], { cell_spaces: [:cell], activate_edit_context: false,
                                  debug: false, report: false, report_path: nil }],
                       model.baseline_call
        end

        def test_continue_policy_commits_successes_marks_failure_and_continues
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
          assert PrecisionValidation::LvnState.failed?(cells[1].group)
          refute PrecisionValidation::LvnState.failed?(cells[0].group)
          refute PrecisionValidation::LvnState.failed?(cells[2].group)
        end

        def test_previous_failure_is_skipped_until_geometry_changes
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
        end

        def test_new_cell_space_is_initialized_with_false_failure_flag
          cell = CellSpace.new('new', Group.new('new'))
          context = CellSpaceLifecycleContext.new

          assert_equal :initialized, context.initialize_scene(cell)
          assert_equal false,
                       cell.group.get_attribute('IndoorGml', 'lvn_failed')
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
