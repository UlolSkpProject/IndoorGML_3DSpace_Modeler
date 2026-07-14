# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module FeatureLifecycle
          def convert_single_group_to_cell_space(sketchup_group, cell_type = CellSpaceType::GENERAL, category_code = nil)
            with_indoor_model_operation('IndoorGML Convert Group to CellSpace') do
              cell_space_lifecycle_service.create_from_group(
                sketchup_group,
                cell_type: cell_type,
                category_code: category_code
              )
            end
          end

          def convert_cell_space_jobs_bulk(jobs, fallback_target:, original_active_path:, preserve_source: nil, operation_name: 'Convert Solid Groups to CellSpace', activate_root_context: true)
            model = @model || Sketchup.active_model
            active_path = ActivePathController.new(model, logger: IndoorCore::Logger)
            service = BulkCellSpaceConversionService.new(
              model: model,
              jobs: jobs,
              fallback_target: fallback_target,
              target_entities: model.entities,
              converter: proc do |source, cell_type, category_code, storey|
                cell_space_lifecycle_service.create_from_group_deferred(
                  source,
                  cell_type: cell_type,
                  category_code: category_code,
                  storey: storey
                )
              end,
              synchronize_all: proc { topology_coordinator.synchronize_all },
              apply_lock_policy: proc { apply_indoor_lock_policy },
              runtime_snapshot: proc { bulk_conversion_runtime_snapshot },
              runtime_restore: proc { |snapshot| restore_bulk_conversion_runtime(snapshot) },
              apply_guards: proc { |&block| with_bulk_cell_space_conversion(&block) },
              restore_active_path: proc { active_path.restore(original_active_path, close_when_nil: true) },
              activate_root_context: activate_root_context ? proc { active_path.close_to_root } : nil,
              clear_dirty_topology: proc { clear_bulk_dirty_topology },
              logger: IndoorCore::Logger,
              labeler: ConversionMessageFormatter.method(:group_label),
              preserve_source: preserve_source,
              operation_name: operation_name
            )
            service.call
          end

          def change_cell_space_type(sketchup_group, cell_type, category_code = nil)
            with_indoor_model_operation('IndoorGML Change CellSpace Type') do
              cell_space = find_cell_space_for_entity(sketchup_group)
              raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
              raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?
              cell_type, category_code = tag_cell_space_type_change_target(cell_space, cell_type, category_code)

              sync do
                cell_space_lifecycle_service.change_type(
                  cell_space,
                  cell_type: cell_type,
                  category_code: category_code
                )
              end

              cell_space
            end
          end

          def cell_space_changed(entity)
            begin
              return false if observer_routing_suppressed? || guard_active?(:@syncing) || guard_active?(:@erasing)

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
            return if observer_routing_suppressed? || @syncing || @erasing

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
            return if observer_routing_suppressed? || @erasing

            cell_space = find_cell_space_for_entity(entity)
            with_transparent_cell_space_operation('IndoorGML CellSpace Erased') do
              erase_cell_space(cell_space, erase_sketchup_group: false)
            end
          end

          def erase_cell_space(cell_space, erase_sketchup_group: true)
            return if cell_space.nil?

            erase_guard do
              cell_space_lifecycle_service.erase(
                cell_space,
                erase_sketchup_group: erase_sketchup_group
              )
            end
          end

          private

          def cell_space_lifecycle_service
            @cell_space_lifecycle_service ||= CellSpaceLifecycleService.new(
              source_preparer: CellSpaceLifecycleSourcePreparer.new(
                converted_group: method(:converted_group?),
                type_resolver: IndoorCore.method(:resolve_cell_space_type_and_category),
                geometry_preparer: Utils::Geometry.method(:prepare_cell_space_source_group!),
                storey_resolver: IndoorCore.method(:resolve_cell_space_storey),
                storey_value_resolver: IndoorCore.method(:resolve_cell_space_storey_value)
              ),
              context: CellSpaceLifecycleContext.new(
                ensure_space_features_groups: method(:ensure_space_features_groups),
                place_cell_group: method(:place_cell_group),
                default_storey_name: method(:default_storey_name),
                fixed_state_height_offset: method(:fixed_state_height_offset),
                recenter_cell_space_geometry: method(:recenter_cell_space_geometry),
                name_cell_space_entity: method(:name_cell_space_entity),
                apply_cell_space_material: method(:apply_cell_space_material),
                track_cell_space_entity: method(:track_cell_space_entity),
                apply_indoor_lock_policy: method(:apply_indoor_lock_policy),
                register_cell_space: method(:register_cell_space),
                register_state: method(:register_state),
                unregister_cell_space: method(:unregister_cell_space),
                unregister_state: method(:unregister_state),
                write_attributes: method(:write_attributes),
                write_cell_space_attributes: method(:write_cell_space_attributes),
                synchronize_adjacency_and_transitions_for_cell_space: method(:synchronize_adjacency_and_transitions_for_cell_space),
                erase_transitions_for_state: method(:erase_transitions_for_state),
                erase_adjacency_for_cell_space: method(:erase_adjacency_for_cell_space)
              )
            )
          end

          def with_bulk_cell_space_conversion
            with_active_path_enforcement_suspended do
              with_runtime_observer_suppression do
                with_guard_flag(:@bulk_cell_space_conversion) do
                  previous_depth = @indoor_operation_depth.to_i
                  @indoor_operation_depth = previous_depth + 1
                  yield
                ensure
                  @indoor_operation_depth = previous_depth
                end
              end
            end
          end

          def clear_bulk_dirty_topology
            dirty_topology_queue.clear
            dirty_topology_queue.unschedule!
          end

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
            copy = EntityCopyHelper.copy_instance(
              source: child,
              target_entities: @primal_group.entities,
              transformation: parent_transformation * child.transformation,
              convert_to_group: :source_group,
              make_unique: :source_group,
              copy_attributes: [:name, :material, :layer, :visible]
            )
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
            return false unless ensure_cell_space_transform_scale_identity(cell_space)

            @feature_registry.add_cell_space(cell_space)
            attach_cell_space_observer(cell_space.sketchup_group)
            @scene_group_guard.track(cell_space.sketchup_group, cell_space.sketchup_group.name)
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            add_validation_focus_highlight_cell(cell_space) if validation_focus_highlight_tracking_active?
            true
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
            runtime_snapshot = cell_space_copy_independence_runtime_snapshot
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
            restore_cell_space_copy_independence_runtime(runtime_snapshot)
            clear_copied_cell_space_indoor_attributes(entity)
            log_cell_space_copy_independence_failure(e)
            defer_cell_space_copy_independence_failure_warning
            false
          end

          def cell_space_copy_independence_runtime_snapshot
            {
              registry: @feature_registry.snapshot,
              scene_group_guard: @scene_group_guard.respond_to?(:snapshot) ? @scene_group_guard.snapshot : nil,
              cell_space_change_snapshots: Hash(@cell_space_change_snapshots).dup,
              space_features_change_snapshots: Hash(@space_features_change_snapshots).dup,
              topology: topology_coordinator.snapshot,
              cell_space_observed_ids: Hash(@cell_space_observed_ids).dup,
              space_features_observed_ids: Hash(@space_features_observed_ids).dup,
              entities_observed_ids: Hash(@entities_observed_ids).dup,
              state_instances: mutable_instance_snapshot(@states),
              transition_instances: mutable_instance_snapshot(@transitions)
            }
          end

          def restore_cell_space_copy_independence_runtime(snapshot)
            return unless snapshot

            restore_mutable_instances(snapshot[:state_instances])
            restore_mutable_instances(snapshot[:transition_instances])
            @feature_registry.restore!(snapshot[:registry])
            bind_registry_collections
            @scene_group_guard.restore!(snapshot[:scene_group_guard]) if snapshot[:scene_group_guard] && @scene_group_guard.respond_to?(:restore!)
            @cell_space_change_snapshots = Hash(snapshot[:cell_space_change_snapshots]).dup
            @space_features_change_snapshots = Hash(snapshot[:space_features_change_snapshots]).dup
            restore_topology_snapshot(snapshot)
            @cell_space_observed_ids = Hash(snapshot[:cell_space_observed_ids]).dup
            @space_features_observed_ids = Hash(snapshot[:space_features_observed_ids]).dup
            @entities_observed_ids = Hash(snapshot[:entities_observed_ids]).dup
          rescue StandardError => rollback_error
            IndoorCore::Logger.puts "[IndoorGML] CellSpace copy independence rollback failed: #{rollback_error.class}: #{rollback_error.message}"
          end

          def clear_copied_cell_space_indoor_attributes(entity)
            @attribute_serializer.clear_indoor_gml_attributes(entity)
          rescue StandardError => clear_error
            IndoorCore::Logger.puts "[IndoorGML] CellSpace copy attribute cleanup failed: #{clear_error.class}: #{clear_error.message}"
            false
          end

          def log_cell_space_copy_independence_failure(error)
            message = "[IndoorGML] CellSpace copy independence failed: #{error.class}: #{error.message}"
            if IndoorCore::Logger.respond_to?(:error)
              IndoorCore::Logger.error(message)
            else
              IndoorCore::Logger.puts(message)
            end
          end

          def defer_cell_space_copy_independence_failure_warning
            defer_ui_message(
              'CellSpace copy independence failed. The copied entity was kept as a normal SketchUp group so duplicate IndoorGML IDs were not registered.'
            )
          rescue StandardError => notification_error
            IndoorCore::Logger.puts "[IndoorGML] CellSpace copy failure notification failed: #{notification_error.class}: #{notification_error.message}"
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
            if cell_space.navigable?
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
            if previous_snapshot.nil?
              remember_cell_space_change_snapshot(entity, current_snapshot)
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
            return false unless ensure_cell_space_transform_scale_identity(cell_space)

            sync { mark_cell_space_dirty(cell_space) }
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
            @editor_session.refresh_visibility_filter if editing?
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
            @editor_session.refresh_visibility_filter if editing?
            true
          end

          def handle_cell_space_etc_changed(cell_space)
            IndoorCore::Logger.puts "[IndoorGML] CellSpace change ignored as etc: entity_id=#{cell_space.sketchup_group.entityID} name=#{cell_space.sketchup_group.name}"
            with_transparent_cell_space_operation('IndoorGML CellSpace Etc Change') {}
            remember_cell_space_change_snapshot(cell_space.sketchup_group)
            false
          end

          def ensure_cell_space_transform_scale_identity(cell_space)
            entity = cell_space&.sketchup_group
            return false unless entity&.valid?
            return true unless entity.respond_to?(:transformation) && entity.respond_to?(:definition)
            return true unless Utils::Transformation.scaled?(entity.transformation)

            normalize_cell_space_transform_scale(cell_space)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace scale invariant check failed: #{e.class}: #{e.message}"
            false
          end

          def normalize_cell_space_transform_scale(cell_space)
            entity = cell_space&.sketchup_group
            return false unless entity&.valid?
            return false unless entity.respond_to?(:transformation) && entity.respond_to?(:definition)
            return false unless Utils::Transformation.scaled?(entity.transformation)

            baked = false
            with_transparent_cell_space_operation('IndoorGML Normalize CellSpace Scale') do
              sync do
                baked = bake_cell_space_transform_scale(entity)
                recenter_cell_space_origin(cell_space) if baked && fixed_state_height_offset(cell_space)
              end
            end
            baked
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace scale normalize failed: #{e.class}: #{e.message}"
            false
          end

          def bake_cell_space_transform_scale(entity)
            return false unless entity&.valid?
            return false unless entity.definition&.respond_to?(:entities)

            unless ensure_cell_space_entity_unique_for_scale_bake(entity)
              IndoorCore::Logger.puts "[IndoorGML] CellSpace scale normalize skipped: make_unique failed entity_id=#{entity.entityID}"
              return false
            end

            original_transform = entity.transformation
            unscaled_transform = Utils::Transformation.unscaled(original_transform)
            bake_transform = Utils::Transformation.scale_bake_transform(original_transform)
            return false unless unscaled_transform && bake_transform

            set_group_transformation(entity, unscaled_transform)
            entity.definition.entities.transform_entities(
              bake_transform,
              entity.definition.entities.to_a
            )
            IndoorCore::Logger.puts "[IndoorGML] CellSpace scale baked into geometry: entity_id=#{entity.entityID}"
            true
          end

          def ensure_cell_space_entity_unique_for_scale_bake(entity)
            return true unless entity.respond_to?(:make_unique)

            entity.make_unique
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace scale bake make_unique failed: #{e.class}: #{e.message}"
            false
          end

          def apply_cell_space_type_attributes(cell_space)
            entity = cell_space.sketchup_group
            cell_space.cell_type = CellSpaceType.from_label(indoor_attribute(entity, 'cell_type'))
            cell_space.set_category(indoor_attribute(entity, 'category_code'))
          end

          def apply_cell_space_navigation_attributes(cell_space)
            return unless cell_space.navigable?

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
            if CellSpaceType.navigable?(CellSpaceType.from_label(snapshot[:cell_type]))
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

            group.material = material if group.respond_to?(:material=)
            group.entities.grep(Sketchup::Face) do |face|
              clear_cell_space_face_material(face)
            end
          end

          def clear_cell_space_face_material(face)
            face.material = nil if face.respond_to?(:material=)
            face.back_material = nil if face.respond_to?(:back_material=)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace face material cleanup failed: #{e.class}: #{e.message}"
          end

          def register_state(state)
            result = @feature_registry.add_state(state)
            invalidate_overlay_transition_points if respond_to?(:invalidate_overlay_transition_points)
            result
          end

          def unregister_cell_space(cell_space)
            return if cell_space.nil?

            @feature_registry.remove_cell_space(cell_space)
            delete_entity_observer_key(@cell_space_observed_ids, cell_space.sketchup_group)
            remove_validation_focus_highlight_cell(cell_space) if validation_focus_highlight_tracking_active?
          end

          def unregister_state(state)
            return if state.nil?

            result = @feature_registry.remove_state(state)
            invalidate_overlay_transition_points if respond_to?(:invalidate_overlay_transition_points)
            result
          end

          def validation_focus_highlight_tracking_active?
            respond_to?(:validation_focus_highlight_active?) &&
              respond_to?(:add_validation_focus_highlight_cell) &&
              respond_to?(:remove_validation_focus_highlight_cell) &&
              validation_focus_highlight_active? &&
              !guard_active?(:@refreshing_runtime)
          rescue StandardError
            false
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
