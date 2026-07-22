# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module SceneGroups
          STATE_FIXED_HEIGHT_OFFSET = 1000.mm unless const_defined?(:STATE_FIXED_HEIGHT_OFFSET, false)
          # Temporary feature flag. When enabled, CellSpace local-center
          # calculation aligns local X to the dominant vertical-wall normal.
          # Local Z remains world Z; the horizontal OBB is only a fallback.
          ALIGN_CELL_SPACE_LOCAL_CENTER_TO_DOMINANT_WALLS = true unless const_defined?(
            :ALIGN_CELL_SPACE_LOCAL_CENTER_TO_DOMINANT_WALLS,
            false
          )

          HORIZONTAL_OBB_EPSILON = 1.0e-12 unless const_defined?(:HORIZONTAL_OBB_EPSILON, false)
          VERTICAL_FACE_ANGLE_TOLERANCE_DEG = 1.0 unless const_defined?(
            :VERTICAL_FACE_ANGLE_TOLERANCE_DEG,
            false
          )
          WALL_NORMAL_CLUSTER_ANGLE_TOLERANCE_DEG = 1.0 unless const_defined?(
            :WALL_NORMAL_CLUSTER_ANGLE_TOLERANCE_DEG,
            false
          )
          WALL_PATCH_COPLANAR_ANGLE_TOLERANCE_DEG = 0.01 unless const_defined?(
            :WALL_PATCH_COPLANAR_ANGLE_TOLERANCE_DEG,
            false
          )
          WALL_PATCH_COPLANAR_TOLERANCE = 0.01.mm unless const_defined?(
            :WALL_PATCH_COPLANAR_TOLERANCE,
            false
          )

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

          def align_cell_space_local_axes_to_dominant_walls(cell_space_entity)
            return cell_space_entity unless cell_space_entity&.valid?
            return cell_space_entity unless @primal_group&.valid?
            return cell_space_entity unless cell_space_entity.respond_to?(:definition)

            cell_space_entity.make_unique if cell_space_entity.respond_to?(:make_unique)

            root_world = Utils::Transformation.root_transformation_in_model(@primal_group)
            old_world = root_world * cell_space_entity.transformation
            axes = dominant_vertical_face_axes(cell_space_entity, old_world)
            source = :dominant_vertical_face_normal
            unless axes
              world_points = cell_space_world_vertex_points(cell_space_entity, old_world)
              axes = horizontal_obb_axes(world_points)
              source = :horizontal_obb
            end
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
              '[IndoorGML] CellSpace local-center axes aligned: ' \
              "entity_id=#{cell_space_entity.entityID} source=#{source} " \
              "angle_deg=#{format('%.9f', axes[:angle] * 180.0 / Math::PI)}"
            )
            cell_space_entity
          end

          def dominant_vertical_face_axes(cell_space_entity, world_transformation)
            samples = cell_space_entity.definition.entities
                                       .grep(Sketchup::Face)
                                       .filter_map do |face|
              normal = world_face_normal(face, world_transformation)
              next unless normal

              {
                face: face,
                normal: normal,
                area: world_face_area(face, world_transformation),
                point: world_face_reference_point(face, world_transformation)
              }
            end
            assign_connected_wall_patch_keys!(samples)
            dominant_vertical_face_axes_from_samples(samples)
          end

          def dominant_vertical_face_axes_from_samples(samples)
            vertical_limit = Math.sin(
              VERTICAL_FACE_ANGLE_TOLERANCE_DEG * Math::PI / 180.0
            )
            candidates = Array(samples).each_with_index.filter_map do |sample, index|
              normal = Array(sample[:normal]).map(&:to_f)
              next unless normal.length == 3

              length = Math.sqrt(normal.sum { |component| component * component })
              next if length <= HORIZONTAL_OBB_EPSILON
              next if (normal[2] / length).abs > vertical_limit

              horizontal_length = Math.sqrt(
                (normal[0] * normal[0]) + (normal[1] * normal[1])
              )
              next if horizontal_length <= HORIZONTAL_OBB_EPSILON

              axis = canonical_horizontal_axis([
                normal[0] / horizontal_length,
                normal[1] / horizontal_length,
                0.0
              ])
              angle = Math.atan2(axis[1], axis[0]) % Math::PI
              {
                angle: angle,
                area: [sample[:area].to_f.abs, 0.0].max,
                frequency_key: sample.fetch(:frequency_key, index)
              }
            end
            return nil if candidates.empty?

            clusters = cluster_unoriented_horizontal_normals(candidates)
            ranked = clusters.map { |cluster| wall_normal_cluster_summary(cluster) }
            selected = ranked.max_by do |cluster|
              [
                cluster[:count],
                cluster[:max_face_area],
                cluster[:total_area],
                cluster[:x][0].abs,
                cluster[:x][1]
              ]
            end
            selected.merge(source: :dominant_vertical_face_normal)
          end

          # Angles describe unoriented axes in [0, PI). Rotate the sorted list
          # after its largest empty arc so nearly identical directions around
          # the 0/PI seam are clustered together deterministically.
          def cluster_unoriented_horizontal_normals(candidates)
            ordered = candidates.sort_by { |candidate| [candidate[:angle], candidate[:area]] }
            return [ordered] if ordered.length == 1

            gaps = ordered.each_index.map do |index|
              following = ordered[(index + 1) % ordered.length][:angle]
              following += Math::PI if index == ordered.length - 1
              [following - ordered[index][:angle], index]
            end
            split_after = gaps.max_by { |gap, index| [gap, -index] }[1]
            rotated = ordered.rotate(split_after + 1)
            start_angle = rotated.first[:angle]
            unwrapped = rotated.map do |candidate|
              angle = candidate[:angle]
              angle += Math::PI if angle < start_angle
              candidate.merge(unwrapped_angle: angle)
            end

            tolerance = WALL_NORMAL_CLUSTER_ANGLE_TOLERANCE_DEG * Math::PI / 180.0
            clusters = []
            unwrapped.each do |candidate|
              current = clusters.last
              if current.nil? ||
                 candidate[:unwrapped_angle] - current.first[:unwrapped_angle] > tolerance
                clusters << [candidate]
              else
                current << candidate
              end
            end
            clusters
          end

          def wall_normal_cluster_summary(cluster)
            cosine = cluster.sum { |candidate| Math.cos(2.0 * candidate[:angle]) }
            sine = cluster.sum { |candidate| Math.sin(2.0 * candidate[:angle]) }
            angle = 0.5 * Math.atan2(sine, cosine)
            axis = canonical_horizontal_axis([
              Math.cos(angle),
              Math.sin(angle),
              0.0
            ])
            {
              count: cluster.map { |candidate| candidate[:frequency_key] }.uniq.length,
              face_count: cluster.length,
              max_face_area: cluster.map { |candidate| candidate[:area] }.max,
              total_area: cluster.sum { |candidate| candidate[:area] },
              angle: Math.atan2(axis[1], axis[0]),
              x: axis,
              y: [-axis[1], axis[0], 0.0]
            }
          end

          def canonical_horizontal_axis(axis)
            if axis[0] < -HORIZONTAL_OBB_EPSILON ||
               (axis[0].abs <= HORIZONTAL_OBB_EPSILON && axis[1] < 0.0)
              [-axis[0], -axis[1], 0.0]
            else
              [axis[0], axis[1], 0.0]
            end
          end

          def world_face_normal(face, world_transformation)
            loop = face.respond_to?(:outer_loop) ? face.outer_loop : nil
            vertices = loop ? loop.vertices : face.vertices
            points = vertices.map do |vertex|
              vertex.position.transform(world_transformation)
            end
            return nil if points.length < 3

            origin = points.first
            (1...(points.length - 1)).each do |first_index|
              ((first_index + 1)...points.length).each do |second_index|
                first = world_point_delta(origin, points[first_index])
                second = world_point_delta(origin, points[second_index])
                normal = world_vector_cross(first, second)
                length = Math.sqrt(normal.sum { |component| component * component })
                next if length <= HORIZONTAL_OBB_EPSILON

                return normal.map { |component| component / length }
              end
            end
            nil
          rescue StandardError
            nil
          end

          def world_face_area(face, world_transformation)
            face.area(world_transformation).to_f.abs
          rescue ArgumentError, TypeError
            face.area.to_f.abs
          rescue StandardError
            0.0
          end

          def world_face_reference_point(face, world_transformation)
            loop = face.respond_to?(:outer_loop) ? face.outer_loop : nil
            vertex = loop ? loop.vertices.first : face.vertices.first
            point = vertex.position.transform(world_transformation)
            [point.x.to_f, point.y.to_f, point.z.to_f]
          rescue StandardError
            nil
          end

          # One wall split by internal SketchUp edges counts once, while
          # disconnected parallel walls remain separate frequency units.
          def assign_connected_wall_patch_keys!(samples)
            indexed_faces = {}
            samples.each_with_index do |sample, index|
              face = sample[:face]
              indexed_faces[face.object_id] = index if face
            end
            visited = Array.new(samples.length, false)
            patch_key = 0

            samples.each_index do |seed|
              next if visited[seed]

              visited[seed] = true
              queue = [seed]
              until queue.empty?
                index = queue.shift
                sample = samples[index]
                sample[:frequency_key] = patch_key
                face = sample[:face]
                next unless face&.respond_to?(:edges)

                face.edges.each do |edge|
                  next unless edge.respond_to?(:faces)

                  edge.faces.each do |neighbor|
                    neighbor_index = indexed_faces[neighbor.object_id]
                    next unless neighbor_index
                    next if visited[neighbor_index]
                    next unless coplanar_wall_samples?(
                      sample,
                      samples[neighbor_index]
                    )

                    visited[neighbor_index] = true
                    queue << neighbor_index
                  end
                end
              end
              patch_key += 1
            end
            samples
          end

          def coplanar_wall_samples?(first, second)
            first_normal = first[:normal]
            second_normal = second[:normal]
            first_point = first[:point]
            second_point = second[:point]
            return false unless first_normal && second_normal &&
                                first_point && second_point

            cosine = world_vector_dot(first_normal, second_normal).abs
            angular_limit = Math.cos(
              WALL_PATCH_COPLANAR_ANGLE_TOLERANCE_DEG * Math::PI / 180.0
            )
            return false if cosine < angular_limit

            offset = world_point_delta_components(first_point, second_point)
            world_vector_dot(first_normal, offset).abs <=
              WALL_PATCH_COPLANAR_TOLERANCE
          end

          def world_point_delta(origin, point)
            [
              point.x.to_f - origin.x.to_f,
              point.y.to_f - origin.y.to_f,
              point.z.to_f - origin.z.to_f
            ]
          end

          def world_vector_cross(first, second)
            [
              (first[1] * second[2]) - (first[2] * second[1]),
              (first[2] * second[0]) - (first[0] * second[2]),
              (first[0] * second[1]) - (first[1] * second[0])
            ]
          end

          def world_vector_dot(first, second)
            (first[0] * second[0]) +
              (first[1] * second[1]) +
              (first[2] * second[2])
          end

          def world_point_delta_components(origin, point)
            [
              point[0] - origin[0],
              point[1] - origin[1],
              point[2] - origin[2]
            ]
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
              if ALIGN_CELL_SPACE_LOCAL_CENTER_TO_DOMINANT_WALLS
                align_cell_space_local_axes_to_dominant_walls(cell_space_entity)
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
