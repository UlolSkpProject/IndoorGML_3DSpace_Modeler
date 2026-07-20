# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/export/gml_exporter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class GmlExporterLocalVertexNormalizationTest < Minitest::Test
          class FakeIndoorModel
            def ensure_vertices_locally_normalized_for_export(cell_spaces:)
              raise "Export must not normalize #{cell_spaces.inspect}"
            end
          end

          class ExporterHarness < GmlExporter
            attr_reader :events

            def initialize(*args, **kwargs)
              super
              @events = []
            end

            private

            def with_root_model_coordinates
              yield
            end

            def validate_exportable_content!
              @events << :validate
            end

            def document
              @events << :document
              '<IndoorGML />'
            end

            def log_export_timing_summary
              @events << :timing
            end
          end

          def test_export_does_not_run_local_vertex_normalization
            Dir.mktmpdir do |directory|
              output_path = File.join(directory, 'model.gml')
              exporter = ExporterHarness.new(
                FakeIndoorModel.new,
                refresh_runtime_data: false,
                cell_spaces: [Object.new]
              )

              result = exporter.export(output_path: output_path)

              assert_equal output_path, result
              assert_equal '<IndoorGML />', File.read(output_path)
              assert_equal [:validate, :document, :timing], exporter.events
              refute exporter.respond_to?(:ensure_local_vertices_normalized!, true)
            end
          end
        end
      end
    end
  end
end
