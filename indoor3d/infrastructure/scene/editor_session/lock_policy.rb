# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        module LockPolicy
          def lock_entity(entity)
            lock_controller.lock_entity(entity)
          end

          def unlock_entity(entity)
            lock_controller.unlock_entity(entity)
          end

          def with_unlocked(entity)
            lock_controller.with_unlocked(entity) { yield }
          end

          def apply_lock_policy
            lock_controller.apply(editing: @editing)
          end
        end
      end
    end
  end
end
