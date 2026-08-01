# frozen_string_literal: true

require_relative 'core'
require_relative 'overlay_state'
require_relative '../../indoor3d/ui/overlays/screen_overlay'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressOverlayPrototype
        PUMP_INTERVAL = 0.05
        TERMINAL_HOLD_SECONDS = 1.5
        DEFAULT_TOTAL = 1_200
        DEFAULT_WORK_PER_ITEM = 40_000

        class ProgressOverlay < ScreenOverlay
          OVERLAY_ID = 'ulol.indoor3dgml_modeler.threaded_progress_prototype'
          OVERLAY_NAME = 'IndoorGML Threaded Progress Prototype'

          PANEL_WIDTH = 560
          PANEL_HEIGHT = 80
          PANEL_MARGIN = 18
          PANEL_COLOR = Sketchup::Color.new(28, 32, 38, 225)
          TRACK_COLOR = Sketchup::Color.new(78, 84, 94, 255)
          FILL_COLOR = Sketchup::Color.new(44, 150, 108, 255)
          TERMINAL_COLOR = Sketchup::Color.new(45, 115, 190, 255)
          FAILED_COLOR = Sketchup::Color.new(190, 55, 55, 255)
          PRIMARY_TEXT_COLOR = Sketchup::Color.new(255, 255, 255, 255)
          SECONDARY_TEXT_COLOR = Sketchup::Color.new(214, 220, 228, 255)

          def initialize(state)
            @state = state
            super(
              OVERLAY_ID,
              OVERLAY_NAME,
              description: 'Shows progress from a pure Ruby worker without blocking the viewport.'
            )
          end

          def draw(view)
            snapshot = @state.snapshot
            return unless snapshot[:visible]

            width = [PANEL_WIDTH, viewport_width(view) - (PANEL_MARGIN * 2)].min
            return if width <= 80

            x = (viewport_width(view) - width) / 2.0
            y = [viewport_height(view) - PANEL_HEIGHT - PANEL_MARGIN, PANEL_MARGIN].max
            draw_panel(view, x, y, width, snapshot)
          rescue StandardError => e
            puts "[THREADED PROGRESS OVERLAY] draw failed: #{e.class}: #{e.message}"
          end

          private

          def draw_panel(view, x, y, width, snapshot)
            draw_2d_quad(view, quad(x, y, width, PANEL_HEIGHT), PANEL_COLOR)

            view.draw_text(
              Geom::Point3d.new(x + 14, y + 10, 0),
              snapshot[:message].to_s,
              text_options(size: 13, bold: true, color: PRIMARY_TEXT_COLOR)
            )

            view.draw_text(
              Geom::Point3d.new(x + 14, y + 32, 0),
              detail_text(snapshot),
              text_options(size: 10, bold: false, color: SECONDARY_TEXT_COLOR)
            )

            track_x = x + 14
            track_y = y + 59
            track_width = width - 28
            track_height = 8
            draw_2d_quad(view, quad(track_x, track_y, track_width, track_height), TRACK_COLOR)

            percent = normalized_percent(snapshot[:percent])
            fill_width = track_width * percent.fdiv(100.0)
            return unless fill_width.positive?

            draw_2d_quad(
              view,
              quad(track_x, track_y, fill_width, track_height),
              fill_color(snapshot)
            )
          end

          def detail_text(snapshot)
            percent = normalized_percent(snapshot[:percent])
            elapsed = format('%.2fs', snapshot[:elapsed].to_f)
            total = snapshot[:total].to_i
            return format('%6.2f%%   %s   %s', percent, snapshot[:type], elapsed) unless total.positive?

            completed = snapshot[:completed].to_i
            if snapshot[:terminal]
              return format('%6.2f%%   완료 %d / %d   %s', percent, completed, total, elapsed)
            end

            current_item = [[snapshot[:current_item].to_i, 1].max, total].min
            current_item_percent = normalized_percent(snapshot[:current_item_percent])
            format(
              '%6.2f%%   완료 %d / %d   현재 %d번 %.1f%%   %s',
              percent,
              completed,
              total,
              current_item,
              current_item_percent,
              elapsed
            )
          end

          def normalized_percent(value)
            [[value.to_f, 0.0].max, 100.0].min
          end

          def fill_color(snapshot)
            return FAILED_COLOR if snapshot[:type].to_sym == :failed
            return TERMINAL_COLOR if snapshot[:terminal]

            FILL_COLOR
          end

          def quad(x, y, width, height)
            [
              [x, y, 0],
              [x + width, y, 0],
              [x + width, y + height, 0],
              [x, y + height, 0]
            ]
          end
        end

        class Controller
          def initialize
            @main_thread = Thread.current
            @state = ThreadedProgressInfrastructure::OverlayState.new
            @overlay = nil
            @registered_model = nil
            @mailbox = nil
            @cancellation_token = nil
            @worker = nil
            @pump_timer_id = nil
            @hide_timer_id = nil
          end

          def install
            assert_main_thread!
            ensure_registered(Sketchup.active_model)
            invalidate_registered_view
            true
          end

          def start_job(total: DEFAULT_TOTAL, work_per_item: DEFAULT_WORK_PER_ITEM)
            assert_main_thread!
            return false if @worker&.alive?

            model = Sketchup.active_model
            return false unless ensure_registered(model)

            stop_timers
            @state.reset!
            @mailbox = ThreadedProgressInfrastructure::ProgressMailbox.new
            @cancellation_token = ThreadedProgressInfrastructure::CancellationToken.new
            @worker = ThreadedProgressInfrastructure::PureRubyWorker.new(
              mailbox: @mailbox,
              cancellation_token: @cancellation_token,
              total: total,
              work_per_item: work_per_item
            )
            @state.apply(
              type: :starting,
              completed: 0,
              total: total.to_i,
              current_item: 1,
              current_item_percent: 0.0,
              effective_completed: 0.0,
              percent: 0.0,
              main_thread_id: @main_thread.object_id
            )
            invalidate_registered_view
            @worker.start
            start_pump_timer
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
            snapshot = @state.snapshot.merge(
              main_thread_id: @main_thread.object_id,
              current_thread_id: Thread.current.object_id,
              worker_alive: @worker&.alive? == true,
              pump_timer_active: !@pump_timer_id.nil?,
              overlay_valid: @overlay&.valid? == true,
              registered_model_id: @registered_model&.object_id
            )
            puts "[THREADED PROGRESS OVERLAY] #{snapshot.inspect}"
            snapshot
          end

          def close
            assert_main_thread!
            @cancellation_token&.cancel!
            stop_timers
            @state.hide!
            invalidate_registered_view
            unregister_overlay
            true
          end

          private

          def ensure_registered(model)
            return false unless model&.respond_to?(:overlays)
            return true if @registered_model.equal?(model) && @overlay&.valid?

            unregister_overlay
            remove_stale_overlay(model)
            @overlay = ProgressOverlay.new(@state)
            model.overlays.add(@overlay)
            @overlay.enabled = true if @overlay.respond_to?(:enabled=)
            @registered_model = model
            true
          rescue StandardError => e
            puts "[THREADED PROGRESS OVERLAY] registration failed: #{e.class}: #{e.message}"
            false
          end

          def unregister_overlay
            model = @registered_model
            overlay = @overlay
            @registered_model = nil
            @overlay = nil
            return unless model&.respond_to?(:overlays)
            return unless overlay&.valid?

            model.overlays.remove(overlay)
          rescue StandardError
            nil
          end

          def remove_stale_overlay(model)
            stale = []
            model.overlays.each do |candidate|
              next unless candidate.overlay_id == ProgressOverlay::OVERLAY_ID
              next if candidate.equal?(@overlay)

              stale << candidate
            end
            stale.each { |candidate| model.overlays.remove(candidate) }
          end

          def start_pump_timer
            @pump_timer_id = UI.start_timer(PUMP_INTERVAL, true) { pump }
          end

          def pump
            assert_main_thread!
            unless Sketchup.active_model.equal?(@registered_model)
              @cancellation_token&.cancel!
              @state.apply(type: :failed, error_message: '작업 중 활성 모델이 변경되었습니다.')
              finish_terminal_event
              return false
            end

            events = @mailbox&.drain || []
            return true if events.empty?

            event = reduce_events(events)
            @state.apply(event.merge(queue_batch_size: events.length))
            invalidate_registered_view
            finish_terminal_event if @state.terminal?
            true
          rescue StandardError => e
            @state.apply(type: :failed, error_message: "#{e.class}: #{e.message}")
            invalidate_registered_view
            finish_terminal_event
            false
          end

          def reduce_events(events)
            terminal = events.reverse.find do |event|
              ThreadedProgressInfrastructure::OverlayState::TERMINAL_TYPES.include?(event[:type].to_sym)
            end
            terminal || events.last
          end

          def finish_terminal_event
            stop_pump_timer
            stop_hide_timer
            @hide_timer_id = UI.start_timer(TERMINAL_HOLD_SECONDS, false) do
              @hide_timer_id = nil
              @state.hide!
              invalidate_registered_view
              false
            end
          end

          def stop_timers
            stop_pump_timer
            stop_hide_timer
          end

          def stop_pump_timer
            stop_timer(:@pump_timer_id)
          end

          def stop_hide_timer
            stop_timer(:@hide_timer_id)
          end

          def stop_timer(variable_name)
            timer_id = instance_variable_get(variable_name)
            instance_variable_set(variable_name, nil)
            return if timer_id.nil?
            return unless UI.respond_to?(:stop_timer)

            UI.stop_timer(timer_id)
          rescue StandardError
            nil
          end

          def invalidate_registered_view
            @registered_model&.active_view&.invalidate
          rescue StandardError
            nil
          end

          def assert_main_thread!
            return if Thread.current.equal?(@main_thread)

            raise "SketchUp API access attempted outside main thread: #{Thread.current.object_id}"
          end
        end

        class << self
          def install!
            controller.install
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

puts '[THREADED PROGRESS OVERLAY PROTOTYPE] installed'
puts 'Install: ...::ThreadedProgressOverlayPrototype.install!'
puts 'Start  : ...::ThreadedProgressOverlayPrototype.start!'
puts 'Cancel : ...::ThreadedProgressOverlayPrototype.cancel!'
puts 'Status : ...::ThreadedProgressOverlayPrototype.status!'
puts 'Close  : ...::ThreadedProgressOverlayPrototype.close!'
