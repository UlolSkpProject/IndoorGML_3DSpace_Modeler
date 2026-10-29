# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        # Validation-only visibility transaction. General Edit Mode filters remain
        # owned by EditVisibilityService and VisibilityController.
        class ValidationFocusVisibilityService
          MAX_PATH_DEPTH = 64

          def initialize(indoor_model:, validation_focus_controller:, visibility_controller:,
                         with_operation:, with_unlocked:, invalidate_view:)
            @indoor_model = indoor_model
            @focus = validation_focus_controller
            @visibility = visibility_controller
            @with_operation = with_operation
            @with_unlocked = with_unlocked
            @invalidate_view = invalidate_view
            discard
          end

          def begin_session(model, session_id:)
            return failure('Validation Model is unavailable') unless valid_model?(model)
            if @model && !@model.equal?(model)
              discard # Never restore into a replaced/closed model.
            end
            return success if @model.equal?(model) && @session_id == session_id

            return failure('Previous visibility session has not been restored') if @model
            @model = model
            @session_id = session_id
            @session_changes = []
            @row_changes = []
            @row_token = nil
            success
          end

          def active_for?(model, session_id:)
            @model && @model.equal?(model) && @session_id == session_id
          end

          # Applies the existing IndoorGML scope: primal visible, every valid
          # CellSpace according to FocusController, unrelated root branches intact.
          def apply(model, session_id:)
            return failure('Stale Validation visibility session') unless active_for?(model, session_id: session_id)
            return failure('Validation Model is no longer active') unless current_model?(model)

            row_token = current_row_token
            desired = visibility_targets(model)
            return failure('No usable PrimalSpaceFeatures') if desired.nil?

            old_row = @row_changes
            changed_row = @row_token != row_token
            next_row = changed_row ? [] : old_row.dup
            next_session = @session_changes.dup
            restore_steps = changed_row ? old_row.reverse.map { |entry| [entry[:entity], entry[:kind], entry[:before], nil] } : []
            apply_steps = desired.map do |entity, kind, value|
              [entity, kind, value, row_token ? :row : :session]
            end
            steps = restore_steps + apply_steps

            perform(model, steps) do |entity, kind, previous, owner|
              next unless owner # Restoring the old Row never captures a new baseline.

              snapshots = owner == :row ? next_row : next_session
              record_once(snapshots, entity, kind, previous)
            end
            @row_changes = next_row
            @session_changes = next_session
            @row_token = row_token
            invalidate(model)
            success
          rescue StandardError => e
            failure("Visibility 적용 실패: #{e.class}: #{e.message}")
          end

          # Final restoration is distinct from Row deselection. A Row deselection
          # calls apply() with no highlight and therefore restores only @row_changes.
          def end_session(model, session_id:)
            return success(restored: false) unless @model
            return failure('Visibility session identity mismatch') unless active_for?(model, session_id: session_id)
            unless current_model?(model)
              discard
              return failure('Validation Model changed: old visibility snapshot discarded')
            end

            steps = @row_changes.reverse.map { |entry| [entry[:entity], entry[:kind], entry[:before], nil] }
            steps.concat(@session_changes.reverse.map { |entry| [entry[:entity], entry[:kind], entry[:before], nil] })
            perform(model, steps)
            discard
            invalidate(model)
            success(restored: true)
          rescue StandardError => e
            failure("Visibility 복원 실패: #{e.class}: #{e.message}")
          end

          def discard
            @model = nil
            @session_id = nil
            @session_changes = []
            @row_changes = []
            @row_token = nil
            success(discarded: true)
          end

          private

          def current_row_token
            return nil unless @focus.highlight_active?

            [@focus.highlight_row_id.to_s, @focus.highlight_code.to_s]
          end

          def visibility_targets(model)
            primal = @indoor_model.primal_group
            return nil unless valid_entity?(primal)

            groups = Array(@indoor_model.cell_spaces).filter_map do |cell|
              next unless cell&.valid?

              group = cell.sketchup_group
              next unless @visibility.cell_space_visibility_target?(group)

              [cell, group]
            end
            targets = {}
            plan(targets, primal, :hidden, false)

            groups.each do |cell, group|
              plan(targets, group, :hidden, !@focus.visible_cell_space?(cell))
            end

            # Revealing an ancestor or Tag is necessary only for a visible target.
            # Do not isolate model.entities or any unrelated top-level siblings.
            visible_groups = groups.filter_map { |cell, group| group if @focus.visible_cell_space?(cell) }
            visible_groups.each do |group|
              path = instance_path(model, group)
              raise "Cannot resolve visible CellSpace instance path (PID=#{persistent_id(group)})" unless path

              path.each do |ancestor|
                plan(targets, ancestor, :hidden, false)
                layer = ancestor.layer if ancestor.respond_to?(:layer)
                plan(targets, layer, :tag_visible, true) if valid_tag?(layer)
              end
            end
            # Primal itself must be visible even in an empty-focus session.
            if visible_groups.empty?
              path = instance_path(model, primal)
              raise 'Cannot resolve PrimalSpaceFeatures instance path' unless path

              path.each do |ancestor|
                plan(targets, ancestor, :hidden, false)
                layer = ancestor.layer if ancestor.respond_to?(:layer)
                plan(targets, layer, :tag_visible, true) if valid_tag?(layer)
              end
            end
            targets.map { |(_id, _kind), entry| entry }
          end

          def plan(targets, entity, kind, value)
            targets[[entity_identity(entity), kind]] = [entity, kind, value]
          end

          # Returns the actual instance chain, not the shared ComponentDefinition
          # path. A visited-definition stack prevents recursive component loops.
          def instance_path(model, target)
            return nil unless model.respond_to?(:entities)

            search_instance_path(model.entities, target, [], [], 0)
          end

          def search_instance_path(entities, target, path, definitions, depth)
            return nil if depth > MAX_PATH_DEPTH || !entities&.respond_to?(:each)

            entities.each do |entity|
              next unless valid_entity?(entity) && container?(entity)

              candidate = path + [entity]
              return candidate if entity_identity(entity) == entity_identity(target)

              definition = entity.definition if entity.respond_to?(:definition)
              next_definitions = definitions
              if definition
                next if definitions.include?(definition.object_id)

                next_definitions = definitions + [definition.object_id]
              end
              nested = entity.entities if entity.respond_to?(:entities)
              nested ||= definition.entities if definition&.respond_to?(:entities)
              found = search_instance_path(nested, target, candidate, next_definitions, depth + 1)
              return found if found
            end
            nil
          end

          def container?(entity)
            return true if entity.respond_to?(:typename) && %w[Group ComponentInstance].include?(entity.typename.to_s)

            entity.respond_to?(:entities) || entity.respond_to?(:definition)
          end

          def valid_tag?(tag)
            valid_entity?(tag) && tag.respond_to?(:visible?) && tag.respond_to?(:visible=)
          end

          def perform(_model, steps)
            # No Undo operation if there are no changes. A Row transition can
            # still require a rollback to its Session baseline.
            return if steps.none? { |entity, kind, value, _| valid_entity?(entity) && state(entity, kind) != value }

            actions = []
            executed = false
            @with_operation.call do
              executed = true
              begin
                steps.each do |entity, kind, value, owner|
                  next unless valid_entity?(entity)

                  previous = state(entity, kind)
                  next if previous == value

                  # Capture before the write: setters can mutate then raise.
                  actions << [entity, kind, previous]
                  write(entity, kind, value)
                  yield(entity, kind, previous, owner) if block_given?
                end
              rescue StandardError => error
                # Roll back inside the same Observer suppression and Operation.
                failures = rollback_actions(actions)
                actions.clear if failures.empty?
                suffix = failures.empty? ? '' : " (Rollback 실패: #{failures.join('; ')})"
                raise RuntimeError, "#{error.message}#{suffix}"
              end
            end
            raise 'Visibility operation did not execute' unless executed
          rescue StandardError => error
            # Protect against an exception thrown by Operation commit/abort after
            # the callback returned. Never write outside the suppression wrapper.
            failures = []
            unless actions.empty?
              begin
                @with_operation.call { failures = rollback_actions(actions) }
              rescue StandardError => rollback_error
                failures << rollback_error.message
              end
            end
            suffix = failures.empty? ? '' : " (Rollback 실패: #{failures.join('; ')})"
            raise RuntimeError, "#{error.message}#{suffix}"
          end

          def rollback_actions(actions)
            failures = []
            actions.reverse_each do |entity, kind, previous|
              next unless valid_entity?(entity)

              begin
                next if state(entity, kind) == previous

                write(entity, kind, previous)
              rescue StandardError => restore_error
                failures << restore_error.message
              end
            end
            failures
          end

          def record_once(entries, entity, kind, before)
            return if entries.any? { |entry| entity_identity(entry[:entity]) == entity_identity(entity) && entry[:kind] == kind }

            entries << {
              entity: entity,
              persistent_id: persistent_id(entity),
              before: before,
              kind: kind,
              model: @model,
              session_id: @session_id
            }
          end

          def state(entity, kind)
            case kind
            when :hidden
              return entity.hidden? == true if entity.respond_to?(:hidden?)
              return entity.visible? != true if entity.respond_to?(:visible?)
            when :tag_visible
              return entity.visible? == true if entity.respond_to?(:visible?)
            end
            raise "Unsupported Visibility property: #{kind}"
          end

          def write(entity, kind, value)
            if kind == :tag_visible
              entity.visible = value
            else
              @with_unlocked.call(entity) do
                if entity.respond_to?(:hidden=)
                  entity.hidden = value
                elsif entity.respond_to?(:visible=)
                  entity.visible = !value
                else
                  raise 'Entity has no Hidden setter'
                end
              end
            end
            raise 'Visibility write did not take effect' unless state(entity, kind) == value
          end

          def persistent_id(entity)
            entity.persistent_id if entity.respond_to?(:persistent_id)
          end

          def entity_identity(entity)
            pid = persistent_id(entity)
            [entity.class.to_s, pid.nil? ? entity.object_id : pid.to_s]
          end

          def current_model?(model)
            return false unless valid_model?(model)
            return false unless @indoor_model.model.equal?(model)
            return true unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

            Sketchup.active_model.equal?(model)
          end

          def valid_model?(model)
            valid_entity?(model)
          end

          def valid_entity?(entity)
            return false unless entity
            return entity.valid? if entity.respond_to?(:valid?)

            true
          rescue StandardError
            false
          end

          def invalidate(model)
            @invalidate_view.call(model)
          end

          def success(**extra)
            { ok: true }.merge(extra)
          end

          def failure(message)
            { ok: false, message: message }
          end
        end
      end
    end
  end
end
