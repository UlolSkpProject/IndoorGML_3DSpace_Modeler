# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceLifecycleService
        def initialize(callbacks)
          @callbacks = callbacks
          @cell_space_class = callbacks.key?(:cell_space_class) ? callbacks[:cell_space_class] : CellSpace
        end

        def create_from_group(sketchup_group, cell_type: CellSpaceType::GENERAL, category_code: nil)
          raise ArgumentError, 'Group is already converted to CellSpace' if call(:converted_group?, sketchup_group)

          resolved_cell_type, resolved_category_code = call(
            :resolve_cell_space_type_and_category,
            sketchup_group,
            cell_type,
            category_code
          )
          validation = call(:prepare_cell_space_source_group!, sketchup_group)
          unless validation[:valid]
            raise ArgumentError, validation[:reason] || 'Invalid CellSpace source geometry'
          end

          call(:ensure_space_features_groups)
          cell_group = call(:place_cell_group, sketchup_group)
          cell_space = @cell_space_class.new(cell_group, resolved_cell_type, resolved_category_code)
          cell_space.set_storey(call(:default_storey_name))
          call(
            :recenter_cell_space_geometry,
            cell_group,
            fixed_z_offset_from_bottom: call(:fixed_state_height_offset, cell_space)
          )
          call(:name_cell_space_entity, cell_space)
          call(:apply_cell_space_material, cell_space)
          state = cell_space.create_duality_state(nil)

          call(:register_cell_space, cell_space)
          call(:register_state, state)
          call(:write_attributes, cell_space)
          call(:track_cell_space_entity, cell_space.sketchup_group)
          call(:synchronize_adjacency_and_transitions_for_cell_space, cell_space)
          call(:apply_indoor_lock_policy)

          cell_space
        end

        def change_type(cell_space, cell_type:, category_code:)
          raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
          raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?

          cell_space.cell_type = cell_type
          cell_space.set_category(category_code)
          call(:name_cell_space_entity, cell_space)
          call(:apply_cell_space_material, cell_space)
          call(:write_cell_space_attributes, cell_space)
          call(:synchronize_adjacency_and_transitions_for_cell_space, cell_space)
          call(:apply_indoor_lock_policy)
          cell_space
        end

        def erase(cell_space, erase_sketchup_group: true)
          return if cell_space.nil?

          state = cell_space.duality_state
          call(:erase_transitions_for_state, state)
          state.erase! if state&.valid?
          call(:unregister_state, state)
          cell_space.erase! if erase_sketchup_group && cell_space.valid?
          call(:unregister_cell_space, cell_space)
          call(:erase_adjacency_for_cell_space, cell_space)
        end

        private

        def call(name, *args, **kwargs)
          callback = @callbacks.fetch(name)
          kwargs.empty? ? callback.call(*args) : callback.call(*args, **kwargs)
        end
      end
    end
  end
end
