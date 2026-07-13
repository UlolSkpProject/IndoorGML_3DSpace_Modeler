# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Face; end unless const_defined?(:Face, false)
end

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Materials
        def self.cell_space(_cell_type, _category_code)
          'cell-space-material'
        end
      end
    end

    module IndoorCore
      class IndoorModel
      end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/feature_lifecycle'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceMaterialApplicationTest < Minitest::Test
        def test_applies_material_to_group_and_clears_face_materials
          face = FakeFace.new(material: 'old-front', back_material: 'old-back')
          group = FakeGroup.new([face])
          cell_space = Struct.new(:sketchup_group, :cell_type, :category_code).new(group, :general, 'Room')
          model = FakeIndoorModel.new

          model.apply_material(cell_space)

          assert_equal 'cell-space-material', group.material
          assert_nil face.material
          assert_nil face.back_material
        end

        class FakeIndoorModel
          include IndoorModel::FeatureLifecycle

          def apply_material(cell_space)
            apply_cell_space_material(cell_space)
          end
        end

        class FakeGroup
          attr_accessor :material
          attr_reader :entities

          def initialize(faces)
            @entities = FakeEntities.new(faces)
          end
        end

        class FakeEntities
          def initialize(faces)
            @faces = faces
          end

          def grep(_klass)
            @faces.each { |face| yield face } if block_given?
            @faces
          end
        end

        class FakeFace < Sketchup::Face
          attr_accessor :material, :back_material

          def initialize(material: nil, back_material: nil)
            @material = material
            @back_material = back_material
          end
        end
      end
    end
  end
end
