# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityProcessAdapter
          attr_reader :args, :current_dir

          def initialize(args:, current_dir:)
            @args = args
            @current_dir = current_dir
          end
        end
      end
    end
  end
end

require_relative '../indoor3d/validity/val3dity_planarity_tolerance'

class Val3dityPlanarityToleranceTest < Minitest::Test
  Converter = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter
  Adapter = Converter::Val3dityProcessAdapter
  Policy = Converter::Val3dityPlanarityTolerance

  def test_fast_and_precision_commands_receive_common_planarity_tolerance
    fast = build_adapter([
      'val3dity.exe', 'fast.gml', '--verbose',
      '--overlap_tol', '-1', '-r', 'fast.json'
    ])
    precision = build_adapter([
      'val3dity.exe', 'precision.gml', '--verbose',
      '--overlap_tol', '0.01', '-r', 'precision.json'
    ])

    [fast, precision].each do |adapter|
      option_index = adapter.args.index('--planarity_d2p_tol')
      report_index = adapter.args.index('-r')

      assert option_index
      assert_equal '0.025', adapter.args[option_index + 1]
      assert_operator option_index, :<, report_index
    end
  end

  def test_existing_explicit_planarity_tolerance_is_preserved
    args = [
      'val3dity.exe', 'input.gml', '--verbose',
      '--planarity_d2p_tol', '0.1', '-r', 'report.json'
    ]

    adapter = build_adapter(args)

    assert_equal args, adapter.args
    assert_equal 1, adapter.args.count('--planarity_d2p_tol')
  end

  def test_input_argument_array_is_not_mutated
    args = ['val3dity.exe', 'input.gml', '--verbose', '-r', 'report.json']
    original = args.dup

    build_adapter(args)

    assert_equal original, args
  end

  def test_installation_is_idempotent
    assert Policy.install!
    assert Policy.install!
    assert_equal 1, Adapter.ancestors.count { |ancestor| ancestor == Policy::ProcessAdapterPatch }
  end

  private

  def build_adapter(args)
    Adapter.new(args: args, current_dir: 'C:/val3dity')
  end
end
