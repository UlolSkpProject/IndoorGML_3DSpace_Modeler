# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/application/progress/gml_export_progress_integration'
require_relative '../indoor3d/application/progress/gml_export_progress_stage_order'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class GmlExportProgressStageOrderTest < Minitest::Test
        Progress = ProductionProgress

        class Tracker
          def initialize(events)
            @events = events
          end

          def active? = true

          def start_stage(name, total:, message:)
            @events << [:start_stage, name, total, message]
          end

          def advance(message: nil, **_options)
            @events << [:advance, message]
          end

          def finish_open_stage(message: nil, **_options)
            @events << [:finish_stage, message]
          end
        end

        class ExporterBase
          attr_reader :events

          def initialize(events)
            @events = events
          end

          private

          def export_snapshot
            @events << :snapshot
            :snapshot
          end

          def validate_exportable_content!
            @events << :core_validation
            true
          end
        end

        class InstrumentedExporter < ExporterBase
          prepend Progress::GmlExporterProgressIntegration
          prepend Progress::GmlExporterProgressStageOrder
        end

        def test_snapshot_is_built_before_validation_stage_starts
          events = []
          tracker = Tracker.new(events)
          exporter = InstrumentedExporter.new(events)

          result = Progress::GmlExportProgressContext.with(tracker) do
            exporter.send(:validate_exportable_content!)
          end

          assert result
          assert_equal :snapshot, events[0]
          assert_equal 'Export 내용 검증', events[1][1]
          assert_equal :core_validation, events[2]
          assert_equal :advance, events[3][0]
          assert_equal :finish_stage, events[4][0]
        end

        def test_production_exporter_has_all_progress_layers
          ancestors = IndoorGmlConverter::GmlExporter.ancestors

          assert_includes ancestors, Progress::GmlExporterProgressStageOrder
          assert_includes ancestors, Progress::GmlExporterProgressIntegration
          assert_operator(
            ancestors.index(Progress::GmlExporterProgressStageOrder),
            :<,
            ancestors.index(Progress::GmlExporterProgressIntegration)
          )
        end
      end
    end
  end
end
