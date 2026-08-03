# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class ProductionProgressOverlay
          private

          def displayed_percent(snapshot)
            stage = snapshot[:stage]
            stage ? stage[:percent].to_f : snapshot[:percent].to_f
          end
        end

        class SketchupOverlayProgressRenderer
          private

          def stage_signature(snapshot)
            stage = snapshot[:stage]
            [stage&.dig(:name), stage&.dig(:status), snapshot[:status]]
          end
        end
      end
    end
  end
end

require_relative '../indoor3d/ui/overlays/production_progress_without_elapsed'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class ProductionProgressWithoutElapsedTest < Minitest::Test
          def test_running_detail_omits_elapsed_time
            overlay = ProductionProgressOverlay.allocate
            text = overlay.send(
              :detail_text,
              stage: {
                name: 'Adjacency 상세 판정',
                completed: 250,
                total: 1000,
                percent: 25.0
              },
              percent: 25.0,
              elapsed: 99.9
            )

            assert_equal 'Adjacency 상세 판정 · 250 / 1000 ·  25.0%', text
            refute_includes text, '초'
          end

          def test_renderer_signature_changes_when_count_increases
            renderer = SketchupOverlayProgressRenderer.allocate
            first = renderer.send(
              :stage_signature,
              stage: {
                name: 'CellSpace/State 생성',
                status: :running,
                completed: 1,
                total: 10
              },
              status: :running
            )
            second = renderer.send(
              :stage_signature,
              stage: {
                name: 'CellSpace/State 생성',
                status: :running,
                completed: 2,
                total: 10
              },
              status: :running
            )

            refute_equal first, second
            assert_equal 1, first[2]
            assert_equal 2, second[2]
          end
        end
      end
    end
  end
end
