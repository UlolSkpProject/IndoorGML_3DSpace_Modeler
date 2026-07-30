# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Centralized UI feedback policy for model mutations.
      #
      # Model-mutation results are always reported non-modally. A post-mutation
      # code path must never depend on registering a new timer immediately after
      # a large SketchUp transaction because SketchUp 2026 can reject that timer
      # registration without invoking its callback.
      #
      # defer_modal remains available only for callers that are already running
      # from a later UI event and genuinely require a modal user response.
      module UiFeedback
        class << self
          def notify(message)
            text = message.to_s
            return false if text.empty?

            notification = build_notification(text)
            return fallback_non_modal(text) unless notification

            retain_notification(notification)
            notification.show
            true
          rescue StandardError => e
            log_failure('Notification', e)
            fallback_non_modal(text)
          end

          def publish_result(message, errors: nil)
            notify(message)
          end

          def defer_modal(message, *arguments)
            fired = false
            timer_id = nil
            timer_id = UI.start_timer(0, false) do
              next if fired

              fired = true
              UI.stop_timer(timer_id) if timer_id && UI.respond_to?(:stop_timer)
              UI.messagebox(message, *arguments)
            end
            timer_id
          rescue StandardError => e
            log_failure('Deferred modal UI', e)
            nil
          end

          private

          def build_notification(message)
            return nil unless defined?(UI::Notification)

            namespace = ::ULOL::Indoor3DGmlModeler
            return nil unless namespace.const_defined?(:EXTENSION, false)

            UI::Notification.new(namespace.const_get(:EXTENSION, false), message)
          end

          # Keep the currently displayed notification alive. Do not attach
          # on_dismiss here: UI::Notification#on_dismiss requires a visible button
          # title and is not invoked for automatic timeout dismissal.
          def retain_notification(notification)
            @last_notification = notification
          end

          def fallback_non_modal(message)
            Sketchup.status_text = message if defined?(Sketchup) && Sketchup.respond_to?(:status_text=)
            IndoorCore::Logger.puts("[IndoorGML] #{message}") if defined?(IndoorCore::Logger)
            false
          rescue StandardError => e
            log_failure('Non-modal fallback', e)
            false
          end

          def log_failure(label, error)
            if defined?(IndoorCore::Logger)
              IndoorCore::Logger.puts(
                "[IndoorGML] #{label} failed: #{error.class}: #{error.message}"
              )
            end
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
