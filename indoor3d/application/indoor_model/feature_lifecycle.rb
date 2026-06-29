# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module FeatureLifecycle
          def convert_single_group_to_cell_space(sketchup_group, cell_type = CellSpaceType::GENERAL, category_code = nil)
            with_indoor_model_operation('IndoorGML Convert Group to CellSpace') do
              raise ArgumentError, 'Group is already converted to CellSpace' if converted_group?(sketchup_group)
              cell_type, category_code = IndoorCore.resolve_cell_space_type_and_category(
                sketchup_group,
                cell_type,
                category_code
              )
              validation = Utils::Geometry.prepare_cell_space_source_group!(sketchup_group)
              unless validation[:valid]
                raise ArgumentError, validation[:reason] || 'Invalid CellSpace source geometry'
              end

              ensure_space_features_groups
              cell_group = place_cell_group(sketchup_group)
              cell_space = CellSpace.new(cell_group, cell_type, category_code)
              cell_space.set_storey(default_storey_name)
              recenter_cell_space_geometry(
                cell_group,
                fixed_z_offset_from_bottom: fixed_state_height_offset(cell_space)
              )
              name_cell_space_entity(cell_space)
              apply_cell_space_material(cell_space)
              state = cell_space.create_duality_state(nil)

              register_cell_space(cell_space)
              register_state(state)
              write_attributes(cell_space)
              track_cell_space_entity(cell_space.sketchup_group)
              synchronize_adjacency_and_transitions_for_cell_space(cell_space)
              apply_indoor_lock_policy()

              cell_space
            end
          end

          def auto_create_tagged_cell_spaces_in_primal
            with_indoor_model_operation('IndoorGML Auto Create Tagged CellSpaces') do
              ensure_space_features_groups
              next 0 unless @primal_group&.valid?

              converted_count = 0
              begin
                @relocating_entity = true
                @primal_group.entities.to_a.each do |entity|
                  next unless entity&.valid?
                  next if indoor_feature(entity) == 'CellSpace'

                  if auto_convert_tagged_primal_entity(entity)
                    converted_count += 1
                  elsif convertible_cell_space_container?(entity)
                    converted_count += 1 if auto_convert_direct_tagged_children(entity)
                  end
                end
              ensure
                @relocating_entity = false
              end
              converted_count
            end
          end

          def change_cell_space_type(sketchup_group, cell_type, category_code = nil)
            with_indoor_model_operation('IndoorGML Change CellSpace Type') do
              cell_space = find_cell_space_for_entity(sketchup_group)
              raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
              raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?
              cell_type, category_code = tag_cell_space_type_change_target(cell_space, cell_type, category_code)

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
              when :navigation_semantics
                handle_cell_space_navigation_semantics_changed(cell_space)
              when :storey
                handle_cell_space_storey_changed(cell_space)
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
            return if @syncing || @erasing

            cell_space = find_cell_space_for_entity(entity)
            cell_space = refresh_and_find_cell_space(entity) if stale_cell_space_runtime?(cell_space, entity)
            return if cell_space.nil? || !cell_space.valid?

            with_transparent_cell_space_operation('IndoorGML CellSpace Geometry Close') do
              sync do
                recenter_cell_space_origin(cell_space)
                name_cell_space_entity(cell_space)
                apply_cell_space_material(cell_space)
                state = cell_space.duality_state
                unless state&.valid?
                  cell_space = refresh_and_find_cell_space(entity)
                  state = cell_space&.duality_state
                end
                mark_cell_space_dirty(cell_space)
              end
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
          end

          def cell_space_erased(entity)
            return if @erasing

            cell_space = find_cell_space_for_entity(entity)
            with_transparent_cell_space_operation('IndoorGML CellSpace Erased') do
              erase_cell_space(cell_space, erase_sketchup_group: false)
            end
          end

          def erase_cell_space(cell_space, erase_sketchup_group: true)
            return if cell_space.nil?

            erase_guard do
              state = cell_space.duality_state
              erase_transitions_for_state(state)
              state.erase! if state&.valid?
              unregister_state(state)
              cell_space.erase! if erase_sketchup_group && cell_space.valid?
              unregister_cell_space(cell_space)
              erase_adjacency_for_cell_space(cell_space)
            end
          end

          private

          def tag_cell_space_type_change_target(cell_space, cell_type, category_code)
            target = IndoorCore.tag_cell_space_type_and_category(cell_space.sketchup_group)
            return [cell_type, category_code] if target.nil?

            if cell_space.cell_type == target[0] && cell_space.category_code == target[1]
              raise ArgumentError, 'CellSpace type is locked by Tag and already matches the mapped type'
            end

            target
          end

          def auto_convert_tagged_primal_entity(entity)
            return false unless convertible_cell_space_container?(entity)
            return false if converted_group?(entity)

            target = IndoorCore.tag_cell_space_type_and_category(entity)
            return false unless target
            return false unless solid_container?(entity)

            convert_single_group_to_cell_space(entity, target[0], target[1])
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Tagged CellSpace auto conversion failed: #{e.class}: #{e.message}"
            false
          end

          def auto_convert_direct_tagged_children(container)
            return false unless convertible_cell_space_container?(container)
            return false unless container.respond_to?(:definition) && container.definition&.valid?

            auto_convert_tagged_descendants(container, container.transformation)
          end

          def auto_convert_tagged_descendants(container, accumulated_transformation)
            parent_target = IndoorCore.tag_cell_space_type_and_category(container)
            converted_any = false
            container.definition.entities.to_a.each do |child|
              next unless child&.valid?
              next unless convertible_cell_space_container?(child)
              next if converted_group?(child)

              if solid_container?(child)
                child_target = target_for_tagged_child(child, parent_target)
                converted_any = convert_primal_child_to_cell_space(child, child_target, accumulated_transformation) || converted_any if child_target
              else
                child_transformation = accumulated_transformation * child.transformation
                child_converted = auto_convert_tagged_descendants(child, child_transformation)
                cleanup_empty_tag_source_container(child) if child_converted
                converted_any = child_converted || converted_any
              end
            end
            converted_any
          end

          def target_for_tagged_child(child, parent_target)
            child_target = IndoorCore.tag_cell_space_type_and_category(child)
            return child_target if child_target
            return parent_target unless IndoorCore.tag_assigned?(child)

            nil
          end

          def convert_primal_child_to_cell_space(child, target, parent_transformation)
            copy = @primal_group.entities.add_instance(
              child.definition,
              parent_transformation * child.transformation
            )
            copy = copy.to_group if child.is_a?(Sketchup::Group) && copy.respond_to?(:to_group)
            copy.make_unique if child.is_a?(Sketchup::Group) && copy.respond_to?(:make_unique)
            copy.name = child.name if copy.respond_to?(:name=) && child.respond_to?(:name)
            copy.material = child.material if copy.respond_to?(:material=) && child.respond_to?(:material)
            copy.layer = child.layer if copy.respond_to?(:layer=) && child.respond_to?(:layer)
            copy.visible = child.visible? if copy.respond_to?(:visible=) && child.respond_to?(:visible?)
            convert_single_group_to_cell_space(copy, target[0], target[1])
            child.erase! if child.valid?
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Tagged child CellSpace auto conversion failed: #{e.class}: #{e.message}"
            copy.erase! if copy&.valid? && indoor_feature(copy) != 'CellSpace'
            false
          end

          def cleanup_empty_tag_source_container(entity)
            return false unless cleanup_candidate_source_container?(entity)
            return false unless entity.respond_to?(:definition) && entity.definition&.valid?
            return false unless entity.definition.entities.to_a.empty?

            entity.erase!
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Empty tagged source group cleanup failed: #{e.class}: #{e.message}"
            false
          end

          def cleanup_candidate_source_container?(entity)
            entity&.valid? &&
              convertible_cell_space_container?(entity) &&
              indoor_feature(entity).to_s.empty?
          rescue StandardError
            false
          end

          def convertible_cell_space_container?(entity)
            entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          end

          def solid_container?(entity)
            entity.respond_to?(:manifold?) && entity.manifold?
          rescue StandardError
            false
          end

          def register_cell_space(cell_space)
            @feature_registry.add_cell_space(cell_space)
            ensure_cell_space_unlocked(cell_space.sketchup_group)
            attach_cell_space_observer(cell_space.sketchup_group)
            @scene_group_guard.track(cell_space.sketchup_group, cell_space.sketchup_group.name)
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
          end

          def ensure_cell_space_unlocked(entity)
            return unless entity&.valid?
            return unless entity.respond_to?(:locked=)
            return unless entity.respond_to?(:locked?) && entity.locked?

            entity.locked = false
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace unlock cleanup failed: #{e.class}: #{e.message}"
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
            IndoorCore::Logger.puts "[IndoorGML] Duplicate CellSpace id detected: entity_id=#{entity.entityID} copied_id=#{original_id}"

            with_transparent_cell_space_operation('IndoorGML CellSpace Copy Independence') do
              sync do
                make_unique_performed = make_cell_space_entity_unique(entity)
                cell_space = build_independent_cell_space(entity)
                state = cell_space.create_duality_state(nil)
                ensure_unique_feature_id!(cell_space)
                ensure_unique_feature_id!(state, reserved_ids: [cell_space.id])

                register_cell_space(cell_space)
                register_state(state)
                name_cell_space_entity(cell_space)
                apply_cell_space_material(cell_space)
                write_cell_space_attributes(cell_space)
                synchronize_adjacency_and_transitions_for_cell_space(cell_space)
                remember_cell_space_change_snapshot(entity)

                IndoorCore::Logger.puts "[IndoorGML] CellSpace copy independent: original_id=#{original_id} new_id=#{cell_space.id} original_state_id=#{original_state_id} new_state_id=#{state.id} make_unique=#{make_unique_performed}"
              end
            end

            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace copy independence failed: #{e.class}: #{e.message}"
            false
          end

          def make_cell_space_entity_unique(entity)
            return false unless entity.respond_to?(:make_unique)

            entity.make_unique
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace make_unique failed: #{e.class}: #{e.message}"
            false
          end

          def build_independent_cell_space(entity)
            cell_type = CellSpaceType.from_label(indoor_attribute(entity, 'cell_type'))
            cell_space = CellSpace.new(entity, cell_type, indoor_attribute(entity, 'category_code'))
            if cell_space.cell_type == CellSpaceType::GENERAL
              cell_space.set_navigation_semantics(
                navigation_class: indoor_attribute(entity, 'navigation_class'),
                navigation_function: indoor_attribute(entity, 'navigation_function'),
                navigation_usage: indoor_attribute(entity, 'navigation_usage')
              )
            end
            cell_space.set_storey(indoor_attribute(entity, 'storey'))
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
              sync { mark_cell_space_dirty(cell_space) }
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
                mark_cell_space_dirty(cell_space)
              end
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            true
          end

          def handle_cell_space_navigation_semantics_changed(cell_space)
            with_transparent_cell_space_operation('IndoorGML CellSpace Navigation Semantics Change') do
              sync do
                apply_cell_space_navigation_attributes(cell_space)
                write_cell_space_attributes(cell_space)
              end
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            true
          end

          def handle_cell_space_storey_changed(cell_space)
            with_transparent_cell_space_operation('IndoorGML CellSpace Storey Change') do
              sync do
                cell_space.set_storey(indoor_attribute(cell_space.sketchup_group, 'storey'))
                write_cell_space_attributes(cell_space)
              end
            end
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            true
          end

          def handle_cell_space_etc_changed(cell_space)
            IndoorCore::Logger.puts "[IndoorGML] CellSpace change ignored as etc: entity_id=#{cell_space.sketchup_group.entityID} name=#{cell_space.sketchup_group.name}"
            with_transparent_cell_space_operation('IndoorGML CellSpace Etc Change') {}
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            false
          end

          def apply_cell_space_type_attributes(cell_space)
            entity = cell_space.sketchup_group
            cell_space.cell_type = CellSpaceType.from_label(indoor_attribute(entity, 'cell_type'))
            cell_space.set_category(indoor_attribute(entity, 'category_code'))
          end

          def apply_cell_space_navigation_attributes(cell_space)
            return unless cell_space.cell_type == CellSpaceType::GENERAL

            entity = cell_space.sketchup_group
            cell_space.set_navigation_semantics(
              navigation_class: indoor_attribute(entity, 'navigation_class'),
              navigation_function: indoor_attribute(entity, 'navigation_function'),
              navigation_usage: indoor_attribute(entity, 'navigation_usage')
            )
          end

          def with_transparent_cell_space_operation(name)
            with_indoor_model_operation(name, transparent: true) { yield }
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
            snapshot = {
              name: entity.name.to_s,
              transformation: entity.transformation.to_a,
              cell_type: indoor_attribute(entity, 'cell_type').to_s,
              category_code: indoor_attribute(entity, 'category_code').to_s,
              storey: indoor_attribute(entity, 'storey').to_s
            }
            if CellSpaceType.from_label(snapshot[:cell_type]) == CellSpaceType::GENERAL
              snapshot[:navigation_class] = indoor_attribute(entity, 'navigation_class').to_s
              snapshot[:navigation_function] = indoor_attribute(entity, 'navigation_function').to_s
              snapshot[:navigation_usage] = indoor_attribute(entity, 'navigation_usage').to_s
            end
            snapshot
          end

          def changed_cell_space_snapshot_fields(previous_snapshot, current_snapshot)
            current_snapshot.keys.select do |key|
              Utils::ChangeSnapshot.field_changed?(key, previous_snapshot[key], current_snapshot[key])
            end
          end

          def cell_space_change_kind(changed_fields)
            return :cell_space_type if (changed_fields & %i[cell_type category_code]).any?
            return :navigation_semantics if (changed_fields & %i[navigation_class navigation_function navigation_usage]).any?
            return :storey if changed_fields.include?(:storey)
            return :name if changed_fields.include?(:name)
            return :transform if changed_fields.include?(:transformation)

            :etc
          end

          def log_cell_space_change(entity, change_kind, changed_fields, previous_snapshot, current_snapshot)
            IndoorCore::Logger.puts "[IndoorGML] CellSpace change classified kind=#{change_kind} entity_id=#{entity.entityID} name=#{entity.name} fields=#{changed_fields.join(',')}"
            changed_fields.each do |field|
              IndoorCore::Logger.puts "[IndoorGML]   #{field}: #{Utils::ChangeSnapshot.log_value(previous_snapshot&.[](field))} -> #{Utils::ChangeSnapshot.log_value(current_snapshot&.[](field))}"
            end
          end

          def name_cell_space_entity(cell_space)
            expected_name = "[#{CellSpaceType.label(cell_space.cell_type)}:#{cell_space.category_code}]-#{cell_space.id}"
            return if cell_space.sketchup_group.name == expected_name

            cell_space.sketchup_group.name = expected_name
            @scene_group_guard.track(cell_space.sketchup_group, expected_name)
          end

          def apply_cell_space_material(cell_space)
            group = cell_space.sketchup_group
            material = Utils::Materials.cell_space(cell_space.cell_type, cell_space.category_code)

            group.material = nil if group.respond_to?(:material=)
            return if material.nil?

            group.entities.grep(Sketchup::Face) do |face|
              apply_cell_space_face_material(face, material)
            end
          end

          def apply_cell_space_face_material(face, material)
            begin
              face.material = material
              face.back_material = material if face.respond_to?(:back_material=)
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] CellSpace face material failed: #{e.class}: #{e.message}"
            end
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
              IndoorCore::Logger.puts "[IndoorGML] #{observer.class} attached=#{attached} entity_id=#{entity.entityID}"
              observed_ids[key] = true
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Observer attach failed: #{e.class}: #{e.message}"
            end
          end
        end
      end
    end
  end
end
