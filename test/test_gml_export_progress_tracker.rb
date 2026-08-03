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

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class GmlExportProgressTrackerTest < Minitest::Test
        Progress = ProductionProgress

        class Adapter
          attr_reader :events

          def initialize
            @events = []
            @active = false
          end

          def available? = true
          def active? = @active

          def start(message:)
            @active = true
            @events << [:start, message]
          end

          def start_stage(**options)
            @events << [:start_stage, options]
          end

          def update_stage(**options)
            @events << [:update_stage, options]
          end

          def finish_stage(**options)
            @events << [:finish_stage, options]
          end

          def complete(**options)
            @events << [:complete, options]
          end

          def fail(error, message:)
            @events << [:fail, error.class, message]
          end

          def close
            @events << [:close]
          end
        end

        class ValidationProgress
          attr_reader :details

          def initialize
            @details = []
          end

          def detail(step, **options)
            @details << [step, options]
          end
        end

        def test_large_stage_is_limited_to_about_one_hundred_updates
          adapter = Adapter.new
          tracker = Progress::GmlExportProgressTracker.new(adapter)

          assert tracker.start
          assert tracker.start_stage(
            'CellSpace Geometry 추출',
            total: 420,
            message: 'start'
          )
          420.times { tracker.advance(message: 'working') }
          tracker.finish_open_stage

          updates = adapter.events.count { |event| event.first == :update_stage }
          assert_operator updates, :<=, 102
          assert_operator updates, :>=, 80
        end

        def test_stage_order_is_fixed
          assert_equal [
            'CellSpace Geometry 추출',
            'State/Transition 구성',
            'Export 내용 검증',
            'GML 구조 생성',
            'XML 변환 및 파일 저장'
          ], Progress::GmlExportProgressTracker::STAGES
        end

        def test_validation_adapter_maps_stage_progress_to_overall_percent
          progress = ValidationProgress.new
          adapter = Progress::ValidationGmlExportProgressAdapter.new(
            progress: progress,
            step: :temp_file
          )
          tracker = Progress::GmlExportProgressTracker.new(adapter)

          tracker.start
          tracker.start_stage(
            'CellSpace Geometry 추출',
            total: 10,
            message: 'geometry'
          )
          5.times { tracker.advance(message: 'geometry') }
          tracker.finish_open_stage

          percentages = progress.details.map { |_step, options| options[:percent] }
          assert_includes percentages, 10
          assert_includes percentages, 20
          assert percentages.each_cons(2).all? { |left, right| right >= left }
        end

        def test_context_restores_previous_value
          first = Object.new
          second = Object.new

          Progress::GmlExportProgressContext.with(first) do
            assert_same first, Progress::GmlExportProgressContext.current
            Progress::GmlExportProgressContext.with(second) do
              assert_same second, Progress::GmlExportProgressContext.current
            end
            assert_same first, Progress::GmlExportProgressContext.current
          end

          assert_nil Progress::GmlExportProgressContext.current
        end
      end
    end
  end
end
