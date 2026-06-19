# frozen_string_literal: true

require 'json'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class ExportProgressDialog
          include Utils::HtmlHelpers

          STEPS = [
            [:runtime, 'runtime data refresh'],
            [:temp_file, "\uC784\uC2DC\uD30C\uC77C \uC0DD\uC131"],
            [:val3dity, "val3dity \uC2E4\uD589 (version2.2.0)"],
            [:report, "report \uC0DD\uC131"],
            [:report_view, "report view \uC0DD\uC131"]
          ].freeze

          INITIAL_WIDTH = 460
          INITIAL_HEIGHT = 430
          MIN_DIALOG_HEIGHT = 320
          MAX_DIALOG_HEIGHT = 720
          CONTENT_PADDING_HEIGHT = 8
          DIALOG_WINDOW_CHROME_HEIGHT = 44

          def initialize
            @dialog = nil
            @dialog_height = INITIAL_HEIGHT
            @statuses = {}
            @detail_payload = nil
            @result_payload = nil
            @dom_ready = false
            @pending_scripts = []
            @create_gml_callback = nil
            @open_report_callback = nil
            @open_temp_gml_callback = nil
            @request_close_callback = nil
            @suppress_close_callback = false
          end

          def show
            dialog.set_file(File.join(__dir__, 'html', 'export_progress', 'index.html'))
            dialog.show
          end

          def running(step)
            set_status(step, 'running')
          end

          def complete(step)
            set_status(step, 'complete')
          end

          def pending(step)
            set_status(step, 'pending')
          end

          def fail(step)
            set_status(step, 'failed')
          end

          def detail(step, percent: nil, phase: nil, message: nil, current: nil)
            payload = {
              step: step.to_s,
              percent: percent,
              phase: phase,
              message: message,
              current: current
            }
            @detail_payload = payload

            execute_or_queue("setDetail(#{JSON.generate(payload)});")
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Export progress detail update failed: #{e.class}: #{e.message}"
          end

          def result(status:, title:, message:, actions:)
            payload = {
              status: status.to_s,
              title: title,
              message: message,
              actions: actions.map(&:to_s)
            }
            @result_payload = payload

            execute_or_queue("setResult(#{JSON.generate(payload)});")
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Export progress result update failed: #{e.class}: #{e.message}"
          end

          def set_result_message(message)
            @result_payload[:message] = message if @result_payload
            execute_or_queue("setResultMessage(#{JSON.generate(message)});")
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Export progress result message update failed: #{e.class}: #{e.message}"
          end

          def on_create_gml(&block)
            @create_gml_callback = block
          end

          def on_open_report(&block)
            @open_report_callback = block
          end

          def on_open_temp_gml(&block)
            @open_temp_gml_callback = block
          end

          def on_request_close(&block)
            @request_close_callback = block
          end

          def request_close
            return if @request_close_callback&.call == :keep_open

            close
          end

          def close
            @suppress_close_callback = true
            @dialog&.close if @dialog&.visible?
            @dialog = nil
            @dom_ready = false
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Export progress close failed: #{e.class}: #{e.message}"
          end

          private

          def dialog
            @dialog ||= build_dialog
          end

          def build_dialog
            dialog = UI::HtmlDialog.new(
              dialog_title: 'Run val3dity2.2',
              preferences_key: 'ULOL.Indoor3DGmlModeler.ExportProgress',
              scrollable: false,
              resizable: false,
              width: INITIAL_WIDTH,
              height: INITIAL_HEIGHT,
              style: UI::HtmlDialog::STYLE_DIALOG
            )
            dialog.add_action_callback('domReady') do |_context|
              @dom_ready = true
              dialog.execute_script(init_script)
              replay_state
              @pending_scripts.clear
            end
            dialog.add_action_callback('fitContentHeight') do |_context, content_height|
              fit_content_height(content_height)
            end
            dialog.add_action_callback('createGml') do |_context|
              @create_gml_callback&.call
            end
            dialog.add_action_callback('openReport') do |_context|
              @open_report_callback&.call
            end
            dialog.add_action_callback('openTempGml') do |_context|
              @open_temp_gml_callback&.call
            end
            dialog.add_action_callback('closeDialog') do |_context|
              request_close
            end
            dialog.set_on_closed do
              handle_window_closed
            end if dialog.respond_to?(:set_on_closed)
            dialog
          end

          def handle_window_closed
            if @suppress_close_callback
              @suppress_close_callback = false
              @dialog = nil
              @dom_ready = false
              return
            end

            IndoorGmlConverter::Val3dityRunner.shutting_down!

            if @request_close_callback&.call == :keep_open
              @dialog = nil
              @dom_ready = false
              UI.start_timer(0, false) do
                show
              end
            else
              @dialog = nil
              @dom_ready = false
            end
          rescue StandardError => e
            @dialog = nil
            @dom_ready = false
            IndoorCore::Logger.puts "[IndoorGML] Export progress close request failed: #{e.class}: #{e.message}"
          end

          def fit_content_height(content_height)
            return unless @dialog

            requested_height = content_height.to_i + CONTENT_PADDING_HEIGHT + DIALOG_WINDOW_CHROME_HEIGHT
            height = [[requested_height, MIN_DIALOG_HEIGHT].max, MAX_DIALOG_HEIGHT].min
            return if height == @dialog_height

            @dialog.set_size(INITIAL_WIDTH, height)
            @dialog_height = height
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Export progress dialog resize failed: #{e.class}: #{e.message}"
          end

          def set_status(step, status)
            @statuses[step.to_s] = status

            execute_or_queue("setStatus(#{step.to_s.inspect}, #{status.inspect});")
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Export progress update failed: #{e.class}: #{e.message}"
          end

          def replay_state
            @statuses.each do |step, status|
              @dialog.execute_script("setStatus(#{step.inspect}, #{status.inspect});")
            end
            @dialog.execute_script("setDetail(#{JSON.generate(@detail_payload)});") if @detail_payload
            @dialog.execute_script("setResult(#{JSON.generate(@result_payload)});") if @result_payload
          end

          def execute_or_queue(script)
            return unless @dialog&.visible?

            if @dom_ready
              @dialog.execute_script(script)
            else
              @pending_scripts << script
            end
          end

          def init_script
            steps = STEPS.map do |key, label|
              "{key: #{key.to_s.inspect}, label: #{label.inspect}}"
            end.join(', ')
            "init([#{steps}]);"
          end
        end
      end
    end
  end
end
