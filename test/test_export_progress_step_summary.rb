# frozen_string_literal: true
# encoding: UTF-8

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module HtmlDialogMetrics
        WINDOW_CHROME_HEIGHT = 40
      end

      module Logger
        def self.puts(_message); end
      end

      module IndoorGmlConverter; end
    end
  end
end

require_relative '../indoor3d/ui/export_progress_dialog'
require_relative '../indoor3d/ui/export_progress_step_summary'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ExportProgressStepSummaryTest < Minitest::Test
        class FakeDialog
          attr_reader :scripts

          def initialize
            @scripts = []
          end

          def visible?
            true
          end

          def execute_script(script)
            @scripts << script
          end
        end

        def setup
          @progress = IndoorGmlConverter::ExportProgressDialog.new
          @dialog = FakeDialog.new
          @progress.instance_variable_set(:@dialog, @dialog)
          @progress.instance_variable_set(:@dom_ready, true)
        end

        def test_step_summary_is_sent_and_replayed_by_step
          message = '전체 9개 중 성공 5개 · 실패 1개 · Skip 3개'

          assert @progress.set_step_summary(:lvn, message, tone: :warning)
          assert_includes @dialog.scripts.last, 'setStepSummary('
          assert_includes @dialog.scripts.last, '"step":"lvn"'
          assert_includes @dialog.scripts.last, '"tone":"warning"'

          before = @dialog.scripts.length
          @progress.send(:replay_state)
          assert_operator @dialog.scripts.length, :>, before
          assert_includes @dialog.scripts.last, message
        end

        def test_step_summary_assets_append_summary_below_each_step
          root = File.expand_path('..', __dir__)
          javascript = File.read(
            File.join(root, 'indoor3d/ui/html/export_progress/step_summary.js'),
            encoding: 'UTF-8'
          )
          stylesheet = File.read(
            File.join(root, 'indoor3d/ui/html/export_progress/step_summary.css'),
            encoding: 'UTF-8'
          )
          html = File.read(
            File.join(root, 'indoor3d/ui/html/export_progress/index.html'),
            encoding: 'UTF-8'
          )

          assert_includes javascript, 'content.appendChild(summary)'
          assert_includes javascript, 'function setStepSummary(payload)'
          assert_includes stylesheet, '.step-summary'
          assert_includes html, 'step_summary.css'
          assert_includes html, 'step_summary.js'
        end
      end
    end
  end
end
