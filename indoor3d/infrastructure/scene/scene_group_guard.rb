# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class SceneGroupGuard
        def initialize(with_unlocked:, notifier: nil)
          @with_unlocked = with_unlocked
          @notifier = notifier
          @expected_names = {}
        end

        def track(group, expected_name)
          return unless group&.valid?

          @expected_names[group.persistent_id] = expected_name
        end

        def ensure_expected_name(group, expected_name)
          return unless group&.valid?

          @expected_names[group.persistent_id] = expected_name
        end

        def untrack(group)
          @expected_names.delete(group.persistent_id)
        rescue StandardError
          nil
        end

        def enforce(groups)
          groups.each do |group|
            next unless group&.valid?

            restore_name_if_needed(group)
          end
        end

        private

        def expected_name_for(group)
          @expected_names[group.persistent_id]
        end

        def name_changed?(group, expected_name = expected_name_for(group))
          !expected_name.nil? && group.name != expected_name
        end

        def restore_name_if_needed(group)
          expected_name = expected_name_for(group)
          return false unless name_changed?(group, expected_name)

          notify('This group name is managed by IndoorGML and cannot be changed.')
          @with_unlocked.call(group) { group.name = expected_name }
          true
        rescue StandardError
          false
        end

        def notify(message)
          @notifier&.call(message)
        end
      end

    end
  end
end
