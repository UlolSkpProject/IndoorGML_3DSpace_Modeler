# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class EditActivePathController
          def initialize(indoor_model:, on_lock:, on_selection:, on_invalidate:, logger: nil)
            @indoor_model = indoor_model
            @on_lock = on_lock
            @on_selection = on_selection
            @on_invalidate = on_invalidate
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
            @previous_active_path = nil
            @editing_active_path_target = nil
            @editing_active_path_suspended = false
            @enforcing_active_path = false
            @active_path_enforcement_suspended = false
          end

          def remember_current_path(model)
            @previous_active_path = snapshot(model)
          end

          def clear_previous_path
            @previous_active_path = nil
          end

          def reset_target
            @editing_active_path_target = nil
            @editing_active_path_suspended = false
          end

          def reset
            @previous_active_path = nil
            @editing_active_path_target = nil
            @editing_active_path_suspended = false
            @enforcing_active_path = false
            @active_path_enforcement_suspended = false
          end

          def activate(model, target_path)
            return false unless model.respond_to?(:active_path=)

            @editing_active_path_target = target_path
            @editing_active_path_suspended = false
            set(model, target_path)
            true
          rescue StandardError => e
            log("Edit context activation failed: #{e.class}: #{e.message}")
            false
          end

          def set_target_path(path)
            @editing_active_path_target = path
            @editing_active_path_suspended = false
          end

          def target_path
            valid_target_path
          end

          def cell_space_geometry_editing?(editing:)
            editing && valid_target_path.length > 1
          end

          def editing_cell_space
            target = valid_target_path
            return nil unless target.length > 1

            target_group = target[1]
            @indoor_model.cell_spaces.find do |cell_space|
              cell_space&.valid? && cell_space.sketchup_group == target_group
            end
          rescue StandardError
            nil
          end

          def active_path_changed(model, editing:, reenter:)
            model ||= Sketchup.active_model
            if !editing && primal_group_active_path?(model)
              reenter.call
              return
            end

            return unless editing
            return if @enforcing_active_path
            return if @active_path_enforcement_suspended
            return adopt_suspended_active_path(model) if @editing_active_path_suspended

            enforce_edit_context(model)
          rescue StandardError => e
            log("Edit active path enforcement failed: #{e.class}: #{e.message}")
          end

          def with_suspended_enforcement
            previous = @active_path_enforcement_suspended
            @active_path_enforcement_suspended = true
            yield
          ensure
            @active_path_enforcement_suspended = previous
          end

          def reconcile_transaction_replay_path(model, editing:)
            return false unless editing

            raw_path = Array(model&.active_path)
            path = raw_path.select { |entity| entity&.valid? }
            primal_group = @indoor_model.primal_group
            @editing_active_path_target =
              if raw_path.length == path.length && (editing_cell_space_path?(path, primal_group) || matches_path?(path, [primal_group]))
                @editing_active_path_suspended = false
                path
              else
                @editing_active_path_suspended = true
                nil
              end
            true
          rescue StandardError => e
            log("Edit context transaction replay path reconciliation failed: #{e.class}: #{e.message}")
            false
          end

          def reconcile_after_runtime_restore(model, editing:)
            return false unless editing

            path = Array(model&.active_path).select { |entity| entity&.valid? }
            primal_group = @indoor_model.primal_group
            if editing_cell_space_path?(path, primal_group) || matches_path?(path, [primal_group])
              @editing_active_path_target = path
            else
              @editing_active_path_target = primal_group&.valid? ? [primal_group] : nil
            end
            @editing_active_path_suspended = false
            true
          rescue StandardError => e
            log("Edit context transaction reconciliation failed: #{e.class}: #{e.message}")
            false
          end

          def prepare_for_finish(model)
            active_path = model.active_path
            return if active_path.nil?

            primal_group = @indoor_model.primal_group
            return if matches?(model, [primal_group])

            if primal_group && active_path.first == primal_group
              set(model, [primal_group])
              return
            end

            close(model)
          rescue StandardError => e
            log("Edit context finish preparation failed: #{e.class}: #{e.message}")
          end

          def close(model)
            model.close_active while model.active_path
          rescue StandardError => e
            log("Edit context close failed: #{e.class}: #{e.message}")
          end

          def set(model, target_path)
            @enforcing_active_path = true
            model.active_path = target_path
          ensure
            @enforcing_active_path = false
          end

          def primal_group_active_path?(model)
            primal_group = @indoor_model.primal_group
            return false unless primal_group&.valid?

            matches?(model, [primal_group])
          end

          private

          def adopt_suspended_active_path(model)
            raw_path = Array(model&.active_path)
            path = raw_path.select { |entity| entity&.valid? }
            primal_group = @indoor_model.primal_group
            return false unless raw_path.length == path.length
            return false unless editing_cell_space_path?(path, primal_group) || matches_path?(path, [primal_group])

            @editing_active_path_target = path
            @editing_active_path_suspended = false
            notify_selection_and_view(model)
            true
          end

          def snapshot(model)
            path = model.active_path
            path ? path.dup : nil
          end

          def enforce_edit_context(model)
            target = valid_target_path
            return if target.empty?
            return if matches?(model, target)

            current_path = model.active_path
            if current_path.nil?
              set(model, target)
              notify_selection_and_view(model)
              return
            end

            primal_group = @indoor_model.primal_group
            if editing_cell_space_path?(current_path, primal_group)
              @editing_active_path_target = current_path
              notify_lock_selection_and_view(model)
              return
            end

            if current_path == [primal_group] && target.length > 1 && target.first == primal_group
              @editing_active_path_target = [primal_group]
              notify_lock_selection_and_view(model)
              return
            end

            set(model, target)
          end

          def valid_target_path
            return [] if @editing_active_path_suspended

            target = Array(@editing_active_path_target).select { |entity| entity&.valid? }
            return target unless target.empty?

            primal_group = @indoor_model.primal_group
            primal_group&.valid? ? [primal_group] : []
          end

          def matches?(model, target_path)
            active_path = model.active_path
            matches_path?(active_path, target_path)
          end

          def matches_path?(active_path, target_path)
            return false unless active_path && active_path.length == target_path.length

            active_path.each_with_index.all? { |entity, index| entity == target_path[index] }
          end

          def editing_cell_space_path?(path, primal_group)
            return false unless path&.length == 2
            return false unless path.first == primal_group

            cell_group = path.last
            @indoor_model.cell_spaces.any? do |cell_space|
              cell_space&.valid? && cell_space.sketchup_group == cell_group
            end
          rescue StandardError
            false
          end

          def notify_lock_selection_and_view(model)
            @on_lock.call
            notify_selection_and_view(model)
          end

          def notify_selection_and_view(model)
            @on_selection.call
            @on_invalidate.call(model)
          end

          def log(message)
            @logger.puts("[IndoorGML] #{message}") if @logger&.respond_to?(:puts)
          end
        end
      end
    end
  end
end
