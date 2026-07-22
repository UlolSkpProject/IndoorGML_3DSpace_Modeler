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

        def test_cell_space_normalization_reuses_the_batch_operation
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
              activate_edit_context: false
            )
          end

          assert_equal({ manifold: true }, result)
          assert_equal [[group, 0.001, { manage_operation: false }]], calls
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
