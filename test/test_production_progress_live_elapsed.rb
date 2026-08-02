# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress; end
    end
  end
end

require_relative '../indoor3d/ui/overlays/production_progress_live_elapsed'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class ProductionProgressLiveElapsedTest < Minitest::Test
          class Host
            prepend ProductionProgressOverlayLiveElapsed

            private

            def displayed_percent(snapshot)
              snapshot[:stage] ? snapshot[:stage][:percent].to_f : snapshot[:percent].to_f
            end
          end

          def test_running_snapshot_uses_current_monotonic_time
            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 2.0
            snapshot = {
              terminal: false,
              started_at: started_at,
              elapsed: 0.1,
              percent: 25.0,
              stage: nil
            }

            text = Host.new.send(:detail_text, snapshot)
            seconds = text[/([0-9]+\.[0-9])초/, 1].to_f

            assert_operator seconds, :>=, 1.9
            assert_operator seconds, :<, 3.0
          end

          def test_terminal_snapshot_keeps_frozen_elapsed_value
            snapshot = {
              terminal: true,
              started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 100.0,
              elapsed: 4.2,
              percent: 100.0,
              stage: nil
            }

            text = Host.new.send(:detail_text, snapshot)

            assert_includes text, '4.2초'
          end
        end
      end
    end
  end
end
