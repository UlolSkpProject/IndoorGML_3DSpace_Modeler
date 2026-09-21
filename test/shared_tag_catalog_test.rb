# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../indoor3d/integration/tag_cell_space_adapter'

class SharedTagCatalogTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Catalog = Core::SharedTagCatalog
  Adapter = Core::TagCellSpaceAdapter
  Type = Core::CellSpaceType

  def setup
    @catalog = Catalog.new([
      row('지하철', 'MV', 'FC_02', '계단'),
      row('공공시설건물', 'MV', 'FC_02', '엘리베이터'),
      row('지하철', 'MV', 'RM_01', '엘리베이터(공간)'),
      row('지하철', 'MV', 'RM_02', '에스컬레이터(공간)'),
      row('공공기관', 'IP', 'RM_05', '계단(공간)'),
      row('구조', 'RM', 'DR', '문(공간)'),
      row('공통', 'RM', 'WD', '창문(공간)'),
      row('구조', 'IS', 'DR', '문')
    ])
    Adapter.instance_variable_set(:@catalog, @catalog)
  end

  def test_same_code_uses_selected_building_type
    assert_equal [Type::TRANSITION, 'Stair'], classify('MV_FC_02', 'subway')
    assert_equal [Type::TRANSITION, 'Elevator'], classify('MV_FC_02', 'public')
    assert_equal [Type::TRANSITION, 'Stair'], classify('IP_RM_05', 'public')
  end

  def test_common_and_special_space_names
    %w[subway public].each do |building|
      assert_equal [Type::CONNECTION, 'Door'], classify('RM_DR', building)
      assert_equal [Type::CONNECTION, 'Door'], classify('IS_DR', building)
      assert_equal [Type::GEOMETRY_ONLY, 'Window'], classify('RM_WD', building)
    end
    assert_equal [Type::TRANSITION, 'Elevator'], classify('MV_RM_01')
    assert_equal [Type::TRANSITION, 'Stair'], classify('MV_RM_02')
  end

  def test_unregistered_tags_are_rooms_only_when_a_classification_part_is_rm
    %w[F01F01_IP_RM F01B03_IP_RM_99 B01B07_RM_CUSTOM_42 F01F01_RM_YY].each do |tag|
      assert_equal [Type::GENERAL, 'Room'], @catalog.classify(tag, building_type: 'subway'), tag
    end
  end

  def test_invalid_or_non_rm_unmapped_tags_are_ignored
    ['', 'Untagged', 'F01_IP_RM_01', 'junk_IP_RM_01', 'F00F00_IP_RM_01',
     'F01F01_XX_RM_01', 'F01F01_FF_FC_99', 'F01F01_IS_WL', 'F01F01_IP',
     'F01F01_IP_RM_TEXT', 'F01F01_IP_RM_01_extra', 'F01F01_IP__RM'].each do |tag|
      assert_nil @catalog.classify(tag, building_type: 'subway'), tag
      assert_nil Adapter.storey_from_tag_name(tag, building_type: 'subway'), tag
    end
  end

  def test_storeys_are_extracted_and_non_transition_ranges_use_first_floor
    assert_equal 'B03~F01', Adapter.storey_from_tag_name('B03F01_IP_RM_01', building_type: 'subway')
    assert_equal 'F01', Adapter.storey_from_tag_name('F01F01_IP_RM_01', building_type: 'subway')
    assert_nil Adapter.storey_from_tag_name('F01F03_FF_FC_99', building_type: 'subway')
    assert_equal 'B03~F01', Adapter.resolve_cell_space_storey_value('B03~F01', Type::TRANSITION, 'Stair', 'F01')
    assert_equal 'B03', Adapter.resolve_cell_space_storey_value('B03~F01', Type::GENERAL, 'Room', 'F01')
  end

  def test_cache_does_not_reread_file_until_explicit_reload
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'tag_catalog.json')
      File.write(path, JSON.generate(categories: [row('지하철', 'MV', 'RM_01', '엘리베이터')]))
      Adapter.load_catalog!(path: path)
      File.write(path, JSON.generate(categories: [row('지하철', 'MV', 'RM_01', '계단')]))
      3.times do
        assert_equal [Type::TRANSITION, 'Elevator'], Adapter.cell_space_type_from_tag('F01F03_MV_RM_01', building_type: 'subway')
      end
      Adapter.load_catalog!(path: path)
      assert_equal [Type::TRANSITION, 'Stair'], Adapter.cell_space_type_from_tag('F01F03_MV_RM_01', building_type: 'subway')
    end
  end

  def test_legacy_read_support_and_shared_file_precedence
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'tag_catalog.json')
      legacy = File.join(directory, 'TagHelper', 'catalog.json')
      FileUtils.mkdir_p(File.dirname(legacy))
      File.write(legacy, JSON.generate(categories: [row('지하철', 'MV', 'RM_01', '엘리베이터')]))
      assert_equal [Type::TRANSITION, 'Elevator'], Catalog.load(path: path).classify('F01F01_MV_RM_01', building_type: 'subway')
      refute File.exist?(path)
      File.write(path, JSON.generate(categories: []))
      assert_equal [Type::GENERAL, 'Room'], Catalog.load(path: path).classify('F01F01_MV_RM_01', building_type: 'subway')
      assert_nil Catalog.load(path: path).classify('F01F01_MV_FC_01', building_type: 'subway')
      File.write(path, '{broken')
      refute_nil Catalog.load(path: path).error
    end
  end

  private

  def classify(code, building = 'subway')
    @catalog.classify("F01F03_#{code}", building_type: building)
  end

  def row(division, major, minor, name)
    { 'division' => division, 'major_code' => major, 'minor_code' => minor, 'minor_category' => name }
  end
end
