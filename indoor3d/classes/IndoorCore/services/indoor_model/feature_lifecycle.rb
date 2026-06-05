# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module FeatureLifecycle
          def convert_group_to_cell_space(sketchup_group, cell_type = CellSpaceType::GENERAL, category_code = nil)
            raise ArgumentError, 'Group is already converted to CellSpace' if converted_group?(sketchup_group)

            ensure_space_features_groups
            cell_group = place_cell_group(sketchup_group)
            recenter_cell_space_geometry(cell_group)
            cell_space = CellSpace.new(cell_group, cell_type, category_code)
            name_cell_space_entity(cell_space)
            apply_cell_space_material(cell_space)
            state = cell_space.create_duality_state(nil, cell_space_local_origin(cell_space))

            register_cell_space(cell_space)
            register_state(state)
            write_attributes(cell_space)
            track_cell_space_entity(cell_space.sketchup_group)
            synchronize_adjacency_and_transitions_for_cell_space(cell_space)
            apply_indoor_lock_policy()

            cell_space
          end

          def change_cell_space_type(sketchup_group, cell_type, category_code = nil)
            cell_space = find_cell_space_for_entity(sketchup_group)
            raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
            raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?

            sync do
              cell_space.cell_type = cell_type
              cell_space.set_category(category_code)
              name_cell_space_entity(cell_space)
              apply_cell_space_material(cell_space)
              write_cell_space_attributes(cell_space)
              synchronize_adjacency_and_transitions_for_cell_space(cell_space)
              apply_indoor_lock_policy()
            end

            cell_space
          end

          def cell_space_changed(entity)
            begin
              return false if guard_active?(:@syncing) || guard_active?(:@erasing)

              cell_space = find_cell_space_for_entity(entity)
              cell_space = refresh_and_find_cell_space(entity) if stale_cell_space_runtime?(cell_space, entity)
              return false if cell_space.nil? || !cell_space.valid?

              change_kind = classify_cell_space_change(entity)
              return false if change_kind.nil?

              case change_kind
              when :cell_space_type
                handle_cell_space_type_changed(cell_space)
              when :name
                handle_cell_space_name_changed(cell_space)
              when :transform
                handle_cell_space_transform_changed(cell_space)
              else
                handle_cell_space_etc_changed(cell_space)
              end
            end
          end

          def cell_space_closed(entity)
            begin
              return if @syncing || @erasing

              cell_space = find_cell_space_for_entity(entity)
              cell_space = refresh_and_find_cell_space(entity) if stale_cell_space_runtime?(cell_space, entity)
              return if cell_space.nil? || !cell_space.valid?

              sync do
                recenter_cell_space_origin(cell_space)
                name_cell_space_entity(cell_space)
                apply_cell_space_material(cell_space)
                state = cell_space.duality_state
                unless state&.valid?
                  cell_space = refresh_and_find_cell_space(entity)
                  state = cell_space&.duality_state
                end
                if state&.valid?
                  local_position = cell_space_local_origin(cell_space)
                  update_state_position(state, local_position)
                end
                synchronize_adjacency_and_transitions_for_cell_space(cell_space)
              end
            ensure
              lock_indoor_entity(entity)
            end
          end

          def cell_space_erased(entity)
            return if @erasing

            cell_space = find_cell_space_for_entity(entity)
            erase_cell_space(cell_space, erase_sketchup_group: false)
          end

          def erase_cell_space(cell_space, erase_sketchup_group: true)
            return if cell_space.nil?

            erase_guard do
              state = cell_space.duality_state
              erase_transitions_for_state(state)
              state.erase! if state&.valid?
              unregister_state(state)
              unlock_indoor_entity(cell_space.sketchup_group) if erase_sketchup_group && cell_space.valid?
              cell_space.erase! if erase_sketchup_group && cell_space.valid?
              unregister_cell_space(cell_space)
              erase_adjacency_for_cell_space(cell_space)
            end
          end

          private

          def register_cell_space(cell_space)
            @feature_registry.add_cell_space(cell_space)
            attach_cell_space_observer(cell_space.sketchup_group)
            lock_indoor_entity(cell_space.sketchup_group)
            @scene_group_guard.track(cell_space.sketchup_group, cell_space.sketchup_group.name)
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
          end

          def duplicate_cell_space_identity?(entity)
            copied_id = indoor_attribute(entity, 'id').to_s
            return false if copied_id.empty?

            original = cell_space_with_id(copied_id)
            original && original.valid? && original.sketchup_group != entity
          end

          def make_cell_space_copy_independent(entity)
            original_id = indoor_attribute(entity, 'id').to_s
            original_state_id = indoor_attribute(entity, 'duality_state_id').to_s
            original_transition_ids = indoor_attribute(entity, 'state_transition_ids')
            puts "[IndoorGML] Duplicate CellSpace id detected: entity_id=#{entity.entityID} copied_id=#{original_id}"

            with_transparent_cell_space_operation('IndoorGML CellSpace Copy Independence') do
              sync do
                make_unique_performed = make_cell_space_entity_unique(entity)
                cell_space = build_independent_cell_space(entity)
                state = cell_space.create_duality_state(nil, cell_space_local_origin(cell_space))
                ensure_unique_feature_id!(cell_space)
                ensure_unique_feature_id!(state, reserved_ids: [cell_space.id])

                register_cell_space(cell_space)
                register_state(state)
                name_cell_space_entity(cell_space)
                apply_cell_space_material(cell_space)
                write_cell_space_attributes(cell_space)
                synchronize_adjacency_and_transitions_for_cell_space(cell_space)
                remember_cell_space_change_snapshot(entity)

                puts "[IndoorGML] CellSpace copy independent: original_id=#{original_id} new_id=#{cell_space.id} original_state_id=#{original_state_id} new_state_id=#{state.id} make_unique=#{make_unique_performed} copied_transition_ids=#{original_transition_ids.inspect}"
              end
            end

            true
          rescue StandardError => e
            puts "[IndoorGML] CellSpace copy independence failed: #{e.class}: #{e.message}"
            false
          end

          def make_cell_space_entity_unique(entity)
            return false unless entity.respond_to?(:make_unique)

            entity.make_unique
            true
          rescue StandardError => e
            puts "[IndoorGML] CellSpace make_unique failed: #{e.class}: #{e.message}"
            false
          end

          def build_independent_cell_space(entity)
            cell_type = CellSpaceType.from_label(indoor_attribute(entity, 'cell_type'))
            cell_space = CellSpace.new(entity, cell_type, indoor_attribute(entity, 'category_code'))
            cell_space.set_category(
              indoor_attribute(entity, 'category_code'),
              indoor_attribute(entity, 'category_label'),
              indoor_attribute(entity, 'category_code_space'),
              indoor_attribute(entity, 'category_standard')
            )
            cell_space
          end

          def cell_space_with_id(id)
            @cell_spaces.find { |cell_space| cell_space&.id == id }
          end

          def ensure_unique_feature_id!(feature, reserved_ids: [])
            return feature unless feature

            while reserved_ids.include?(feature.id) || feature_id_in_use?(feature.id, excluding: feature)
              feature.instance_variable_set(:@id, random_feature_id)
            end
            feature
          end

          def feature_id_in_use?(id, excluding: nil)
            return false if id.to_s.empty?

            (@cell_spaces + @states + @transitions).any? do |feature|
              feature && feature != excluding && feature.id == id
            end
          end

          def random_feature_id
            rand(36**8).to_s(36)
          end

          def classify_cell_space_change(entity)
            previous_snapshot = cell_space_change_snapshot_for(entity)
            current_snapshot = build_cell_space_change_snapshot(entity)
            remember_cell_space_change_snapshot(entity, current_snapshot)
            if previous_snapshot.nil?
              log_cell_space_change(entity, :initial_snapshot, [], previous_snapshot, current_snapshot)
              return nil
            end

            changed_fields = changed_cell_space_snapshot_fields(previous_snapshot, current_snapshot)
            change_kind = cell_space_change_kind(changed_fields)
            log_cell_space_change(entity, change_kind, changed_fields, previous_snapshot, current_snapshot)

            change_kind
          end

          def handle_cell_space_name_changed(cell_space)
            with_transparent_cell_space_operation('IndoorGML CellSpace Name Change') do
              sync { name_cell_space_entity(cell_space) }
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            true
          end

          def handle_cell_space_transform_changed(cell_space)
            with_transparent_cell_space_operation('IndoorGML CellSpace Transform Change') do
              sync { synchronize_cell_space_geometry_change(cell_space) }
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            true
          end

          def handle_cell_space_type_changed(cell_space)
            with_transparent_cell_space_operation('IndoorGML CellSpace Type Change') do
              sync do
                apply_cell_space_type_attributes(cell_space)
                name_cell_space_entity(cell_space)
                apply_cell_space_material(cell_space)
                write_cell_space_attributes(cell_space)
                synchronize_adjacency_and_transitions_for_cell_space(cell_space)
              end
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            true
          end

          def handle_cell_space_etc_changed(cell_space)
            puts "[IndoorGML] CellSpace change ignored as etc: entity_id=#{cell_space.sketchup_group.entityID} name=#{cell_space.sketchup_group.name}"
            with_transparent_cell_space_operation('IndoorGML CellSpace Etc Change') {}
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            false
          end

          def synchronize_cell_space_geometry_change(cell_space)
            state = cell_space.duality_state
            unless state&.valid?
              cell_space = refresh_and_find_cell_space(cell_space.sketchup_group)
              state = cell_space&.duality_state
            end
            if state&.valid?
              local_position = cell_space_local_origin(cell_space)
              update_state_position(state, local_position)
            end
            synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          end

          def apply_cell_space_type_attributes(cell_space)
            entity = cell_space.sketchup_group
            cell_space.cell_type = CellSpaceType.from_label(indoor_attribute(entity, 'cell_type'))
            cell_space.set_category(
              indoor_attribute(entity, 'category_code'),
              indoor_attribute(entity, 'category_label'),
              indoor_attribute(entity, 'category_code_space'),
              indoor_attribute(entity, 'category_standard')
            )
          end

          def with_transparent_cell_space_operation(name)
            model = Sketchup.active_model
            operation_started = false
            begin
              operation_started = model.start_operation(name, true, false, true) if model
              yield
            ensure
              model.commit_operation if operation_started
            end
          end

          def remember_cell_space_change_snapshot(entity, snapshot = nil)
            return unless entity&.valid?

            @cell_space_change_snapshots[entity_observer_key(entity)] = snapshot || build_cell_space_change_snapshot(entity)
          rescue StandardError
            nil
          end

          def cell_space_change_snapshot_for(entity)
            @cell_space_change_snapshots[entity_observer_key(entity)]
          rescue StandardError
            nil
          end

          def build_cell_space_change_snapshot(entity)
            {
              name: entity.name.to_s,
              transformation: entity.transformation.to_a,
              cell_type: indoor_attribute(entity, 'cell_type').to_s,
              category_code: indoor_attribute(entity, 'category_code').to_s,
              category_label: indoor_attribute(entity, 'category_label').to_s,
              category_code_space: indoor_attribute(entity, 'category_code_space').to_s,
              category_standard: indoor_attribute(entity, 'category_standard').to_s
            }
          end

          def changed_cell_space_snapshot_fields(previous_snapshot, current_snapshot)
            current_snapshot.keys.select do |key|
              snapshot_field_changed?(key, previous_snapshot[key], current_snapshot[key])
            end
          end

          def snapshot_field_changed?(key, previous_value, current_value)
            if key == :transformation
              return true if previous_value.nil? || current_value.nil?

              previous_value.each_with_index.any? do |value, index|
                (value - current_value[index]).abs > 0.000001
              end
            else
              previous_value != current_value
            end
          end

          def cell_space_change_kind(changed_fields)
            return :cell_space_type if (changed_fields & %i[cell_type category_code category_label category_code_space category_standard]).any?
            return :name if changed_fields.include?(:name)
            return :transform if changed_fields.include?(:transformation)

            :etc
          end

          def log_cell_space_change(entity, change_kind, changed_fields, previous_snapshot, current_snapshot)
            puts "[IndoorGML] CellSpace change classified kind=#{change_kind} entity_id=#{entity.entityID} name=#{entity.name} fields=#{changed_fields.join(',')}"
            changed_fields.each do |field|
              puts "[IndoorGML]   #{field}: #{snapshot_log_value(previous_snapshot&.[](field))} -> #{snapshot_log_value(current_snapshot&.[](field))}"
            end
          end

          def snapshot_log_value(value)
            return 'nil' if value.nil?
            return transform_log_value(value) if value.is_a?(Array) && value.length == 16

            value.inspect
          end

          def transform_log_value(values)
            translation = values.values_at(12, 13, 14).map { |value| format('%.6f', value) }
            axes = values.values_at(0, 5, 10).map { |value| format('%.6f', value) }
            "translation=[#{translation.join(',')}] axes_diag=[#{axes.join(',')}]"
          end

          def name_cell_space_entity(cell_space)
            expected_name = "[#{CellSpaceType.label(cell_space.cell_type)}:#{cell_space.category_code}]-#{cell_space.id}"
            return if cell_space.sketchup_group.name == expected_name
            with_unlocked(cell_space.sketchup_group) do
              cell_space.sketchup_group.name = expected_name
            end
            @scene_group_guard.track(cell_space.sketchup_group, expected_name)
          end

          def apply_cell_space_material(cell_space)
            group = cell_space.sketchup_group
            text_material = Utils::Materials.cell_space_text(cell_space.cell_type, cell_space.category_code)

            with_unlocked(group) do
              group.material = nil if group.respond_to?(:material=)
              return if text_material.nil?

              group.entities.grep(Sketchup::Face) do |face|
                apply_cell_space_face_material(face, text_material)
              end
            end
          end

          def apply_cell_space_face_material(face, material)
            begin
              face.material = material
              face.back_material = material if face.respond_to?(:back_material=)
              position_cell_space_text_material(face, material) if material.texture
            rescue StandardError => e
              puts "[IndoorGML] CellSpace face material failed: #{e.class}: #{e.message}"
            end
          end

          def position_cell_space_text_material(face, material)
            axes = cell_space_text_axes(face)
            return if axes.nil?

            u_axis, v_axis = axes
            origin = face.bounds.center
            projected = face.vertices.map do |vertex|
              vector = origin.vector_to(vertex.position)
              [vector.dot(u_axis), vector.dot(v_axis)]
            end
            min_u, max_u = projected.map(&:first).minmax
            min_v, max_v = projected.map(&:last).minmax
            width = max_u - min_u
            height = max_v - min_v
            return if width <= 0.001 || height <= 0.001

            corners = [
              point_on_face_plane(origin, u_axis, v_axis, min_u, min_v),
              point_on_face_plane(origin, u_axis, v_axis, max_u, min_v),
              point_on_face_plane(origin, u_axis, v_axis, max_u, max_v),
              point_on_face_plane(origin, u_axis, v_axis, min_u, max_v)
            ]
            uv_points = [
              Geom::Point3d.new(0.0, 0.0, 0.0),
              Geom::Point3d.new(1.0, 0.0, 0.0),
              Geom::Point3d.new(1.0, 1.0, 0.0),
              Geom::Point3d.new(0.0, 1.0, 0.0)
            ]

            face.position_material(material, corners.zip(uv_points).flatten, true)
            face.position_material(material, corners.zip(uv_points).flatten, false)
          end

          def point_on_face_plane(origin, u_axis, v_axis, u, v)
            Geom::Point3d.new(
              origin.x + (u_axis.x * u) + (v_axis.x * v),
              origin.y + (u_axis.y * u) + (v_axis.y * v),
              origin.z + (u_axis.z * u) + (v_axis.z * v)
            )
          end

          def cell_space_text_axes(face)
            normal = face.normal
            longest_edge = face.edges.max_by(&:length)
            return nil if longest_edge.nil?

            u_axis = longest_edge.start.position.vector_to(longest_edge.end.position)
            return nil if u_axis.length <= 0.001

            u_axis.normalize!
            v_axis = normal.cross(u_axis)
            return nil if v_axis.length <= 0.001

            v_axis.normalize!
            if v_axis.dot(Z_AXIS) < 0.0
              u_axis.reverse!
              v_axis.reverse!
            end
            [u_axis, v_axis]
          end

          def register_state(state)
            @feature_registry.add_state(state)
          end

          def unregister_cell_space(cell_space)
            return if cell_space.nil?

            @feature_registry.remove_cell_space(cell_space)
            delete_entity_observer_key(@cell_space_observed_ids, cell_space.sketchup_group)
          end

          def unregister_state(state)
            return if state.nil?

            @feature_registry.remove_state(state)
          end

          def update_state_position(state, local_position)
            state.update_position(local_position)
            write_state_attributes(state)
          end

          def attach_cell_space_observer(entity)
            attach_entity_observer(entity, @cell_space_observer, @cell_space_observed_ids)
          end

          def track_cell_space_entity(entity)
            @primal_entities_observer.track_entity(entity) if @primal_entities_observer && entity&.valid?
          end

          def attach_entity_observer(entity, observer, observed_ids)
            begin
              return unless entity&.valid? && observer

              key = entity_observer_key(entity)
              return if observed_ids[key]

              attached = entity.add_observer(observer)
              puts "[IndoorGML] #{observer.class} attached=#{attached} entity_id=#{entity.entityID}"
              observed_ids[key] = true
            rescue StandardError => e
              puts "[IndoorGML] Observer attach failed: #{e.class}: #{e.message}"
            end
          end
        end
      end
    end
  end
end
