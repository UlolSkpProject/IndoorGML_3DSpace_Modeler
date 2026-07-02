# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceLifecycleService
        def initialize(source_preparer:, scene_policy:, repository:, persistence:, topology:, cell_space_class: CellSpace)
          @source_preparer = source_preparer
          @scene_policy = scene_policy
          @repository = repository
          @persistence = persistence
          @topology = topology
          @cell_space_class = cell_space_class
        end

        def create_from_group(sketchup_group, cell_type: CellSpaceType::GENERAL, category_code: nil)
          raise ArgumentError, 'Group is already converted to CellSpace' if @source_preparer.converted?(sketchup_group)

          resolved_cell_type, resolved_category_code = @source_preparer.resolve_type_and_category(
            sketchup_group,
            cell_type,
            category_code
          )
          validation = @source_preparer.prepare!(sketchup_group)
          unless validation[:valid]
            raise ArgumentError, validation[:reason] || 'Invalid CellSpace source geometry'
          end

          @scene_policy.ensure_space_features_groups
          cell_group = @scene_policy.place_cell_group(sketchup_group)
          cell_space = @cell_space_class.new(cell_group, resolved_cell_type, resolved_category_code)
          cell_space.set_storey(@scene_policy.default_storey_name)
          @scene_policy.recenter_cell_space_geometry(
            cell_group,
            fixed_z_offset_from_bottom: @scene_policy.fixed_state_height_offset(cell_space)
          )
          @scene_policy.name_cell_space_entity(cell_space)
          @scene_policy.apply_cell_space_material(cell_space)
          state = cell_space.create_duality_state(nil)

          @repository.register_cell_space(cell_space)
          @repository.register_state(state)
          @persistence.write_attributes(cell_space)
          @scene_policy.track_cell_space_entity(cell_space.sketchup_group)
          @topology.synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          @scene_policy.apply_indoor_lock_policy

          cell_space
        end

        def change_type(cell_space, cell_type:, category_code:)
          raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
          raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?

          cell_space.cell_type = cell_type
          cell_space.set_category(category_code)
          @scene_policy.name_cell_space_entity(cell_space)
          @scene_policy.apply_cell_space_material(cell_space)
          @persistence.write_cell_space_attributes(cell_space)
          @topology.synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          @scene_policy.apply_indoor_lock_policy
          cell_space
        end

        def erase(cell_space, erase_sketchup_group: true)
          return if cell_space.nil?

          state = cell_space.duality_state
          @topology.erase_transitions_for_state(state)
          state.erase! if state&.valid?
          @repository.unregister_state(state)
          cell_space.erase! if erase_sketchup_group && cell_space.valid?
          @repository.unregister_cell_space(cell_space)
          @topology.erase_adjacency_for_cell_space(cell_space)
        end
      end

      class CellSpaceLifecycleSourcePreparer
        def initialize(converted_group:, type_resolver:, geometry_preparer:)
          @converted_group = converted_group
          @type_resolver = type_resolver
          @geometry_preparer = geometry_preparer
        end

        def converted?(sketchup_group)
          @converted_group.call(sketchup_group)
        end

        def resolve_type_and_category(sketchup_group, cell_type, category_code)
          @type_resolver.call(sketchup_group, cell_type, category_code)
        end

        def prepare!(sketchup_group)
          @geometry_preparer.call(sketchup_group)
        end
      end

      class CellSpaceLifecycleScenePolicy
        def initialize(ensure_space_features_groups:, place_cell_group:, default_storey_name:, fixed_state_height_offset:, recenter_cell_space_geometry:, name_cell_space_entity:, apply_cell_space_material:, track_cell_space_entity:, apply_indoor_lock_policy:)
          @ensure_space_features_groups = ensure_space_features_groups
          @place_cell_group = place_cell_group
          @default_storey_name = default_storey_name
          @fixed_state_height_offset = fixed_state_height_offset
          @recenter_cell_space_geometry = recenter_cell_space_geometry
          @name_cell_space_entity = name_cell_space_entity
          @apply_cell_space_material = apply_cell_space_material
          @track_cell_space_entity = track_cell_space_entity
          @apply_indoor_lock_policy = apply_indoor_lock_policy
        end

        def ensure_space_features_groups
          @ensure_space_features_groups.call
        end

        def place_cell_group(sketchup_group)
          @place_cell_group.call(sketchup_group)
        end

        def default_storey_name
          @default_storey_name.call
        end

        def fixed_state_height_offset(cell_space)
          @fixed_state_height_offset.call(cell_space)
        end

        def recenter_cell_space_geometry(cell_group, fixed_z_offset_from_bottom:)
          @recenter_cell_space_geometry.call(cell_group, fixed_z_offset_from_bottom: fixed_z_offset_from_bottom)
        end

        def name_cell_space_entity(cell_space)
          @name_cell_space_entity.call(cell_space)
        end

        def apply_cell_space_material(cell_space)
          @apply_cell_space_material.call(cell_space)
        end

        def track_cell_space_entity(sketchup_group)
          @track_cell_space_entity.call(sketchup_group)
        end

        def apply_indoor_lock_policy
          @apply_indoor_lock_policy.call
        end
      end

      class CellSpaceLifecycleRepository
        def initialize(register_cell_space:, register_state:, unregister_cell_space:, unregister_state:)
          @register_cell_space = register_cell_space
          @register_state = register_state
          @unregister_cell_space = unregister_cell_space
          @unregister_state = unregister_state
        end

        def register_cell_space(cell_space)
          @register_cell_space.call(cell_space)
        end

        def register_state(state)
          @register_state.call(state)
        end

        def unregister_cell_space(cell_space)
          @unregister_cell_space.call(cell_space)
        end

        def unregister_state(state)
          @unregister_state.call(state)
        end
      end

      class CellSpaceLifecyclePersistence
        def initialize(write_attributes:, write_cell_space_attributes:)
          @write_attributes = write_attributes
          @write_cell_space_attributes = write_cell_space_attributes
        end

        def write_attributes(cell_space)
          @write_attributes.call(cell_space)
        end

        def write_cell_space_attributes(cell_space)
          @write_cell_space_attributes.call(cell_space)
        end
      end

      class CellSpaceLifecycleTopologyGateway
        def initialize(synchronize_adjacency_and_transitions_for_cell_space:, erase_transitions_for_state:, erase_adjacency_for_cell_space:)
          @synchronize_adjacency_and_transitions_for_cell_space = synchronize_adjacency_and_transitions_for_cell_space
          @erase_transitions_for_state = erase_transitions_for_state
          @erase_adjacency_for_cell_space = erase_adjacency_for_cell_space
        end

        def synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          @synchronize_adjacency_and_transitions_for_cell_space.call(cell_space)
        end

        def erase_transitions_for_state(state)
          @erase_transitions_for_state.call(state)
        end

        def erase_adjacency_for_cell_space(cell_space)
          @erase_adjacency_for_cell_space.call(cell_space)
        end
      end
    end
  end
end
