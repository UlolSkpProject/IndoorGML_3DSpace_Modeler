# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class ExportProgressDialog
          include Utils::HtmlHelpers

          STEPS = [
            [:runtime, 'runtime data refresh'],
            [:temp_file, "\uC784\uC2DC\uD30C\uC77C \uC0DD\uC131"],
            [:val3dity, "val3dity \uC2E4\uD589"],
            [:report, "report \uC0DD\uC131"],
            [:report_view, "report view \uC0DD\uC131"]
          ].freeze

          INITIAL_WIDTH = 380
          INITIAL_HEIGHT = 320

          def initialize
            @dialog = nil
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

          def close
            @dialog&.close if @dialog&.visible?
            @dialog = nil
          rescue StandardError => e
            puts "[IndoorGML] Export progress close failed: #{e.class}: #{e.message}"
          end

          private

          def dialog
            @dialog ||= build_dialog
          end

          def build_dialog
            dialog = UI::HtmlDialog.new(
              dialog_title: 'IndoorGML Export',
              preferences_key: 'ULOL.Indoor3DGmlModeler.ExportProgress',
              scrollable: false,
              resizable: false,
              width: INITIAL_WIDTH,
              height: INITIAL_HEIGHT,
              style: UI::HtmlDialog::STYLE_DIALOG
            )
            dialog.add_action_callback('domReady') do |_context|
              dialog.execute_script(init_script)
            end
            dialog
          end

          def set_status(step, status)
            return unless @dialog&.visible?

            @dialog.execute_script("setStatus(#{step.to_s.inspect}, #{status.inspect});")
          rescue StandardError => e
            puts "[IndoorGML] Export progress update failed: #{e.class}: #{e.message}"
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
