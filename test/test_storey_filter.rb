# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpace
        DEFAULT_STOREY = 'F01' unless const_defined?(:DEFAULT_STOREY, false)
      end
    end
  end
end

require_relative '../indoor3d/application/storey_filter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class StoreyFilterTest < Minitest::Test
        def test_normalize_labels_filters_invalid_values
          assert_equal %w[B02 F01], StoreyFilter.normalize_labels(['f1', 'B02', 'x', '', nil])
        end

        def test_labels_for_single_storey
          assert_equal ['F03'], StoreyFilter.labels_for('f3')
        end

        def test_labels_for_range
          assert_equal %w[F01 F02 F03], StoreyFilter.labels_for('f1~f3')
        end

        def test_labels_for_reversed_range
          assert_equal %w[B01 B02 B03], StoreyFilter.labels_for('b3~b1')
        end

        def test_labels_for_cross_kind_range_keeps_endpoints
          assert_equal %w[B01 F02], StoreyFilter.labels_for('b1~f2')
        end

        def test_labels_for_invalid_value_uses_default_storey
          assert_equal [CellSpace::DEFAULT_STOREY], StoreyFilter.labels_for('bad')
        end

        def test_options_for_cell_spaces
          cell_space = Struct.new(:storey) do
            def valid?
              true
            end
          end

          assert_equal [
            { value: 'F01', label: 'F01' },
            { value: 'F02', label: 'F02' }
          ], StoreyFilter.options_for([cell_space.new('F01~F02')])
        end
      end
    end
  end
end
