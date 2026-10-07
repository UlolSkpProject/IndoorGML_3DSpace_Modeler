# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # CellSpace lifecycle context used by batch orchestration.
      #
      # A single CellSpace creation/update only owns entity-local work here.
      # Cross-cutting work such as material application, topology synchronization,
      # lock policy and SpaceFeatures preparation is owned by IndoorModel's batch
      # orchestration below.
      class CellSpaceBatchLifecycleContext < CellSpaceLifecycleContext
        def prepare_cell_group(sketchup_group)
          @place_cell_group.call(sketchup_group)
        end

        def initialize_scene(cell_space, storey: default_storey_name)
          cell_space.set_storey(storey)
          @recenter_cell_space_geometry.call(
            cell_space.sketchup_group,
            fixed_z_offset_from_bottom: @fixed_state_height_offset.call(cell_space),
            defer_center: true
          )
          @name_cell_space_entity.call(cell_space)
        end

        def register_created(cell_space, state, **_options)
          raise ArgumentError, 'CellSpace scale normalization failed' if @register_cell_space.call(cell_space) == false

          @register_state.call(state)
          @write_attributes.call(cell_space)
          @track_cell_space_entity.call(cell_space.sketchup_group)
        end

        def persist_type_change(cell_space)
          @name_cell_space_entity.call(cell_space)
          @write_cell_space_attributes.call(cell_space)
        end
      end

      # Local Grid keeps its coordinate-preparation policy while following the
      # same entity-local lifecycle boundary as the standard context.
      class CellSpaceBatchLocalGridContext < CellSpaceLifecycleLocalGridContext
        def prepare_cell_group(sketchup_group)
          @place_cell_group.call(sketchup_group)
        end

        def initialize_scene(cell_space, storey: default_storey_name)
          cell_space.set_storey(storey)
          @coordinate_preparer.call(cell_space)
          @name_cell_space_entity.call(cell_space)
        end

        def register_created(cell_space, state, **_options)
          raise ArgumentError, 'CellSpace scale normalization failed' if @register_cell_space.call(cell_space) == false

          @register_state.call(state)
          @write_attributes.call(cell_space)
          @track_cell_space_entity.call(cell_space.sketchup_group)
        end

        def persist_type_change(cell_space)
          @name_cell_space_entity.call(cell_space)
          @write_cell_space_attributes.call(cell_space)
        end
      end

      class IndoorModel
        module CellSpaceBatchLifecycle
          # Public single-create compatibility entrypoint. A single source is now
          # just a batch of size one, so single and bulk creation share ordering.
          def convert_single_group_to_cell_space(
            sketchup_group,
            cell_type = CellSpaceType::GENERAL,
            category_code = nil
          )
            create_cell_spaces(
              [
                {
                  source: sketchup_group,
                  cell_type: cell_type,
                  category_code: category_code
                }
              ],
              operation_name: 'IndoorGML Convert Group to CellSpace'
            ).first
          end

          # Creates one or more CellSpaces. Each request can be either a SketchUp
          # source entity or a hash with :source, :cell_type, :category_code,
          # :storey and optional :local_grid.
          def create_cell_spaces(
            requests,
            cell_type: CellSpaceType::GENERAL,
            category_code: nil,
            storey: nil,
            local_grid: false,
            operation_name: 'Create CellSpaces'
          )
            plan = Array(requests).map do |request|
              normalize_cell_space_create_request(
                request,
                cell_type: cell_type,
                category_code: category_code,
                storey: storey,
                local_grid: local_grid
              )
            end
            return [] if plan.empty?

            created = []
            native_state_cells = []
            with_validation_focus_mutation_batch do
              with_bulk_cell_space_conversion do
                with_indoor_model_operation(operation_name, force: true) do
                  prepare_cell_space_batch_environment
                  plan.each do |request|
                    service = request[:local_grid] ?
                      cell_space_lifecycle_service_local_grid :
                      cell_space_lifecycle_service
                    created_cell = service.create_from_group_deferred(
                      request[:source],
                      cell_type: request[:cell_type],
                      category_code: request[:category_code],
                      storey: request[:storey]
                    )
                    created << created_cell
                    native_state_cells << created_cell unless request[:local_grid]
                  end
                  finalize_cell_space_batch(created, state_cells: native_state_cells)
                end
              end
            end
            created
          end

          def convert_cell_space_jobs_bulk(
            jobs,
            fallback_target:,
            original_active_path:,
            preserve_source: nil,
            operation_name: 'Convert Solid Groups to CellSpace',
            activate_root_context: true
          )
            build_batch_conversion_service(
              jobs,
              fallback_target: fallback_target,
              original_active_path: original_active_path,
              preserve_source: preserve_source,
              operation_name: operation_name,
              activate_root_context: activate_root_context,
              local_grid: false
            ).call
          end

          def convert_cell_space_jobs_bulk_local_grid(
            jobs,
            fallback_target:,
            original_active_path:,
            preserve_source: nil,
            operation_name: 'Convert Solid Groups to CellSpace Local Grid',
            activate_root_context: true
          )
            build_batch_conversion_service(
              jobs,
              fallback_target: fallback_target,
              original_active_path: original_active_path,
              preserve_source: preserve_source,
              operation_name: operation_name,
              activate_root_context: activate_root_context,
              local_grid: true
            ).call
          end

          def change_cell_space_type(sketchup_group, cell_type, category_code = nil)
            change_cell_space_types(
              [sketchup_group],
              cell_type,
              category_code,
              operation_name: 'IndoorGML Change CellSpace Type'
            ).first
          end

          # Type changes are planned first, then entity-local state is updated for
          # all targets, followed by one material pass, one topology sync and one
          # lock-policy application.
          def change_cell_space_types(
            sketchup_groups,
            cell_type,
            category_code = nil,
            operation_name: 'Change CellSpace Types'
          )
            plan = Array(sketchup_groups).map do |group|
              cell_space = find_cell_space_for_entity(group)
              raise ArgumentError, 'Selected entity is not a registered CellSpace' if cell_space.nil?
              raise ArgumentError, 'CellSpace is no longer valid' unless cell_space.valid?

              resolved_type, resolved_category = tag_cell_space_type_change_target(
                cell_space,
                cell_type,
                category_code
              )
              {
                cell_space: cell_space,
                cell_type: resolved_type,
                category_code: resolved_category
              }
            end
            return [] if plan.empty?

            changed = []
            with_validation_focus_mutation_batch do
              with_bulk_cell_space_conversion do
                with_indoor_model_operation(operation_name, force: true) do
                  sync do
                    plan.each do |entry|
                      cell_space_lifecycle_service.change_type(
                        entry[:cell_space],
                        cell_type: entry[:cell_type],
                        category_code: entry[:category_code]
                      )
                      changed << entry[:cell_space]
                    end
                    finalize_cell_space_batch(changed)
                  end
                end
              end
            end
            changed
          end

          # Editor selection path now submits the whole selection as one batch.
          def set_selected_cell_space_type(cell_type_label, category_code = nil)
            return false if validation_focus_recheck_running?

            cell_spaces = selected_cell_spaces
            cell_spaces = [@editor_session.editing_cell_space].compact if cell_spaces.empty?
            cell_spaces = cell_spaces.select { |cell_space| cell_space&.valid? }
            return false if cell_spaces.empty?

            cell_type = CellSpaceType.from_label(cell_type_label)
            category_code = nil unless CellSpaceCategory.valid_for_type?(cell_type, category_code)
            change_cell_space_types(
              cell_spaces.map(&:sketchup_group),
              cell_type,
              category_code,
              operation_name: 'Change CellSpace Type and Category'
            )

            model = Sketchup.active_model
            @editor_session.refresh_visibility_filter
            @editor_session.selection_changed
            model.active_view.invalidate if model&.active_view
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Selected CellSpace type update failed: #{e.class}: #{e.message}"
            false
          end

          private

          def cell_space_lifecycle_service
            @cell_space_lifecycle_service ||= CellSpaceLifecycleService.new(
              source_preparer: batch_cell_space_source_preparer,
              context: build_batch_lifecycle_context(CellSpaceBatchLifecycleContext)
            )
          end

          def cell_space_lifecycle_service_local_grid
            @cell_space_lifecycle_service_local_grid ||= CellSpaceLifecycleService.new(
              source_preparer: batch_cell_space_source_preparer,
              context: CellSpaceBatchLocalGridContext.new(
                coordinate_preparer: method(:initialize_cell_space_coordinates_local_grid),
                **batch_lifecycle_callbacks
              )
            )
          end

          def batch_cell_space_source_preparer
            CellSpaceLifecycleSourcePreparer.new(
              converted_group: method(:converted_group?),
              type_resolver: IndoorCore.method(:resolve_cell_space_type_and_category),
              geometry_preparer: Utils::Geometry.method(:prepare_cell_space_source_group!),
              tag_storey_resolver: IndoorCore.method(:tag_cell_space_storey),
              storey_resolver: IndoorCore.method(:resolve_cell_space_storey),
              storey_value_resolver: IndoorCore.method(:resolve_cell_space_storey_value)
            )
          end

          def build_batch_lifecycle_context(context_class)
            context_class.new(**batch_lifecycle_callbacks)
          end

          def batch_lifecycle_callbacks
            {
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
            }
          end

          # Equivalent to ensure_space_features_groups without material mutation.
          # Batch creation calls this once before the first entity is created.
          def prepare_cell_space_batch_environment
            merged = false
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
            refresh_runtime_after_primal_merge if merged
            @primal_group
          end

          def finalize_cell_space_batch(
            cell_spaces,
            synchronize_topology: true,
            apply_lock_policy: true,
            clear_dirty_topology: true,
            state_cells: []
          )
            valid_cell_spaces = Array(cell_spaces).select { |cell_space| cell_space&.valid? }
            return {} if valid_cell_spaces.empty?

            with_native_state_geometry_session(state_cells) do
              apply_cell_space_materials_batch(valid_cell_spaces)
              metrics = synchronize_topology ? synchronize_topology_after_bulk_conversion : {}
              apply_indoor_lock_policy() if apply_lock_policy
              clear_bulk_dirty_topology() if clear_dirty_topology
              metrics || {}
            end
          end

          def with_native_state_geometry_session(state_cells)
            pending = Array(state_cells).select { |cell_space| cell_space&.valid? }.uniq
            return yield if pending.empty?

            unless defined?(NativeAdjacencyBridge) &&
                   NativeAdjacencyBridge.shared_session_supported?
              pending.each { |cell_space| recenter_prepared_cell_space_state_ruby(cell_space) }
              return yield
            end

            pending_by_id = pending.each_with_object({}) { |cell_space, out| out[cell_space.id] = cell_space }
            session_entries = Array(@feature_registry.cell_spaces).uniq.filter_map do |cell_space|
              next unless cell_space&.valid? && cell_space.duality_state&.valid?

              snapshot = Utils::Geometry.adjacency_snapshot(cell_space.sketchup_group)
              next unless snapshot

              { cell_space: cell_space, snapshot: snapshot }
            end

            available_ids = session_entries.each_with_object({}) do |entry, out|
              out[entry[:cell_space].id] = true
            end
            pending.each do |cell_space|
              next if available_ids[cell_space.id]

              recenter_prepared_cell_space_state_ruby(cell_space)
              pending_by_id.delete(cell_space.id)
            end
            return yield if pending_by_id.empty?

            snapshots = session_entries.map { |entry| entry[:snapshot] }
            keys = session_entries.map { |entry| entry[:cell_space].id }
            state_options = session_entries.map do |entry|
              cell_space = entry[:cell_space]
              unless pending_by_id.key?(cell_space.id)
                next({ needs_state: false })
              end

              fixed_offset = fixed_state_height_offset(cell_space)
              fixed_z = native_state_fixed_parent_z(cell_space)
              if !fixed_offset.nil? && fixed_z.nil?
                recenter_prepared_cell_space_state_ruby(cell_space)
                pending_by_id.delete(cell_space.id)
                next({ needs_state: false })
              end

              {
                needs_state: true,
                fixed_z: fixed_z
              }
            end
            return yield if pending_by_id.empty?

            state_progress = native_state_progress_sink
            emit_native_state_progress(
              state_progress,
              event: :stage_start,
              stage: :state_position,
              name: 'State 내부점 계산',
              total: pending_by_id.length,
              message: "State 내부점 계산: 0 / #{pending_by_id.length}"
            )
            last_state_progress = -1

            begin
              NativeAdjacencyBridge.open_geometry_session(
                snapshots,
                keys: keys,
                state_options: state_options
              )
              state_result = NativeAdjacencyBridge.compute_state_from_open_session do |_event, payload|
                current = payload[:current].to_i
                total = payload[:total].to_i
                next if current == last_state_progress

                last_state_progress = current
                emit_native_state_progress(
                  state_progress,
                  event: :stage_progress,
                  stage: :state_position,
                  name: 'State 내부점 계산',
                  total: total,
                  completed: current,
                  message: "State 내부점 계산: #{current} / #{total}"
                )
              end
              state_metrics = Hash(state_result[:metrics])
              emit_native_state_progress(
                state_progress,
                event: :stage_finish,
                stage: :state_position,
                name: 'State 내부점 계산',
                total: pending_by_id.length,
                completed: pending_by_id.length,
                message: 'State 내부점 계산 완료',
                telemetry: {
                  native_success_count: state_metrics[:state_success_count].to_i,
                  volume_centroid_success_count:
                    state_metrics[:state_volume_centroid_success_count].to_i,
                  bvh_count: state_metrics[:state_bvh_count].to_i,
                  duration: state_metrics[:state_duration].to_f
                }
              )
            rescue StandardError => e
              NativeAdjacencyBridge.close_geometry_session
              IndoorCore::Logger.puts(
                "[IndoorGML] Native State batch failed; using Ruby fallback: #{e.class}: #{e.message}"
              ) if defined?(IndoorCore::Logger)
              pending_by_id.each_value do |cell_space|
                recenter_prepared_cell_space_state_ruby(cell_space)
              end
              return yield
            end

            points = Hash(state_result[:points])
            session_entries.each_with_index do |entry, index|
              cell_space = pending_by_id[entry[:cell_space].id]
              next unless cell_space

              coordinates = points[index]
              if coordinates
                begin
                  apply_native_state_parent_point(cell_space, coordinates)
                  next
                rescue StandardError => e
                  IndoorCore::Logger.puts(
                    "[IndoorGML] Native State apply failed for #{cell_space.id}; " \
                    "using Ruby fallback: #{e.class}: #{e.message}"
                  ) if defined?(IndoorCore::Logger)
                end
              end
              recenter_prepared_cell_space_state_ruby(cell_space)
            end

            yield
          ensure
            if defined?(NativeAdjacencyBridge) &&
               NativeAdjacencyBridge.shared_session_active?
              NativeAdjacencyBridge.close_geometry_session
            end
          end

          def native_state_progress_sink
            return nil unless defined?(ProductionProgress::AdjacencyProgressContext)

            ProductionProgress::AdjacencyProgressContext.current
          rescue StandardError
            nil
          end

          def emit_native_state_progress(sink, payload)
            return false unless sink&.respond_to?(:call)

            sink.call(payload.freeze)
          rescue StandardError
            false
          end

          def apply_cell_space_materials_batch(cell_spaces)
            grouped = Array(cell_spaces)
              .select { |cell_space| cell_space&.valid? }
              .group_by { |cell_space| CellSpaceType.label(cell_space.cell_type) }
            return {} if grouped.empty?

            materials = Utils::Materials.ensure_keys(grouped.keys)
            grouped.each do |type_label, typed_cell_spaces|
              material = materials[type_label]
              typed_cell_spaces.each do |cell_space|
                apply_cell_space_material_with_material(cell_space, material)
              end
            end
            materials
          end

          def apply_cell_space_material(cell_space)
            material = Utils::Materials.cell_space(cell_space.cell_type, cell_space.category_code)
            apply_cell_space_material_with_material(cell_space, material)
          end

          def apply_cell_space_material_with_material(cell_space, material)
            group = cell_space.sketchup_group
            if group.respond_to?(:material=) && group.material != material
              group.material = material
            end
            group.entities.grep(Sketchup::Face).each do |face|
              clear_cell_space_face_material(face)
            end
            material
          end

          def clear_cell_space_face_material(face)
            face.material = nil if face.respond_to?(:material=) && !face.material.nil?
            face.back_material = nil if face.respond_to?(:back_material=) && !face.back_material.nil?
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace face material cleanup failed: #{e.class}: #{e.message}"
          end

          def clear_cell_space_materials(group)
            return false unless group&.valid?

            group.material = nil if group.respond_to?(:material=) && !group.material.nil?
            entities = if group.respond_to?(:definition) && group.definition&.valid?
                         group.definition.entities
                       elsif group.respond_to?(:entities)
                         group.entities
                       end
            Array(entities&.grep(Sketchup::Face)).each do |face|
              clear_cell_space_face_material(face)
            end
            true
          end

          def feature_id_in_use?(id, excluding: nil)
            if @feature_registry.respond_to?(:feature_id_in_use?)
              return @feature_registry.feature_id_in_use?(id, excluding: excluding)
            end

            super
          end

          def normalize_cell_space_create_request(request, cell_type:, category_code:, storey:, local_grid:)
            if request.is_a?(Hash)
              source = request[:source]
              return {
                source: source,
                cell_type: request.fetch(:cell_type, cell_type),
                category_code: request.fetch(:category_code, category_code),
                storey: request.fetch(:storey, storey),
                local_grid: request.fetch(:local_grid, local_grid)
              }
            end

            {
              source: request,
              cell_type: cell_type,
              category_code: category_code,
              storey: storey,
              local_grid: local_grid
            }
          end
        end
      end
    end
  end
end
