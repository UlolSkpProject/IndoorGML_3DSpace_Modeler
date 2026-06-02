# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class SceneGroupGuard
        def initialize(with_unlocked:)
          @with_unlocked = with_unlocked
          @expected_names = {}
          @last_transforms = {}
        end

        def track(group, expected_name)
          return unless group&.valid?

          @expected_names[group.persistent_id] = expected_name
          @last_transforms[group.persistent_id] = group.transformation
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

            restore_name(group)
            next if restore_scale(group)

            last_transform = @last_transforms[group.persistent_id]
            next if last_transform && Utils::Transformation.same?(group.transformation, last_transform)

            synchronize_from(group, groups)
          end
        end

        def synchronize_from(source_group, groups)
          return unless source_group&.valid?
          return if Utils::Transformation.scaled?(source_group.transformation)

          groups.each do |group|
            next unless group&.valid?
            next if group == source_group
            next if Utils::Transformation.same?(group.transformation, source_group.transformation)

            set_group_transformation(group, source_group.transformation)
          end

          groups.each do |group|
            next unless group&.valid?

            @last_transforms[group.persistent_id] = group.transformation
          end
        end

        private

        def restore_name(group)
          expected_name = @expected_names[group.persistent_id]
          return if expected_name.nil? || group.name == expected_name

          UI.messagebox('This group name is managed by IndoorGML and cannot be changed.')
          @with_unlocked.call(group) { group.name = expected_name }
        end

        def restore_scale(group)
          return false unless Utils::Transformation.scaled?(group.transformation)

          UI.messagebox('This group scale is managed by IndoorGML and cannot be changed.')
          set_group_transformation(group, @last_transforms[group.persistent_id] || Geom::Transformation.new)
          true
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
