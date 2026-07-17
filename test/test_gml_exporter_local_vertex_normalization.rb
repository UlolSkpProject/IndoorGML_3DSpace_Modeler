# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/export/gml_exporter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class GmlExporterLocalVertexNormalizationTest < Minitest::Test
          class FakeIndoorModel
            attr_reader :calls

            def initialize
              @calls = []
            end

            def ensure_vertices_locally_normalized_for_export(cell_spaces:)
              @calls << cell_spaces
              {
                tolerance_mm: 0.01,
                cell_space_count: 1,
                already_normalized_cell_space_count: 2
              }
            end
          end

          def test_exporter_passes_requested_cell_spaces_to_normalization_guard
            indoor_model = FakeIndoorModel.new
            requested = [Object.new, Object.new]
            exporter = GmlExporter.new(indoor_model, refresh_runtime_data: false, cell_spaces: requested)

            report = exporter.send(:ensure_local_vertices_normalized!)

            assert_equal [requested], indoor_model.calls
            assert_equal 1, report[:cell_space_count]
          end

          def test_exporter_requires_normalization_capability
            exporter = GmlExporter.new(Object.new, refresh_runtime_data: false)

            error = assert_raises(RuntimeError) do
              exporter.send(:ensure_local_vertices_normalized!)
            end

            assert_match(/does not support local vertex normalization/, error.message)
          end
        end
      end
    end
  end
end
