# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class FakeLogger
        attr_reader :messages

        def initialize
          @messages = []
        end

        def puts(message)
          @messages << message
        end
      end

      class BulkCellSpaceConversionService
        attr_reader :converter_calls, :sync_calls

        def initialize(jobs:, converter:, synchronize_all:, logger: FakeLogger.new)
          @jobs = jobs
          @converter = converter
          @synchronize_all = synchronize_all
          @logger = logger
          @converter_calls = 0
          @sync_calls = 0
        end

        def call
          plan = prepare_plan
          plan = validate_plan_geometry(plan)
          plan = validate_plan_targets(plan)
          apply_plan(plan)
        end

        private

        def prepare_plan
          @jobs
        end

        def validate_plan_geometry(plan)
          plan
        end

        def validate_plan_targets(plan)
          plan
        end

        def apply_plan(plan)
          plan.each do |job|
            @converter.call(job, :general, nil, 'F01')
            @converter_calls += 1
          end
          @sync_calls += 1
          @synchronize_all.call
          :applied
        end
      end

      class IndoorModel
        attr_reader :built_service

        def initialize(converter:, synchronize_all:)
          @converter = converter
          @synchronize_all = synchronize_all
        end

        def convert_cell_space_jobs_bulk(
          jobs,
          fallback_target:,
          original_active_path:,
          preserve_source: nil,
          operation_name: 'Convert Solid Groups to CellSpace',
          activate_root_context: true
        )
          build_batch_conversion_service(
            jobs,
            fallback_target: fallback_target,
            original_active_path: original_active_path,
            preserve_source: preserve_source,
            operation_name: operation_name,
            activate_root_context: activate_root_context,
            local_grid_v2: false
          ).call
        end

        private

        def build_batch_conversion_service(jobs, **_keywords)
          @built_service = BulkCellSpaceConversionService.new(
            jobs: jobs,
            converter: @converter,
            synchronize_all: @synchronize_all
          )
        end
      end
    end
  end
end

require_relative '../indoor3d/application/progress/cell_space_create_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class CellSpaceCreateProgressIntegrationTest < Minitest::Test
          class RecordingProgress
            attr_reader :events

            def initialize(fail_on: nil)
              @events = []
              @active = true
              @fail_on = fail_on
            end

            def active?
              @active
            end

            def start_stage(name, total:, message:, cancellable:, metadata: {})
              raise 'progress start failed' if @fail_on == :start_stage

              @events << [:start_stage, name, total, message, cancellable, metadata]
            end

            def update_stage(completed:, message:, telemetry: nil)
              raise 'progress update failed' if @fail_on == :update_stage

              @events << [:update_stage, completed, message, telemetry]
            end

            def finish_stage(message:, telemetry: nil)
              raise 'progress finish failed' if @fail_on == :finish_stage

              @events << [:finish_stage, message, telemetry]
            end
          end

          def test_service_emits_stage_boundaries_and_per_job_creation_progress
            converted = []
            progress = RecordingProgress.new
            service = BulkCellSpaceConversionService.new(
              jobs: %i[a b c],
              converter: proc { |source, type, category, storey| converted << [source, type, category, storey] },
              synchronize_all: proc { { pair_comparison_count: 3 } }
            )
            service.production_progress = progress

            assert_equal :applied, service.call
            assert_equal 3, converted.length

            starts = progress.events.select { |event| event.first == :start_stage }
            assert_equal [
              '사전검사/작업 준비',
              '사전검사/형상 검증',
              '사전검사/대상 검증',
              'CellSpace/State 생성',
              'CellSpace 재질 적용'
            ], starts.map { |event| event[1] }

            creation_updates = progress.events.select do |event|
              event.first == :update_stage && event[2].include?('CellSpace/State 생성')
            end
            assert_equal [1, 2, 3], creation_updates.map { |event| event[1] }

            final_stage = progress.events.reverse.find { |event| event.first == :finish_stage }
            assert_equal 'CellSpace 재질 및 Topology 후처리 완료', final_stage[1]
            assert_equal({ pair_comparison_count: 3 }, final_stage[2])
          end

          def test_adjacency_sink_replaces_material_stage_with_detailed_stages
            progress = RecordingProgress.new
            sink = AdjacencyProgressSink.new(progress, logger: FakeLogger.new)
            sink.mark_stage_open('CellSpace 재질 적용')

            sink.call(
              event: :stage_start,
              stage: :candidate_generation,
              name: 'Adjacency 후보 생성',
              total: 10,
              completed: 0,
              message: '후보 생성 중'
            )
            sink.call(
              event: :stage_progress,
              stage: :candidate_generation,
              name: 'Adjacency 후보 생성',
              total: 10,
              completed: 5,
              message: '5 / 10'
            )
            sink.call(
              event: :stage_finish,
              stage: :candidate_generation,
              name: 'Adjacency 후보 생성',
              total: 10,
              completed: 10,
              message: '후보 생성 완료',
              telemetry: { candidate_pair_count: 4 }
            )

            assert_equal [:finish_stage, 'CellSpace 재질 적용 완료', nil], progress.events[0]
            assert_equal :start_stage, progress.events[1][0]
            assert_equal 'Adjacency 후보 생성', progress.events[1][1]
            assert_equal [:update_stage, 5, '5 / 10', nil], progress.events[2]
            assert_equal [:finish_stage, '후보 생성 완료', { candidate_pair_count: 4 }], progress.events[3]
          end

          def test_three_argument_converter_contract_is_preserved
            calls = []
            service = BulkCellSpaceConversionService.new(
              jobs: [:a],
              converter: proc { |source, type, category| calls << [source, type, category] },
              synchronize_all: proc { {} }
            )
            service.production_progress = RecordingProgress.new

            assert_equal :applied, service.call
            assert_equal [[:a, :general, nil]], calls
          end

          def test_progress_failures_do_not_change_conversion_result
            converted = []
            logger = FakeLogger.new
            service = BulkCellSpaceConversionService.new(
              jobs: %i[a b],
              converter: proc { |source, _type, _category, _storey| converted << source },
              synchronize_all: proc { {} },
              logger: logger
            )
            service.production_progress = RecordingProgress.new(fail_on: :start_stage)

            assert_equal :applied, service.call
            assert_equal %i[a b], converted
            refute_empty logger.messages
          end

          def test_indoor_model_injects_progress_without_forwarding_unknown_keyword_to_original_method
            converted = []
            progress = RecordingProgress.new
            model = IndoorModel.new(
              converter: proc { |source, _type, _category, _storey| converted << source },
              synchronize_all: proc { {} }
            )

            result = model.convert_cell_space_jobs_bulk(
              %i[a b],
              fallback_target: [:general, nil],
              original_active_path: [],
              progress: progress
            )

            assert_equal :applied, result
            assert_equal %i[a b], converted
            assert_includes progress.events.map(&:first), :start_stage
            assert_nil model.instance_variable_get(:@production_cell_space_progress)
          end
        end
      end
    end
  end
end
