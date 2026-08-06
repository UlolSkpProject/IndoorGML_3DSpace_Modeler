# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  def self.active_model
    :model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      module ProductionProgress
        class ProductionProgressSession
          @instances = []

          class << self
            attr_reader :instances
          end

          attr_reader :events

          def initialize(**_options)
            @events = []
            @active = false
            self.class.instances << self
          end

          def start(message: nil)
            @active = true
            @events << [:start, message]
            self
          end

          def active?
            @active
          end

          def complete(message: nil, telemetry: nil)
            @events << [:complete, message, telemetry]
            @active = false
          end

          def fail(_error, message: nil)
            @events << [:fail, message]
            @active = false
          end

          def close
            @events << [:close]
          end
        end

        class SketchupOverlayProgressRenderer
          def initialize(model:); end
        end

        module CellSpaceProgressContext
          THREAD_KEY = :test_cell_space_progress

          module_function

          def current
            Thread.current[THREAD_KEY]
          end

          def with(progress)
            previous = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = progress
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end
      end

      CellSpaceMutationProgressTestResult = Struct.new(
        :converted_count,
        :errors,
        :metrics
      )

      class IndoorModel
        attr_reader :cell_space_mutation_test_create_progress,
                    :cell_space_mutation_test_type_progress

        def convert_cell_space_jobs_bulk(*_arguments, progress: nil, **_keywords)
          @cell_space_mutation_test_create_progress = progress
          CellSpaceMutationProgressTestResult.new(2, [], {})
        end

        def change_cell_space_types(groups, *_arguments, progress: nil, **_keywords)
          @cell_space_mutation_test_type_progress = progress
          groups
        end
      end
    end
  end
end

$LOADED_FEATURES << File.expand_path(
  '../indoor3d/application/progress/production_progress_session.rb',
  __dir__
)
$LOADED_FEATURES << File.expand_path(
  '../indoor3d/application/progress/adjacency_progress_keyword_guard.rb',
  __dir__
)
$LOADED_FEATURES << File.expand_path(
  '../indoor3d/ui/overlays/production_progress_overlay.rb',
  __dir__
)

require_relative '../indoor3d/application/progress/cell_space_mutation_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceMutationProgressIntegrationTest < Minitest::Test
        def setup
          ProductionProgress::ProductionProgressSession.instances.clear
        end

        def test_create_without_context_owns_overlay_session
          model = IndoorModel.new
          result = model.convert_cell_space_jobs_bulk(
            [1, 2],
            fallback_target: [:general, nil],
            original_active_path: []
          )

          assert_equal 2, result.converted_count
          assert_instance_of(
            ProductionProgress::ProductionProgressSession,
            model.cell_space_mutation_test_create_progress
          )
          assert_equal 1, ProductionProgress::ProductionProgressSession.instances.length
          assert_equal :complete, model.cell_space_mutation_test_create_progress.events[-2][0]
          assert_equal :close, model.cell_space_mutation_test_create_progress.events[-1][0]
        end

        def test_create_reuses_command_context_without_second_session
          model = IndoorModel.new
          existing = Object.new

          ProductionProgress::CellSpaceProgressContext.with(existing) do
            model.convert_cell_space_jobs_bulk(
              [1],
              fallback_target: [:general, nil],
              original_active_path: []
            )
          end

          assert_same existing, model.cell_space_mutation_test_create_progress
          assert_empty ProductionProgress::ProductionProgressSession.instances
        end

        def test_type_change_owns_overlay_session
          model = IndoorModel.new
          result = model.change_cell_space_types(%w[A B], :general)

          assert_equal %w[A B], result
          assert_instance_of(
            ProductionProgress::ProductionProgressSession,
            model.cell_space_mutation_test_type_progress
          )
          assert_equal 1, ProductionProgress::ProductionProgressSession.instances.length
          assert_equal :complete, model.cell_space_mutation_test_type_progress.events[-2][0]
          assert_equal :close, model.cell_space_mutation_test_type_progress.events[-1][0]
        end

        def test_type_change_with_explicit_progress_does_not_create_overlay
          model = IndoorModel.new
          explicit = Object.new

          model.change_cell_space_types(['A'], :general, progress: explicit)

          assert_same explicit, model.cell_space_mutation_test_type_progress
          assert_empty ProductionProgress::ProductionProgressSession.instances
        end
      end
    end
  end
end
