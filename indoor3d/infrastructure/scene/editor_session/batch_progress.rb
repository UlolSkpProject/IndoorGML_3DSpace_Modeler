# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        module BatchProgress
          # Owns @progress.
          # Depends on EditorSession private helpers:
          # ensure_overlay_registered, update_overlay_enabled, and invalidate_view.
          def progress_active?
            @progress && @progress[:active] == true
          end

          def progress_current
            @progress ? @progress[:current].to_i : 0
          end

          def progress_total
            @progress ? @progress[:total].to_i : 0
          end

          def progress_message
            @progress ? @progress[:message].to_s : ''
          end

          def start_progress(total, message)
            @progress = {
              active: true,
              current: 0,
              total: [total.to_i, 0].max,
              message: message.to_s
            }
            model = Sketchup.active_model()
            ensure_overlay_registered(model)
            update_overlay_enabled()
            invalidate_view(model)
            true
          end

          def update_progress(current, message = nil)
            return false unless @progress

            @progress[:current] = [current.to_i, 0].max
            @progress[:message] = message.to_s if message
            invalidate_view(Sketchup.active_model())
            true
          end

          def finish_progress
            @progress = nil
            model = Sketchup.active_model()
            update_overlay_enabled()
            invalidate_view(model)
            true
          end

          def run_batched(items, message:, batch_size: 20, complete: nil, failure: nil, &block)
            items = Array(items)
            return false if items.empty?

            batch_size = [batch_size.to_i, 1].max
            index = 0
            total = items.length
            start_progress(total, message)

            processor = nil
            processor = proc do
              begin
                limit = [index + batch_size, total].min
                while index < limit
                  block.call(items[index], index) if block
                  index += 1
                end
                update_progress(index, message)
                if index < total
                  UI.start_timer(0, false) { processor.call }
                else
                  finish_progress()
                  complete&.call()
                end
              rescue StandardError => e
                finish_progress()
                if failure
                  failure.call(e)
                else
                  IndoorCore::Logger.puts "[IndoorGML] Batched operation failed: #{e.class}: #{e.message}"
                end
              end
            end
            UI.start_timer(0, false) { processor.call }
            true
          end
        end
      end
    end
  end
end
