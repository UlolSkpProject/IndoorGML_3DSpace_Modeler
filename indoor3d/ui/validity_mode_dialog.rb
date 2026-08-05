# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ValidityModeDialog
        WIDTH = 520
        HEIGHT = 430

        class << self
          def show(&on_select)
            current = active
            if current&.visible?
              current.bring_to_front
              return current
            end

            instance = new(&on_select)
            @active_dialog = instance
            instance.show
            instance
          end

          def active
            dialog = @active_dialog
            dialog&.visible? ? dialog : nil
          rescue StandardError
            nil
          end

          def clear_active(instance)
            @active_dialog = nil if @active_dialog.equal?(instance)
          end
        end

        def initialize(&on_select)
          @on_select = on_select
          @dialog = nil
          @closed = false
        end

        def show
          dialog.set_file(File.join(__dir__, 'html', 'validity_mode', 'index.html'))
          dialog.show
          dialog.set_size(WIDTH, HEIGHT)
          self
        end

        def visible?
          @dialog && @dialog.visible?
        rescue StandardError
          false
        end

        def bring_to_front
          return unless visible?

          if @dialog.respond_to?(:bring_to_front)
            @dialog.bring_to_front
          else
            @dialog.show
          end
        rescue StandardError
          nil
        end

        def close
          return if @closed

          @closed = true
          @dialog&.close if @dialog&.visible?
          self.class.clear_active(self)
          @dialog = nil
        rescue StandardError => e
          IndoorCore::Logger.puts(
            "[IndoorGML] Validity mode dialog close failed: #{e.class}: #{e.message}"
          )
        end

        private

        def dialog
          @dialog ||= build_dialog
        end

        def build_dialog
          html_dialog = UI::HtmlDialog.new(
            dialog_title: 'IndoorGML Validity Check',
            preferences_key: 'ULOL.Indoor3DGmlModeler.ValidityMode',
            scrollable: false,
            resizable: false,
            width: WIDTH,
            height: HEIGHT,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          html_dialog.add_action_callback('selectFast') do |_context|
            commit_selection(:fast)
          end
          html_dialog.add_action_callback('selectPrecision') do |_context|
            commit_selection(:precision)
          end
          html_dialog.add_action_callback('cancel') do |_context|
            close
          end
          html_dialog.set_on_closed do
            @closed = true
            self.class.clear_active(self)
            @dialog = nil
            @on_select = nil
          end if html_dialog.respond_to?(:set_on_closed)
          html_dialog
        end

        def commit_selection(profile)
          callback = @on_select
          @on_select = nil
          close
          return unless callback

          UI.start_timer(0, false) do
            callback.call(profile)
          end
        rescue StandardError => e
          IndoorCore::Logger.puts(
            "[IndoorGML] Validity mode selection failed: #{e.class}: #{e.message}"
          )
        end
      end
    end
  end
end
