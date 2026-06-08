# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class SceneGroupGuard
        def initialize(with_unlocked:, notifier: nil)
          @with_unlocked = with_unlocked
          @notifier = notifier
          @expected_names = {}
          @last_transforms = {}
        end

        def track(group, expected_name)
          return unless group&.valid?

          @expected_names[group.persistent_id] = expected_name
          @last_transforms[group.persistent_id] = group.transformation
        end

        def ensure_expected_name(group, expected_name)
          return unless group&.valid?

          @expected_names[group.persistent_id] = expected_name
          @last_transforms[group.persistent_id] ||= group.transformation
        end

        def untrack(group)
          @expected_names.delete(group.persistent_id)
          @last_transforms.delete(group.persistent_id)
        rescue StandardError
          nil
        end

        def enforce(groups)
          groups.each do |group|
            next unless group&.valid?

            restore_name_if_needed(group)
            restore_scale_if_needed(group)
          end
        end

        private

        def expected_name_for(group)
          @expected_names[group.persistent_id]
        end

        def last_transform_for(group)
          @last_transforms[group.persistent_id] || Geom::Transformation.new
        end

        def name_changed?(group, expected_name = expected_name_for(group))
          !expected_name.nil? && group.name != expected_name
        end

        def scaled?(group)
          Utils::Transformation.scaled?(group.transformation)
        end

        def restore_name_if_needed(group)
          expected_name = expected_name_for(group)
          return false unless name_changed?(group, expected_name)

          notify('This group name is managed by IndoorGML and cannot be changed.')
          @with_unlocked.call(group) { group.name = expected_name }
          true
        end

        def restore_scale_if_needed(group)
          return false unless scaled?(group)

          notify('This group scale is managed by IndoorGML and cannot be changed.')
          set_group_transformation(group, last_transform_for(group))
          true
        end

        def notify(message)
          @notifier&.call(message)
        end

        def set_group_transformation(group, transformation)
          @with_unlocked.call(group) do
            if group.respond_to?(:transformation=)
              group.transformation = transformation
            else
              group.transform!(group.transformation.inverse * transformation)
            end
          end
        end
      end

    end
  end
end
