# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/indoor_model/local_vertex_normalization'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModelLocalVertexNormalizationTest < Minitest::Test
        FakeCellSpace = Struct.new(:id, :group) do
          def valid?
            true
          end

          def valid_sketchup_group
            group
          end
        end

        class Harness
          include IndoorModel::LocalVertexNormalization

          attr_reader :normalized_targets

          def initialize(cell_spaces)
            @cell_spaces = cell_spaces
          end

          def local_vertex_normalize(tolerance_mm = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM, cell_spaces: nil)
            @normalized_targets = Array(cell_spaces)
            {
              tolerance_mm: tolerance_mm,
              cell_space_count: @normalized_targets.length,
              cell_spaces: @normalized_targets
            }
          end
        end

        class GroupNormalizationHarness
          include IndoorModel::LocalVertexNormalization

          def with_unlocked(_group)
            yield
          end
        end

        def test_model_predicate_requires_every_cell_space_to_be_normalized
          first = FakeCellSpace.new('first', Object.new)
          second = FakeCellSpace.new('second', Object.new)
          harness = Harness.new([first, second])
          normalized_groups = { first.group => true, second.group => false }

          result = with_normalized_predicate(->(group, _tolerance) { normalized_groups[group] }) do
            harness.is_vertex_locally_normalized?
          end

          refute result
        end

        def test_export_guard_normalizes_only_unnormalized_cell_spaces
          first = FakeCellSpace.new('first', Object.new)
          second = FakeCellSpace.new('second', Object.new)
          third = FakeCellSpace.new('third', Object.new)
          harness = Harness.new([first, second, third])
          normalized_groups = { first.group => true, second.group => false, third.group => true }

          report = with_normalized_predicate(->(group, _tolerance) { normalized_groups[group] }) do
            harness.ensure_vertices_locally_normalized_for_export
          end

          assert_equal [second], harness.normalized_targets
          assert_equal 1, report[:cell_space_count]
          assert_equal 2, report[:already_normalized_cell_space_count]
          refute report[:skipped]
        end

        def test_export_guard_is_noop_when_all_targets_are_normalized
          cells = [FakeCellSpace.new('first', Object.new), FakeCellSpace.new('second', Object.new)]
          harness = Harness.new(cells)

          report = with_normalized_predicate(->(_group, _tolerance) { true }) do
            harness.ensure_vertices_locally_normalized_for_export
          end

          assert_nil harness.normalized_targets
          assert_equal 0, report[:cell_space_count]
          assert_equal 2, report[:already_normalized_cell_space_count]
          assert report[:skipped]
        end

        def test_group_normalization_forwards_debug_option
          group = Object.new
          cell_space = FakeCellSpace.new('cell-1', group)
          calls = []

          result = with_normalize_replacement(
            lambda do |entity, tolerance, **options|
              calls << [entity, tolerance, options]
              { manifold: true }
            end
          ) do
            GroupNormalizationHarness.new.send(
              :normalize_cell_space_group,
              cell_space,
              group,
              0.001,
              activate_edit_context: false,
              debug: true
            )
          end

          assert_equal({ manifold: true }, result)
          assert_equal(
            [[group, 0.001, { debug: true, manage_operation: false }]],
            calls
          )
        end

        def test_group_normalization_collects_report_without_writing_per_solid_files
          group = Object.new
          cell_space = FakeCellSpace.new('cell-1', group)
          calls = []

          with_normalize_replacement(
            lambda do |entity, tolerance, **options|
              calls << [entity, tolerance, options]
              { manifold: true }
            end
          ) do
            GroupNormalizationHarness.new.send(
              :normalize_cell_space_group,
              cell_space,
              group,
              0.001,
              activate_edit_context: false,
              report: true
            )
          end

          assert_equal(
            [[group, 0.001, {
              debug: false,
              manage_operation: false,
              report: true,
              write_report: false
            }]],
            calls
          )
        end

        def test_batch_timing_report_contains_geometry_and_stage_totals
          group = Object.new
          target = FakeCellSpace.new('cell-1', group)
          profile = {
            geometry_before: { faces: 4, edges: 6, vertices: 4, volume_mm3: 10.0 },
            geometry_after: { faces: 6, edges: 9, vertices: 5, volume_mm3: 10.0 },
            stages: {
              source_brep_snapshot: {
                calls: 1,
                total_seconds: 2.5,
                max_seconds: 2.5,
                failures: 0
              }
            },
            snapshot_roles: {
              source_initial: {
                calls: 1,
                total_seconds: 1.5,
                max_seconds: 1.5,
                failures: 0
              }
            },
            snapshot_reuse: {
              reused: true,
              rejection_reasons: []
            }
          }
          timing = {
            status: :success,
            total_seconds: 3.0,
            operation_total_seconds: 3.0,
            operation_body_seconds: 2.9,
            operation_boundary_overhead_seconds: 0.1,
            topology_sync_seconds: 0.2,
            cell_spaces: [profile]
          }

          Dir.mktmpdir do |directory|
            path = File.join(directory, 'batch-report.json')
            written = GroupNormalizationHarness.new.send(
              :write_local_normalization_timing_report,
              timing,
              normalization_report: { cell_space_count: 1, cell_spaces: [] },
              targets: [target],
              report_path: path
            )
            parsed = JSON.parse(File.read(written, encoding: 'UTF-8'))

            assert_equal 4, parsed.dig('geometry_totals', 'before', 'faces')
            assert_equal 5, parsed.dig('geometry_totals', 'after', 'vertices')
            assert_equal 2.5,
                         parsed.dig('stage_totals', 'source_brep_snapshot', 'total_seconds')
            assert_equal 1.5,
                         parsed.dig(
                           'snapshot_role_totals',
                           'source_initial',
                           'total_seconds'
                         )
            assert_equal true,
                         parsed.dig('solids', 0, 'snapshot_reuse', 'reused')
            assert_equal 1, parsed['solids'].length
          end
        end

        def test_empty_batch_failure_still_writes_report
          Dir.mktmpdir do |directory|
            path = File.join(directory, 'empty-batch-report.json')
            capture_io do
              assert_raises(RuntimeError) do
                GroupNormalizationHarness.new.local_vertex_normalize(
                  0.001,
                  cell_spaces: [],
                  report: true,
                  report_path: path
                )
              end
            end
            parsed = JSON.parse(File.read(path, encoding: 'UTF-8'))

            assert_equal 'failed', parsed['status']
            assert_equal 0, parsed['solids'].length
            assert_match(/No valid CellSpace/, parsed['error'])
          end
        end

        private

        def with_normalized_predicate(replacement)
          singleton_class = class << LocalVertexNormalizer; self; end
          original = LocalVertexNormalizer.method(:normalized?)
          singleton_class.send(:define_method, :normalized?, &replacement)
          yield
        ensure
          singleton_class.send(:define_method, :normalized?, original) if singleton_class && original
        end


        def with_normalize_replacement(replacement)
          singleton_class = class << LocalVertexNormalizer; self; end
          original = LocalVertexNormalizer.method(:normalize)
          singleton_class.send(:define_method, :normalize, &replacement)
          yield
        ensure
          singleton_class.send(:define_method, :normalize, original) if singleton_class && original
        end
      end
    end
  end
end
