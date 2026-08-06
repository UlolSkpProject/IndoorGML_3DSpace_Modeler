# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Centralized UI feedback dispatcher.
      #
      # All application-owned message boxes are queued here. Runtime code never opens
      # UI.messagebox inline; one dispatcher timer created at extension load consumes
      # queued feedback on a later UI turn. Confirmations use the same queue and resume
      # their caller through a callback after the user responds.
      module UiFeedback
        DISPATCH_INTERVAL_SECONDS = 0.05
        MIN_DISPATCH_TURNS_AFTER_ENQUEUE = 1
        MAX_RETAINED_NOTIFICATIONS = 8
        MODAL_SUPPRESSION_DEPTH_KEY = :ulol_indoor3d_modal_feedback_suppression_depth
        MODAL_SUPPRESSION_REASON_KEY = :ulol_indoor3d_modal_feedback_suppression_reason

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

          # Suppresses only informational/error modal messages enqueued inside the
          # block. Confirmations are intentionally not suppressed because they are
          # control flow, not passive feedback. The scope is thread-local and
          # nestable so an initial model refresh cannot leak suppression into later
          # user commands.
          def with_modal_suppressed(reason: nil)
            thread = Thread.current
            previous_depth = thread[MODAL_SUPPRESSION_DEPTH_KEY].to_i
            previous_reason = thread[MODAL_SUPPRESSION_REASON_KEY]
            thread[MODAL_SUPPRESSION_DEPTH_KEY] = previous_depth + 1
            thread[MODAL_SUPPRESSION_REASON_KEY] = reason unless reason.nil?
            yield
          ensure
            if defined?(thread) && thread
              thread[MODAL_SUPPRESSION_DEPTH_KEY] = previous_depth
              thread[MODAL_SUPPRESSION_REASON_KEY] = previous_reason
            end
          end

          def modal_suppressed?
            Thread.current[MODAL_SUPPRESSION_DEPTH_KEY].to_i.positive?
          rescue StandardError
            false
          end

          def notify(message)
            enqueue_feedback(:notification, message)
          end

          def publish_result(message, errors: nil)
            defer_modal(message)
          end

          def defer_modal(message, *arguments)
            enqueue_feedback(:modal, message, arguments)
          end

          def confirm(message, *arguments, &callback)
            modal_arguments = arguments.empty? ? [MB_YESNO] : arguments
            enqueue_feedback(:confirmation, message, modal_arguments, callback)
          end

          private

          def enqueue_feedback(kind, message, arguments = [], callback = nil)
            text = message.to_s
            return false if text.empty?

            if kind == :modal && modal_suppressed?
              reason = Thread.current[MODAL_SUPPRESSION_REASON_KEY]
              suffix = reason.nil? ? '' : " reason=#{reason}"
              log_message("Modal feedback suppressed#{suffix}: #{text}")
              return false
            end

            unless dispatcher_started?
              log_message("UI feedback dispatcher unavailable: #{text}")
              fallback_non_modal(text)
              callback&.call(nil)
              return false
            end

            @pending_feedback ||= []
            @dispatcher_tick ||= 0
            @pending_feedback << {
              kind: kind,
              message: text,
              arguments: Array(arguments),
              callback: callback,
              ready_after_tick: @dispatcher_tick + MIN_DISPATCH_TURNS_AFTER_ENQUEUE
            }
            true
          rescue StandardError => e
            log_failure('UI feedback enqueue', e)
            fallback_non_modal(text)
            callback&.call(nil)
            false
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
            when :modal, :confirmation
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
            result = UI.messagebox(item[:message], *Array(item[:arguments]))
            item[:callback]&.call(result)
            result
          rescue StandardError => e
            log_failure('Modal UI', e)
            fallback_non_modal(item[:message])
            item[:callback]&.call(nil)
            nil
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

ULOL::Indoor3DGmlModeler::IndoorCore::UiFeedback.start_dispatcher if defined?(UI)
