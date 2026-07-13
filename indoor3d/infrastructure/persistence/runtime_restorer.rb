# frozen_string_literal: true

require 'securerandom'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class RuntimeRestorer
        def initialize(registry:, serializer:, cell_space_registrar:, state_registrar:)
          @registry = registry
          @serializer = serializer
          @cell_space_registrar = cell_space_registrar
          @state_registrar = state_registrar
        end

        def restore(primal_group:, persist_repaired_ids: false)
          @used_feature_ids = {}
          @repaired_cell_spaces = {}
          restore_cell_spaces_from_primal_group(primal_group)
          restore_states_from_cell_spaces
          persist_repaired_ids() if persist_repaired_ids
        end

        private

        def restore_cell_spaces_from_primal_group(primal_group)
          return unless primal_group&.valid?

          indoor_children(primal_group.entities, 'CellSpace').each do |entity|
            cell_space = restore_cell_space(entity)
            next unless cell_space

            registered = @cell_space_registrar.call(cell_space)
            IndoorCore::Logger.puts "[IndoorGML] CellSpace restore skipped: scale normalization failed cell=#{cell_space.id}" if registered == false
          end
        end

        def restore_states_from_cell_spaces
          @registry.cell_spaces.each do |cell_space|
            state = restore_state(cell_space)
            next unless state

            cell_space.restore_duality_state(state)
            @state_registrar.call(state)
          end
        end

        def restore_cell_space(entity)
          original_id = @serializer.attribute(entity, 'id')
          restored_id = unique_feature_id(original_id)
          CellSpace.restore(
            entity,
            CellSpaceType.from_label(@serializer.attribute(entity, 'cell_type')),
            id: restored_id,
            category_code: @serializer.attribute(entity, 'category_code'),
            navigation_class: @serializer.attribute(entity, 'navigation_class'),
            navigation_class_code_space: @serializer.attribute(entity, 'navigation_class_code_space'),
            navigation_function: @serializer.attribute(entity, 'navigation_function'),
            navigation_function_code_space: @serializer.attribute(entity, 'navigation_function_code_space'),
            navigation_usage: @serializer.attribute(entity, 'navigation_usage'),
            navigation_usage_code_space: @serializer.attribute(entity, 'navigation_usage_code_space'),
            storey: @serializer.attribute(entity, 'storey')
          ).tap do |cell_space|
            @repaired_cell_spaces[cell_space] = true if restored_id != original_id.to_s
          end
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace restore failed: #{e.class}: #{e.message}"
          nil
        end

        def restore_state(cell_space)
          original_id = @serializer.attribute(cell_space.sketchup_group, 'duality_state_id')
          restored_id = unique_feature_id(original_id)
          State.restore(
            cell_space,
            nil,
            id: restored_id,
            name: nil
          ).tap do
            @repaired_cell_spaces[cell_space] = true if restored_id != original_id.to_s
          end
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] State restore failed: #{e.class}: #{e.message}"
          nil
        end

        def indoor_children(entities, feature)
          entities.to_a.select do |entity|
            entity&.valid? && @serializer.feature(entity) == feature
          end
        end

        def unique_feature_id(value)
          candidate = value.to_s
          candidate = generated_feature_id if candidate.empty? || @used_feature_ids[candidate]
          @used_feature_ids[candidate] = true
          candidate
        end

        def generated_feature_id
          loop do
            candidate = SecureRandom.hex(8)
            return candidate unless @used_feature_ids[candidate]
          end
        end

        def persist_repaired_ids
          @repaired_cell_spaces.each_key do |cell_space|
            @serializer.write_cell_space(cell_space) if @serializer.respond_to?(:write_cell_space)
          end
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Repaired feature ID persistence failed: #{e.class}: #{e.message}"
        end

      end

    end
  end
end
