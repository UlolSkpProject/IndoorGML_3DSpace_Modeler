# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Centralized UI feedback dispatcher.
      #
      # SketchUp 2026 does not provide a public "UI is settled" callback after a
      # large model mutation. Creating a new zero-delay timer immediately after a
      # bulk operation is also not reliable in that context. Instead, one repeating
      # dispatcher timer is registered once while the extension is loading. Runtime
      # operations only enqueue feedback; the already-running dispatcher consumes it
      # on a later UI turn.
      module UiFeedback
        DISPATCH_INTERVAL_SECONDS = 0.05
        MIN_DISPATCH_TURNS_AFTER_ENQUEUE = 1
        MAX_RETAINED_NOTIFICATIONS = 8

        class << self
          def start_dispatcher
            @pending_feedback ||= []
            @dispatcher_tick ||= 0
            return @dispatcher_timer_id unless @dispatcher_timer_id.nil?

            @dispatcher_timer_id = UI.start_timer(DISPATCH_INTERVAL_SECONDS, true) do
              dispatch_pending_feedback
            end
          rescue StandardError => e
            log_failure('UI feedback dispatcher start', e)
            @dispatcher_timer_id = nil
          end

          def dispatcher_started?
            !@dispatcher_timer_id.nil?
          end

          def dispatcher_diagnostics
            {
              timer_id: @dispatcher_timer_id,
              tick: @dispatcher_tick.to_i,
              pending: Array(@pending_feedback).length,
              dispatching_modal: @dispatching_modal == true
            }
          end

          def notify(message)
            enqueue_feedback(:notification, message)
          end

          # CellSpace conversion results are intentionally modal. The modal itself
          # is not opened inline after the model mutation; it is queued for the
          # persistent dispatcher that already existed before the mutation started.
          def publish_result(message, errors: nil)
            defer_modal(message)
          end

          # Queue a modal for the persistent dispatcher. This method intentionally
          # does not register a timer. It is safe for post-bulk callers because the
          # dispatcher already existed before the model mutation started.
          def defer_modal(message, *arguments)
            enqueue_feedback(:modal, message, arguments)
          end

          private

          def enqueue_feedback(kind, message, arguments = [])
            text = message.to_s
            return false if text.empty?

            unless dispatcher_started?
              log_message("UI feedback dispatcher unavailable: #{text}")
              return fallback_non_modal(text)
            end

            @pending_feedback ||= []
            @dispatcher_tick ||= 0
            @pending_feedback << {
              kind: kind,
              message: text,
              arguments: Array(arguments),
              ready_after_tick: @dispatcher_tick + MIN_DISPATCH_TURNS_AFTER_ENQUEUE
            }
            true
          rescue StandardError => e
            log_failure('UI feedback enqueue', e)
            fallback_non_modal(text)
          end

          def dispatch_pending_feedback
            @dispatcher_tick = @dispatcher_tick.to_i + 1
            return false if @dispatching_modal == true

            queue = (@pending_feedback ||= [])
            item = queue.first
            return false unless item
            return false if @dispatcher_tick <= item[:ready_after_tick].to_i

            queue.shift
            case item[:kind]
            when :modal
              show_modal_now(item)
            else
              show_notification_now(item[:message])
            end
            true
          rescue StandardError => e
            log_failure('UI feedback dispatch', e)
            false
          end

          def show_modal_now(item)
            @dispatching_modal = true
            UI.messagebox(item[:message], *Array(item[:arguments]))
          rescue StandardError => e
            log_failure('Modal UI', e)
            fallback_non_modal(item[:message])
          ensure
            @dispatching_modal = false
          end

          def show_notification_now(message)
            notification = build_notification(message)
            return fallback_non_modal(message) unless notification

            retain_notification(notification)
            shown = notification.show
            return true if shown == true

            fallback_non_modal(message)
          rescue StandardError => e
            log_failure('Notification', e)
            fallback_non_modal(message)
          end

          def build_notification(message)
            return nil unless defined?(UI::Notification)

            namespace = ::ULOL::Indoor3DGmlModeler
            return nil unless namespace.const_defined?(:EXTENSION, false)

            UI::Notification.new(namespace.const_get(:EXTENSION, false), message)
          end

          def retain_notification(notification)
            @retained_notifications ||= []
            @retained_notifications << notification
            @retained_notifications.shift while @retained_notifications.length > MAX_RETAINED_NOTIFICATIONS
            notification
          end

          def fallback_non_modal(message)
            Sketchup.status_text = message if defined?(Sketchup) && Sketchup.respond_to?(:status_text=)
            log_message(message)
            false
          rescue StandardError => e
            log_failure('Non-modal fallback', e)
            false
          end

          def log_message(message)
            IndoorCore::Logger.puts("[IndoorGML] #{message}") if defined?(IndoorCore::Logger)
          rescue StandardError
            nil
          end

          def log_failure(label, error)
            log_message("#{label} failed: #{error.class}: #{error.message}")
          end
        end
      end
    end
  end
end

# Register the dispatcher while the extension is loading, before any long-running
# CellSpace operation can enter the fragile post-bulk UI context. Re-loading this
# file in development is safe because start_dispatcher is idempotent.
ULOL::Indoor3DGmlModeler::IndoorCore::UiFeedback.start_dispatcher if defined?(UI)
