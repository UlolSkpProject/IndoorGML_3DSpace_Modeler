# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceLifecycleService
        def initialize(source_preparer:, context:, cell_space_class: CellSpace)
          @source_preparer = source_preparer
          @context = context
          @cell_space_class = cell_space_class
        end

        def create_from_group(sketchup_group, cell_type: CellSpaceType::GENERAL, category_code: nil, storey: nil)
          create_from_group_internal(
            sketchup_group,
            cell_type: cell_type,
            category_code: category_code,
            storey: storey,
            synchronize_adjacency: true,
            apply_lock_policy: true
          )
        end

        def create_from_group_deferred(sketchup_group, cell_type: CellSpaceType::GENERAL, category_code: nil, storey: nil)
          create_from_group_internal(
            sketchup_group,
            cell_type: cell_type,
            category_code: category_code,
            storey: storey,
            synchronize_adjacency: false,
            apply_lock_policy: false
          )
        end

        def create_from_group_internal(sketchup_group, cell_type:, category_code:, storey:, synchronize_adjacency:, apply_lock_policy:)
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

          cell_group = @context.prepare_cell_group(sketchup_group)
          cell_space = @cell_space_class.new(cell_group, resolved_cell_type, resolved_category_code)
          storey = @source_preparer.resolve_storey(
            sketchup_group,
            resolved_cell_type,
            resolved_category_code,
            @context.default_storey_name,
            storey
          )
          @context.initialize_scene(cell_space, storey: storey)
          state = cell_space.create_duality_state(nil)
          @context.register_created(
            cell_space,
            state,
            synchronize_adjacency: synchronize_adjacency,
            apply_lock_policy: apply_lock_policy
          )

          cell_space
        end
        private :create_from_group_internal

        def change_type(cell_space, cell_type:, category_code:)
          raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
          raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?

          cell_space.cell_type = cell_type
          cell_space.set_category(category_code)
          @context.persist_type_change(cell_space)
          cell_space
        end

        def erase(cell_space, erase_sketchup_group: true)
          return if cell_space.nil?

          @context.erase(cell_space, erase_sketchup_group: erase_sketchup_group)
        end
      end

      class CellSpaceLifecycleSourcePreparer
        def initialize(converted_group:, type_resolver:, geometry_preparer:, tag_storey_resolver: nil, storey_resolver: nil, storey_value_resolver: nil)
          @converted_group = converted_group
          @type_resolver = type_resolver
          @geometry_preparer = geometry_preparer
          @tag_storey_resolver = tag_storey_resolver
          @storey_resolver = storey_resolver
          @storey_value_resolver = storey_value_resolver
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

        def resolve_storey(sketchup_group, cell_type, category_code, default_storey, storey_override = nil)
          tag_storey = @tag_storey_resolver&.call(sketchup_group)
          unless tag_storey.to_s.empty?
            return resolve_storey_value(tag_storey, cell_type, category_code, default_storey)
          end

          unless storey_override.to_s.empty?
            return resolve_storey_value(storey_override, cell_type, category_code, default_storey)
          end

          return default_storey unless @storey_resolver

          @storey_resolver.call(sketchup_group, cell_type, category_code, default_storey)
        end

        private

        def resolve_storey_value(storey, cell_type, category_code, default_storey)
          return storey unless @storey_value_resolver

          @storey_value_resolver.call(storey, cell_type, category_code, default_storey)
        end
      end

      class CellSpaceLifecycleContext
        def initialize(ensure_space_features_groups:, place_cell_group:, default_storey_name:, fixed_state_height_offset:, recenter_cell_space_geometry:, name_cell_space_entity:, apply_cell_space_material:, track_cell_space_entity:, apply_indoor_lock_policy:, register_cell_space:, register_state:, unregister_cell_space:, unregister_state:, write_attributes:, write_cell_space_attributes:, synchronize_adjacency_and_transitions_for_cell_space:, erase_transitions_for_state:, erase_adjacency_for_cell_space:)
          @ensure_space_features_groups = ensure_space_features_groups
          @place_cell_group = place_cell_group
          @default_storey_name = default_storey_name
          @fixed_state_height_offset = fixed_state_height_offset
          @recenter_cell_space_geometry = recenter_cell_space_geometry
          @name_cell_space_entity = name_cell_space_entity
          @apply_cell_space_material = apply_cell_space_material
          @track_cell_space_entity = track_cell_space_entity
          @apply_indoor_lock_policy = apply_indoor_lock_policy
          @register_cell_space = register_cell_space
          @register_state = register_state
          @unregister_cell_space = unregister_cell_space
          @unregister_state = unregister_state
          @write_attributes = write_attributes
          @write_cell_space_attributes = write_cell_space_attributes
          @synchronize_adjacency_and_transitions_for_cell_space = synchronize_adjacency_and_transitions_for_cell_space
          @erase_transitions_for_state = erase_transitions_for_state
          @erase_adjacency_for_cell_space = erase_adjacency_for_cell_space
        end

        def prepare_cell_group(sketchup_group)
          @ensure_space_features_groups.call
          @place_cell_group.call(sketchup_group)
        end

        def default_storey_name
          @default_storey_name.call
        end

        def initialize_scene(cell_space, storey: default_storey_name)
          cell_space.set_storey(storey)
          @recenter_cell_space_geometry.call(
            cell_space.sketchup_group,
            fixed_z_offset_from_bottom: @fixed_state_height_offset.call(cell_space)
          )
          @name_cell_space_entity.call(cell_space)
          @apply_cell_space_material.call(cell_space)
        end

        def register_created(cell_space, state, synchronize_adjacency: true, apply_lock_policy: true)
          raise ArgumentError, 'CellSpace scale normalization failed' if @register_cell_space.call(cell_space) == false

          @register_state.call(state)
          @write_attributes.call(cell_space)
          @track_cell_space_entity.call(cell_space.sketchup_group)
          @synchronize_adjacency_and_transitions_for_cell_space.call(cell_space) if synchronize_adjacency
          @apply_indoor_lock_policy.call if apply_lock_policy
        end

        def persist_type_change(cell_space)
          @name_cell_space_entity.call(cell_space)
          @apply_cell_space_material.call(cell_space)
          @write_cell_space_attributes.call(cell_space)
          if cell_space.navigable?
            @synchronize_adjacency_and_transitions_for_cell_space.call(cell_space)
          else
            @erase_transitions_for_state.call(cell_space.duality_state)
            @erase_adjacency_for_cell_space.call(cell_space)
          end
          @apply_indoor_lock_policy.call
        end

        def erase(cell_space, erase_sketchup_group: true)
          state = cell_space.duality_state
          @erase_transitions_for_state.call(state)
          state.erase! if state&.valid?
          @unregister_state.call(state)
          cell_space.erase! if erase_sketchup_group && cell_space.valid?
          @unregister_cell_space.call(cell_space)
          @erase_adjacency_for_cell_space.call(cell_space)
        end
      end
    end
  end
end
