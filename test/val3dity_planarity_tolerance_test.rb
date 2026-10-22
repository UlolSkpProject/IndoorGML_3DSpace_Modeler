# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/validity/val3dity_process_adapter'
require_relative '../indoor3d/validity/val3dity_planarity_tolerance'

class Val3dityPlanarityToleranceTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Converter = Core::IndoorGmlConverter
  Planarity = Converter::Val3dityPlanarityTolerance

  Model = Struct.new(:options)

  def model_with_unit(unit_key)
    Model.new({ 'UnitsOptions' => { 'LengthUnit' => unit_key } })
  end

  def base_args
    ['val3dity.exe', 'input.gml', '--verbose', '-r', 'report.json']
  end

  def test_physical_planarity_tolerance_matches_exported_coordinate_units
    # The GML writer exports SketchUp inches multiplied by the configured
    # output factor; all of these values must represent the same 0.025 mm.
    {
      0 => 0.025 / 25.4,      # in
      1 => 0.025 / 304.8,     # ft
      2 => 0.025,             # mm
      3 => 0.0025,            # cm
      4 => 0.000025           # m
    }.each do |unit_key, expected|
      result = Planarity.apply(base_args, model: model_with_unit(unit_key))
      option_index = result.index(Planarity::OPTION)
      refute_nil option_index, "missing planarity option for unit #{unit_key}"
      assert_equal result.length - 4, option_index
      assert_in_delta expected, Float(result[option_index + 1]), expected * 1.0e-12
      assert_equal ['-r', 'report.json'], result.last(2)
    end
  end

  def test_already_explicit_planarity_option_is_preserved
    original = ['val3dity.exe', 'input.gml', Planarity::OPTION, '0.123', '-r', 'report.json']
    result = Planarity.apply(original, model: model_with_unit(4))
    assert_equal original, result
    refute_same original, result
    assert_equal 1, result.count(Planarity::OPTION)
  end

  def test_without_report_option_appends_planarity_option
    result = Planarity.apply(['val3dity.exe', 'input.gml'], model: model_with_unit(2))
    assert_equal [Planarity::OPTION, '0.025'], result.last(2)
  end

  def test_model_is_required_if_no_explicit_planarity_option_is_supplied
    assert_raises(ArgumentError) { Planarity.apply(base_args, model: nil) }
  end

  def test_process_adapter_receives_converted_planarity_from_model
    original = base_args
    adapter = Converter::Val3dityProcessAdapter.new(
      args: original,
      current_dir: '.',
      model: model_with_unit(4)
    )
    argv = adapter.instance_variable_get(:@args)
    index = argv.index(Planarity::OPTION)
    refute_nil index
    assert_in_delta 0.000025, Float(argv[index + 1]), 1.0e-16
    refute_includes original, Planarity::OPTION
  end
end
