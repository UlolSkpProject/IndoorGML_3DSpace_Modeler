# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        # Coordinates the already-existing Focus, Visibility, Rendering, Overlay,
        # Camera and ActivePath APIs. It never owns their snapshots or geometry.
        # An absent Stage-4 overlay service uses OverlayController as an adapter.
        class ValidationResultFocusService
          attr_reader :last_result, :state, :session_generation, :row_generation

          def initialize(indoor_model:, focus:, cancel_async:, apply_visibility:, apply_rendering:,
                         show_overlay:, clear_overlay:, schedule_camera:, restore_camera:,
                         restore_context:, refresh:, restore_previous_context: nil)
            @indoor_model = indoor_model
            @focus = focus
            @cancel_async = cancel_async
            @apply_visibility = apply_visibility
            @apply_rendering = apply_rendering
            @show_overlay = show_overlay
            @clear_overlay = clear_overlay
            @schedule_camera = schedule_camera
            @restore_camera = restore_camera
            @restore_context = restore_context
            @restore_previous_context = restore_previous_context
            @refresh = refresh
            @session_generation = 0
            @row_generation = 0
            @state = :inactive
            @last_result = result(ok: true, status: :inactive)
          end

          def begin_session(model)
            return failure('Validation session is not active') unless @focus.active?
            return failure('Validation Model is invalid') unless same_model?(model)
            return failure('Validation session already started') unless @state == :inactive

            @session_generation += 1
            @model = model
            @state = :session_active
            @last_result = result(ok: true, status: @state)
          end

          def focus_row(cell_ids, code = nil, row_id: nil, row_cells: nil, states: nil, transitions: nil)
            return failure('Validation session is not active') unless @focus.active?
            unless same_model?(@model)
              invalidate_async
              return failure('Validation Model has changed')
            end
            return failure('Focus session is restoring') if @state == :restoring
            return failure('Focus scene requires restoration') if @state == :failed
            return failure('Focus session is unavailable') if @state == :inactive

            ids = Array(cell_ids).map(&:to_s).reject(&:empty?).uniq
            selected = !row_id.to_s.empty?
            if selected && ids.empty?
              return failure('Focus Row has no valid CellSpace', row_id: row_id)
            end
            if selected && @focus.respond_to?(:focus_row) && !@focus.focus_row(row_id)
              return failure('Focus Row ID is no longer registered', row_id: row_id)
            end
            if !selected && !ids.empty?
              return failure('Focus request is missing Row ID')
            end

            previous = @focus.snapshot
            previous_path = !selected && @model.respond_to?(:active_path) ? Array(@model.active_path).dup : nil
            previous_path = nil if previous_path&.empty?
            context_attempted = false
            @cancel_async.call
            @row_generation += 1

            # Clearing the old Row overlay is deliberately before its Visibility
            # restore, and the original Focus Snapshot is retained for rollback.
            warnings = []
            begin
              warnings << 'Old validation geometry could not be cleared' if @clear_overlay.call == false
            rescue StandardError => e
              warnings << "Old validation geometry clear failed: #{e.class}: #{e.message}"
            end
            options = {}
            options[:row_id] = row_id unless row_id.nil?
            options[:row_cells] = row_cells unless row_cells.nil?
            options[:states] = states unless states.nil?
            options[:transitions] = transitions unless transitions.nil?
            updated = if options.empty?
                        @focus.set_highlight(ids, code)
                      else
                        @focus.set_highlight(ids, code, **options)
                      end
            return rollback(previous, 'Validation Row state update failed', row_id) if updated == false

            # Required Scene changes first. Context reset is part of deselection
            # and its own ActivePath policy stays in EditorSession.
            return rollback(previous, 'Validation Visibility update failed', row_id) unless @apply_visibility.call
            return rollback(previous, 'RenderingOptions update failed', row_id) unless @apply_rendering.call
            unless selected
              camera = @restore_camera.call
              return rollback(previous, 'Camera Snapshot restoration failed', row_id) unless successful?(camera)
              context_attempted = true
              unless @restore_context.call
                return rollback(previous, 'Primal edit context restoration failed', row_id,
                                previous_path: previous_path)
              end
            end

            if selected
              begin
                geometry = @show_overlay.call(row_id)
                warnings << 'Validation geometry could not be displayed' if geometry.nil? || geometry == false
              rescue StandardError => e
                warnings << "Validation geometry failed: #{e.class}: #{e.message}"
              end
              begin
                camera = @schedule_camera.call(row_id)
                warnings << 'Camera framing was not scheduled' unless successful?(camera)
              rescue StandardError => e
                warnings << "Camera framing failed: #{e.class}: #{e.message}"
              end
            end

            begin
              @refresh.call
            rescue StandardError => e
              warnings << "Scene redraw failed: #{e.class}: #{e.message}"
            end
            @state = selected ? :row_focused : :session_active
            @last_result = result(ok: true, status: warnings.empty? ? :success : :partial,
                                  row_id: selected ? row_id : nil, warnings: warnings)
          rescue StandardError => e
            rollback(previous, "Focus transition failed: #{e.class}: #{e.message}", row_id,
                     previous_path: context_attempted ? previous_path : nil)
          end

          # Cleanup is separated from EditSession.close. A failed required restore
          # is reported without clearing FocusController or its owned snapshots.
          def end_session(model:, restore_visibility:, restore_rendering:, restore_camera: true)
            errors = {}
            warnings = []
            begin
              @cancel_async.call
            rescue StandardError => e
              errors[:async] = "#{e.class}: #{e.message}"
            end
            @row_generation += 1
            @state = :restoring
            begin
              warnings << 'Validation overlay clear failed' if @clear_overlay.call == false
            rescue StandardError => e
              warnings << "Validation overlay clear failed: #{e.class}: #{e.message}"
            end

            if same_model?(model)
              begin
                errors[:visibility] = 'Restore failed' unless successful?(restore_visibility.call)
              rescue StandardError => e
                errors[:visibility] = "#{e.class}: #{e.message}"
              end
              begin
                errors[:rendering] = 'Restore failed' unless successful?(restore_rendering.call)
              rescue StandardError => e
                errors[:rendering] = "#{e.class}: #{e.message}"
              end
              if restore_camera
                begin
                  errors[:camera] = 'Camera Snapshot restoration failed' unless successful?(@restore_camera.call)
                rescue StandardError => e
                  errors[:camera] = "Camera Snapshot restoration failed: #{e.class}: #{e.message}"
                end
              end
            else
              errors[:model] = 'Original Validation Model is no longer active'
            end

            if errors.empty?
              @model = nil
              @state = :inactive
            else
              @state = :failed
            end
            @last_result = result(ok: errors.empty?,
                                  status: errors.empty? ? :inactive : :failed,
                                  errors: errors, warnings: warnings)
          rescue StandardError => e
            @state = :failed
            failure("Validation session cleanup failed: #{e.class}: #{e.message}")
          end

          def invalidate_async
            @cancel_async.call
            @row_generation += 1
          end

          def discard
            invalidate_async
            @model = nil
            @state = :inactive
            @last_result = result(ok: true, status: :inactive)
          end

          private

          def rollback(previous, message, row_id, previous_path: nil)
            errors = { transition: message }
            if previous
              begin
                @focus.restore!(previous)
              rescue StandardError => e
                errors[:state] = e.message
              end
              if previous_path && @restore_previous_context && same_model?(@model)
                begin
                  restored_path = @restore_previous_context.call(previous_path)
                  errors[:active_path] = 'Previous Edit Context restore failed' unless restored_path
                rescue StandardError => e
                  errors[:active_path] = e.message
                end
              end
              begin
                errors[:visibility] = 'Rollback failed' unless @apply_visibility.call
              rescue StandardError => e
                errors[:visibility] = e.message
              end
              begin
                errors[:rendering] = 'Rollback failed' unless @apply_rendering.call
              rescue StandardError => e
                errors[:rendering] = e.message
              end
              begin
                old_id = previous[:highlight_row_id]
                old_id.to_s.empty? ? @clear_overlay.call : @show_overlay.call(old_id)
              rescue StandardError => e
                errors[:overlay] = e.message
              end
            end
            old_row = previous && previous[:highlight_row_id].to_s
            if errors.keys == [:transition] && !old_row.to_s.empty?
              begin
                camera = @schedule_camera.call(old_row)
                errors[:camera] = 'Previous Row camera reschedule failed' unless successful?(camera)
              rescue StandardError => e
                errors[:camera] = e.message
              end
            end
            @state = errors.keys == [:transition] ? (old_row.to_s.empty? ? :session_active : :row_focused) : :failed
            @last_result = result(ok: false, status: :failed, row_id: row_id, errors: errors)
          end

          def same_model?(model)
            return false unless model && @indoor_model.model.equal?(model)
            return false if model.respond_to?(:valid?) && !model.valid?
            return false if defined?(Sketchup) && Sketchup.respond_to?(:active_model) &&
                            !Sketchup.active_model.equal?(model)

            true
          end

          def successful?(value)
            value == true || (value.is_a?(Hash) && value[:ok] == true)
          end

          def result(ok:, status:, row_id: nil, errors: {}, warnings: [])
            {
              ok: ok, status: status, row_id: row_id,
              session_generation: @session_generation, row_generation: @row_generation,
              errors: errors, warnings: warnings
            }
          end

          def failure(message, row_id: nil)
            @last_result = result(ok: false, status: :failed, row_id: row_id, errors: { request: message })
          end
        end
      end
    end
  end
end
