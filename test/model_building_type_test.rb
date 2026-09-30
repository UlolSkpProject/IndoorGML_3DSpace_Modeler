# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/domain/model_building_type'

class ModelBuildingTypeTest < Minitest::Test
  Classifier = ULOL::Indoor3DGmlModeler::IndoorCore::ModelBuildingType

  def test_only_u_sb_with_six_digits_is_subway
    assert_equal 'subway', Classifier.from_path('C:\\models\\U_SB_260930_station.skp')
    assert_equal 'subway', Classifier.from_path('/models/u_sb_260930_.SKP')
  end

  def test_other_matching_p_or_u_filename_is_public
    assert_equal 'public', Classifier.from_path('C:\\models\\P_SB_260930_station.skp')
    assert_equal 'public', Classifier.from_path('C:\\models\\U_AB_260930_station.skp')
  end

  def test_nonmatching_filename_has_no_building_type
    assert_nil Classifier.from_path('C:\\models\\U_SB_26093_station.skp')
    assert_nil Classifier.from_path('C:\\models\\A_AB_260930_station.skp')
    assert_nil Classifier.from_path('')
  end
end
