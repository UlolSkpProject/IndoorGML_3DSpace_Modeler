# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module ObserverRouting
          def space_features_changed(entity)
            return false if observer_routing_suppressed? || guard_active?(:@constraining_space_features) || guard_active?(:@erasing) || @finishing_editing
            return false unless entity&.valid?
            return true if restore_validation_primal_group_lock(entity)

            @classified_space_features_transform_change = nil
            change_kind = classify_space_features_change(entity)
            return false if change_kind.nil?

            case change_kind
            when :name
              handle_space_features_name_changed(entity)
            when :transform
              change = @classified_space_features_transform_change || {}
              handle_space_features_transform_changed(
                entity,
                previous_snapshot: change[:previous],
                current_snapshot: change[:current]
              )
            else
              handle_space_features_etc_changed(entity)
            end
          ensure
            @classified_space_features_transform_change = nil
          end

          def restore_validation_primal_group_lock(entity)
            return false unless defined?(
              IndoorGmlConverter::Val3dityPrimalGroupLock
            )

            lock = IndoorGmlConverter::Val3dityPrimalGroupLock
            return false unless lock.active_for?(entity)
            return false if entity.locked? == true

            with_transparent_space_features_operation(
              'IndoorGML Restore Validation Primal Lock'
            ) do
              with_guard_flag(:@constraining_space_features) do
                entity.locked = true
              end
            end
            restored = entity.locked? == true
            IndoorCore::Logger.puts(
              "[IndoorGML] Validation primal_group lock restored: " \
              "entity_id=#{entity.entityID}"
            ) if restored
            restored
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Validation primal_group relock failed: " \
              "#{e.class}: #{e.message}"
            )
            false
          end
          private :restore_validation_primal_group_lock

          def observer_routing_suppressed?
            guard_active?(:@syncing) ||
              guard_active?(:@bulk_cell_space_conversion) ||
              guard_active?(:@merging_space_features) ||
              guard_active?(:@transaction_reconciliation) ||
              (respond_to?(:transaction_replay_pending?, true) && transaction_replay_pending?)
          end

          def classify_space_features_change(entity)
            previous_snapshot = space_features_change_snapshot_for(entity)
            current_snapshot = build_space_features_change_snapshot(entity)
            if previous_snapshot.nil?
              expected_name = expected_space_features_name_for(entity)
              if expected_name && current_snapshot[:name] != expected_name
                remember_space_features_change_snapshot(entity, current_snapshot)
                log_space_features_change(entity, :name, [:name], { name: expected_name }, current_snapshot)
                return :name
              end

              if scaled_transform_values?(current_snapshot[:transformation])
                @classified_space_features_transform_change = {
                  previous: previous_snapshot,
                  current: current_snapshot
                }
                log_space_features_change(entity, :transform, [:transformation], previous_snapshot, current_snapshot)
                return :transform
              end

              remember_space_features_change_snapshot(entity, current_snapshot)
              log_space_features_change(entity, :initial_snapshot, [], previous_snapshot, current_snapshot)
              return nil
            end

            changed_fields = changed_space_features_snapshot_fields(previous_snapshot, current_snapshot)
            return nil if changed_fields.empty?

            remember_space_features_scale_revert_transform(entity, previous_snapshot, current_snapshot) if changed_fields.include?(:transformation)

            change_kind =
              if changed_fields.include?(:name)
                :name
              elsif changed_fields.include?(:transformation)
                @classified_space_features_transform_change = {
                  previous: previous_snapshot,
                  current: current_snapshot
                }
                :transform
              else
                :etc
              end
            log_space_features_change(entity, change_kind, changed_fields, previous_snapshot, current_snapshot)
            change_kind
          end

          def handle_space_features_name_changed(entity)
            with_transparent_space_features_operation('IndoorGML SpaceFeatures Name Change') do
              with_guard_flag(:@constraining_space_features) do
                enforce_space_features_constraints()
              end
            end
            remember_space_features_change_snapshot(entity)
            true
          end

          def handle_space_features_transform_changed(entity, previous_snapshot: nil, current_snapshot: nil)
            return true if reject_scaled_space_features_transform(entity)

            if primal_axes_rebased?(previous_snapshot, current_snapshot)
              rebuilt = rebuild_transitions_for_primal_axes_change
              clear_overlay_transition_cache
              IndoorCore::Logger.puts(
                "[IndoorGML] Primal axes rebased: rebuilt #{rebuilt} Transition curves"
              )
            else
              invalidate_overlay_primal_render_transform
            end
            remember_space_features_change_snapshot(entity)
            Sketchup.active_model&.active_view&.invalidate
            true
          end

          # SketchUp reports both a rigid Primal move and Change Axes as an
          # instance transformation change. Change Axes additionally applies
          # the inverse frame delta to direct children so their World frames
          # stay fixed. Detect that invariant before deciding which Transition
          # cache layer is safe to retain.
          def primal_axes_rebased?(previous_snapshot, current_snapshot)
            previous_values = previous_snapshot&.[](:transformation)
            current_values = current_snapshot&.[](:transformation)
            return false unless transformation_values?(previous_values) &&
                                transformation_values?(current_values)

            previous_root = Geom::Transformation.new(previous_values)
            current_root = Geom::Transformation.new(current_values)
            root_rebase = current_root.inverse * previous_root

            frame_result = primal_axes_cell_frame_evidence(
              previous_root,
              current_root,
              root_rebase
            )
            return true if frame_result == :rebase

            primal_axes_transition_endpoint_evidence(
              previous_root,
              current_root,
              root_rebase
            ) == :rebase
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Primal axes classification failed: #{e.class}: #{e.message}"
            )
            false
          end

          def primal_axes_cell_frame_evidence(previous_root, current_root, root_rebase)
            samples = Array(@cell_spaces).filter_map do |cell_space|
              group = cell_space&.valid_sketchup_group
              next unless group

              previous_values = cell_space_change_snapshot_for(group)&.[](:transformation)
              next unless transformation_values?(previous_values)

              previous_local = Geom::Transformation.new(previous_values)
              current_local = cell_space_root_local_transformation(cell_space)
              next unless current_local.respond_to?(:to_a)

              {
                rebased: transformations_close?(current_local, root_rebase * previous_local) &&
                  transformations_close?(current_root * current_local, previous_root * previous_local),
                unchanged: transformations_close?(current_local, previous_local)
              }
            end
            primal_axes_evidence_result(samples)
          end

          def primal_axes_transition_endpoint_evidence(previous_root, current_root, root_rebase)
            endpoints = {}
            Array(@transitions).each do |transition|
              [[transition&.cell1, transition&.state1_point],
               [transition&.cell2, transition&.state2_point]].each do |cell_space, previous_point|
                next unless cell_space&.valid? && previous_point.is_a?(Geom::Point3d)

                endpoints[cell_space.id.to_s] ||= [cell_space, previous_point]
              end
            end

            samples = endpoints.values.filter_map do |cell_space, previous_point|
              current_local = cell_space_root_local_transformation(cell_space)
              next unless current_local.respond_to?(:origin)

              current_point = current_local.origin
              {
                rebased: points_close?(current_point, previous_point.transform(root_rebase)) &&
                  points_close?(current_point.transform(current_root), previous_point.transform(previous_root)),
                unchanged: points_close?(current_point, previous_point)
              }
            end
            primal_axes_evidence_result(samples)
          end

          def primal_axes_evidence_result(samples)
            evidence = Array(samples)
            return :unknown if evidence.empty?

            rebased = evidence.count { |sample| sample[:rebased] }
            unchanged = evidence.count { |sample| sample[:unchanged] }
            required = [(evidence.length * 0.8).ceil, 1].max
            rebased >= required && rebased > unchanged ? :rebase : :motion
          end

          def rebuild_transitions_for_primal_axes_change
            # Native reference graphs stay CellSpace-local. update_transition
            # reprojects their waypoint anchors with each CellSpace's current
            # Primal-local transform and replaces the transient curve inputs.
            Array(@transitions).count do |transition|
              transition&.valid? && update_transition(transition)
            rescue StandardError => e
              IndoorCore::Logger.puts(
                "[IndoorGML] Primal axes Transition rebuild failed " \
                "transition=#{transition&.id}: #{e.class}: #{e.message}"
              )
              false
            end
          end

          def transformation_values?(values)
            values.is_a?(Array) && values.length == 16 &&
              values.all? { |value| value.is_a?(Numeric) && value.finite? }
          end

          def transformations_close?(first, second)
            first_values = first&.to_a
            second_values = second&.to_a
            return false unless transformation_values?(first_values) &&
                                transformation_values?(second_values)

            first_values.each_index.all? do |index|
              (first_values[index].to_f - second_values[index].to_f).abs <= 0.000001
            end
          end

          def points_close?(first, second)
            return false unless first.is_a?(Geom::Point3d) && second.is_a?(Geom::Point3d)

            first.distance(second) <= 0.001
          end

          def handle_space_features_etc_changed(entity)
            IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures change ignored as etc: entity_id=#{entity.entityID} name=#{entity.name}"
            remember_space_features_change_snapshot(entity)
            false
          end

          def with_transparent_space_features_operation(name)
            with_indoor_model_operation(name, transparent: true) { yield }
          end

          def remember_space_features_change_snapshot(entity, snapshot = nil)
            return unless entity&.valid?

            @space_features_change_snapshots[entity_observer_key(entity)] = snapshot || build_space_features_change_snapshot(entity)
          rescue StandardError
            nil
          end

          def space_features_change_snapshot_for(entity)
            @space_features_change_snapshots[entity_observer_key(entity)]
          rescue StandardError
            nil
          end

          def remember_space_features_scale_revert_transform(entity, previous_snapshot, current_snapshot)
            scale_revert_transforms.delete(entity_observer_key(entity))
            current_transform = current_snapshot&.[](:transformation)
            return unless scaled_transform_values?(current_transform)

            previous_transform = previous_snapshot&.[](:transformation)
            return if scaled_transform_values?(previous_transform)
            return unless previous_transform.is_a?(Array) && previous_transform.length == 16

            scale_revert_transforms[entity_observer_key(entity)] = previous_transform
          rescue StandardError
            nil
          end

          def reject_scaled_space_features_transform(entity)
            return false unless entity&.valid?
            return false unless Utils::Transformation.scaled?(entity.transformation)

            revert_values = scale_revert_transforms.delete(entity_observer_key(entity))
            revert_transform = if revert_values.is_a?(Array) && revert_values.length == 16
                                 Geom::Transformation.new(revert_values)
                               else
                                 Utils::Transformation.unscaled(entity.transformation)
                               end
            unless revert_transform
              IndoorCore::Logger.puts "[IndoorGML] Primal scale rejected but no unscaled transform is available: entity_id=#{entity.entityID}"
              return false
            end

            with_transparent_space_features_operation('IndoorGML Reject Primal Scale') do
              with_guard_flag(:@constraining_space_features) do
                set_group_transformation(entity, revert_transform)
              end
            end
            invalidate_overlay_primal_render_transform
            remember_space_features_change_snapshot(entity)
            Sketchup.active_model&.active_view&.invalidate
            IndoorCore::Logger.puts "[IndoorGML] Primal scale rejected and transform restored: entity_id=#{entity.entityID}"
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Primal scale restore failed: #{e.class}: #{e.message}"
            false
          end

          def scaled_transform_values?(values)
            return false unless values.is_a?(Array) && values.length == 16

            Utils::Transformation.scaled?(Geom::Transformation.new(values))
          rescue StandardError
            false
          end

          def scale_revert_transforms
            @space_features_scale_revert_transforms ||= {}
          end

          def build_space_features_change_snapshot(entity)
            {
              name: entity.name.to_s,
              transformation: entity.transformation.to_a
            }
          end

          def changed_space_features_snapshot_fields(previous_snapshot, current_snapshot)
            current_snapshot.keys.select do |key|
              Utils::ChangeSnapshot.field_changed?(key, previous_snapshot[key], current_snapshot[key])
            end
          end

          def log_space_features_change(entity, change_kind, changed_fields, previous_snapshot, current_snapshot)
            IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures change classified kind=#{change_kind} entity_id=#{entity.entityID} name=#{entity.name} fields=#{changed_fields.join(',')}"
            changed_fields.each do |field|
              IndoorCore::Logger.puts "[IndoorGML]   #{field}: #{Utils::ChangeSnapshot.log_value(previous_snapshot&.[](field))} -> #{Utils::ChangeSnapshot.log_value(current_snapshot&.[](field))}"
            end
          end

          def root_entity_added(entity)
            return if observer_routing_suppressed? || @relocating_entity
            return unless indoor_gml_entity?(entity)

            feature = indoor_feature(entity)
            if space_features_feature?(feature)
              with_indoor_model_operation('IndoorGML SpaceFeatures Restore', transparent: true) do
                register_space_features_entity(entity, feature)
              end
              return
            end

            ensure_space_features_groups(transparent: true)
            case feature
            when 'CellSpace'
              relocate_indoor_entity(entity, @primal_group.entities, @primal_group, transparent: true)
            end
          end

          def primal_entity_added(entity)
            return if observer_routing_suppressed? || @relocating_entity
            unless indoor_gml_entity?(entity)
              return
            end

            ensure_space_features_groups(transparent: true)
            if indoor_feature(entity) == 'CellSpace'
              with_indoor_model_operation('IndoorGML Primal CellSpace Added', transparent: true) do
                if duplicate_cell_space_identity?(entity)
                  next if make_cell_space_copy_independent(entity)

                  next
                end

                cell_space = find_cell_space_for_entity(entity)
                attach_cell_space_observer(entity)
                if stale_cell_space_runtime?(cell_space, entity)
                  IndoorCore::Logger.puts '[IndoorGML] CellSpace runtime stale. Refreshing runtime data.'
                  refresh_runtime_data
                elsif cell_space
                  synchronize_adjacency_and_transitions_for_cell_space(cell_space)
                else
                  IndoorCore::Logger.puts '[IndoorGML] CellSpace runtime data missing. Refresh is required.'
                end
              end
            else
              relocate_indoor_entity(entity, Sketchup.active_model.entities, transparent: true)
            end
          end

          def primal_entity_removed(entity_id)
            return if observer_routing_suppressed? || @erasing || @relocating_entity

            cell_space = @feature_registry.find_cell_space_by_removed_entity_id(entity_id)
            IndoorCore::Logger.puts "[IndoorGML] Primal entity removed: entity_id=#{entity_id} cell_space=#{cell_space&.id || 'missing'}"
            with_indoor_model_operation('IndoorGML Primal CellSpace Removed', transparent: true) do
              erase_cell_space(cell_space, erase_sketchup_group: false) if cell_space
            end
          end

          def space_features_erased(entity)
            begin
              primal_group_erased = entity == @primal_group
              @primal_group = nil if primal_group_erased
              delete_entity_observer_key(@space_features_observed_ids, entity)
              @scene_group_guard.untrack(entity)
              clear_runtime_after_primal_group_erased if primal_group_erased
              true
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] SpaceFeatures erase cleanup failed: #{e.class}: #{e.message}"
              false
            end
          end

          def root_entity_removed(entity_id)
            primal_group = @primal_group
            return false unless primal_group
            return false unless primal_group.entityID == entity_id

            space_features_erased(primal_group)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Root entity removal cleanup failed: #{e.class}: #{e.message}"
            false
          end

          private

          def clear_runtime_after_primal_group_erased
            reset_runtime_collections
            @cell_space_observed_ids.clear
            @cell_space_change_snapshots.clear
            @primal_entities_observer.clear_tracked_entities if @primal_entities_observer.respond_to?(:clear_tracked_entities)
            @root_entities_observer.clear_tracked_entities if @root_entities_observer.respond_to?(:clear_tracked_entities)
            @scene_group_guard.restore!({}) if @scene_group_guard.respond_to?(:restore!)
            if @editor_session&.validation_focus_active?
              @editor_session.clear_validation_focus
            end
            clear_overlay_transition_cache
            Sketchup.active_model&.active_view&.invalidate
            true
          end
        end
      end
    end
  end
end
