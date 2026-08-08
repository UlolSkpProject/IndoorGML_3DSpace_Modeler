# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Face; end
end

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        class << self
          attr_accessor :source_group_validation_result

          def validate_cell_space_source_group(_group)
            source_group_validation_result
          end
        end
      end
    end
  end
end

require_relative '../indoor3d/export/export_snapshot'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ExportSnapshotCavityPolicyTest < Minitest::Test
          def test_builder_accepts_classified_cavity_shells
            model = Struct.new(:cell_spaces, :transitions).new([], [])
            builder = ExportSnapshot::Builder.new(
              indoor_model: model,
              cell_spaces: [],
              transitions: [],
              transition_geometry_mode: ExportSnapshot::TRANSITION_GEOMETRY_ENDPOINTS
            )
            cell = Struct.new(:id).new('cell_cavity')
            group = Struct.new(:definition).new(Object.new)
            exterior_faces = [:outer]
            interior_faces = [[:inner]]
            Utils::Geometry.source_group_validation_result = {
              valid: true,
              component_count: 2,
              exterior_faces: exterior_faces,
              interior_face_components: interior_faces
            }

            result = builder.send(:validate_supported_cell_geometry!, cell, group)

            assert_same exterior_faces, result[:exterior_faces]
            assert_same interior_faces, result[:interior_face_components]
          end

          def test_builder_rejects_disconnected_exterior_shells
            model = Struct.new(:cell_spaces, :transitions).new([], [])
            builder = ExportSnapshot::Builder.new(
              indoor_model: model,
              cell_spaces: [],
              transitions: [],
              transition_geometry_mode: ExportSnapshot::TRANSITION_GEOMETRY_ENDPOINTS
            )
            cell = Struct.new(:id).new('cell_disconnected')
            group = Struct.new(:definition).new(Object.new)
            Utils::Geometry.source_group_validation_result = {
              valid: false,
              reason: 'Disconnected or nested solid shells detected (2 components)',
              component_count: 2
            }

            error = assert_raises(ExportSnapshot::UnsupportedCellSpaceGeometryError) do
              builder.send(:validate_supported_cell_geometry!, cell, group)
            end

            assert_includes error.message, 'cell_disconnected'
            assert_includes error.message, 'Disconnected or nested solid shells detected'
          end
        end
      end
    end
  end
end
