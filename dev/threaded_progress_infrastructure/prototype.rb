# frozen_string_literal: true

require 'json'
require_relative 'core'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructurePrototype
        PUMP_INTERVAL = 0.05
        DEFAULT_TOTAL = 1_200
        DEFAULT_WORK_PER_ITEM = 40_000
        TERMINAL_TYPES = %i[completed cancelled failed].freeze

        class Controller
          def initialize
            @main_thread = Thread.current
            @dialog = nil
            @dialog_ready = false
            @mailbox = nil
            @cancellation_token = nil
            @worker = nil
            @timer_id = nil
            @last_event = idle_event
          end

          def show
            assert_main_thread!
            dialog.set_file(File.join(__dir__, 'index.html'))
            dialog.show
            true
          end

          def start_job(total: DEFAULT_TOTAL, work_per_item: DEFAULT_WORK_PER_ITEM)
            assert_main_thread!
            return false if @worker&.alive?

            stop_timer
            @mailbox = ThreadedProgressInfrastructure::ProgressMailbox.new
            @cancellation_token = ThreadedProgressInfrastructure::CancellationToken.new
            @worker = ThreadedProgressInfrastructure::PureRubyWorker.new(
              mailbox: @mailbox,
              cancellation_token: @cancellation_token,
              total: total,
              work_per_item: work_per_item
            )
            @last_event = {
              type: :starting,
              completed: 0,
              total: total.to_i,
              percent: 0.0,
              main_thread_id: @main_thread.object_id
            }
            push_event_to_dialog(@last_event)
            @worker.start
            start_timer
            true
          end

          def cancel_job
            assert_main_thread!
            return false unless @cancellation_token

            @cancellation_token.cancel!
            true
          end

          def status
            assert_main_thread!
            snapshot = @last_event.merge(
              main_thread_id: @main_thread.object_id,
              current_thread_id: Thread.current.object_id,
              worker_alive: @worker&.alive? == true,
              timer_active: !@timer_id.nil?
            )
            puts "[THREADED PROGRESS PROTOTYPE] #{snapshot.inspect}"
            snapshot
          end

          def close
            assert_main_thread!
            @cancellation_token&.cancel!
            stop_timer
            @dialog&.close if @dialog&.visible?
            @dialog = nil
            @dialog_ready = false
            true
          end

          private

          def dialog
            @dialog ||= build_dialog
          end

          def build_dialog
            instance = UI::HtmlDialog.new(
              dialog_title: 'Threaded Progress Infrastructure Prototype',
              preferences_key: 'ULOL.Indoor3DGmlModeler.ThreadedProgressPrototype',
              scrollable: false,
              resizable: false,
              width: 500,
              height: 390,
              style: UI::HtmlDialog::STYLE_DIALOG
            )

            instance.add_action_callback('domReady') do |_context|
              UI.start_timer(0, false) do
                next unless @dialog

                @dialog_ready = true
                push_event_to_dialog(@last_event)
              end
            end
            instance.add_action_callback('startPrototype') do |_context, total, work_per_item|
              UI.start_timer(0, false) do
                start_job(total: total, work_per_item: work_per_item)
              end
            end
            instance.add_action_callback('cancelPrototype') do |_context|
              UI.start_timer(0, false) { cancel_job }
            end
            instance.add_action_callback('requestStatus') do |_context|
              UI.start_timer(0, false) { status }
            end
            instance.set_on_closed do
              @cancellation_token&.cancel!
              stop_timer
              @dialog = nil
              @dialog_ready = false
            end if instance.respond_to?(:set_on_closed)

            instance
          end

          def start_timer
            stop_timer
            @timer_id = UI.start_timer(PUMP_INTERVAL, true) { pump }
          end

          def stop_timer
            return unless @timer_id

            UI.stop_timer(@timer_id)
            @timer_id = nil
          rescue StandardError
            @timer_id = nil
          end

          def pump
            assert_main_thread!
            events = @mailbox&.drain || []
            return if events.empty?

            @last_event = reduce_events(events)
            push_event_to_dialog(@last_event)
            stop_timer if TERMINAL_TYPES.include?(@last_event[:type].to_sym)
          rescue StandardError => e
            @last_event = {
              type: :failed,
              error_class: e.class.name,
              error_message: e.message,
              main_thread_id: @main_thread.object_id
            }
            push_event_to_dialog(@last_event)
            stop_timer
          end

          def reduce_events(events)
            terminal = events.reverse.find { |event| TERMINAL_TYPES.include?(event[:type].to_sym) }
            selected = terminal || events.last
            selected.merge(
              main_thread_id: @main_thread.object_id,
              queue_batch_size: events.length
            )
          end

          def push_event_to_dialog(event)
            return unless @dialog_ready
            return unless @dialog&.visible?

            payload = JSON.generate(event)
            @dialog.execute_script("window.ThreadedProgressPrototype.update(#{payload});")
          end

          def idle_event
            {
              type: :idle,
              total: DEFAULT_TOTAL,
              completed: 0,
              percent: 0.0,
              main_thread_id: @main_thread.object_id
            }
          end

          def assert_main_thread!
            return if Thread.current.equal?(@main_thread)

            raise "SketchUp UI access attempted outside main thread: #{Thread.current.object_id}"
          end
        end

        class << self
          def show!
            controller.show
          end

          def start!(total: DEFAULT_TOTAL, work_per_item: DEFAULT_WORK_PER_ITEM)
            controller.start_job(total: total, work_per_item: work_per_item)
          end

          def cancel!
            controller.cancel_job
          end

          def status!
            controller.status
          end

          def close!
            controller.close
          end

          private

          def controller
            @controller ||= Controller.new
          end
        end
      end
    end
  end
end

puts '[THREADED PROGRESS INFRASTRUCTURE PROTOTYPE] installed'
puts 'Show   : ...::ThreadedProgressInfrastructurePrototype.show!'
puts 'Start  : ...::ThreadedProgressInfrastructurePrototype.start!'
puts 'Cancel : ...::ThreadedProgressInfrastructurePrototype.cancel!'
puts 'Status : ...::ThreadedProgressInfrastructurePrototype.status!'
