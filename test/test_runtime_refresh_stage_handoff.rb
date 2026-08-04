# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  def self.active_model
    nil
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      module ProductionProgress
        class SketchupOverlayProgressRenderer
          attr_reader :forwarded_snapshots, :model

          def initialize(model:)
            @model = model
            @forwarded_snapshots = []
          end

          def update(snapshot)
            @forwarded_snapshots << snapshot
            :forwarded
          end
        end

        class ProductionProgressSession
          attr_reader :title, :total, :renderer, :cancellable, :metadata

          def initialize(title:, total:, renderer:, cancellable:, metadata:)
            @title = title
            @total = total
            @renderer = renderer
            @cancellable = cancellable
            @metadata = metadata
          end
        end
      end

      class IndoorModel
        def initialize(model)
          @model = model
        end
      end
    end
  end
end

require_relative '../indoor3d/application/progress/runtime_refresh_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class RuntimeRefreshStageHandoffTest < Minitest::Test
        Progress = ProductionProgress

        def test_intermediate_one_hundred_percent_snapshots_are_not_forwarded
          renderer = Progress::RuntimeRefreshProgressRenderer.new(model: Object.new)

          assert_equal :forwarded, renderer.update(snapshot(:running, 9, 10))
          assert renderer.update(snapshot(:running, 10, 10))
          assert renderer.update(snapshot(:completed, 10, 10))
          assert_equal :forwarded, renderer.update(snapshot(:running, 0, 5))

          assert_equal 2, renderer.forwarded_snapshots.length
          assert_equal 9, renderer.forwarded_snapshots[0][:stage][:completed]
          assert_equal 0, renderer.forwarded_snapshots[1][:stage][:completed]
        end

        def test_terminal_completion_is_forwarded
          renderer = Progress::RuntimeRefreshProgressRenderer.new(model: Object.new)
          terminal = snapshot(:completed, 10, 10, terminal: true)

          assert_equal :forwarded, renderer.update(terminal)
          assert_equal [terminal], renderer.forwarded_snapshots
        end

        def test_zero_total_intermediate_completion_is_not_forwarded
          renderer = Progress::RuntimeRefreshProgressRenderer.new(model: Object.new)

          assert renderer.update(snapshot(:completed, 0, 0))
          assert_empty renderer.forwarded_snapshots
        end

        def test_runtime_refresh_session_uses_handoff_renderer
          model = Object.new
          indoor_model = IndoorModel.new(model)

          session = indoor_model.send(:build_runtime_refresh_progress_session, true)

          assert_equal 'IndoorGML 모델 열기', session.title
          assert_equal 6, session.total
          assert_instance_of Progress::RuntimeRefreshProgressRenderer, session.renderer
          assert_same model, session.renderer.model
          assert_equal :runtime_refresh, session.metadata[:operation]
          assert_equal true, session.metadata[:initial_model_load]
        end

        private

        def snapshot(status, completed, total, terminal: false)
          {
            terminal: terminal,
            stage: {
              status: status,
              completed: completed,
              total: total
            }
          }
        end
      end
    end
  end
end
