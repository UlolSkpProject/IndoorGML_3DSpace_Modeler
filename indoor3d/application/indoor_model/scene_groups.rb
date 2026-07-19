# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module SceneGroups
          STATE_FIXED_HEIGHT_OFFSET = 1000.mm unless const_defined?(:STATE_FIXED_HEIGHT_OFFSET, false)
          # Temporary feature flag. When enabled, CellSpace local-center
          # calculation first aligns local X/Y to the horizontal OBB. Local Z
          # remains equal to world Z and the world-space geometry is preserved.
          ALIGN_CELL_SPACE_LOCAL_CENTER_TO_HORIZONTAL_OBB = true unless const_defined?(
            :ALIGN_CELL_SPACE_LOCAL_CENTER_TO_HORIZONTAL_OBB,
            false
          )

          HORIZONTAL_OBB_EPSILON = 1.0e-12 unless const_defined?(:HORIZONTAL_OBB_EPSILON, false)

          private

          def ensure_space_features_groups(transparent: false)
            merged = false
            group = with_indoor_model_operation('IndoorGML Ensure SpaceFeatures Groups', transparent: transparent) do
              Utils::Materials.ensure_all()

              entities = (@model || Sketchup.active_model).entities
              @primal_group, merged = resolve_and_merge_primal_groups(entities)
              unless @primal_group&.valid?
                @primal_group = entities.add_group
                @primal_group.name = PRIMAL_GROUP_NAME
              end
              attach_space_features_observer(@primal_group, PRIMAL_GROUP_NAME)
              write_space_features_attributes(@primal_group, PRIMAL_GROUP_FEATURE)
              ensure_space_features_origin_point(@primal_group)
              attach_entities_observers
              @primal_group
            end
            refresh_runtime_after_primal_merge if merged
            group
          end

          def find_existing_space_features_groups
            entities = (@model || Sketchup.active_model).entities
            @primal_group, merged = resolve_and_merge_primal_groups(entities)
            IndoorCore::Logger.puts '[IndoorGML] PrimalSpaceFeatures group not found during refresh.' unless @primal_group&.valid?
            merged
          end

          def attach_existing_space_features_observers
            model = @model || Sketchup.active_model
            attach_entities_observer(:root, model.entities, @root_entities_observer)
            attach_space_features_observer(@primal_group, PRIMAL_GROUP_NAME, normalize: false)
            @root_entities_observer.track_entity(@primal_group) if @primal_group&.valid?
            attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer) if @primal_group&.valid?
            @primal_entities_observer.track_entities(@primal_group.entities) if @primal_group&.valid?
          end

          def find_group(entities, name)
            expected_feature = space_features_feature_for_name(name)
            entities.grep(Sketchup::Group).find do |group|
              group.valid? && indoor_feature(group) == expected_feature
            end || entities.grep(Sketchup::Group).find { |group| group.valid? && group.name == name }
          end

          def space_features_feature_for_name(name)
            return PRIMAL_GROUP_FEATURE if name == PRIMAL_GROUP_NAME

            nil
          end

          def place_cell_group(sketchup_group)
            return sketchup_group if inside_primal_group?(sketchup_group)

            raise ArgumentError, 'IndoorGML_PrimalSpaceFeatures is not ready' unless @primal_group&.valid?

            clone_group_under_primal_space(sketchup_group)
          end

          def clone_group_under_primal_space(sketchup_group)
            local_transformation = @primal_group.transformation.inverse * Utils::Transformation.entity_transformation_for_current_context(sketchup_group)
            cell_space_entity = EntityCopyHelper.copy_instance(
              source: sketchup_group,
              target_entities: @primal_group.entities,
              transformation: local_transformation,
              convert_to_group: true,
              make_unique: true
            )
            sketchup_group.erase! if sketchup_group.valid?
            cell_space_entity
          end

          def align_cell_space_local_axes_to_horizontal_obb(cell_space_entity)
            return cell_space_entity unless cell_space_entity&.valid?
            return cell_space_entity unless @primal_group&.valid?
            return cell_space_entity unless cell_space_entity.respond_to?(:definition)

            cell_space_entity.make_unique if cell_space_entity.respond_to?(:make_unique)

            root_world = Utils::Transformation.root_transformation_in_model(@primal_group)
            old_world = root_world * cell_space_entity.transformation
            world_points = cell_space_world_vertex_points(cell_space_entity, old_world)
            axes = horizontal_obb_axes(world_points)
            return cell_space_entity unless axes

            desired_world = Geom::Transformation.axes(
              old_world.origin,
              Geom::Vector3d.new(axes[:x]),
              Geom::Vector3d.new(axes[:y]),
              Geom::Vector3d.new(0.0, 0.0, 1.0)
            )
            geometry_transform = desired_world.inverse * old_world
            definition_entities = cell_space_entity.definition.entities
            entities = definition_entities.to_a
            return cell_space_entity if entities.empty?

            definition_entities.transform_entities(geometry_transform, entities)
            set_group_transformation(
              cell_space_entity,
              root_world.inverse * desired_world
            )

            IndoorCore::Logger.puts(
              '[IndoorGML] CellSpace local-center axes aligned to horizontal OBB: ' \
              "entity_id=#{cell_space_entity.entityID} angle_deg=#{format('%.9f', axes[:angle] * 180.0 / Math::PI)}"
            )
            cell_space_entity
          end

          def cell_space_world_vertex_points(cell_space_entity, world_transformation)
            cell_space_entity.definition.entities
                             .grep(Sketchup::Edge)
                             .flat_map(&:vertices)
                             .uniq
                             .map { |vertex| vertex.position.transform(world_transformation) }
          end

          def horizontal_obb_axes(world_points)
            hull = horizontal_convex_hull(world_points)
            return nil if hull.length < 3

            best = nil
            hull.each_with_index do |point, index|
              following = hull[(index + 1) % hull.length]
              dx = following[0] - point[0]
              dy = following[1] - point[1]
              length = Math.sqrt((dx * dx) + (dy * dy))
              next if length <= HORIZONTAL_OBB_EPSILON

              x_axis = [dx / length, dy / length]
              y_axis = [-x_axis[1], x_axis[0]]
              x_values = hull.map { |candidate| horizontal_dot(candidate, x_axis) }
              y_values = hull.map { |candidate| horizontal_dot(candidate, y_axis) }
              x_extent = x_values.max - x_values.min
              y_extent = y_values.max - y_values.min
              area = x_extent * y_extent

              if y_extent > x_extent
                x_axis = y_axis
                y_axis = [-x_axis[1], x_axis[0]]
                x_extent, y_extent = y_extent, x_extent
              end

              if x_axis[0] < -HORIZONTAL_OBB_EPSILON ||
                 (x_axis[0].abs <= HORIZONTAL_OBB_EPSILON && x_axis[1] < 0.0)
                x_axis = x_axis.map { |value| -value }
                y_axis = y_axis.map { |value| -value }
              end

              angle = Math.atan2(x_axis[1], x_axis[0])
              candidate = {
                area: area,
                alignment: x_axis[0].abs,
                angle: angle,
                x: [x_axis[0], x_axis[1], 0.0],
                y: [y_axis[0], y_axis[1], 0.0],
                extents: [x_extent, y_extent]
              }
              best = candidate if better_horizontal_obb_candidate?(candidate, best)
            end
            best
          end

          def horizontal_convex_hull(world_points)
            points = Array(world_points).map { |point| [point.x.to_f, point.y.to_f] }.uniq.sort
            return points if points.length <= 2

            lower = []
            points.each do |point|
              lower.pop while lower.length >= 2 && horizontal_cross(lower[-2], lower[-1], point) <= HORIZONTAL_OBB_EPSILON
              lower << point
            end

            upper = []
            points.reverse_each do |point|
              upper.pop while upper.length >= 2 && horizontal_cross(upper[-2], upper[-1], point) <= HORIZONTAL_OBB_EPSILON
              upper << point
            end
            lower[0...-1] + upper[0...-1]
          end

          def horizontal_cross(origin, first, second)
            ((first[0] - origin[0]) * (second[1] - origin[1])) -
              ((first[1] - origin[1]) * (second[0] - origin[0]))
          end

          def horizontal_dot(point, axis)
            (point[0] * axis[0]) + (point[1] * axis[1])
          end

          def better_horizontal_obb_candidate?(candidate, current)
            return true unless current

            tolerance = [candidate[:area].abs, current[:area].abs, 1.0].max * 1.0e-12
            return true if candidate[:area] < current[:area] - tolerance
            return false if candidate[:area] > current[:area] + tolerance

            candidate[:alignment] > current[:alignment]
          end

          def recenter_cell_space_geometry(cell_space_entity, fixed_z_offset_from_bottom: nil)
            with_indoor_model_operation('IndoorGML Recenter CellSpace Geometry', transparent: true) do
              if ALIGN_CELL_SPACE_LOCAL_CENTER_TO_HORIZONTAL_OBB
                align_cell_space_local_axes_to_horizontal_obb(cell_space_entity)
              end
              fixed_z = fixed_z_offset_from_bottom.nil? ? nil : fixed_local_z_from_world_offset(cell_space_entity, fixed_z_offset_from_bottom)
              center = Utils::Geometry.find_shell_inner_centroid(cell_space_entity, fixed_z: fixed_z)
              # IndoorCore::Logger.puts "[IndoorGML] recenter_cell_space_geometry center=#{center} distance=#{center.distance(ORIGIN)}"
              next if center.distance(ORIGIN) <= 0.001

              set_group_transformation(
                cell_space_entity,
                cell_space_entity.transformation * Geom::Transformation.translation(center)
              )
              cell_space_entity.definition.entities.transform_entities(
                Geom::Transformation.translation(center.vector_to(ORIGIN)),
                cell_space_entity.definition.entities.to_a
              )
            end
          end

          def fixed_local_z_from_world_offset(cell_space_entity, offset_from_world_bottom)
            bounds = cell_space_entity.definition.bounds
            transform = cell_space_entity.transformation
            world_min_z = bounds_corners(bounds).map { |point| point.transform(transform).z }.min
            world_target = Geom::Point3d.new(transform.origin.x, transform.origin.y, world_min_z + offset_from_world_bottom)
            world_target.transform(transform.inverse).z
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] fixed local z from world offset failed: #{e.class}: #{e.message}"
            cell_space_entity.definition.bounds.min.z + offset_from_world_bottom
          end

          def bounds_corners(bounds)
            min = bounds.min
            max = bounds.max
            [
              Geom::Point3d.new(min.x, min.y, min.z),
              Geom::Point3d.new(min.x, min.y, max.z),
              Geom::Point3d.new(min.x, max.y, min.z),
              Geom::Point3d.new(min.x, max.y, max.z),
              Geom::Point3d.new(max.x, min.y, min.z),
              Geom::Point3d.new(max.x, min.y, max.z),
              Geom::Point3d.new(max.x, max.y, min.z),
              Geom::Point3d.new(max.x, max.y, max.z)
            ]
          end

          def recenter_cell_space_origin(cell_space)
            return unless cell_space&.valid?

            ensure_cell_space_is_child_of_primal_space!(cell_space)
            recenter_cell_space_geometry(
              cell_space.sketchup_group,
              fixed_z_offset_from_bottom: fixed_state_height_offset(cell_space)
            )
          end

          def attach_space_features_observer(group, expected_name, normalize: true)
            return unless group&.valid?

            observer_key = entity_observer_key(group)
            @scene_group_guard.track(group, expected_name)
            ensure_space_features_name(group, expected_name) if normalize
            return unless ensure_space_features_scale_identity(group)

            remember_space_features_change_snapshot(group)
            return if @space_features_observed_ids[observer_key]

            group.add_observer(@space_features_observer)
            @space_features_observed_ids[observer_key] = true
          end

          def attach_entities_observers
            model = @model || Sketchup.active_model
            attach_entities_observer(:root, model.entities, @root_entities_observer)
            @root_entities_observer.track_entity(@primal_group) if @primal_group&.valid?
            attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer) if @primal_group&.valid?
            @primal_entities_observer.track_entities(@primal_group.entities) if @primal_group&.valid?
          end

          def attach_entities_observer(scope, entities, observer)
            return unless entities && observer

            key = [scope, entities.object_id]
            return if @entities_observed_ids[key]

            entities.add_observer(observer)
            @entities_observed_ids[key] = true
          end

          def register_space_features_entity(entity, feature)
            unless entity.is_a?(Sketchup::Group)
              IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures restore skipped: #{feature} is #{entity.class}"
              return
            end

            case feature
            when PRIMAL_GROUP_FEATURE
              entities = (@model || Sketchup.active_model).entities
              @primal_group, merged = resolve_and_merge_primal_groups(entities)
              @primal_group ||= entity
              attach_space_features_observer(@primal_group, PRIMAL_GROUP_NAME)
              write_space_features_attributes(@primal_group, PRIMAL_GROUP_FEATURE)
              ensure_space_features_origin_point(@primal_group)
              attach_entities_observer(:primal, @primal_group.entities, @primal_entities_observer)
              refresh_runtime_after_primal_merge if merged
            end
          end

          def resolve_and_merge_primal_groups(entities)
            candidates = primal_group_candidates(entities)
            canonical = canonical_primal_group(entities, candidates)
            return [canonical, false] unless canonical&.valid?

            duplicates = candidates.reject { |group| group == canonical }
            return [canonical, false] if duplicates.empty?

            @primal_group = canonical
            merge_duplicate_primal_groups(canonical, duplicates)
            [canonical, true]
          end

          def primal_group_candidates(entities)
            entities.grep(Sketchup::Group).select do |group|
              group&.valid? && (
                indoor_feature(group) == PRIMAL_GROUP_FEATURE ||
                group.name.to_s == PRIMAL_GROUP_NAME
              )
            end
          end

          def canonical_primal_group(entities, candidates)
            root_groups = entities.grep(Sketchup::Group)
            if @primal_group&.valid? && root_groups.include?(@primal_group)
              return @primal_group
            end

            candidates.find do |group|
              indoor_feature(group) == PRIMAL_GROUP_FEATURE && group.name.to_s == PRIMAL_GROUP_NAME
            end || candidates.find do |group|
              indoor_feature(group) == PRIMAL_GROUP_FEATURE
            end || candidates.find do |group|
              group.name.to_s == PRIMAL_GROUP_NAME
            end
          end

          def merge_duplicate_primal_groups(canonical, duplicates)
            with_guard_flag(:@merging_space_features) do
              Array(duplicates).each do |duplicate|
                merge_duplicate_primal_group(canonical, duplicate)
              end
            end
            true
          end

          def merge_duplicate_primal_group(canonical, duplicate)
            return false unless canonical&.valid? && duplicate&.valid?

            children = duplicate.entities.grep(Sketchup::Group).select do |child|
              child&.valid? && indoor_feature(child) == 'CellSpace'
            end
            copies = []
            children.each do |child|
              transformation = canonical.transformation.inverse * duplicate.transformation * child.transformation
              copy = EntityCopyHelper.copy_instance(
                source: child,
                target_entities: canonical.entities,
                transformation: transformation,
                convert_to_group: :source_group,
                make_unique: :source_group,
                copy_attributes: [:name, :material, :layer, :visible],
                attribute_copier: method(:copy_indoor_attributes)
              )
              copies << [child, copy]
            end

            copies.each do |child, _copy|
              cleanup_merged_primal_child_tracking(child)
            end
            cleanup_merged_primal_group_tracking(duplicate)
            duplicate.erase! if duplicate.valid?
            IndoorCore::Logger.puts "[IndoorGML] Duplicate PrimalSpaceFeatures merged: cells=#{copies.length}"
            true
          rescue StandardError
            Array(copies).each do |_child, copy|
              copy.erase! if copy&.valid?
            rescue StandardError
              nil
            end
            raise
          end

          def cleanup_merged_primal_child_tracking(child)
            delete_entity_observer_key(@cell_space_observed_ids, child)
            @cell_space_change_snapshots.delete(entity_observer_key(child))
            @scene_group_guard.untrack(child)
          rescue StandardError
            nil
          end

          def cleanup_merged_primal_group_tracking(group)
            delete_entity_observer_key(@space_features_observed_ids, group)
            @space_features_change_snapshots.delete(entity_observer_key(group))
            @entities_observed_ids.delete([:primal, group.entities.object_id])
            @scene_group_guard.untrack(group)
          rescue StandardError
            nil
          end

          def refresh_runtime_after_primal_merge
            return true if guard_active?(:@refreshing_runtime)

            refresh_runtime_data
          end

          def ensure_space_features_origin_point(group)
            begin
              return unless group&.valid?

              point = origin_construction_point(group) || group.entities.add_cpoint(ORIGIN)
              point.hidden = true if point&.valid? && point.respond_to?(:hidden=)
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Origin point creation failed: #{e.class}: #{e.message}"
            end
          end

          def ensure_space_features_name(group, expected_name)
            return true unless group&.valid?
            return true if group.name == expected_name

            with_unlocked(group) { group.name = expected_name }
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures name update skipped: #{e.class}: #{e.message}"
            false
          end

          def ensure_space_features_scale_identity(group)
            return true unless group&.valid?
            return true unless group.respond_to?(:transformation)
            return true unless Utils::Transformation.scaled?(group.transformation)

            reject_scaled_space_features_transform(group)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures scale invariant check failed: #{e.class}: #{e.message}"
            false
          end

          def origin_construction_point(group)
            begin
              group.entities.grep(Sketchup::ConstructionPoint).find do |point|
                point.valid? && point.position.distance(ORIGIN) <= 0.001
              end
            rescue StandardError
              nil
            end
          end

          def enforce_space_features_constraints
            ensure_space_features_guard_tracking
            @scene_group_guard.enforce(ordered_space_features_groups)
          end

          def ordered_space_features_groups
            [@primal_group].compact
          end

          def ensure_space_features_guard_tracking
            @scene_group_guard.ensure_expected_name(@primal_group, PRIMAL_GROUP_NAME) if @primal_group&.valid?
          end

          def expected_space_features_name_for(entity)
            return PRIMAL_GROUP_NAME if entity == @primal_group
            return PRIMAL_GROUP_NAME if indoor_feature(entity) == PRIMAL_GROUP_FEATURE

            nil
          end

          def set_group_transformation(group, transformation)
            with_unlocked(group) do
              if group.respond_to?(:transformation=)
                group.transformation = transformation
              else
                group.transform!(group.transformation.inverse * transformation)
              end
            end
          end

          def fixed_state_height_offset(cell_space)
            category = cell_space&.category_code.to_s.downcase
            return STATE_FIXED_HEIGHT_OFFSET if category.include?('room') || category.include?('door')

            nil
          end

          def inside_primal_group?(sketchup_group)
            begin
              Utils::Transformation.direct_child_of_root?(sketchup_group, @primal_group)
            rescue StandardError
              false
            end
          end

          def ensure_cell_space_is_child_of_primal_space!(cell_space)
            Utils::Transformation.ensure_direct_child_of_root!(
              cell_space.sketchup_group,
              @primal_group,
              "[IndoorGML] Coordinate warning: CellSpace #{cell_space.sketchup_group.name} is not a child of #{PRIMAL_GROUP_NAME}"
            )
          end

        end
      end
    end
  end
end
