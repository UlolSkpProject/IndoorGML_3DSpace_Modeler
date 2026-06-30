# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        module LockPolicy
          # Depends on EditorSession-owned state:
          # @editing, @editable_entity_ids, and @indoor_model.
          def lock_entity(entity)
            set_entity_locked(entity, true)
          end

          def unlock_entity(entity)
            set_entity_locked(entity, false)
          end

          def with_unlocked(entity)
            return yield unless lockable_entity?(entity)

            was_locked = entity.locked?
            entity.locked = false if was_locked
            yield
          ensure
            entity.locked = true if was_locked && entity&.valid?
          end

          def apply_lock_policy
            return true unless @editing == true

            primal_group = @indoor_model.primal_group

            unlock_entity(primal_group) if primal_group&.valid?

            @indoor_model.cell_spaces.each do |cell_space|
              group = cell_space&.sketchup_group
              next unless group&.valid?

              unlock_entity(group)
            end

            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Lock policy apply failed: #{e.class}: #{e.message}"
            false
          end

          private

          def lockable_entity?(entity)
            entity&.valid? && entity.respond_to?(:locked?) && entity.respond_to?(:locked=)
          rescue StandardError
            false
          end

          def set_entity_locked(entity, locked)
            return false unless lockable_entity?(entity)

            entity.locked = locked == true
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Entity lock update failed: #{e.class}: #{e.message}"
            false
          end
        end
      end
    end
  end
end
