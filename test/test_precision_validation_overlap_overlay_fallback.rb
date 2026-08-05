# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/precision_validation/overlap_overlay_fallback'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class PrecisionValidationOverlapOverlayFallbackTest < Minitest::Test
        Resolver = IndoorGmlConverter::ValidationErrorGeometryResolver

        def setup
          @resolver = Resolver.allocate
        end

        def test_raw_701_without_extension_recheck_authorizes_lazy_boolean_overlay
          row = {
            code: '701 CELLS_OVERLAP',
            geometry_refs: {}
          }

          assert @resolver.send(:positive_overlap_recheck?, row, %w[cell_a cell_b])
        end

        def test_raw_704_without_extension_recheck_does_not_authorize_overlap_overlay
          row = {
            code: '704 PRIMAL_DUAL_ADJACENCIES_INCONSISTENT',
            geometry_refs: {}
          }

          refute @resolver.send(:positive_overlap_recheck?, row, %w[cell_a cell_b])
        end

        def test_explicit_tolerated_recheck_remains_authoritative
          row = {
            code: 701,
            geometry_refs: {
              overlap_recheck: {
                cells: %w[cell_a cell_b],
                tolerated: true,
                actual_overlap_volume_mm3: 12.5
              }
            }
          }

          refute @resolver.send(:positive_overlap_recheck?, row, %w[cell_a cell_b])
        end

        def test_explicit_positive_matching_recheck_keeps_existing_behavior
          row = {
            code: 701,
            geometry_refs: {
              overlap_recheck: {
                cells: %w[solid_cell_a cell_cell_b],
                tolerated: false,
                actual_overlap_volume_mm3: 12.5
              }
            }
          }

          assert @resolver.send(:positive_overlap_recheck?, row, %w[cell_a cell_b])
        end

        def test_explicit_nonpositive_or_mismatched_recheck_is_not_overridden
          zero_volume = {
            code: 701,
            geometry_refs: {
              overlap_recheck: {
                cells: %w[cell_a cell_b],
                tolerated: false,
                actual_overlap_volume_mm3: 0.0
              }
            }
          }
          mismatched_pair = {
            code: 701,
            geometry_refs: {
              overlap_recheck: {
                cells: %w[cell_a cell_c],
                tolerated: false,
                actual_overlap_volume_mm3: 12.5
              }
            }
          }

          refute @resolver.send(:positive_overlap_recheck?, zero_volume, %w[cell_a cell_b])
          refute @resolver.send(:positive_overlap_recheck?, mismatched_pair, %w[cell_a cell_b])
        end
      end
    end
  end
end
