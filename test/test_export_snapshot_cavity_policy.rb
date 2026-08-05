# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Face; end
end

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        def self.validate_cell_space_source_group(_group)
          {
            valid: false,
            reason: 'Disconnected solid shells detected (2 components)',
            component_count: 2
          }
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
          def test_builder_explicitly_rejects_cavity_or_disconnected_shell
            model = Struct.new(:cell_spaces, :transitions).new([], [])
            builder = ExportSnapshot::Builder.new(
              indoor_model: model,
              cell_spaces: [],
              transitions: [],
              transition_geometry_mode: ExportSnapshot::TRANSITION_GEOMETRY_ENDPOINTS
            )
            cell = Struct.new(:id).new('cell_cavity')
            group = Struct.new(:definition).new(Object.new)

            error = assert_raises(ExportSnapshot::UnsupportedCellSpaceGeometryError) do
              builder.send(:validate_supported_cell_geometry!, cell, group)
            end

            assert_includes error.message, 'cell_cavity'
            assert_includes error.message, 'cavities and disconnected solid shells are unsupported'
          end
        end
      end
    end
  end
end
