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

require_relative '../indoor3d/application/storey_filter_parser'
require_relative '../indoor3d/application/storey_filter_options_builder'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class StoreyFilterParserTest < Minitest::Test
        def test_normalize_labels_filters_invalid_values
          assert_equal %w[B02 F01], StoreyFilterParser.normalize_labels(['f1', 'B02', 'x', '', nil])
        end

        def test_labels_for_single_storey
          assert_equal ['F03'], StoreyFilterParser.labels_for('f3')
        end

        def test_labels_for_range
          assert_equal %w[F01 F02 F03], StoreyFilterParser.labels_for('f1~f3')
        end

        def test_labels_for_reversed_range
          assert_equal %w[B01 B02 B03], StoreyFilterParser.labels_for('b3~b1')
        end

        def test_labels_for_cross_kind_range_keeps_endpoints
          assert_equal %w[B01 F02], StoreyFilterParser.labels_for('b1~f2')
        end

        def test_labels_for_invalid_value_uses_default_storey
          assert_equal [CellSpace::DEFAULT_STOREY], StoreyFilterParser.labels_for('bad')
        end
      end
    end
  end
end
