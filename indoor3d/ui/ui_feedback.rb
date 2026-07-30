# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Centralized UI feedback policy for model mutations.
      #
      # Successful operations stay non-modal through UI::Notification. Any modal
      # feedback that is still required is moved to the next SketchUp event-loop
      # turn with a zero-delay timer. This intentionally expresses an event-loop
      # boundary rather than an arbitrary time delay.
      module UiFeedback
        class << self
          def notify(message)
            text = message.to_s
            return false if text.empty?

            notification = build_notification(text)
            unless notification
              defer_modal(text)
              return false
            end

            retain_notification(notification)
            notification.show
            true
          rescue StandardError => e
            log_failure('Notification', e)
            defer_modal(text) unless text.to_s.empty?
            false
          end

          def publish_result(message, errors: nil)
            Array(errors).empty? ? notify(message) : defer_modal(message)
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
