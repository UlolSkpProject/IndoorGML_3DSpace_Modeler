# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/export/val3dity_overlap_geometry_rechecker'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityOverlapGeometryRecheckerTest < Minitest::Test
          def test_missing_cells_are_reported_as_reconstruction_failure
            reader = FakeSnapshotReader.new({})
            rechecker = Val3dityOverlapGeometryRechecker.new(
              snapshot_reader: reader,
              tolerance: 0.001
            )

            analysis = rechecker.pair_analysis('cell_A', 'cell_B')

            assert_equal :inconclusive, analysis[:status]
            assert_equal %w[cell_A cell_B], analysis[:cells]
            assert_equal 'GML_RECONSTRUCTION_FAILED', analysis[:reason]
          end

          def test_pair_analysis_is_cached_by_sorted_pair
            reader = FakeSnapshotReader.new({})
            rechecker = Val3dityOverlapGeometryRechecker.new(
              snapshot_reader: reader,
              tolerance: 0.001
            )

            rechecker.pair_analysis('cell_A', 'cell_B')
            rechecker.pair_analysis('cell_B', 'cell_A')

            assert_equal 1, reader.read_count
          end

          def test_best_candidate_prefers_701_penetration_then_area
            rechecker = Val3dityOverlapGeometryRechecker.new(
              snapshot_reader: FakeSnapshotReader.new({}),
              tolerance: 0.001
            )
            candidates = [
              { distance: 0.0, overlap_area: 100.0 },
              { distance: -0.001, overlap_area: 5.0 }
            ]

            assert_equal candidates.last, rechecker.best_candidate(candidates, 701)
            assert_equal candidates.first, rechecker.best_candidate(candidates, 704)
          end

          class FakeSnapshotReader
            attr_reader :read_count

            def initialize(snapshot)
              @snapshot = snapshot
              @read_count = 0
            end

            def read
              @read_count += 1
              @snapshot
            end
          end
        end
      end
    end
  end
end
