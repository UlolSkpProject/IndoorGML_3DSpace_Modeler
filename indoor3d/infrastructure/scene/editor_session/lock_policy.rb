# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        module LockPolicy
          # Depends on EditorSession-owned state:
          # @editing, @editable_entity_ids, and @indoor_model.
          def lock_entity(entity)
            begin
              return true unless lockable?(entity)
              return true if editable_entity?(entity)
              return true if entity.respond_to?(:locked?) && entity.locked?

              entity.locked = true
              true
            rescue StandardError
              true
            end
          end

          def unlock_entity(entity)
            begin
              return true unless lockable?(entity)
              return true if entity.respond_to?(:locked?) && !entity.locked?

              entity.locked = false
              true
            rescue StandardError
              true
            end
          end

          def with_unlocked(entity)
            begin
              entities = temporary_unlock_entities(entity)
              lock_states = entities.to_h do |target|
                [target, target.respond_to?(:locked?) && target.locked?]
              end
              entities.each { |target| unlock_entity(target) if lock_states[target] }
              yield
            ensure
              entities&.reverse_each { |target| lock_entity(target) if lock_states&.[](target) }
            end
          end

          def apply_lock_policy
            @editable_entity_ids = {}
            primal_group = @indoor_model.primal_group
            return unless primal_group&.valid?

            unlock_entity(primal_group)
          end

          private

          def temporary_unlock_entities(entity)
            [entity].compact.select { |target| target&.valid?() }
          end

          def lockable?(entity)
            begin
              entity&.valid?() && entity.respond_to?(:locked=)
            rescue StandardError
              false
            end
          end
        end
      end
    end
  end
end
