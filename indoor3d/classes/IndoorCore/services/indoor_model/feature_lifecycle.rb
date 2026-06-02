# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module FeatureLifecycle
          def convert_group_to_cell_space(sketchup_group, cell_type = CellSpaceType::GENERAL)
            raise ArgumentError, 'Group is already converted to CellSpace' if converted_group?(sketchup_group)

            ensure_space_features_groups
            cell_group = place_cell_group(sketchup_group)
            recenter_cell_space_geometry(cell_group)
            cell_space = CellSpace.new(cell_group, cell_type)
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

          def change_cell_space_type(sketchup_group, cell_type)
            cell_space = find_cell_space_for_entity(sketchup_group)
            raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
            raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?

            sync do
              remove_cell_space_from_type_runtime_lists(cell_space)
              cell_space.cell_type = cell_type
              update_cell_space_type_runtime_lists(cell_space)
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
              return if @syncing || @erasing

              cell_space = find_cell_space_for_entity(entity)
              cell_space = refresh_and_find_cell_space(entity) if stale_cell_space_runtime?(cell_space, entity)
              return if cell_space.nil? || !cell_space.valid?

              sync do
                state = cell_space.duality_state
                unless state&.valid?
                  cell_space = refresh_and_find_cell_space(entity)
                  state = cell_space&.duality_state
                end
                if state&.valid?
                  local_position = cell_space_local_origin(cell_space)
                  move_state_to_local_position(state, local_position)
                end
                synchronize_adjacency_and_transitions_for_cell_space(cell_space)
              end
            ensure
              lock_indoor_entity(entity)
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
                state = cell_space.duality_state
                unless state&.valid?
                  cell_space = refresh_and_find_cell_space(entity)
                  state = cell_space&.duality_state
                end
                if state&.valid?
                  local_position = cell_space_local_origin(cell_space)
                  move_state_to_local_position(state, local_position)
                end
                synchronize_adjacency_and_transitions_for_cell_space(cell_space)
              end
            ensure
              lock_indoor_entity(entity)
            end
          end

          def state_changed(entity)
            begin
              return if @syncing || @erasing

              state = find_state_for_entity(entity)
              state = refresh_and_find_state(entity) if stale_state_runtime?(state, entity)
              return if state.nil? || !state.valid?

              sync do
                cell_space = state.duality_cell
                local_position = state_local_position(state)
                update_state_position(state, local_position)
                move_cell_space_to_local_position(cell_space, local_position) if cell_space&.valid?
                synchronize_adjacency_and_transitions_for_cell_space(cell_space) if cell_space&.valid?
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

          def state_erased(entity)
            return if @erasing

            state = find_state_for_entity(entity)
            erase_state(state, erase_sketchup_instance: false)
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

          def erase_state(state, erase_sketchup_instance: true)
            return if state.nil?

            erase_guard do
              cell_space = state.duality_cell
              erase_transitions_for_state(state)
              unlock_indoor_entity(cell_space.sketchup_group) if cell_space&.valid?
              cell_space.erase! if cell_space&.valid?
              state.erase! if erase_sketchup_instance && state.valid?
              unregister_cell_space(cell_space)
              unregister_state(state)
              erase_adjacency_for_cell_space(cell_space)
            end
          end

          private

          def register_cell_space(cell_space)
            @feature_registry.add_cell_space(cell_space)
            attach_cell_space_observer(cell_space.sketchup_group)
            lock_indoor_entity(cell_space.sketchup_group)
          end

          def name_cell_space_entity(cell_space)
            with_unlocked(cell_space.sketchup_group) do
              cell_space.sketchup_group.name = "[#{CellSpaceType.label(cell_space.cell_type)}]-#{cell_space.id}"
            end
          end

          def apply_cell_space_material(cell_space)
            material = Utils::Materials.cell_space(cell_space.cell_type)
            text_material = Utils::Materials.cell_space_text(cell_space.cell_type)
            with_unlocked(cell_space.sketchup_group) do
              cell_space.sketchup_group.material = material
              cell_space.sketchup_group.entities.each do |entity|
                apply_cell_space_face_material(entity, text_material || material) if entity.is_a?(Sketchup::Face)
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

          def update_cell_space_type_runtime_lists(cell_space)
            @feature_registry.add_cell_space_type_reference(cell_space)
          end

          def remove_cell_space_from_type_runtime_lists(cell_space)
            @feature_registry.remove_cell_space_type_reference(cell_space)
          end

          def register_state(state)
            @feature_registry.add_state(state)
          end

          def unregister_cell_space(cell_space)
            return if cell_space.nil?

            @feature_registry.remove_cell_space(cell_space)
            @cell_space_observed_ids.delete(cell_space.sketchup_group.object_id)
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

          def attach_state_observer(entity)
            attach_entity_observer(entity, @state_observer, @state_observed_ids)
          end

          def attach_entity_observer(entity, observer, observed_ids)
            begin
              return unless entity&.valid? && observer

              key = entity.object_id
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
