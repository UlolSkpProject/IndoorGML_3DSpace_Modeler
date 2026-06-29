# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        module LockPolicy
          # Depends on EditorSession-owned state:
          # @editing, @editable_entity_ids, and @indoor_model.
          def lock_entity(_entity)
            true
          end

          def unlock_entity(_entity)
            true
          end

          def with_unlocked(_entity)
            yield
          end

          def apply_lock_policy
            @editable_entity_ids = {}
          end
        end
      end
    end
  end
end
